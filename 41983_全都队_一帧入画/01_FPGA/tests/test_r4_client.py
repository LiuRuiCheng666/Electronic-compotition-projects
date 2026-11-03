"""R4 host-only tests; portable C backend is a memory identity fixture, not an NN."""
from pathlib import Path
import unittest,tempfile,sys,struct,zlib,math,socket,select,threading,time,json,subprocess
from unittest.mock import patch
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
import a_image_transfer as m
import test_image_transfer as legacy
class Tests(unittest.TestCase):
 def setUp(self):self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
 def tearDown(self):self.temp.cleanup()
 def test_alpha_white_composite(self):
  p=self.root/'rgba.png';im=Image.new('RGBA',(3,1));im.putdata([(255,0,0,0),(255,0,0,128),(0,128,255,255)]);im.save(p)
  raw,d=m.load_image(p,0);self.assertEqual(raw,bytes([255,255,255,255,127,127,0,128,255]));self.assertEqual(d.crc32,zlib.crc32(raw))
 def test_palette_transparency(self):
  p=self.root/'palette.png';im=Image.new('P',(3,1));im.putpalette([255,0,0,0,255,0,0,0,255]+[0]*759);im.putdata([0,1,2]);im.save(p,transparency=bytes([0,128,255]))
  raw,d=m.load_image(p,1);self.assertEqual(raw,bytes([255,255,255,127,255,127,0,0,255]))
 def test_grayscale_alpha(self):
  p=self.root/'la.png';im=Image.new('LA',(2,1));im.putdata([(80,0),(80,255)]);im.save(p)
  raw,_=m.load_image(p,0);self.assertEqual(raw,bytes([255,255,255,80,80,80]))
 def test_rgb_color_key_transparency(self):
  p=self.root/'key.png';im=Image.new('RGB',(2,1));im.putdata([(255,0,0),(0,0,255)]);im.save(p,transparency=(255,0,0))
  raw,_=m.load_image(p,0);self.assertEqual(raw,bytes([255,255,255,0,0,255]))
 def test_gray16_preserves_midtones(self):
  p=self.root/'gray16.png';Image.frombytes('I;16',(3,1),struct.pack('<3H',0,32768,65535)).save(p)
  raw,_=m.load_image(p,2);self.assertEqual(raw[:3],b'\0'*3);self.assertIn(raw[3],(127,128));self.assertEqual(raw[3:6],bytes([raw[3]])*3);self.assertEqual(raw[-3:],b'\xff'*3)
 def test_exif_orientation(self):
  p=self.root/'oriented.png';im=Image.new('RGB',(2,3),(12,34,56));exif=Image.Exif();exif[274]=6;im.save(p,exif=exif)
  raw,d=m.load_image(p,0);self.assertEqual((d.width,d.height),(3,2));self.assertEqual(raw,bytes([12,34,56])*6)
 def test_nonfinite_parameters_fail_before_socket(self):
  with patch.object(m.socket,'socket',side_effect=AssertionError('must not open socket')):
   for kwargs in [{'timeout':float('nan')},{'job_timeout':float('inf')},{'transfer_timeout':0},{'transfer_timeout':float('inf')},{'attempts':1.5}]:
    with self.subTest(kwargs=kwargs),self.assertRaises(ValueError):m.ImageClient('127.0.0.1',**kwargs)
 def test_retry_accounting_and_stale_frames(self):
  b=legacy.CBridge(faults=True);c=m.ImageClient('127.0.0.1',b.port,bind_ip='127.0.0.1',timeout=.04,job_timeout=3)
  try:
   raw,d=legacy.Tests().make_input(320,240);out,result=c.transfer(raw,d);self.assertEqual(out,raw)
   self.assertEqual(c.stats['retransmissions'],c.stats['control_replays']+c.stats['packet_retries']);self.assertGreater(c.stats['control_replays'],0);self.assertGreater(c.stats['packet_retries'],0)
   self.assertAlmostEqual(c.stats['task_wait_ms'],c.stats['commit_roundtrip_ms']+c.stats['ready_status_wait_ms'],places=5);self.assertIsNone(c._transfer_deadline)
  finally:c.close();b.close()
 def test_whole_deadline_cancel_and_client_reuse(self):
  b=legacy.CBridge();down=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);down.bind(('127.0.0.1',0));up=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);up.bind(('127.0.0.1',0));stop=threading.Event();peer=[None];delay=[True];errors=[]
  def relay():
   try:
    while not stop.is_set():
     ready,_,_=select.select([down,up],[],[],.03)
     for sock in ready:
      raw,src=sock.recvfrom(2048)
      if sock is down:
       peer[0]=src
       if delay[0]and m.decode(raw).op==m.DATA:time.sleep(.03)
       up.sendto(raw,('127.0.0.1',b.port))
      elif peer[0]:down.sendto(raw,peer[0])
   except Exception as e:errors.append(e)
  t=threading.Thread(target=relay,daemon=True);t.start();c=m.ImageClient('127.0.0.1',down.getsockname()[1],bind_ip='127.0.0.1',timeout=.08,job_timeout=2,transfer_timeout=.15)
  try:
   raw,d=legacy.Tests().make_input(320,240);start=time.monotonic()
   with self.assertRaisesRegex(m.TransferError,'whole transfer deadline'):c.transfer(raw,d)
   self.assertLess(time.monotonic()-start,1);self.assertIsNone(c._transfer_deadline)
   delay[0]=False;c.transfer_timeout=5;out,result=c.transfer(raw,d);self.assertEqual(out,raw);self.assertIsNone(c._transfer_deadline);self.assertNotIn('failure_phase',c.stats)
  finally:
   c.close();stop.set();t.join(2);down.close();up.close();b.close()
  self.assertFalse(errors);self.assertEqual(b.stats[0],2);self.assertEqual(b.stats[2:],(1,2))
 def test_cli_failed_preparation_writes_report(self):
  report=self.root/'failed.json';script=Path(m.__file__)
  q=subprocess.run([sys.executable,'-X','utf8',str(script),str(self.root/'missing.jpg'),str(self.root/'out.png'),'--ip','127.0.0.1','--report',str(report)],capture_output=True,text=True)
  self.assertNotEqual(q.returncode,0);data=json.loads(report.read_text());self.assertEqual(data['status'],'FAIL');self.assertIn('FileNotFoundError',data['error']);self.assertFalse((self.root/'out.png').exists())
 def test_cli_report_cannot_overwrite_input_or_output(self):
  image=self.root/'input.png';Image.new('RGB',(2,2),(1,2,3)).save(image);before=image.read_bytes()
  q=subprocess.run([sys.executable,'-X','utf8',str(Path(m.__file__)),str(image),str(self.root/'out.png'),'--ip','127.0.0.1','--report',str(image)],capture_output=True,text=True)
  self.assertEqual(q.returncode,2);self.assertEqual(image.read_bytes(),before)
if __name__=='__main__':unittest.main(verbosity=2)
