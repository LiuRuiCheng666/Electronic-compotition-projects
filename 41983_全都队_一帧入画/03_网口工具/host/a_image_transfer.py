"""Reliable ANET image client; requires image-session firmware, not a HELLO-only build.

Uses stop-and-wait with bounded retransmission; no model executes on this PC.
"""
from dataclasses import dataclass
from pathlib import Path
import argparse,json,secrets,socket,struct,sys,time,zlib,tempfile,os,math
from a_net_wire import Packet,encode,decode,chunks,Collector,CHUNK_BYTES,STATUS,BEGIN,DATA,ACK,COMMIT,ABORT,RESULT

DESC=struct.Struct('!4sHHBBHIIIHHI');ACK_HEADER=struct.Struct('!4sBBHII')
ERROR_NAMES={1:'BUSY',2:'FORMAT',3:'STATE',4:'RANGE',5:'FRAME_CRC',6:'BACKEND_IO',7:'MISSING_CHUNKS',8:'NOT_READY',9:'TIMEOUT',10:'WRONG_OWNER',11:'CONFLICT',12:'UNSUPPORTED'}
class TransferError(RuntimeError):pass
@dataclass(frozen=True)
class ImageDesc:
 width:int;height:int;format:int;style:int;stride:int;total:int;crc32:int
 def validate(self):
  bpp={1:3,2:4,3:4}.get(self.format,0)
  if not (bpp and 1<=self.width<=1280 and 1<=self.height<=720 and 0<=self.style<4 and
    self.width*bpp<=self.stride and self.total==self.stride*self.height and 0<self.total<=4*1024*1024 and 0<=self.crc32<=0xffffffff):raise ValueError('image descriptor bounds/format')
  return self
 def pack(self):
  self.validate();return DESC.pack(b'IMG1',self.width,self.height,self.format,self.style,0,self.stride,self.total,self.crc32,CHUNK_BYTES,0,0)
 @classmethod
 def unpack(cls,raw):
  if len(raw)!=32:raise ValueError('image descriptor length')
  magic,w,h,fmt,style,res,stride,total,crc,chunk,res2,res3=DESC.unpack(raw)
  if magic!=b'IMG1' or res or res2 or res3 or chunk!=CHUNK_BYTES:raise ValueError('image descriptor ABI')
  return cls(w,h,fmt,style,stride,total,crc).validate()

def parse_ack(request,reply,generation=None):
 if reply.op!=ACK or (reply.session,reply.sequence,reply.offset,reply.total)!=(request.session,request.sequence,request.offset,request.total) or len(reply.payload)<16:raise TransferError('ACK identity/length')
 magic,op,status,flags,detail,gen=ACK_HEADER.unpack(reply.payload[:16])
 if magic!=b'ACK1' or op!=request.op:raise TransferError('image protocol ACK ABI; requires image-session firmware')
 if generation is not None and gen!=generation:raise TransferError('buffer generation changed')
 return status,flags,detail,gen

