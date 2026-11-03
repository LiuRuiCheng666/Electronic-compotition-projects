"""Train new A4 students against real pretrained neural-style teachers.
No hardware or baseline files are modified. PyTorch teacher attribution in teacher/.
"""
from pathlib import Path
import sys,time,json,hashlib,random,math,argparse,re,copy,struct,zlib
import numpy as np
from PIL import Image,ImageDraw
import torch
from torch import nn
import torch.nn.functional as F

P=Path(__file__).resolve().parent
BASE=Path('D:/FPGA_C/ABC_best_current_20261022')
sys.path.insert(0,str(P/'teacher'))
from transformer_net import TransformerNet
NAMES=['enc.0','enc.1','enc.2','enc.3','res.c1','res.c2','dec.1','dec.3','out.1']
CIN=[3,4,4,8,4,4,4,4,4];COUT=[4,4,8,4,4,4,4,4,3]
STRIDE=[1,1,2,2,1,1,1,1,1];RELU=[1,1,1,1,1,0,1,1,0]
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def seed(n):
 random.seed(n);np.random.seed(n);torch.manual_seed(n);torch.cuda.manual_seed_all(n)
def quant(x,s):
 y=(x/s).round().clamp(-127,127)*s
 return x+(y-x).detach()
class Student(nn.Module):
 def __init__(self):
  super().__init__()
  self.layers=nn.ModuleList([nn.Conv2d(ci,co,3,stride=st) for ci,co,st in zip(CIN,COUT,STRIDE)])
  self.norms=nn.ModuleList([nn.BatchNorm2d(co) if i<8 else nn.Identity() for i,co in enumerate(COUT)])
  self.register_buffer('shifts',torch.full((9,),7,dtype=torch.int64))
  self.qat=False
 def forward(self,x):
  x=torch.floor((x*255).round()/2)/128
  skip=None
  for i,(c,n) in enumerate(zip(self.layers,self.norms)):
   if i in (6,7):x=F.interpolate(x,scale_factor=2,mode='nearest')
   x=F.pad(x,(1,1,1,1),mode='reflect')
   if self.qat:
    si=1/128 if i==0 else 1/16;so=1/32 if i==8 else 1/16
    ws=(2.**(-int(self.shifts[i])))*so/si
    w=quant(c.weight,ws)
    b=c.bias+((c.bias/(si*ws)).round()*(si*ws)-c.bias).detach()
    y=F.conv2d(x,w,b,stride=STRIDE[i])
   else:y=n(c(x))
   if RELU[i]:y=F.relu(y)
   if self.qat:y=quant(y,so)
   x=y
   if i==3:skip=x
   if i==5:
    x=x+skip
    if self.qat:x=quant(x,1/16)
  return (torch.tanh(x)+1)/2
 def fold_qat(self):
  self.eval()
  for i in range(8):
   self.layers[i]=torch.nn.utils.fusion.fuse_conv_bn_eval(self.layers[i],self.norms[i])
   self.norms[i]=nn.Identity()
  for i,c in enumerate(self.layers):
   si=1/128 if i==0 else 1/16;so=1/32 if i==8 else 1/16
   candidates=[s for s in [9,8,7,6] if c.weight.abs().max().item() <=127*(2.**-s)*so/si]
   self.shifts[i]=max(candidates) if candidates else 6
  self.qat=True
 def project(self):
  if not self.qat:return
  with torch.no_grad():
   for i,c in enumerate(self.layers):
    si=1/128 if i==0 else 1/16;so=1/32 if i==8 else 1/16
    ws=(2.**(-int(self.shifts[i])))*so/si
    c.weight.clamp_(-127*ws,127*ws)
    a=2**(24-int(self.shifts[i]));lim=min(65535,(2**31-1)//a)
    c.bias.clamp_(-lim*si*ws,lim*si*ws)
def image(p,w=256,h=192):
 return torch.from_numpy(np.array(Image.open(p).convert('RGB').resize((w,h),Image.Resampling.BICUBIC)).transpose(2,0,1).copy()).float()/255
def target(teacher,x):
 # Soft teacher blend retains scene structure; never a hand-written color filter.
 return .85*(teacher(x*255)/255).clamp(0,1)+.15*x
def loss_fn(y,t,x):
 l=F.l1_loss(y,t)
 edge=F.l1_loss(y[:,:,1:]-y[:,:,:-1],t[:,:,1:]-t[:,:,:-1])+F.l1_loss(y[:,:,:,1:]-y[:,:,:,:-1],t[:,:,:,1:]-t[:,:,:,:-1])
 return l+.5*edge+.1*F.l1_loss(F.avg_pool2d(y,8),F.avg_pool2d(t,8))
def export(net,out):
 assert net.qat
 packed=bytearray();coeff=[];records=[]
 for i,c in enumerate(net.layers):
  si=1/128 if i==0 else 1/16;so=1/32 if i==8 else 1/16
  shift=int(net.shifts[i]);ws=2.**(-shift)*so/si;a=2**(24-shift)
  qw=(c.weight/ws).round().clamp(-127,127).to(torch.int8).cpu().numpy()
  bq=(c.bias/(si*ws)).round().long().cpu().numpy();b=bq*a
  assert np.all(b>=-2**31) and np.all(b<2**31)
  co=(COUT[i]+3)//4*4;ci=4 if i==0 else CIN[i]
  arr=np.zeros((co,ci,3,3),np.int8);arr[:COUT[i],:CIN[i]]=qw
  for og in range(0,co,4):
   for ig in range(0,ci,4):packed.extend(arr[og:og+4,ig:ig+4].tobytes());packed.extend(bytes(16))
  for j in range(co):coeff.append(struct.pack('<Ii',a,int(b[j])) if j<COUT[i] else bytes(8))
  records.append({'layer':NAMES[i],'shift':shift,'A':a,'input_scale':si,'output_scale':so,'weight_scale':ws,'bias_codes':bq.tolist()})
 assert len(packed)==1760 and len(coeff)==40
 lut=bytes(round((math.tanh((i-128)/32)+1)*127.5) for i in range(256))
 assert lut[128]==128 and all(lut[i]+lut[256-i]==255 for i in range(1,128))
 slot=bytearray(4096);slot[:1760]=packed;slot[0x800:0x940]=b''.join(coeff);slot[0xa00:0xb00]=lut
 (out/'slot.bin').write_bytes(slot)
 (out/'a4_weights_pci4.mem').write_text(''.join(f'{int.from_bytes(packed[i:i+32],"little"):064x}\n' for i in range(0,1760,32)),encoding='ascii')
 (out/'a4_coeff.mem').write_text(''.join(f'{int.from_bytes(v,"little"):016x}\n' for v in coeff+[bytes(8)]*24),encoding='ascii')
 (out/'a4_tanh.mem').write_text(''.join(f'{v:02x}\n' for v in lut),encoding='ascii')
 return records
