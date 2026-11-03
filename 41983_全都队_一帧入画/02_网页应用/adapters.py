"""Board adapters. Image wire implementation is the unmodified R4 release."""
from pathlib import Path
import ipaddress
import re
import secrets
import socket
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "vendor" / "pure"))
if sys.platform == "win32" and sys.version_info[:2] == (3, 10):
    sys.path.insert(0, str(ROOT / "vendor" / "win_py310"))
sys.path.insert(0, str(ROOT / "protocol"))
from a_image_transfer import ImageClient, ImageDesc, TransferError, load_image, pack_rgbx7, save_image
from a_net_wire import Packet, STATUS, DATA, RESULT, ABORT, BEGIN


class Cancelled(TransferError):
    pass


class CancellableSocket:
    """Observe cancellation during long waits without changing retry deadlines."""
    def __init__(self, sock, event, cleanup):
        self.sock, self.event, self.cleanup = sock, event, cleanup

    def __getattr__(self, name):
        return getattr(self.sock, name)

    def check(self):
        if self.event.is_set() and not self.cleanup():
            raise Cancelled("用户取消，正在释放板端会话")

    def sendto(self, *args):
        self.check()
        return self.sock.sendto(*args)

    def recvfrom(self, *args):
        original = self.sock.gettimeout()
        deadline = time.monotonic()+original if original is not None else None
        try:
            while True:
                self.check()
                remaining = deadline-time.monotonic() if deadline is not None else .1
                if remaining <= 0:
                    raise socket.timeout()
                self.sock.settimeout(min(.1, remaining))
                try:
                    return self.sock.recvfrom(*args)
                except socket.timeout:
                    if deadline is not None and time.monotonic() >= deadline:
                        raise
        finally:
            self.sock.settimeout(original)


def validate_config(value):
    if not isinstance(value, dict):
        raise ValueError("连接参数应为对象")
    conf = dict(ip="192.168.0.2", port=40000, bind_ip="192.168.0.3", interface_index=3, serial_port="COM9", baud=115200, transport="packed")
    if set(value) - set(conf):
        raise ValueError("包含未知连接参数")
    conf.update(value)
    for key in ("ip", "bind_ip"):
        conf[key] = str(ipaddress.IPv4Address(conf[key]))
    for key, low, high in (("port", 1, 65535), ("interface_index", 1, 0xffffffff)):
        if conf[key] is None and key == "interface_index":
            continue
        if type(conf[key]) is not int or not low <= conf[key] <= high:
            raise ValueError(f"{key} 超出范围")
    if conf["baud"] != 115200 or type(conf["baud"]) is not int:
        raise ValueError("当前固件使用 115200 波特率")
    if not isinstance(conf["serial_port"], str) or not re.fullmatch(r"COM[1-9][0-9]{0,3}|", conf["serial_port"]):
        raise ValueError("串口请填写 COM9 等端口名，留空可仅用网口")
    if conf["transport"] not in ("packed", "rgb"):
        raise ValueError("传输格式应为 packed 或 rgb")
    return conf


def make_client(config, **kwargs):
    return ImageClient(config["ip"], config["port"], config["bind_ip"], config["interface_index"], **kwargs)


def probe_network(config):
    client = make_client(config, attempts=3, job_timeout=2, transfer_timeout=4)
    began = time.perf_counter()
    try:
        packet = Packet(STATUS, secrets.randbits(32) or 1, client._control(), payload=b"CAP1")
        _, cap = client._ack(packet)
        flags = cap[2]
        return dict(online=True, image_ready=bool(cap[1] & 0x8000 and flags & 7 == 7), packed=bool(flags & 8), capability_bits=flags, rtt_ms=round((time.perf_counter()-began)*1000, 3), checked_at=time.time())
    finally:
        client.close()


