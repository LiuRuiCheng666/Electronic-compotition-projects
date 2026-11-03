"""Host-only failure injection, not model or hardware proof."""
from pathlib import Path
from unittest.mock import patch
from dataclasses import replace
import json,sys,tempfile,unittest,zlib
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
import a_image_batch as m
class Tests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.input=self.root/'input.png';Image.new('RGB',(32,24),(80,120,160)).save(self.input);self.calls=0;self.closed=0
 def tearDown(self):self.tmp.cleanup()
 def factory(self,*args):
  owner=self
  class Client:
   stats={'session':99,'total_ms':1}
   def transfer(self,raw,d):owner.calls+=1;return raw,d
   def close(self):owner.closed+=1
  return Client()
 def test_connection_creation_retries(self):
  attempts=[]
  def create(*args):
   attempts.append(1)
   if len(attempts)==1:raise OSError('injected bind failure')
   return self.factory(*args)
  with patch.object(m.time,'sleep'):
   root,r=m.batch([self.input],self.root/'run',styles=[3],size=(32,24),client_factory=create)
  j=r['images'][0]['jobs'][0];self.assertEqual(r['status'],'PASS');self.assertEqual([a['status']for a in j['attempts']],['FAIL','PASS']);self.assertEqual(self.calls,1);self.assertEqual(self.closed,1)
 def test_connection_failure_exhaustion_is_terminal(self):
  def fail(*args):raise OSError('injected permanent bind failure')
  with patch.object(m.time,'sleep'):
   root,r=m.batch([self.input],self.root/'run',styles=[3],size=(32,24),client_factory=fail)
  j=r['images'][0]['jobs'][0];self.assertEqual(r['status'],'FAIL');self.assertEqual(j['status'],'FAIL');self.assertEqual(len(j['attempts']),2);self.assertFalse(list(root.glob('*slot*.png')))
 def test_disk_error_does_not_repeat_inference(self):
  real=m.save_image
  def fail(path,*args,**kw):
   if 'slot'in str(path):raise OSError('injected disk full')
   return real(path,*args,**kw)
  with patch.object(m,'save_image',side_effect=fail),self.assertRaises(OSError):
   m.batch([self.input],self.root/'run',styles=[3],size=(32,24),client_factory=self.factory)
  r=json.loads((self.root/'run/manifest.json').read_text());self.assertEqual(self.calls,1);self.assertEqual(r['status'],'FAIL');self.assertEqual(r['images'][0]['jobs'][0]['status'],'FAIL')
 def test_interruption_is_terminal_and_closes_client(self):
  def factory(*args):
   c=self.factory(*args)
   def stop(*a):raise KeyboardInterrupt()
   c.transfer=stop;return c
  with self.assertRaises(KeyboardInterrupt):m.batch([self.input],self.root/'run',styles=[3],size=(32,24),client_factory=factory)
  r=json.loads((self.root/'run/manifest.json').read_text());self.assertEqual(self.closed,1);self.assertEqual(r['status'],'INTERRUPTED');self.assertEqual(r['images'][0]['jobs'][0]['status'],'INTERRUPTED')
if __name__=='__main__':unittest.main(verbosity=2)

