"""Loopback protocol timing tests; server is not a board or an NN model."""
from pathlib import Path
import hashlib,json,socket,sys,threading,time,unittest
P=Path(__file__).resolve().parents[1];sys.path.insert(0,str(P/'host'))
from a_image_transfer import ImageClient,TransferError,ACK_HEADER
from a_net_wire import Packet,encode,decode,BEGIN,COMMIT,STATUS,ACK

class ReplyServer:
 def __init__(self,busy=0,delay=0,generation=7,silent=False):
  self.busy=busy;self.delay=delay;self.generation=generation;self.silent=silent;self.requests=[];self.errors=[]
  self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);self.sock.bind(('127.0.0.1',0));self.sock.settimeout(.01)
  self.port=self.sock.getsockname()[1];self.stop=threading.Event()
  self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
 def run(self):
  try:
   while not self.stop.is_set():
    try:raw,peer=self.sock.recvfrom(2048)
    except socket.timeout:continue
    q=decode(raw);self.requests.append(q)
    if self.silent:continue
    if self.delay:time.sleep(self.delay)
    code=1 if len(self.requests)<=self.busy else 0
    payload=ACK_HEADER.pack(b'ACK1',q.op,code,0,1 if code else 0,self.generation)
    self.sock.sendto(encode(Packet(ACK,q.session,q.sequence,q.offset,q.total,payload)),peer)
  except BaseException as e:self.errors.append(e)
 def close(self):
  self.stop.set();self.thread.join(1);self.sock.close()
  if self.thread.is_alive()or self.errors:raise RuntimeError(self.errors or 'server thread hung')

class Tests(unittest.TestCase):
 def exercise(self,server,op=BEGIN,payload=b'',job_timeout=.5,generation=None,expect_error=False):
  c=ImageClient('127.0.0.1',server.port,timeout=.01,attempts=2,job_timeout=job_timeout)
  p=Packet(op,123,0x80000001,payload=payload);start=time.perf_counter()
  try:
   if expect_error:
    with self.assertRaises(TransferError):c._ack(p,generation)
   else:
    _,ack=c._ack(p,generation);self.assertEqual(ack[0],0)
   return dict(c.stats),time.perf_counter()-start
  finally:c.close();server.close()
 def test_busy_more_than_packet_attempts(self):
  b=ReplyServer(busy=8);stats,elapsed=self.exercise(b)
  self.assertEqual(stats['busy_replies'],8);self.assertEqual(len(b.requests),9)
  self.assertTrue(all(q.session==123 and q.sequence==0x80000001 for q in b.requests))
  self.assertLess(elapsed,.5)
 def test_busy_has_overall_deadline(self):
  b=ReplyServer(busy=100000);stats,elapsed=self.exercise(b,job_timeout=.12,expect_error=True)
  self.assertGreater(stats['busy_replies'],2);self.assertLess(elapsed,.3)
 def test_slow_commit_crc_reply(self):
  b=ReplyServer(delay=.07);stats,elapsed=self.exercise(b,COMMIT,b'crc!',.3)
  self.assertEqual(stats['sent'],1);self.assertGreater(elapsed,.05);self.assertLess(elapsed,.3)
 def test_slow_result_crc_poll(self):
  b=ReplyServer(delay=.07);stats,_=self.exercise(b,STATUS,b'\0',.3)
  self.assertEqual(stats['sent'],1)
 def test_unresponsive_begin_still_fails_fast(self):
  b=ReplyServer(silent=True);stats,elapsed=self.exercise(b,job_timeout=.5,expect_error=True)
  self.assertEqual(stats['sent'],2);self.assertLess(elapsed,.2)
 def test_busy_cannot_hide_generation_change(self):
  b=ReplyServer(busy=100,generation=8);stats,_=self.exercise(b,generation=7,expect_error=True)
  self.assertEqual(stats['sent'],1)

if __name__=='__main__':
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests))
 sources=[Path(__file__),P/'host/a_image_transfer.py',P/'host/a_net_wire.py']
 (P/'HOST_CONTROL_WAIT_VALIDATION.json').write_text(json.dumps(dict(
  status='PASS'if result.wasSuccessful()else'FAIL',tests=result.testsRun,
  hardware_accessed=False,board_image_roundtrip=False,
  sha256={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources},
  scope='Loopback ACK timing only: bounded BUSY replay, slow CRC replies, generation and fail-fast guards.'
 ),indent=2),encoding='utf-8')
 sys.exit(0 if result.wasSuccessful() else 1)