def verify_lease_available(config):
    """Acquire an empty upload lease and abort it; never commit or execute NN."""
    client = make_client(config, attempts=3, job_timeout=3, transfer_timeout=8)
    sid = secrets.randbits(32) or 1
    attempted = False
    try:
        probe = Packet(STATUS, sid, client._control(), payload=b"CAP1")
        _, cap = client._ack(probe)
        if not cap[1] & 0x8000 or cap[2] & 7 != 7:
            raise TransferError("板端不支持图片会话")
        desc = ImageDesc(1280, 720, 1, 0, 3840, 2764800, 0)
        attempted = True
        client._ack(Packet(BEGIN, sid, client._control(), total=desc.total, payload=desc.pack()))
        client._ack(Packet(ABORT, sid, client._control()))
        attempted = False
        return {"lease_available": True, "scope": "empty BEGIN/ABORT acknowledged; no image inference"}
    finally:
        if attempted:
            try:
                client._ack(Packet(ABORT, sid, client._control()))
            except Exception:
                pass
        client.close()


class ProgressClient(ImageClient):
    """Adds observation/cancellation at protocol boundaries, keeping R4 intact."""
    def __init__(self, config, event, on_progress):
        super().__init__(config["ip"], config["port"], config["bind_ip"], config["interface_index"], job_timeout=60, transfer_timeout=180)
        self.cancel_event, self.on_progress = event, on_progress
        self.cleaning = False
        self.sock = CancellableSocket(self.sock, event, lambda: self.cleaning)
        self.upload_seen, self.download_seen = set(), set()
        self.upload_bytes = self.download_bytes = 0
        self.result_total = 2764800
        self.last_emit, self.last_phase = 0, None

    def emit(self, force=False):
        phase = self.stats.get("phase", "capability")
        now = time.monotonic()
        if force or phase != self.last_phase or now-self.last_emit >= .12:
            self.last_emit, self.last_phase = now, phase
            self.on_progress(dict(phase=phase, upload_bytes=self.upload_bytes, download_bytes=self.download_bytes, download_total=self.result_total, stats=dict(self.stats)))

    def _exchange(self, packet, accept, *args, **kwargs):
        if packet.op != ABORT:
            if self.cancel_event.is_set():
                raise Cancelled("用户取消，正在释放板端会话")
            self.emit()
        previous = self.cleaning
        self.cleaning = packet.op == ABORT
        try:
            reply = super()._exchange(packet, accept, *args, **kwargs)
        finally:
            self.cleaning = previous
        if reply.op == RESULT and reply.sequence not in self.download_seen:
            self.result_total = reply.total
            self.download_seen.add(reply.sequence)
            self.download_bytes += len(reply.payload)
            self.emit()
        return reply

    def _ack(self, packet, generation=None):
        value = super()._ack(packet, generation)
        if packet.op == DATA and packet.sequence not in self.upload_seen:
            self.upload_seen.add(packet.sequence)
            self.upload_bytes += len(packet.payload)
            self.emit()
        return value


def fields(text):
    values = {}
    for key, value in re.findall(r"([A-Za-z_][A-Za-z_0-9]*)=([^\s;]+)", text):
        if re.fullmatch(r"0x[0-9a-fA-F]+|[0-9]+", value):
            value = int(value, 16 if value.startswith("0x") else 10)
        values[key] = value
    return values


