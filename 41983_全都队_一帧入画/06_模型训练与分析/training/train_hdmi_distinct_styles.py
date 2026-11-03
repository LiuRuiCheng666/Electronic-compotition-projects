"""Train three A4-compatible stylization candidates for the real HDMI RGB ABI.

Targets are explicitly procedural paired supervision, not paintings or learned
large-model teachers. Delivered preview is the quantized CNN, never the target.
"""
from pathlib import Path
import argparse,json,time,copy,random,sys,hashlib
import numpy as np
from PIL import Image,ImageDraw
import torch
import torch.nn.functional as F
import shutil
from train_students import P,Student,export,image,seed,sha

ROOT=P/'runs/hdmi_distinct_20261023'
STYLES=['comic_color','neon_cyan_magenta','woodcut_indigo_cream']

def blur(x,k=5):return F.avg_pool2d(F.pad(x,(k//2,)*4,mode='reflect'),k,1)

def target(x,style):
 # The target sees exactly reconstructed HDMI RGB7, excluding unavailable LSBs.
 x=torch.floor((x*255).round()/2)*2/255
 y=(x*x.new_tensor([.299,.587,.114])[None,:,None,None]).sum(1,keepdim=True)
 sm=blur(x,5);ys=blur(y,3)
 kx=x.new_tensor([[-1,0,1],[-2,0,2],[-1,0,1]])[None,None]/4
 gx=F.conv2d(F.pad(ys,(1,1,1,1),mode='reflect'),kx)
 gy=F.conv2d(F.pad(ys,(1,1,1,1),mode='reflect'),kx.transpose(2,3))
 edge=(gx.abs()+gy.abs())
 ink=((edge-.025)/.12).clamp(0,1)
 if style=='comic_color':
  l=(sm*sm.new_tensor([.299,.587,.114])[None,:,None,None]).sum(1,keepdim=True)
  c=(l+1.25*(sm-l)).clamp(0,1)
  # Soft enough tone transitions to fit the actual tiny deployment model.
  q=(c*4).round()/4
  fill=.72*q+.28*c
  return (fill*(1-.92*ink)+.018*ink).clamp(0,1)
 if style=='neon_cyan_magenta':
  # Cold cyan outlines, magenta warm-colour outlines, dark violet scene body.
  warm=torch.sigmoid((sm[:,0:1]-sm[:,2:3])*10)
  cyan=x.new_tensor([.02,.95,1.])[None,:,None,None]
  pink=x.new_tensor([1.,.035,.68])[None,:,None,None]
  line=cyan*(1-warm)+pink*warm
  background=x.new_tensor([.065,.018,.15])[None,:,None,None]+.15*sm
  glow=((edge-.008)/.15).clamp(0,1)
  return (background*(1-.88*glow)+line*glow).clamp(0,1)
 # Indigo woodcut print: three tonal regions plus crisp local contours.
 dark=x.new_tensor([.035,.09,.20])[None,:,None,None]
 mid=x.new_tensor([.25,.43,.58])[None,:,None,None]
 paper=x.new_tensor([1.,.91,.69])[None,:,None,None]
 a=torch.sigmoid((blur(y,5)-.32)*22);b=torch.sigmoid((blur(y,5)-.64)*22)
 fill=dark*(1-a)+mid*(a-b)+paper*b
 return (fill*(1-.82*ink)+dark*.82*ink).clamp(0,1)

def objective(y,t):
 dx=lambda z:z[:,:,:,1:]-z[:,:,:,:-1]
 dy=lambda z:z[:,:,1:]-z[:,:,:-1]
 return F.l1_loss(y,t)+.5*(F.l1_loss(dx(y),dx(t))+F.l1_loss(dy(y),dy(t)))+.15*F.l1_loss(F.avg_pool2d(y,8),F.avg_pool2d(t,8))

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--warm',type=int,default=1200);ap.add_argument('--qat',type=int,default=4800);ap.add_argument('--continue-run',action='store_true');args=ap.parse_args()
 ROOT.mkdir(exist_ok=args.continue_run,parents=True)
 seed(20261023);torch.set_num_threads(4);torch.backends.cudnn.benchmark=True
 torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
 tr=sorted((P/'dataset/train').glob('*.jpg'));va=sorted((P/'dataset/val').glob('*.jpg'))[:12]
 reserved=sorted((P/'dataset/val').glob('*.jpg'))[40:48]
 assert len(tr)==200 and len(va)==12 and len(reserved)==8
 assert not {sha(p)for p in tr}&{sha(p)for p in va+reserved}
 paths=tr+va
 X=torch.stack([(image(p,640,480)*255).round().byte()for p in paths])
 # Neutral colours and smooth digital graphics broaden HDMI colour coverage.
 synt=[]
 yy,xx=np.meshgrid(np.linspace(0,1,480),np.linspace(0,1,640),indexing='ij')
 for j in range(16):
  r=np.random.default_rng(20261023+j)
  a=np.stack([xx,yy,(xx+yy)/2])
  if j%2:a=np.tile(r.random((3,8,10)).repeat(60,1).repeat(64,2),(1,1,1))
  synt.append(torch.from_numpy((a*255).round().clip(0,255).astype(np.uint8)))
 X=torch.cat([X[:200],torch.stack(synt),X[200:]],0);train_n=216
 provenance=dict(training=[dict(path=str(p),sha256=sha(p))for p in tr],validation=[dict(path=str(p),sha256=sha(p))for p in va],reserved=[dict(path=str(p),sha256=sha(p))for p in reserved],synthetic_training_frames=16,seed=20261023,
  supervision='Procedural RGB paired targets: local smoothing, posterization/edges or limited palette. No claimed painting/reference-image training.',
  inspiration_sources=['https://research.adobe.com/publication/xdog-an-extended-difference-of-gaussians-compendium-including-advanced-image-stylization/'],
  deployment='Unchanged A4 4096-byte slot; actual RGB7 input; HDMI output has no camera tone curve. QAT and integer preview required.',
  script_sha256=sha(Path(__file__)),glass_preserved=True,hardware_accessed=False)
 if not(ROOT/'DATA_AND_METHOD.json').exists():(ROOT/'DATA_AND_METHOD.json').write_text(json.dumps(provenance,indent=2),encoding='utf-8')
 (ROOT/'CONTINUE_SESSION.json').write_text(json.dumps(dict(script_sha256=sha(Path(__file__)),continue_run=args.continue_run),indent=2),encoding='utf-8')
 for style in STYLES:
  out=ROOT/style
  if(out/'TRAINING_MANIFEST.json').exists():print('PRESERVE COMPLETED',style,flush=True);continue
  out.mkdir(exist_ok=True);T=[];start=time.time()
  if(out/'training_log.json').exists():shutil.copy2(out/'training_log.json',out/f'interrupted_log_{time.time_ns()}.json')
  with torch.inference_mode():
   for batch in X.split(8):T.append((target(batch.cuda().float()/255,style)*255).round().byte().cpu())
  T=torch.cat(T);net=Student().cuda();opt=torch.optim.Adam(net.parameters(),lr=.002)
  best=1e9;best_state=None;records=[]
  for step in range(args.warm+args.qat):
   if step==args.warm:
    net.fold_qat();net.project();opt=torch.optim.Adam(net.parameters(),lr=.00035)
   ids=torch.randint(0,train_n,(12,));top=random.randrange(0,353,4);left=random.randrange(0,513,4)
   x=X[ids,:,top:top+128,left:left+128].cuda().float()/255;t=T[ids,:,top:top+128,left:left+128].cuda().float()/255
   if random.random()<.5:x=x.flip(3);t=t.flip(3)
   y=net(x);loss=objective(y,t);opt.zero_grad(set_to_none=True);loss.backward();torch.nn.utils.clip_grad_norm_(net.parameters(),5);opt.step();net.project()
   if (step+1)%400==0:
    net.eval();scores=[]
    with torch.inference_mode():
     for j in range(train_n,len(X)):
      z=net(X[j:j+1].cuda().float()/255);scores.append(float(objective(z,T[j:j+1].cuda().float()/255)))
    score=float(np.mean(scores));r=dict(style=style,step=step+1,qat=net.qat,validation_objective=score,seconds=time.time()-start);records.append(r);print(json.dumps(r),flush=True)
    if net.qat and score<best:best=score;best_state=copy.deepcopy(net.state_dict())
    (out/'training_log.json').write_text(json.dumps(records,indent=2),encoding='utf-8')
    torch.save(dict(state_dict=net.state_dict(),qat=net.qat,step=step+1,style=style,best_state=best_state,best_validation=best),out/'stage_checkpoint.pth')
    if not net.qat:net.train()
  assert best_state is not None
  net.load_state_dict(best_state);net.eval();torch.save(dict(state_dict=net.state_dict(),qat=True,style=style,architecture='A4 fixed4KB',supervision='Procedural paired targets; no painting teacher'),out/'model_best.pth')
  layers=export(net,out)
  (out/'TRAINING_MANIFEST.json').write_text(json.dumps(dict(style=style,status='TRAINED_QAT_EXACT_AND_VISUAL_REVIEW_PENDING',warm=args.warm,qat=args.qat,best_validation_objective=best,parameters=sum(p.numel()for p in net.parameters()),slot_bytes=4096,slot_sha256=sha(out/'slot.bin'),checkpoint_sha256=sha(out/'model_best.pth'),layers=layers,board_tested=False,display_tone_applied=False),indent=2),encoding='utf-8')
  print('COMPLETE',style,flush=True)
 (ROOT/'TRAINING_COMPLETE.json').write_text(json.dumps(dict(status='THREE_MODELS_TRAINED',styles=STYLES,board_tested=False),indent=2),encoding='utf-8')
if __name__=='__main__':main()
