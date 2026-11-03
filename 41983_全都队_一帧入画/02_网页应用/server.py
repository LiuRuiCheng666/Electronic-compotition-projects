"""Local FPGA creation app. HTTP stays responsive while the board worker runs."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, unquote
from dataclasses import asdict
import argparse
import errno
import hashlib
import io
import json
import os
import re
import secrets
import sqlite3
import threading
import time
import uuid
import warnings
import webbrowser

from adapters import ROOT, UART, ProgressClient, Cancelled, validate_config, probe_network, verify_lease_available, load_image, pack_rgbx7, save_image
from PIL import Image

MAX_UPLOAD = 20 * 1024 * 1024
Image.MAX_IMAGE_PIXELS = 20_000_000
TERMINAL = {"completed", "failed", "cancelled", "interrupted"}


class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)


def atomic_json(path, value):
    temp = path.with_suffix(".json.tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temp, path)


class App:
    def __init__(self, data_dir, offline_fixture=False):
        self.offline_fixture = offline_fixture
        self.root = Path(data_dir).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.live_jobs = {}
        self.storage_error = None
        self.db = sqlite3.connect(self.root / "records.sqlite3", check_same_thread=False)
        self.db.execute("CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, idem TEXT UNIQUE, payload TEXT)")
        self.db.execute("CREATE TABLE IF NOT EXISTS uploads(id TEXT PRIMARY KEY, payload TEXT)")
        self.db.execute("CREATE TABLE IF NOT EXISTS settings(id TEXT PRIMARY KEY, payload TEXT)")
        self.db.execute("CREATE TABLE IF NOT EXISTS controls(id TEXT PRIMARY KEY, payload TEXT)")
        self.db.commit()
        self.config = validate_config(self.setting("config") or {})
        self.uart = UART()
        self.network = dict(online=False, image_ready=False, error="尚未探测")
        self.serial = dict(online=False, error="尚未连接")
        self.health = None
        self.operation, self.active_job, self.cancel_event = None, None, None
        self.recovery_required = bool(self.setting("recovery_required"))
        for item in self.history(100000):
            if item["status"] not in TERMINAL:
                item.update(status="interrupted", phase="interrupted", error="服务重启，上一任务终态未确认；先检查并释放会话", updated_at=time.time())
                self.save_job(item)
                self.recovery_required = True
        self.set_setting("recovery_required", self.recovery_required)

    def setting(self, key):
        with self.lock:
            row = self.db.execute("SELECT payload FROM settings WHERE id=?", (key,)).fetchone()
            return json.loads(row[0]) if row else None

    def set_setting(self, key, value):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO settings VALUES(?,?)", (key, json.dumps(value, ensure_ascii=False)))
            self.db.commit()

    def save_job(self, value):
        with self.lock:
            payload = json.dumps(value, ensure_ascii=False)
            self.live_jobs[value["id"]] = payload
            try:
                self.db.execute("INSERT OR REPLACE INTO jobs VALUES(?,?,?)", (value["id"], value["idempotency_key"], payload))
                self.db.commit()
            except sqlite3.Error as error:
                self.storage_error = str(error)
                raise

    def job(self, ident):
        with self.lock:
            if ident in self.live_jobs:
                return json.loads(self.live_jobs[ident])
            row = self.db.execute("SELECT payload FROM jobs WHERE id=?", (ident,)).fetchone()
            if not row:
                raise APIError(404, "没有找到任务")
            return json.loads(row[0])

    def history(self, limit=100):
        with self.lock:
            rows = self.db.execute("SELECT payload FROM jobs ORDER BY rowid DESC LIMIT ?", (limit,)).fetchall()
            jobs = {item["id"]: item for item in (json.loads(row[0]) for row in rows)}
            jobs.update({ident: json.loads(payload) for ident, payload in self.live_jobs.items()})
            return sorted(jobs.values(), key=lambda item: item.get("created_at", 0), reverse=True)[:limit]

    def device(self):
        with self.lock:
            return dict(config=dict(self.config), network=dict(self.network), serial=dict(self.serial), health=self.health,
                        operation=self.operation, active_job=self.active_job, recovery_required=self.recovery_required, storage_error=self.storage_error,
                        supports_hdmi_task_osd=None, supports_ethernet_global_control=False,
                        supported_roi_presets=["full", "center", "left", "right"], app_version="4.0.0", offline_fixture=self.offline_fixture)

    def reserve(self, operation, allow_recovery=False):
        with self.lock:
            if self.operation or self.active_job:
                raise APIError(409, "板卡正在执行任务，请等待结束后再操作")
            if self.storage_error and operation in ("image", "control"):
                raise APIError(503, "任务记录存储异常，请先保存现有结果，检查磁盘空间后重启应用")
            if self.recovery_required and not allow_recovery:
                raise APIError(409, "上次任务清理尚未确认，请先执行会话恢复检查")
            self.operation = operation

    def connect(self, value):
        config = validate_config(value)
        self.reserve("connecting", allow_recovery=True)
        try:
            self.uart.close()
            self.health = None
            with self.lock:
                self.config = config
                self.network = dict(online=False, image_ready=False, error="正在探测")
                self.serial = dict(online=False, error="正在连接")
                self.set_setting("config", config)
            try:
                network = probe_network(config)
                if not network["image_ready"]:
                    network["error"] = "端点响应，但不支持完整图片会话"
            except Exception as error:
                network = dict(online=False, image_ready=False, error=str(error), checked_at=time.time())
            try:
                serial = self.uart.open(config)
            except Exception as error:
                self.uart.close()
                serial = dict(online=False, error=str(error), checked_at=time.time())
            with self.lock:
                self.network, self.serial = network, serial
            if serial["online"]:
                try:
                    self.health = self.uart.health()
                except Exception as error:
                    self.serial = dict(online=False, error=str(error), checked_at=time.time())
            return self.device()
        finally:
            with self.lock:
                self.operation = None

    def refresh_health(self):
        self.reserve("health", allow_recovery=True)
        try:
            if not self.serial.get("online"):
                raise APIError(409, "串口未连接，无法读取板端健康状态")
            self.health = self.uart.health()
            return self.device()
        except Exception:
            if self.uart.port is None:
                self.serial.update(online=False, error="串口通信中断，请重新连接")
            raise
        finally:
            self.operation = None

    def control(self, request):
        self.reserve("control")
        try:
            if not self.serial.get("online"):
                raise APIError(409, "请先连接 USB 串口；当前网口协议仅支持图片任务")
            result = self.uart.control(request)
            self.health = None  # Earlier snapshot must not look like current state.
            result["request"] = request
            with self.lock:
                self.db.execute("INSERT INTO controls VALUES(?,?)", (uuid.uuid4().hex, json.dumps(result, ensure_ascii=False)))
                self.db.commit()
            return result
        except Exception:
            if self.uart.port is None:
                self.serial.update(online=False, error="串口通信中断，请重新连接")
            raise
        finally:
            self.operation = None

    def recover(self):
        self.reserve("recovering", allow_recovery=True)
        try:
            result = verify_lease_available(self.config)
            with self.lock:
                self.recovery_required = False
                self.set_setting("recovery_required", False)
            return result
        except Exception:
            self.recovery_required = True
            self.set_setting("recovery_required", True)
            raise
        finally:
            self.operation = None

    def upload(self, data, name):
        if not data or len(data) > MAX_UPLOAD:
            raise ValueError("图片必须小于20MiB且不能为空")
        ident = uuid.uuid4().hex
        folder = self.root / ident
        folder.mkdir()
        source = folder / "upload.bin"
        source.write_bytes(data)
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(io.BytesIO(data)) as image:
                    width, height = image.size
                    if getattr(image, "n_frames", 1) != 1:
                        raise ValueError("请使用单帧图片，动画和多页图片暂不支持")
                    if width*height > Image.MAX_IMAGE_PIXELS:
                        raise ValueError("图片解码尺寸超过2000万像素")
                    image.verify()
                raw, desc = load_image(source, 0, (1280, 720))
            save_image(folder / "input.png", raw, desc)
        except Exception:
            # Only files in this newly created, known folder are removed.
            source.unlink(missing_ok=True)
            (folder / "input.png").unlink(missing_ok=True)
            folder.rmdir()
            raise
        source.unlink()
        result = dict(id=ident, name=str(name)[:200], width=width, height=height, target_width=1280, target_height=720,
                      sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw), preview_url=f"/api/uploads/{ident}/preview", created_at=time.time())
        with self.lock:
            self.db.execute("INSERT INTO uploads VALUES(?,?)", (ident, json.dumps(result, ensure_ascii=False)))
            self.db.commit()
        return result

    def get_upload(self, ident):
        with self.lock:
            row = self.db.execute("SELECT payload FROM uploads WHERE id=?", (ident,)).fetchone()
            if not row:
                raise APIError(404, "请重新选择图片")
            return json.loads(row[0])

    def submit(self, value):
        if not isinstance(value, dict) or set(value) != {"upload_id", "slot", "idempotency_key"}:
            raise ValueError("图片任务参数不完整")
        upload = self.get_upload(value["upload_id"])
        if type(value["slot"]) is not int or value["slot"] not in range(5):
            raise ValueError("风格槽位范围为0～4")
        key = value["idempotency_key"]
        if not isinstance(key, str) or not re.fullmatch(r"[a-zA-Z0-9_-]{16,80}", key):
            raise ValueError("任务幂等键不合法")
        with self.lock:
            old = self.db.execute("SELECT payload FROM jobs WHERE idem=?", (key,)).fetchone()
            if old:
                previous = json.loads(old[0])
                if previous["upload_id"] != upload["id"] or previous["slot"] != value["slot"]:
                    raise APIError(409, "同一任务键对应了不同图片或风格")
                return previous
            self.reserve("image")
            if not self.network.get("image_ready"):
                self.operation = None
                raise APIError(409, "网口图片通路尚未连接，请先探测设备")
            ident = uuid.uuid4().hex
            config = dict(self.config)
            event = threading.Event()
            job = dict(id=ident, idempotency_key=key, upload_id=upload["id"], name=upload["name"], slot=value["slot"],
                       status="running", phase="preparing", created_at=time.time(), updated_at=time.time(), config=config,
                       upload_bytes=0, download_bytes=0, upload_total=3686400 if config["transport"] == "packed" else 2764800,
                       download_total=2764800, preview_url=upload["preview_url"], result_url=None, stats={}, error=None,
                       model_profile="board-slots-unconfirmed-names", execution="offline_identity_fixture" if self.offline_fixture else "fpga")
            try:
                self.save_job(job)
                self.active_job, self.cancel_event = ident, event
                self.operation = None
                self.health = None
                thread = threading.Thread(target=self._worker, args=(job, event), name="fpga-image-"+ident[:8], daemon=True)
                thread.start()
            except Exception as error:
                self.active_job, self.cancel_event, self.operation = None, None, None
                job.update(status="failed", phase="failed", error="任务未启动："+str(error), finished_at=time.time())
                self.live_jobs[ident] = json.dumps(job, ensure_ascii=False)
                self.db.rollback()
                raise
            return self.job(ident)

    def _worker(self, job, event):
        client = None
        folder = self.root / job["id"]
        def progress(value):
            job.update(value, updated_at=time.time())
            if event.is_set():
                job["phase"] = "cancelling"
            self.save_job(job)
        try:
            folder.mkdir()
            raw, desc = load_image(self.root / job["upload_id"] / "input.png", job["slot"])
            if event.is_set():
                raise Cancelled("用户取消了任务")
            if job["config"]["transport"] == "packed":
                raw, desc = pack_rgbx7(raw, desc)
            client = ProgressClient(job["config"], event, progress)
            output, result = client.transfer(raw, desc)
            if (result.width, result.height, result.style) != (1280, 720, job["slot"]):
                raise ValueError("结果尺寸或槽位与本次任务不一致")
            progress(dict(phase="saving", stats=dict(client.stats)))
            save_image(folder / "result.png", output, result)
            job.update(status="completed", phase="done", result_url=f"/api/jobs/{job['id']}/result", stats=dict(client.stats),
                       output_sha256=hashlib.sha256(output).hexdigest(), result_descriptor=asdict(result),
                       upload_bytes=len(raw), download_bytes=len(output), download_total=len(output), cleanup="release_acknowledged")
        except Exception as error:
            if client is not None:
                job["stats"] = dict(client.stats)
            stats = job["stats"]
            uncertain = stats.get("cancel_attempted", False) or (client is not None and stats.get("phase") not in ("done", "failed", None))
            job.update(status="cancelled" if isinstance(error, Cancelled) else "failed", phase="cancelled" if isinstance(error, Cancelled) else "failed", error=str(error),
                       cleanup="needs_recovery_check" if uncertain else "not_acquired_or_released")
            with self.lock:
                if uncertain:
                    self.recovery_required = True
                    try:
                        self.set_setting("recovery_required", True)
                    except sqlite3.Error as storage_error:
                        self.storage_error = str(storage_error)
                transport_lost = client is not None and stats.get("phase") != "done" and (isinstance(error, OSError) or "no valid reply" in str(error) or "whole transfer deadline" in str(error))
                if transport_lost:
                    self.network.update(online=False, image_ready=False, error=str(error), checked_at=time.time())
                if isinstance(error, OSError) and (getattr(error, "errno", None) in (errno.ENOSPC, errno.EACCES, errno.EROFS) or getattr(error, "winerror", None) == 112):
                    self.storage_error = str(error)
        finally:
            if client is not None:
                client.close()
            job.update(updated_at=time.time(), finished_at=time.time())
            try:
                atomic_json(folder / "report.json", job)
            except OSError as error:
                job["report_error"] = str(error)
            try:
                self.save_job(job)
            except sqlite3.Error as error:
                job["storage_warning"] = "记录未持久化，请立即下载结果/报告："+str(error)
                with self.lock:
                    self.live_jobs[job["id"]] = json.dumps(job, ensure_ascii=False)
            finally:
                with self.lock:
                    self.active_job, self.cancel_event = None, None

    def cancel(self, ident):
        with self.lock:
            job = self.job(ident)
            if job["status"] in TERMINAL:
                return job
            if self.active_job != ident or self.cancel_event is None:
                raise APIError(409, "此任务已不在当前执行器中")
            if job["phase"] in ("saving", "release", "done"):
                raise APIError(409, "结果正在释放和保存，请等待完成")
            self.cancel_event.set()
            job.update(phase="cancelling", updated_at=time.time())
            self.save_job(job)
            return job

    def diagnostics(self):
        with self.lock:
            controls = [json.loads(row[0]) for row in self.db.execute("SELECT payload FROM controls ORDER BY rowid DESC LIMIT 100")]
        return dict(device=self.device(), jobs=self.history(100), controls=controls, exported_at=time.time())


class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, app):
        super().__init__(address, Handler)
        self.app, self.token = app, secrets.token_urlsafe(32)


class Handler(BaseHTTPRequestHandler):
    server_version = "YizhenLocal/4.0"
    def log_message(self, fmt, *args):
        pass

    def send(self, status, data, content_type="application/json; charset=utf-8", attachment=None):
        if not isinstance(data, bytes):
            data = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' blob: data:; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
        if attachment:
            self.send_header("Content-Disposition", f'attachment; filename="{attachment}"')
        self.end_headers()
        self.wfile.write(data)

    def check_host(self):
        valid = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
        if self.headers.get("Host") not in valid:
            raise APIError(403, "仅允许从本机地址访问")

    def do_GET(self):
        try:
            self.check_host()
            self.get_route(urlsplit(self.path).path)
        except APIError as error:
            self.send(error.status, {"error": error.message})
        except (ValueError, TypeError) as error:
            self.send(400, {"error": str(error)})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.send(500, {"error": str(error)})

    def get_route(self, path):
        app = self.server.app
        if path == "/api/bootstrap":
            from serial.tools.list_ports import comports
            return self.send(200, dict(token=self.server.token, device=app.device(), jobs=app.history(), ports=[dict(port=p.device, description=p.description) for p in comports()]))
        if path == "/api/device":
            return self.send(200, app.device())
        if path == "/api/history":
            return self.send(200, app.history())
        if path == "/api/diagnostics":
            return self.send(200, app.diagnostics(), attachment="yizhen_diagnostics.json")
        match = re.fullmatch(r"/api/jobs/([a-f0-9]{32})(?:/(result|report))?", path)
        if match:
            ident, kind = match.groups()
            job = app.job(ident)
            if kind is None:
                return self.send(200, job)
            if kind == "report":
                return self.send(200, job, attachment=ident+"_report.json")
            if job["status"] != "completed":
                raise APIError(409, "结果尚未完成 CRC 校验和保存")
            return self.send(200, (app.root / ident / "result.png").read_bytes(), "image/png", ident+"_result.png")
        match = re.fullmatch(r"/api/uploads/([a-f0-9]{32})/preview", path)
        if match:
            ident = match.group(1)
            app.get_upload(ident)
            return self.send(200, (app.root / ident / "input.png").read_bytes(), "image/png")
        if path.startswith("/api/"):
            raise APIError(404, "没有此接口")
        relative = "index.html" if path == "/" else path.lstrip("/")
        if relative not in {"index.html", "styles.css", "app.js", "scene3d.js", "favicon.svg"} and not re.fullmatch(r"assets/[a-zA-Z0-9_.-]+\.(png|svg)", relative):
            raise APIError(404, "没有找到文件")
        file = ROOT / "web" / relative
        if not file.is_file():
            raise APIError(404, "没有找到文件")
        mime = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".png": "image/png", ".svg": "image/svg+xml"}[file.suffix]
        self.send(200, file.read_bytes(), mime)

    def do_POST(self):
        try:
            self.check_host()
            allowed = {f"http://127.0.0.1:{self.server.server_port}", f"http://localhost:{self.server.server_port}"}
            if self.headers.get("Origin") not in allowed or not secrets.compare_digest(self.headers.get("X-Yizhen-Token", ""), self.server.token):
                raise APIError(403, "请求来源或本机会话令牌无效，请刷新页面")
            length = int(self.headers.get("Content-Length", "0"))
            path = urlsplit(self.path).path
            if not 0 < length <= (MAX_UPLOAD if path == "/api/uploads" else 16384):
                raise APIError(413, "请求大小超过限制或为空")
            self.connection.settimeout(15)
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise APIError(400, "请求数据不完整")
            if path == "/api/uploads":
                return self.send(201, self.server.app.upload(raw, unquote(self.headers.get("X-Upload-Name", "image"))))
            if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                raise APIError(415, "请求格式应为 application/json")
            value = json.loads(raw)
            app = self.server.app
            if path == "/api/device/connect":
                return self.send(200, app.connect(value))
            if path == "/api/device/refresh":
                return self.send(200, app.refresh_health())
            if path == "/api/device/control":
                return self.send(200, app.control(value))
            if path == "/api/device/recover":
                return self.send(200, app.recover())
            if path == "/api/jobs":
                return self.send(202, app.submit(value))
            match = re.fullmatch(r"/api/jobs/([a-f0-9]{32})/cancel", path)
            if match:
                return self.send(202, app.cancel(match.group(1)))
            raise APIError(404, "没有此接口")
        except APIError as error:
            self.send(error.status, {"error": error.message})
        except (ValueError, TypeError, KeyError) as error:
            self.send(400, {"error": str(error)})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.send(502, {"error": str(error)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8770)
    parser.add_argument("--data-dir", default=str(ROOT / "data"))
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()
    app = App(args.data_dir)
    try:
        server = Server(("127.0.0.1", args.port), app)
    except OSError as error:
        app.db.close()
        print(f"无法启动本地服务：{error}\n端口可能被占用。请关闭旧预览，或使用 --port 8771。", flush=True)
        return 1
    url = f"http://127.0.0.1:{server.server_port}/"
    print(f"一帧入画 V4: {url}\n数据目录: {app.root}\n按 Ctrl+C 结束；执行任务时请先在网页取消并等清理结束。", flush=True)
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        if app.cancel_event is not None:
            app.cancel_event.set()
            deadline = time.monotonic()+8
            while app.active_job and time.monotonic() < deadline:
                time.sleep(.05)
    finally:
        server.server_close()
        app.uart.close()
        if not app.active_job:
            app.db.close()


if __name__ == "__main__":
    raise SystemExit(main())