class UART:
    def __init__(self):
        self.port, self.name = None, None
        self.lock = threading.RLock()

    def close(self):
        with self.lock:
            if self.port is not None:
                self.port.close()
            self.port, self.name = None, None

    def open(self, config):
        import serial
        self.close()
        if not config["serial_port"]:
            raise ValueError("未指定串口；网口图片处理不需要串口")
        port = serial.Serial(port=None, baudrate=config["baud"], timeout=.05, write_timeout=1)
        port.dtr = False
        port.rts = False
        port.port = config["serial_port"]
        port.open()
        self.port, self.name = port, config["serial_port"]
        reply = self.command("version")
        if "firmware=C_systemDemo" not in reply:
            self.close()
            raise TransferError("串口没有返回可识别的 C_systemDemo 固件版本")
        return dict(online=True, port=self.name, version=fields(reply).get("firmware"), raw=reply, checked_at=time.time())

    def command(self, command, timeout=3):
        with self.lock:
            if self.port is None:
                raise TransferError("串口未连接")
            try:
                self.port.reset_input_buffer()
                self.port.write((command+"\n").encode("ascii"))
                self.port.flush()
                data = bytearray()
                deadline = time.monotonic()+timeout
                while time.monotonic() < deadline:
                    data.extend(self.port.read(max(1, self.port.in_waiting)))
                    if len(data) > 32768:
                        raise TransferError("串口回复超过限制")
                    if data.endswith(b"C> "):
                        result = data.decode("ascii", errors="replace")
                        if command not in result:
                            raise TransferError("收到不匹配的串口回复；需要重新连接")
                        return result
                raise TransferError("串口回复超时；请确认端口、波特率及 VOFA 已断开")
            except Exception:
                self.close()
                raise

    def health(self):
        replies = {}
        required = {"version": "firmware", "weights status": "crc_verified", "nnstatus": "active_model", "video": "NEW", "source status": "active", "light": "mode", "camera status": "camera_ready", "hdmi status": "pll_lock"}
        for name, key in required.items():
            reply = self.command(name)
            replies[name] = reply
            if re.search(r"(?:^|\n)ERR\b", reply):
                raise TransferError(f"{name}: {reply}")
            if key not in fields(reply):
                raise TransferError(f"{name} 回复字段不完整，请确认固件版本")
        return {"checked_at": time.time(), "raw": replies, "values": {key: fields(value) for key, value in replies.items()}}

    def control(self, request):
        if not isinstance(request, dict):
            raise ValueError("控制指令应为对象")
        kind, value = request.get("type"), request.get("value")
        whitelist = {
            "source": {"camera": "source camera", "hdmi": "source hdmi", "buttons": "source buttons"},
            "style": {**{str(n): f"style {n}" for n in range(5)}, "buttons": "style buttons"},
            "roi": {v: "roi "+v for v in ("full", "center", "left", "right")},
            "light": {v: "light "+v for v in ("auto", "off")},
            "mode": {"auto": "mode auto", "single": "run 1"},
        }
        if set(request) != {"type", "value"} or kind not in whitelist or str(value) not in whitelist[kind]:
            raise ValueError("不支持的控制类型或参数")
        command = whitelist[kind][str(value)]
        response = self.command(command, 12 if value == "single" else 3)
        expected = {"style": r"style_command=OK", "source": r"source (?:request )?accepted", "roi": r"roi_command=OK", "light": r"LIGHT result=0", "mode": r"run_complete=1" if value == "single" else r"command=2 result=OK"}[kind]
        if not re.search(expected, response):
            raise TransferError("板端未接受操作："+response)
        result = dict(accepted=True, confirmed=False, command=command, response=response, checked_at=time.time())
        if kind == "roi" or kind == "style" and value == "buttons":
            result["note"] = "板端已接受区域请求；现有串口没有独立的已显示区域查询，仍需观察屏幕确认" if kind == "roi" else "板端已接受跟随风格开关请求；仍需拨动板上开关确认"
            return result
        deadline = time.monotonic()+2
        while True:
            query = {"style": "nnstatus", "source": "source status", "light": "light", "mode": "ctrl"}[kind]
            raw = self.command(query)
            values = fields(raw)
            confirmed = False
            if kind == "style":
                confirmed = values.get("active_model") == int(value) and values.get("requested_model") == int(value)
            elif kind == "source":
                confirmed = values.get("override") == 0 if value == "buttons" else values.get("active") == value.upper() and values.get("switching") == 0
            elif kind == "light":
                confirmed = values.get("mode") == (3 if value == "auto" else 0)
            elif kind == "mode":
                confirmed = values.get("cpu_mode") == (1 if value == "single" else 0)
            result.update(confirmed=confirmed, verification=raw)
            if confirmed or time.monotonic() >= deadline:
                break
            time.sleep(.08)
        result["note"] = "查询已确认板端状态；不等于测量了显示屏切换时延" if result["confirmed"] else "请求已接受，查询尚未确认生效，请刷新设备状态"
        if value == "single" and kind == "mode":
            result["note"] += "；单帧后保持手动模式，可点击连续运行恢复"
        return result