class ImageClient:
 def __init__(self,ip,port=40000,bind_ip='0.0.0.0',interface_index=None,timeout=0.25,attempts=5,job_timeout=30,transfer_timeout=180):
  if not all(math.isfinite(v)and v>0 for v in (timeout,job_timeout,transfer_timeout)) or type(attempts)is not int or attempts<1 or attempts>100:raise ValueError('finite positive retry/time bounds required')
  self.peer=(socket.gethostbyname(ip),port);self.timeout=timeout;self.attempts=attempts;self.job_timeout=job_timeout;self.transfer_timeout=transfer_timeout;self._transfer_deadline=None
  self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
  try:
   if interface_index is not None:
    if sys.platform!='win32' or not 1<=interface_index<=0xffffffff:raise ValueError('Windows interface index required')
    self.sock.setsockopt(socket.IPPROTO_IP,31,struct.pack('!I',interface_index))
   self.sock.bind((bind_ip,0))
  except BaseException:self.sock.close();raise
  self.stats=dict(sent=0,retransmissions=0,bad_datagrams=0,foreign_datagrams=0,busy_replies=0,control_replays=0,packet_retries=0,stale_datagrams=0)
  self.control=0x80000000
 def close(self):self.sock.close()
 def _control(self):
  n=self.control;self.control=(self.control+1)&0xffffffff;return n
 def _exchange(self,p,accept,reply_timeout=None,limit=None,attempt_limit=None):
  if self._transfer_deadline is not None:limit=self._transfer_deadline if limit is None else min(limit,self._transfer_deadline)
  raw=encode(p);attempt_bound=self.attempts if attempt_limit is None else attempt_limit;sent_attempts=0
  for attempt in range(attempt_bound):
   if limit is not None and time.perf_counter()>=limit:break
   if attempt:
    self.stats['retransmissions']+=1
    key='control_replays'if p.op==COMMIT or p.op==STATUS and p.payload==b'\0'else'packet_retries';self.stats[key]+=1
   self.sock.sendto(raw,self.peer);self.stats['sent']+=1;sent_attempts+=1
   deadline=time.perf_counter()+(self.timeout if reply_timeout is None else reply_timeout)
   if limit is not None:deadline=min(deadline,limit)
   while time.perf_counter()<deadline:
    self.sock.settimeout(max(0.000001,deadline-time.perf_counter()))
    try:data,source=self.sock.recvfrom(2048)
    except socket.timeout:break
    if source!=self.peer:self.stats['foreign_datagrams']+=1;continue
    try:q=decode(data)
    except ValueError:self.stats['bad_datagrams']+=1;continue
    if q.session==p.session and accept(q):return q
    self.stats['stale_datagrams']+=1
  if self._transfer_deadline is not None and time.perf_counter()>=self._transfer_deadline:raise TransferError('whole transfer deadline exceeded')
  raise TransferError(f'no valid reply after {sent_attempts} attempts, op=0x{p.op:02x}')
 def _ack(self,p,generation=None):
  def accept(r):
   if r.op!=ACK or r.sequence!=p.sequence:return False
   parse_ack(p,r,generation)
   return True
  deadline=time.perf_counter()+self.job_timeout
  # CRC/conversion at COMMIT and final result CRC may take longer than a
  # packet retransmission interval. Keep a total deadline, not an unbounded
  # retry loop. Reuse the same session/sequence for idempotent control replay.
  slow=p.op==COMMIT or p.op==STATUS and p.payload==b'\0'
  # Slow work can outlast one retry interval, but losing its ACK must not
  # wait longer than the board lease. Identical controls are idempotent.
  reply_timeout=min(1.0,max(self.timeout,0.5)) if slow else self.timeout
  attempt_bound=min(256,max(self.attempts,int(self.job_timeout/reply_timeout)+1)) if slow else self.attempts
  while True:
   q=self._exchange(p,accept,reply_timeout,deadline,attempt_bound);result=parse_ack(p,q,generation)
   if result[0]==1:
    self.stats['busy_replies']+=1
    remaining=deadline-time.perf_counter()
    if remaining<=0:raise TransferError('board remained BUSY until control deadline')
    time.sleep(min(0.02,remaining));continue
   if result[0]:raise TransferError('board rejected request: '+ERROR_NAMES.get(result[0],str(result[0])))
   return q,result
 def transfer(self,raw,desc):
  desc.validate()
  if not isinstance(raw,bytes) or len(raw)!=desc.total or zlib.crc32(raw)!=desc.crc32:raise ValueError('input bytes/CRC disagree with descriptor')
  for key in ('session','generation','upload_ms','task_wait_ms','commit_roundtrip_ms','ready_status_wait_ms','download_ms','total_ms','input_bytes','output_bytes','output_crc32','failure_phase','cancel_attempted','cancel_confirmed','cancel_error'):self.stats.pop(key,None)
  sid=secrets.randbits(32) or 1;begun=False;gen=None;start=time.perf_counter();self._transfer_deadline=start+self.transfer_timeout
  self.stats['session']=sid
  try:
   self.stats['phase']='capability'
   p=Packet(STATUS,sid,self._control(),payload=b'CAP1');_,cap=self._ack(p)
   if not cap[1]&0x8000 or cap[2]&7!=7:raise TransferError('endpoint lacks image upload/result/cancel capabilities')
   if desc.format==3 and not cap[2]&8:raise TransferError('endpoint lacks packed RGBX7 capability; use RGB888')
   self.stats['phase']='begin'
   p=Packet(BEGIN,sid,self._control(),total=desc.total,payload=desc.pack())
   # BEGIN can acquire a buffer even if its ACK is lost; cancel on any later error.
   begun=True;_,state=self._ack(p);gen=state[3];self.stats['generation']=gen
   if not gen:raise TransferError('board granted invalid zero generation')
   self.stats['phase']='upload'
   for p in chunks(raw,sid,DATA):self._ack(p,gen)
   uploaded=time.perf_counter()
   self.stats['phase']='commit'
   self._ack(Packet(COMMIT,sid,self._control(),total=desc.total,payload=struct.pack('!I',desc.crc32)),gen)
   self.stats['phase']='ready_status'
   committed=time.perf_counter();deadline=committed+self.job_timeout
   while True:
    q,info=self._ack(Packet(STATUS,sid,self._control(),payload=b'\0'),gen)
    if info[2]==3:
     if not info[1]&1 or len(q.payload)!=48:raise TransferError('missing result descriptor')
     result=ImageDesc.unpack(q.payload[16:]);break
    if info[2] not in (1,2):raise TransferError(f'unexpected task state {info[2]}')
    if time.perf_counter()>=deadline:raise TransferError('model task timeout')
    time.sleep(min(0.02,self.timeout))
   self.stats['phase']='download'
   ready=time.perf_counter();collector=Collector(sid,result.total,RESULT)
   for i in range(len(collector.parts)):
    p=Packet(STATUS,sid,self._control(),payload=b'\1'+struct.pack('!I',i))
    q=self._exchange(p,lambda r:(r.op==RESULT and r.sequence==i) or (r.op==ACK and r.sequence==p.sequence))
    if q.op==ACK:
     code=parse_ack(p,q,gen)[0];raise TransferError('result read rejected: '+ERROR_NAMES.get(code,str(code)))
    collector.accept(q)
   output=collector.finish(result.crc32);downloaded=time.perf_counter()
   self.stats['phase']='release'
   self._ack(Packet(STATUS,sid,self._control(),payload=b'\2'),gen);begun=False
   self.stats['phase']='done'
   self.stats.update(session=sid,generation=gen,upload_ms=(uploaded-start)*1000,task_wait_ms=(ready-uploaded)*1000,
    commit_roundtrip_ms=(committed-uploaded)*1000,ready_status_wait_ms=(ready-committed)*1000,download_ms=(downloaded-ready)*1000,total_ms=(time.perf_counter()-start)*1000,input_bytes=len(raw),output_bytes=len(output),output_crc32=f'{result.crc32:08x}')
   return output,result
  except BaseException:
   self.stats['failure_phase']=self.stats.get('phase','unknown');self.stats['phase']='failed'
   if begun:
    # Bounded cleanup; backend must keep ownership if its DMA cannot drain.
    self._transfer_deadline=time.perf_counter()+min(3.0,self.job_timeout)
    self.stats['cancel_attempted']=True
    try:self._ack(Packet(ABORT,sid,self._control()));self.stats['cancel_confirmed']=True
    except Exception as cleanup_error:self.stats.update(cancel_confirmed=False,cancel_error=f'{type(cleanup_error).__name__}: {cleanup_error}')
   raise
  finally:self._transfer_deadline=None

