"""Offline tests only. UDP endpoint is a loopback identity fixture, NOT an NN."""
from pathlib import Path
import io
import errno
import json
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
import uuid
import zlib
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import adapters as a
import server as s
from compare_results import compare
from a_net_wire import Packet, encode, decode, BEGIN, DATA, COMMIT, STATUS, ABORT, ACK, RESULT, chunks
from a_image_transfer import ImageDesc, ImageClient
from PIL import Image


class Endpoint:
    def __init__(self, delay=0, corrupt=False, silent_commit=False):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(.05)
        self.port = self.sock.getsockname()[1]
        self.stop = False
        self.owner = None
        self.gen = 0
        self.parts = {}
        self.begins = self.commits = self.aborts = 0
        self.delay, self.corrupt, self.silent_commit = delay, corrupt, silent_commit
        self.drop_all = False
        self.errors = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def ack(self, p, code=0, flags=0, detail=0, extra=b""):
        return Packet(ACK, p.session, p.sequence, p.offset, p.total, struct.pack("!4sBBHII", b"ACK1", p.op, code, flags, detail, self.gen)+extra)

    def serve(self):
        try:
            while not self.stop:
                try:
                    raw, peer = self.sock.recvfrom(2048)
                except socket.timeout:
                    continue
                p = decode(raw)
                if self.drop_all:
                    continue
                if p.op == STATUS and p.payload == b"CAP1":
                    q = self.ack(p, flags=0x8000, detail=15)
                elif p.op == BEGIN:
                    if self.owner and self.owner != (p.session, peer):
                        q = self.ack(p, code=1)
                    else:
                        if not self.owner:
                            self.gen += 1
                            self.begins += 1
                            self.parts = {}
                        self.owner = (p.session, peer)
                        self.desc = ImageDesc.unpack(p.payload)
                        q = self.ack(p, detail=1)
                elif p.op == ABORT:
                    if self.owner == (p.session, peer):
                        self.owner = None
                        self.aborts += 1
                    q = self.ack(p)
                elif self.owner != (p.session, peer):
                    q = self.ack(p, code=10)
                elif p.op == DATA:
                    if self.delay:
                        time.sleep(self.delay)
                    self.parts[p.sequence] = p.payload
                    q = self.ack(p)
                elif p.op == COMMIT:
                    if self.silent_commit:
                        continue
                    raw = b"".join(self.parts[i] for i in sorted(self.parts))
                    if zlib.crc32(raw) != self.desc.crc32:
                        q = self.ack(p, code=5)
                    else:
                        self.commits += 1
                        if self.desc.format == 3:
                            rgb = bytearray(self.desc.width*self.desc.height*3)
                            lut = bytes((x << 1) & 255 for x in range(256))
                            for c in range(3):
                                rgb[c::3] = raw[c::4].translate(lut)
                            raw = bytes(rgb)
                        self.output = raw
                        self.result = ImageDesc(self.desc.width, self.desc.height, 1, self.desc.style, self.desc.width*3, len(raw), zlib.crc32(raw))
                        self.results = list(chunks(raw, p.session, RESULT))
                        q = self.ack(p, detail=2)
                elif p.op == STATUS and p.payload == b"\0":
                    q = self.ack(p, flags=1, detail=3, extra=self.result.pack())
                elif p.op == STATUS and p.payload[:1] == b"\1":
                    index = struct.unpack("!I", p.payload[1:])[0]
                    q = self.results[index]
                    if self.corrupt and index == 0:
                        q = Packet(q.op, q.session, q.sequence, q.offset, q.total, bytes([q.payload[0]^1])+q.payload[1:])
                elif p.op == STATUS and p.payload == b"\2":
                    self.owner = None
                    q = self.ack(p)
                else:
                    q = self.ack(p, code=3)
                self.sock.sendto(encode(q), peer)
        except Exception as error:
            self.errors.append(error)

    def close(self):
        self.stop = True
        self.thread.join(3)
        self.sock.close()
        if self.errors:
            raise self.errors[0]


