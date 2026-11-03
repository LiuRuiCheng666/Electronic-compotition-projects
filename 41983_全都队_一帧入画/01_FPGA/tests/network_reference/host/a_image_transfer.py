"""Reliable ANET image session client. Current HELLO-only bit cannot run this.

Uses stop-and-wait with bounded retransmission; no model executes on this PC.
"""
from dataclasses import dataclass
from pathlib import Path
import argparse,json,secrets,socket,struct,sys,time,zlib,tempfile,os
from a_net_wire import Packet,encode,decode,chunks,Collector,CHUNK_BYTES,STATUS,BEGIN,DATA,ACK,COMMIT,ABORT,RESULT

DESC=struct.Struct('!4sHHBBHIIIHHI');ACK_HEADER=struct.Struct('!4sBBHII')
ERROR_NAMES={1:'BUSY',2:'FORMAT',3:'STATE',4:'RANGE',5:'FRAME_CRC',6:'BACKEND_IO',7:'MISSING_CHUNKS',8:'NOT_READY',9:'TIMEOUT',10:'WRONG_OWNER',11:'CONFLICT',12:'UNSUPPORTED'}
class TransferError(RuntimeError):pass
@dataclass(frozen=True)
class ImageDesc:
 width:int;height:int;format:int;style:int;stride:int;total:int;crc32:int
 def validate(self):
  bpp={1:3,2:4}.get(self.format,0)
  if not (bpp and 1<=self.width<=1280 and 1<=self.height<=720 and 0<=self.style<4 and
    self.width*bpp<=self.stride and self.total==self.stride*self.height and 0<self.total<=8*1024*1024 and 0<=self.crc32<=0xffffffff):raise ValueError('image descriptor bounds/format')
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
 def __init__(self,ip,port=40000,bind_ip='0.0.0.0',interface_index=None,timeout=0.25,attempts=5,job_timeout=30):
  if timeout<=0 or attempts<1 or attempts>100 or job_timeout<=0:raise ValueError('retry/time bounds')
  self.peer=(socket.gethostbyname(ip),port);self.timeout=timeout;self.attempts=attempts;self.job_timeout=job_timeout
  self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
  try:
   if interface_index is not None:
    if sys.platform!='win32' or not 1<=interface_index<=0xffffffff:raise ValueError('Windows interface index required')
    self.sock.setsockopt(socket.IPPROTO_IP,31,struct.pack('!I',interface_index))
   self.sock.bind((bind_ip,0))
  except BaseException:self.sock.close();raise
  self.stats=dict(sent=0,retransmissions=0,bad_datagrams=0,foreign_datagrams=0)
  self.control=0x80000000
 def close(self):self.sock.close()
 def _control(self):
  n=self.control;self.control=(self.control+1)&0xffffffff;return n
 def _exchange(self,p,accept):
  raw=encode(p)
  for attempt in range(self.attempts):
   if attempt:self.stats['retransmissions']+=1
   self.sock.sendto(raw,self.peer);self.stats['sent']+=1;deadline=time.perf_counter()+self.timeout
   while time.perf_counter()<deadline:
    self.sock.settimeout(max(0.000001,deadline-time.perf_counter()))
    try:data,source=self.sock.recvfrom(2048)
    except socket.timeout:break
    if source!=self.peer:self.stats['foreign_datagrams']+=1;continue
    try:q=decode(data)
    except ValueError:self.stats['bad_datagrams']+=1;continue
    if q.session==p.session and accept(q):return q
  raise TransferError(f'no valid reply after {self.attempts} attempts, op=0x{p.op:02x}; current HELLO-only bit has no image service')
 def _ack(self,p,generation=None):
  def accept(r):
   if r.op!=ACK or r.sequence!=p.sequence:return False
   return parse_ack(p,r,generation)[0]!=1
  q=self._exchange(p,accept);result=parse_ack(p,q,generation)
  if result[0]:raise TransferError('board rejected request: '+ERROR_NAMES.get(result[0],str(result[0])))
  return q,result
 def transfer(self,raw,desc):
  desc.validate()
  if not isinstance(raw,bytes) or len(raw)!=desc.total or zlib.crc32(raw)!=desc.crc32:raise ValueError('input bytes/CRC disagree with descriptor')
  sid=secrets.randbits(32) or 1;begun=False;gen=None;start=time.perf_counter()
  try:
   p=Packet(STATUS,sid,self._control(),payload=b'CAP1');_,cap=self._ack(p)
   if not cap[1]&0x8000 or cap[2]&7!=7:raise TransferError('endpoint lacks image upload/result/cancel capabilities')
   p=Packet(BEGIN,sid,self._control(),total=desc.total,payload=desc.pack())
   # BEGIN can acquire a buffer even if its ACK is lost; cancel on any later error.
   begun=True;_,state=self._ack(p);gen=state[3]
   if not gen:raise TransferError('board granted invalid zero generation')
   for p in chunks(raw,sid,DATA):self._ack(p,gen)
   uploaded=time.perf_counter()
   self._ack(Packet(COMMIT,sid,self._control(),total=desc.total,payload=struct.pack('!I',desc.crc32)),gen)
   deadline=time.perf_counter()+self.job_timeout
   while True:
    q,info=self._ack(Packet(STATUS,sid,self._control(),payload=b'\0'),gen)
    if info[2]==3:
     if not info[1]&1 or len(q.payload)!=48:raise TransferError('missing result descriptor')
     result=ImageDesc.unpack(q.payload[16:]);break
    if info[2] not in (1,2):raise TransferError(f'unexpected task state {info[2]}')
    if time.perf_counter()>=deadline:raise TransferError('model task timeout')
    time.sleep(min(0.02,self.timeout))
   ready=time.perf_counter();collector=Collector(sid,result.total,RESULT)
   for i in range(len(collector.parts)):
    p=Packet(STATUS,sid,self._control(),payload=b'\1'+struct.pack('!I',i))
    q=self._exchange(p,lambda r:(r.op==RESULT and r.sequence==i) or (r.op==ACK and r.sequence==p.sequence))
    if q.op==ACK:
     code=parse_ack(p,q,gen)[0];raise TransferError('result read rejected: '+ERROR_NAMES.get(code,str(code)))
    collector.accept(q)
   output=collector.finish(result.crc32);downloaded=time.perf_counter()
   self._ack(Packet(STATUS,sid,self._control(),payload=b'\2'),gen);begun=False
   self.stats.update(session=sid,generation=gen,upload_ms=(uploaded-start)*1000,task_wait_ms=(ready-uploaded)*1000,
    download_ms=(downloaded-ready)*1000,total_ms=(time.perf_counter()-start)*1000,input_bytes=len(raw),output_bytes=len(output),output_crc32=f'{result.crc32:08x}')
   return output,result
  except BaseException:
   if begun:
    # Bounded cleanup; backend must keep ownership if its DMA cannot drain.
    try:self._ack(Packet(ABORT,sid,self._control()))
    except Exception:pass
   raise