def load_image(path,style,size=None):
 from PIL import Image,ImageOps
 with Image.open(path)as source:
  gray16=source.format=='PNG'and source.mode in ('I','I;16','I;16B','I;16L')and 'transparency'not in source.info
  img=ImageOps.exif_transpose(source)
  if gray16:img=img.point(lambda value:value/257.0).convert('L')
  if img.mode in ('RGBA','LA')or 'transparency'in img.info:
   rgba=img.convert('RGBA')
   img=Image.alpha_composite(Image.new('RGBA',rgba.size,(255,255,255,255)),rgba).convert('RGB')
  else:img=img.convert('RGB')
  if size:img=ImageOps.pad(img,size,method=Image.Resampling.LANCZOS,color=(255,255,255))
  raw=img.tobytes();d=ImageDesc(img.width,img.height,1,style,img.width*3,len(raw),zlib.crc32(raw)).validate()
 return raw,d

def pack_rgbx7(raw,desc):
 if desc.format!=1 or desc.stride!=desc.width*3 or len(raw)!=desc.total or zlib.crc32(raw)!=desc.crc32:raise ValueError('packed input requires verified tight RGB888')
 lut=bytes(v>>1 for v in range(256)); packed=bytearray(desc.width*desc.height*4)
 for channel in range(3):packed[channel::4]=raw[channel::3].translate(lut)
 packed=bytes(packed)
 return packed,ImageDesc(desc.width,desc.height,3,desc.style,desc.width*4,len(packed),zlib.crc32(packed)).validate()