class FakeUART:
    def __init__(self):
        self.buffer = bytearray()
        self.model, self.source, self.mode, self.light = 0, "CAMERA", 0, 3
        self.writes = []
    @property
    def in_waiting(self):
        return len(self.buffer)
    def reset_input_buffer(self):
        self.buffer.clear()
    def write(self, raw):
        command = raw.decode().strip()
        self.writes.append(command)
        if command.startswith("style "):
            if command != "style buttons": self.model = int(command[-1])
            reply = "style_command=OK"
        elif command.startswith("source ") and command != "source status":
            self.source = command.split()[1].upper(); reply = "source accepted; switch at frame boundary"
        elif command.startswith("roi "):
            reply = "roi_command=OK mode=1"
        elif command.startswith("light "):
            self.light = 3 if command.endswith("auto") else 0; reply = "LIGHT result=0"
        elif command == "light":
            reply = f"LIGHT mode={self.light} ready=1 fault=0"
        elif command == "nnstatus":
            reply = f"active_model={self.model} requested_model={self.model} boot_fault=0 compute_fault=0"
        elif command == "source status":
            reply = f"active={self.source} requested={self.source} switching=0 override=1"
        elif command == "mode auto":
            self.mode = 0; reply = "command=2 result=OK"
        elif command == "run 1":
            self.mode = 1; reply = "task=1 result=PASS\nrun_complete=1; CPU mode retained"
        elif command == "ctrl":
            reply = f"cpu_mode={self.mode}"
        elif command == "version":
            reply = "firmware=C_systemDemo fixture-only backend=HW_PROBE"
        elif command == "video":
            reply = "CAP=30 NEW=30 HDMI=60 errors=0x00000000"
        elif command == "camera status":
            reply = "camera_ready=1 error=0 table_index=167"
        elif command == "hdmi status":
            reply = "present=1 pll_lock=1 width=1280 height=720"
        else:
            reply = "weights_result=OK crc_verified=1"
        self.buffer.extend((command+"\r\n"+reply+"\r\nC> ").encode())
    def flush(self):
        pass
    def read(self, n):
        raw = bytes(self.buffer[:n]); del self.buffer[:n]; return raw
    def close(self):
        pass


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = s.App(self.temp.name)
        self.endpoints = []

    def tearDown(self):
        while self.app.active_job:
            if self.app.cancel_event:
                self.app.cancel_event.set()
            time.sleep(.02)
        self.app.uart.close()
        self.app.db.close()
        for endpoint in self.endpoints:
            endpoint.close()
        self.temp.cleanup()

    def endpoint(self, **kwargs):
        endpoint = Endpoint(**kwargs)
        self.endpoints.append(endpoint)
        self.app.config = a.validate_config(dict(ip="127.0.0.1", bind_ip="127.0.0.1", interface_index=None, port=endpoint.port, serial_port=""))
        self.app.network = a.probe_network(self.app.config)
        return endpoint

    def upload(self):
        image = Image.new("RGBA", (24, 16), (37, 79, 123, 128))
        data = io.BytesIO(); image.save(data, format="PNG")
        return self.app.upload(data.getvalue(), "验证图片.png")

    def wait_job(self, ident):
        deadline = time.monotonic()+15
        while time.monotonic() < deadline:
            job = self.app.job(ident)
            if job["status"] in s.TERMINAL and self.app.active_job is None:
                return job
            time.sleep(.02)
        self.fail("worker exceeded test deadline")

    def test_image_roundtrip_progress_and_reference_match(self):
        endpoint = self.endpoint()
        upload = self.upload()
        request = dict(upload_id=upload["id"], slot=4, idempotency_key=uuid.uuid4().hex)
        job = self.app.submit(request)
        same = self.app.submit(request)
        self.assertEqual(job["id"], same["id"])
        with self.assertRaises(s.APIError):
            self.app.control(dict(type="style", value="1"))
        complete = self.wait_job(job["id"])
        self.assertEqual(complete["status"], "completed", complete)
        self.assertEqual(complete["slot"], 4)
        self.assertEqual(endpoint.desc.style, 4)
        self.assertEqual(complete["upload_bytes"], 3686400)
        self.assertEqual(complete["download_bytes"], 2764800)
        raw, desc = a.load_image(Path(self.temp.name)/upload["id"]/"input.png", 4)
        packed, pd = a.pack_rgbx7(raw, desc)
        ref = ImageClient("127.0.0.1", endpoint.port, bind_ip="127.0.0.1")
        try:
            expected, _ = ref.transfer(packed, pd)
        finally:
            ref.close()
        actual, _ = a.load_image(Path(self.temp.name)/job["id"]/"result.png", 4)
        self.assertEqual(actual, expected, "UI adapter must match the shared CLI image client")
        self.assertEqual(endpoint.commits, 2)
        self.assertFalse(self.app.recovery_required)
        self.assertTrue((Path(self.temp.name)/job["id"]/"report.json").is_file())
        with self.assertRaises(s.APIError):
            self.app.submit({**request, "slot": 2})

    def test_five_slot_bounds(self):
        upload = self.upload()
        for slot in (-1, 5, True, "4"):
            with self.subTest(slot=slot), self.assertRaises(ValueError):
                self.app.submit(dict(upload_id=upload["id"], slot=slot, idempotency_key=uuid.uuid4().hex))
        for slot in range(5):
            desc = ImageDesc(1, 1, 1, slot, 3, 3, 0)
            self.assertEqual(ImageDesc.unpack(desc.pack()).style, slot)
        for slot in (-1, 5):
            with self.assertRaises(ValueError):
                ImageDesc(1, 1, 1, slot, 3, 3, 0).validate()

    def test_cancellation_during_upload_and_recovery(self):
        endpoint = self.endpoint(delay=.001)
        upload = self.upload()
        job = self.app.submit(dict(upload_id=upload["id"], slot=1, idempotency_key=uuid.uuid4().hex))
        deadline = time.monotonic()+5
        while not endpoint.parts and time.monotonic() < deadline:
            time.sleep(.01)
        self.app.cancel(job["id"])
        result = self.wait_job(job["id"])
        self.assertEqual(result["status"], "cancelled")
        self.assertTrue(result["stats"]["cancel_confirmed"])
        self.assertTrue(self.app.recovery_required)
        self.assertFalse((Path(self.temp.name)/job["id"]/"result.png").exists())
        self.app.recover()
        self.assertFalse(self.app.recovery_required)
        self.assertIsNone(endpoint.owner)

    def test_cancel_interrupts_silent_commit_wait(self):
        endpoint = self.endpoint(silent_commit=True)
        upload = self.upload()
        job = self.app.submit(dict(upload_id=upload["id"], slot=1, idempotency_key=uuid.uuid4().hex))
        deadline = time.monotonic()+8
        while self.app.job(job["id"])["phase"] != "commit" and time.monotonic() < deadline:
            time.sleep(.01)
        began = time.monotonic()
        self.app.cancel(job["id"])
        result = self.wait_job(job["id"])
        self.assertEqual(result["status"], "cancelled")
        self.assertLess(time.monotonic()-began, 2)
        self.assertTrue(result["stats"]["cancel_confirmed"])

    def test_crc_failure_never_publishes_result(self):
        self.endpoint(corrupt=True)
        upload = self.upload()
        job = self.app.submit(dict(upload_id=upload["id"], slot=2, idempotency_key=uuid.uuid4().hex))
        result = self.wait_job(job["id"])
        self.assertEqual(result["status"], "failed")
        self.assertIn("CRC", result["error"])
        self.assertIsNone(result["result_url"])
        self.assertTrue(self.app.recovery_required)

    def test_transport_timeout_clears_cached_network_ready(self):
        endpoint = self.endpoint()
        endpoint.drop_all = True
        upload = self.upload()
        job = self.app.submit(dict(upload_id=upload["id"], slot=0, idempotency_key=uuid.uuid4().hex))
        result = self.wait_job(job["id"])
        self.assertEqual(result["status"], "failed")
        self.assertFalse(self.app.network["image_ready"])
        self.assertFalse(self.app.network["online"])

    def test_full_disk_keeps_release_proof_and_blocks_new_work(self):
        endpoint = self.endpoint()
        upload = self.upload()
        with patch.object(s, "save_image", side_effect=OSError(errno.ENOSPC, "offline disk-full fixture")):
            job = self.app.submit(dict(upload_id=upload["id"], slot=0, idempotency_key=uuid.uuid4().hex))
            result = self.wait_job(job["id"])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["stats"]["phase"], "done")
        self.assertIsNone(endpoint.owner)
        self.assertTrue(self.app.network["image_ready"])
        self.assertIsNotNone(self.app.storage_error)
        with self.assertRaises(s.APIError):
            self.app.submit(dict(upload_id=upload["id"], slot=0, idempotency_key=uuid.uuid4().hex))

    def test_restart_blocks_uncertain_old_job(self):
        job = dict(id=uuid.uuid4().hex, idempotency_key=uuid.uuid4().hex, status="running", phase="upload", slot=0, upload_id="x")
        self.app.save_job(job)
        other = s.App(self.temp.name)
        try:
            self.assertTrue(other.recovery_required)
            self.assertEqual(other.job(job["id"])["status"], "interrupted")
        finally:
            other.db.close()

    def test_uart_whitelist_verification_and_roi_limit(self):
        uart = a.UART(); fake = FakeUART(); uart.port = fake
        for kind, value in (tuple(("style", str(n)) for n in range(5)) + (("source", "hdmi"), ("light", "off"), ("mode", "single"), ("mode", "auto"))):
            self.assertTrue(uart.control(dict(type=kind, value=value))["confirmed"])
        self.assertFalse(uart.control(dict(type="roi", value="center"))["confirmed"])
        self.assertFalse(uart.control(dict(type="style", value="buttons"))["confirmed"])
        self.assertEqual(uart.health()["values"]["hdmi status"]["width"], 1280)
        before = list(fake.writes)
        for request in (dict(type="style", value="5"), dict(type="style", value="-1"), dict(type="shell", value="x"), dict(type="style", value="1\nmode cpu"), dict(type="source", value="other")):
            with self.assertRaises(ValueError):
                uart.control(request)
        self.assertEqual(before, fake.writes)

    def test_upload_validation_and_preprocess(self):
        with self.assertRaises(Exception):
            self.app.upload(b"this is not an image", "bad.png")
        self.assertFalse(list(Path(self.temp.name).glob("*/upload.bin")))
        upload = self.upload()
        raw, desc = a.load_image(Path(self.temp.name)/upload["id"]/"input.png", 0)
        self.assertEqual((desc.width, desc.height), (1280, 720))
        self.assertTrue(bytes((146, 167, 189)) in raw, "white alpha composition pixel missing")
        self.assertEqual(raw[:3], b"\xff"*3)  # Aspect ratio pad.

    def test_packaged_jpeg_decoder_and_exif_orientation(self):
        image = Image.new("RGB", (24, 16), (90, 130, 210))
        exif = Image.Exif(); exif[274] = 6
        data = io.BytesIO(); image.save(data, format="JPEG", quality=95, exif=exif)
        upload = self.app.upload(data.getvalue(), "相机照片.jpg")
        with Image.open(Path(self.temp.name)/upload["id"]/"input.png") as normalized:
            self.assertEqual(normalized.size, (1280, 720))
            self.assertEqual(normalized.getpixel((250, 360)), (255, 255, 255), "EXIF rotation must make the subject portrait before padding")
            red, green, blue = normalized.getpixel((640, 360))
            self.assertTrue(70 < red < 110 and 110 < green < 150 and blue > 180)

    def test_record_write_failure_does_not_leave_a_phantom_worker(self):
        upload = self.upload()
        self.app.network = dict(image_ready=True, online=True)
        self.app.db.execute("CREATE TRIGGER reject_insert BEFORE INSERT ON jobs BEGIN SELECT RAISE(FAIL, 'offline disk fixture'); END;")
        self.app.db.commit()
        with self.assertRaises(Exception):
            self.app.submit(dict(upload_id=upload["id"], slot=0, idempotency_key=uuid.uuid4().hex))
        self.assertIsNone(self.app.active_job)
        self.assertIsNone(self.app.operation)
        self.assertIsNotNone(self.app.storage_error)
        self.assertEqual(self.app.history()[0]["status"], "failed")

    def test_result_comparison_uses_pixels_and_detects_one_pixel_change(self):
        first = Path(self.temp.name)/"first.png"
        second = Path(self.temp.name)/"second.png"
        image = Image.new("RGB", (9, 7), (20, 70, 120))
        image.save(first, compress_level=0)
        image.save(second, compress_level=9)
        self.assertNotEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(compare(first, second)["status"], "PASS")
        image.putpixel((4, 2), (20, 71, 120)); image.save(second)
        different = compare(first, second)
        self.assertEqual(different["status"], "FAIL")
        self.assertEqual(different["differing_pixels"], 1)
        self.assertEqual(different["max_channel_error"], 1)
        self.assertEqual(different["first_difference"]["x"], 4)
        self.assertEqual(different["first_difference"]["y"], 2)
        image.resize((8, 7)).save(second)
        self.assertFalse(compare(first, second)["same_size"])

    def test_http_authority_input_validation_and_artifacts(self):
        http = s.Server(("127.0.0.1", 0), self.app)
        thread = threading.Thread(target=http.serve_forever, daemon=True); thread.start()
        base = f"http://127.0.0.1:{http.server_port}"
        def request(path, data=None, headers=None):
            req = urllib.request.Request(base+path, data=data, headers=headers or {})
            try:
                with urllib.request.urlopen(req) as response:
                    return response.status, response.read(), response.headers
            except urllib.error.HTTPError as response:
                return response.code, response.read(), response.headers
        try:
            status, body, headers = request("/api/bootstrap")
            self.assertEqual(status, 200)
            token = json.loads(body)["token"]
            self.assertEqual(request("/api/jobs", b"{}")[0], 403)
            self.assertEqual(request("/api/bootstrap", headers={"Host": "evil.example"})[0], 403)
            auth = {"Origin": base, "X-Yizhen-Token": token, "Content-Type": "application/json"}
            self.assertEqual(request("/api/jobs", b"{}", auth)[0], 400)
            self.assertEqual(request("/../server.py")[0], 404)
            self.assertEqual(request("/api/uploads/not-an-id/preview")[0], 404)
            self.assertEqual(request("/api/device/control", b'{"type":"shell","value":"x"}', auth)[0], 409)
            self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        finally:
            http.shutdown(); http.server_close(); thread.join(2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