def load_image(path,style,size=None):
 from PIL import Image,ImageOps
 with Image.open(path)as source:
  img=ImageOps.exif_transpose(source).convert('RGB')
  if size:img=ImageOps.pad(img,size,method=Image.Resampling.LANCZOS,color=(255,255,255))
  raw=img.tobytes();d=ImageDesc(img.width,img.height,1,style,img.width*3,len(raw),zlib.crc32(raw)).validate()
 return raw,d

def save_image(path,raw,desc,overwrite=False):
 path=Path(path)
 if path.exists() and not overwrite:raise FileExistsError(path)
 if len(raw)!=desc.total or zlib.crc32(raw)!=desc.crc32:raise ValueError('result not verified')
 rows=[];bpp=3 if desc.format==1 else 4
 for y in range(desc.height):
  row=raw[y*desc.stride:y*desc.stride+desc.width*bpp]
  rows.append(row if bpp==3 else b''.join(row[x:x+3] for x in range(0,len(row),4)))
 rgb=b''.join(rows);tmp=None
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
 a.add_argument('--size',nargs=2,type=int,metavar=('WIDTH','HEIGHT'));a.add_argument('--timeout',type=float,default=0.25)
 a.add_argument('--attempts',type=int,default=5);a.add_argument('--job-timeout',type=float,default=30);a.add_argument('--overwrite',action='store_true');a.add_argument('--report')
 args=a.parse_args()
 if Path(args.input).resolve()==Path(args.output).resolve():a.error('input and output paths must differ')
 if Path(args.output).exists() and not args.overwrite:a.error('output exists; choose another path or use --overwrite')
 raw,d=load_image(args.input,args.style,tuple(args.size) if args.size else None)
 client=ImageClient(args.ip,args.port,args.bind_ip,args.interface_index,args.timeout,args.attempts,args.job_timeout)
 try:
  output,result=client.transfer(raw,d);save_image(args.output,output,result,args.overwrite)
  if args.report:Path(args.report).write_text(json.dumps(client.stats,indent=2),encoding='utf-8')
  print('Verified result saved:',args.output);print(json.dumps(client.stats,indent=2))
 finally:client.close()
if __name__=='__main__':main()
