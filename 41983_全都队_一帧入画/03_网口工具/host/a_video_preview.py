"""Local-only, single-latest-frame MJPEG viewer. No directory/file serving."""
import json,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit
class Preview:
 def __init__(self,port):
  self.condition=threading.Condition();self.jpeg=None;self.serial=0;self.closed=False;self.meta={"status":"WAITING_FOR_FPGA"}
  owner=self
  class Handler(BaseHTTPRequestHandler):
   def log_message(self,*args):pass
   def do_GET(self):
    self.connection.settimeout(2)
    path=urlsplit(self.path).path
    if path=='/':
     body=b'<!doctype html><meta charset="utf-8"><title>FPGA live result</title><h1>FPGA result stream</h1><p>Actual returned frames only. Low-rate prototype, not real-time. Left=input, right=FPGA result.</p><img style="max-width:100%" src="/stream.mjpg">'
     self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    elif path=='/status.json':
     with owner.condition:body=json.dumps(dict(owner.meta,preview_serial=owner.serial)).encode()
     self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    elif path=='/stream.mjpg':
     self.send_response(200);self.send_header('Content-Type','multipart/x-mixed-replace; boundary=frame');self.send_header('Cache-Control','no-store');self.end_headers();seen=0
     try:
      while True:
       with owner.condition:
        owner.condition.wait_for(lambda:owner.closed or owner.serial!=seen,timeout=1)
        if owner.closed:break
        if owner.serial==seen:continue
        seen=owner.serial;jpeg=owner.jpeg
       self.wfile.write(b'--frame\r\nContent-Type: image/jpeg\r\nContent-Length: '+str(len(jpeg)).encode()+b'\r\nX-Preview-Serial: '+str(seen).encode()+b'\r\n\r\n'+jpeg+b'\r\n');self.wfile.flush()
     except (OSError,TimeoutError):pass
    else:self.send_error(404)
  self.server=ThreadingHTTPServer(('127.0.0.1',port),Handler);self.server.daemon_threads=True
  self.port=self.server.server_port;self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
 def publish(self,jpeg,meta):
  with self.condition:
   self.jpeg=bytes(jpeg);self.serial+=1;self.meta=dict(meta);self.condition.notify_all()
 def close(self):
  with self.condition:self.closed=True;self.condition.notify_all()
  self.server.shutdown();self.server.server_close();self.thread.join(timeout=3)
