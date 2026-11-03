import sys,unittest,http.client,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from a_video_preview import Preview
class PreviewTests(unittest.TestCase):
 def setUp(self):self.preview=Preview(0)
 def tearDown(self):self.preview.close();self.assertFalse(self.preview.thread.is_alive())
 def request(self,path):
  c=http.client.HTTPConnection('127.0.0.1',self.preview.port,timeout=2);c.request('GET',path);return c,c.getresponse()
 def test_status_and_loopback_binding(self):
  self.assertEqual(self.preview.server.server_address[0],'127.0.0.1')
  c,r=self.request('/status.json')
  try:self.assertEqual(json.loads(r.read())['status'],'WAITING_FOR_FPGA')
  finally:c.close()
 def test_no_file_serving(self):
  c,r=self.request('/../FILES.json')
  try:self.assertEqual(r.status,404);r.read()
  finally:c.close()
 def test_stream_latest_only(self):
  self.preview.publish(b'first',{'source_frame':1});self.preview.publish(b'latest',{'source_frame':2})
  c,r=self.request('/stream.mjpg')
  try:
   self.assertEqual(r.status,200);self.assertEqual(r.readline(),b'--frame\r\n');headers={}
   while True:
    line=r.readline()
    if line==b'\r\n':break
    k,v=line.decode().split(':',1);headers[k.lower()]=v.strip()
   self.assertEqual(headers['x-preview-serial'],'2');self.assertEqual(r.read(int(headers['content-length'])),b'latest')
  finally:c.close()
if __name__=='__main__':unittest.main()
