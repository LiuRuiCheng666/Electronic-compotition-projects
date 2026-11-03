from pathlib import Path
import sys,os,socket,threading,subprocess,time,unittest,zlib,tempfile
P=Path(__file__).resolve().parents[1];sys.path.insert(0,str(P/'host'))
from a_net_wire import Packet,encode,decode,DATA,BEGIN,COMMIT,STATUS,RESULT
from a_image_transfer import ImageClient,ImageDesc,TransferError,save_image,load_image

class CBridge:
 """Localhost UDP -> real portable C session -> host identity memory fixture.
 Not a board simulator or a style model. No non-loopback socket is opened.
 """
 def __init__(self,faults=False,corrupt_frame=False,drop_all=False):
  env=os.environ.copy();env['PATH']='D:/Quartus18.0/quartus/bin64/cygwin/bin;'+env['PATH']
  self.process=subprocess.Popen([str(P/'tests/image_session_cli.exe')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1,env=env)
  self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);self.sock.bind(('127.0.0.1',0));self.sock.settimeout(0.05)
  self.port=self.sock.getsockname()[1];self.stop=False;self.errors=[];self.faults=faults;self.seen=set();self.corrupt_frame=corrupt_frame;self.drop_all=drop_all
  self.thread=threading.Thread(target=self.serve,daemon=True);self.thread.start()
 def serve(self):
  try:
   while not self.stop:
    try:raw,peer=self.sock.recvfrom(2048)
    except socket.timeout:continue
    if self.drop_all:continue
    try:p=decode(raw)
    except ValueError:continue
    if self.faults and p.op==DATA and p.sequence==0 and 'request0' not in self.seen:
     self.seen.add('request0');continue
    owner=(int.from_bytes(socket.inet_aton(peer[0]),'big')<<16)|peer[1]
    self.process.stdin.write(f'{owner} {p.op} {p.session} {p.sequence} {p.offset} {p.total} {int(time.perf_counter()*1000)&0xffffffff} {p.payload.hex() or "-"}\n');self.process.stdin.flush()
    line=self.process.stdout.readline().strip();parts=line.split()
    if len(parts)!=6:raise RuntimeError('C bridge response: '+line)
    op,sid,seq,off,total=map(int,parts[:5]);payload=bytes.fromhex(parts[5]) if parts[5]!='-' else b''
    if self.corrupt_frame and op==RESULT and seq==0:payload=bytes([payload[0]^1])+payload[1:]
    reply=encode(Packet(op,sid,seq,off,total,payload))
    key='begin_ack' if p.op==BEGIN else 'commit_ack' if p.op==COMMIT else 'release_ack' if p.op==STATUS and p.payload==b'\2' else ''
    if self.faults and key and key not in self.seen:self.seen.add(key);continue
    if self.faults and op==RESULT and seq==1 and 'result_crc' not in self.seen:
     self.seen.add('result_crc');reply=reply[:-1]+bytes([reply[-1]^1])
    self.sock.sendto(reply,peer)
  except BaseException as e:self.errors.append(e)
 def close(self):
  self.stop=True;self.thread.join(2);self.sock.close()
  if self.thread.is_alive():raise RuntimeError('C bridge did not stop')
  self.process.stdin.write('STATS\n');self.process.stdin.flush();self.stats=tuple(map(int,self.process.stdout.readline().split()[1:]))
  self.process.stdin.close();self.process.wait(timeout=3)
  stderr=self.process.stderr.read();self.process.stdout.close();self.process.stderr.close()
  if self.process.returncode:raise RuntimeError(stderr)
  if self.errors:raise self.errors[0]

class Tests(unittest.TestCase):
 def make_input(self,w=64,h=32):
  raw=bytes((i*19+7)%256 for i in range(w*h*3));return raw,ImageDesc(w,h,1,3,w*3,len(raw),zlib.crc32(raw))
 def run_transfer(self,faults=False):
  b=CBridge(faults=faults);c=ImageClient('127.0.0.1',b.port,bind_ip='127.0.0.1',timeout=0.08,attempts=5)
  try:
   raw,d=self.make_input(320,240);out,result=c.transfer(raw,d)
   self.assertEqual(out,raw);self.assertEqual(result,d)
   if faults:
    self.assertGreaterEqual(c.stats['retransmissions'],5);self.assertGreaterEqual(c.stats['bad_datagrams'],1)
    self.assertEqual(b.seen,{'request0','begin_ack','commit_ack','release_ack','result_crc'})
  finally:c.close();b.close()
  self.assertEqual(b.stats,(1,169,1,1),'reserve, successful chunk writes, task submissions, releases')
 def test_real_c_session_roundtrip(self):self.run_transfer()
 def test_loss_ack_loss_corrupt_result_and_release_retry(self):self.run_transfer(True)
 def test_whole_frame_crc_failure_cancels(self):
  b=CBridge(corrupt_frame=True);c=ImageClient('127.0.0.1',b.port,timeout=0.08)
  try:
   raw,d=self.make_input()
   with self.assertRaisesRegex(ValueError,'frame CRC'):c.transfer(raw,d)
  finally:c.close();b.close()
  self.assertEqual(b.stats[2:],(1,1))
 def test_bounded_timeout_without_image_service(self):
  b=CBridge(drop_all=True);c=ImageClient('127.0.0.1',b.port,timeout=0.03,attempts=2)
  try:
   raw,d=self.make_input();start=time.perf_counter()
   with self.assertRaises(TransferError):c.transfer(raw,d)
   self.assertLess(time.perf_counter()-start,1);self.assertEqual(c.stats['sent'],2)
  finally:c.close();b.close()
  self.assertEqual(b.stats,(0,0,0,0))
 def test_descriptor_and_atomic_image_save(self):
  raw,d=self.make_input();self.assertEqual(ImageDesc.unpack(d.pack()),d)
  with self.assertRaises(ValueError):ImageDesc(0,32,1,3,192,len(raw),0).pack()
  with tempfile.TemporaryDirectory()as temp:
   p=Path(temp)/'image.png';save_image(p,raw,d);loaded,ld=load_image(p,3);self.assertEqual(loaded,raw);self.assertEqual(ld,d)
   before=p.read_bytes()
   with self.assertRaises(FileExistsError):save_image(p,raw,d)
   self.assertEqual(before,p.read_bytes())
   bad=Path(temp)/'bad.png'
   with self.assertRaises(ValueError):save_image(bad,raw[:-1],d)
   self.assertFalse(bad.exists())
if __name__=='__main__':unittest.main()