def save_image(path,raw,desc,overwrite=False):
 path=Path(path)
 if path.exists() and not overwrite:raise FileExistsError(path)
 if len(raw)!=desc.total or zlib.crc32(raw)!=desc.crc32:raise ValueError('result not verified')
 rows=[];bpp=3 if desc.format==1 else 4
 for y in range(desc.height):
  row=raw[y*desc.stride:y*desc.stride+desc.width*bpp]
  rows.append(row if bpp==3 else b''.join(row[x:x+3] for x in range(0,len(row),4)))
 rgb=b''.join(rows);tmp=None
 if desc.format==3:rgb=rgb.translate(bytes((v<<1)&255 for v in range(256)))
 try:
  with tempfile.NamedTemporaryFile(dir=path.parent,prefix=path.name+'.',suffix='.tmp',delete=False)as f:
   tmp=Path(f.name)
   if path.suffix.lower()=='.ppm':f.write(f'P6\n{desc.width} {desc.height}\n255\n'.encode()+rgb)
   elif path.suffix.lower()=='.png':
    from PIL import Image
    Image.frombytes('RGB',(desc.width,desc.height),rgb).save(f,format='PNG')
   else:raise ValueError('output must be .png or .ppm')
  if not overwrite and path.exists():raise FileExistsError(path)
  os.replace(tmp,path);tmp=None
 finally:
  if tmp is not None:tmp.unlink(missing_ok=True)

def main():
 a=argparse.ArgumentParser(description=__doc__)
 a.add_argument('input');a.add_argument('output');a.add_argument('--ip',required=True);a.add_argument('--port',type=int,default=40000)
 a.add_argument('--bind-ip',default='0.0.0.0');a.add_argument('--interface-index',type=int);a.add_argument('--style',type=int,choices=range(4),default=3)
 a.add_argument('--size',nargs=2,type=int,metavar=('WIDTH','HEIGHT'),default=(1280,720),help='Pad/resize input to the board NN dimensions (default:1280 720)');a.add_argument('--timeout',type=float,default=0.25)
 a.add_argument('--attempts',type=int,default=5);a.add_argument('--job-timeout',type=float,default=30);a.add_argument('--transfer-timeout',type=float,default=180,help='Whole image deadline; bounded cancellation gets up to 3 extra seconds');a.add_argument('--overwrite',action='store_true');a.add_argument('--report')
 a.add_argument('--packed-rgbx7',action='store_true',help='Requires v0.23 packed capability; host performs exact RGBX7 input conversion')
 args=a.parse_args()
 if Path(args.input).resolve()==Path(args.output).resolve():a.error('input and output paths must differ')
 if Path(args.output).exists() and not args.overwrite:a.error('output exists; choose another path or use --overwrite')
 if args.report and Path(args.report).resolve()in(Path(args.input).resolve(),Path(args.output).resolve()):a.error('report path must differ from input and output')
 client=None;report={'status':'PREPARING','client_version':'r5-packed'};success=False
 try:
  raw,d=load_image(args.input,args.style,tuple(args.size) if args.size else None)
  if args.packed_rgbx7:raw,d=pack_rgbx7(raw,d)
  client=ImageClient(args.ip,args.port,args.bind_ip,args.interface_index,args.timeout,args.attempts,args.job_timeout,args.transfer_timeout)
  output,result=client.transfer(raw,d);save_image(args.output,output,result,args.overwrite)
  report.update(client.stats,status='PASS');success=True
  print('Verified result saved:',args.output);print(json.dumps(report,indent=2))
 except BaseException as error:
  if client is not None:report.update(client.stats)
  report.update(status='INTERRUPTED'if isinstance(error,KeyboardInterrupt)else'FAIL',error=f'{type(error).__name__}: {error}')
  raise
 finally:
  if client is not None:client.close()
  if args.report:
   destination=Path(args.report);temporary=None
   try:
    destination.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8',dir=destination.parent,delete=False)as file:
     temporary=Path(file.name);json.dump(report,file,indent=2);file.flush();os.fsync(file.fileno())
    os.replace(temporary,destination);temporary=None
   except OSError as report_error:
    if success:raise
    print('Could not save failure report: '+str(report_error),file=sys.stderr)
   finally:
    if temporary is not None:temporary.unlink(missing_ok=True)
if __name__=='__main__':main()

