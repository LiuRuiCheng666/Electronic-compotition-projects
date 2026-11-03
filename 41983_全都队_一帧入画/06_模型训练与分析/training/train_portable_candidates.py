"""Distill the two approved RGB teachers into the unchanged 4KB A4 core.
Offline candidate preparation only; no hardware access.
"""
from pathlib import Path
import sys,json,time,copy,random,argparse
import numpy as np
from PIL import Image,ImageDraw
import torch
import torch.nn.functional as F
from train_students import Student,export,image,seed,sha,BASE,P
from art_models import ArtTransformer

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--style',required=True,choices=['vangogh','glass']);ap.add_argument('--warm',type=int,default=800);ap.add_argument('--qat',type=int,default=1600);args=ap.parse_args()
 out=P/'runs/portable_20261023'/args.style;out.mkdir(parents=True,exist_ok=False)
 cp=P/'architecture_experiments'/('vangogh_brush_rgb_v1' if args.style=='vangogh' else 'glass_mosaic_rgb_v1')/'model_best.pth'
 if not cp.exists():
  cp=next((Path('C:/Users/ASUS/Documents/ChatGPT')/'FPGA嵌赛/C_NN_INTEGRATION/other_styles_vangogh_glass_20261023/models').glob(args.style+'.pth'))
 seed(20261023);torch.set_num_threads(4);torch.backends.cudnn.benchmark=True;torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
 teacher=ArtTransformer().cuda().eval();teacher.load_state_dict(torch.load(cp,map_location='cuda',weights_only=True)['state_dict'])
 tr=sorted((P/'dataset/train').glob('*.jpg'));va=sorted((P/'dataset/val').glob('*.jpg'))[:12];files=tr+va
 assert len(tr)==200
 X=[];T=[]
 with torch.inference_mode():
  for i,p in enumerate(files):
   x=image(p,640,480);t=teacher(x[None].cuda())[0].cpu();X.append((x*255).round().byte());T.append((t*255).round().byte())
   if i%40==0:print('CACHE',args.style,i,flush=True)
 del teacher;torch.cuda.empty_cache();X=torch.stack(X);T=torch.stack(T)
 # Include the unchanged board tone curve in the training objective.
 sys.path.insert(0,str(BASE/'tools'));from board_exact_infer import tone_table
 table=torch.tensor(tone_table(),device='cuda',dtype=torch.float32)/256
 def render(y):
  level=y.amax(1,keepdim=True)*255;lo=level.floor().long().clamp(0,255);hi=(lo+1).clamp(0,255);f=level-lo
  return (y*(table[lo]*(1-f)+table[hi]*f)).clamp(0,1)
 def objective(y,t):
  edge=F.l1_loss(y[:,:,1:]-y[:,:,:-1],t[:,:,1:]-t[:,:,:-1])+F.l1_loss(y[:,:,:,1:]-y[:,:,:,:-1],t[:,:,:,1:]-t[:,:,:,:-1])
  return F.l1_loss(y,t)+.5*edge+.2*F.l1_loss(F.avg_pool2d(y,8),F.avg_pool2d(t,8))
 net=Student().cuda();opt=torch.optim.Adam(net.parameters(),lr=.002);best=1e9;best_state=None;log=[];start=time.time()
 for step in range(args.warm+args.qat):
  if step==args.warm:
   net.fold_qat();net.project();opt=torch.optim.Adam(net.parameters(),lr=.0004)
  ids=torch.randint(0,200,(12,));top=random.randrange(0,480-128+1,4);left=random.randrange(0,640-128+1,4)
  x=X[ids,:,top:top+128,left:left+128].cuda().float()/255;t=T[ids,:,top:top+128,left:left+128].cuda().float()/255
  if random.random()<.5:x=x.flip(3);t=t.flip(3)
  loss=objective(render(net(x)),t);opt.zero_grad(set_to_none=True);loss.backward();torch.nn.utils.clip_grad_norm_(net.parameters(),5);opt.step();net.project()
  if (step+1)%200==0:
   net.eval();scores=[];preview=[]
   with torch.inference_mode():
    for j in range(200,len(files)):
     y=render(net(X[j:j+1].cuda().float()/255))[0];scores.append(F.l1_loss(y,T[j].cuda().float()/255).item())
     if j<202:preview.append((j,y.cpu()))
   score=float(np.mean(scores));rec=dict(step=step+1,qat=net.qat,validation_display_teacher_mae=score,seconds=time.time()-start);log.append(rec);print(json.dumps(rec),flush=True)
   if net.qat and score<best:best=score;best_state=copy.deepcopy(net.state_dict())
   for j,y in preview:
    pan=Image.new('RGB',(960,260),'white');draw=ImageDraw.Draw(pan)
    for col,(a,title) in enumerate([(X[j],'Input'),(T[j],'Large RGB teacher'),((y*255).round().byte(),'4KB student + board tone')]):
     pan.paste(Image.fromarray(a.permute(1,2,0).numpy()).resize((320,240)),(col*320,20));draw.text((col*320+5,4),title,fill='black')
    pan.save(out/f'preview_{j-200}.png')
   (out/'training_log.json').write_text(json.dumps(log,indent=2),encoding='utf-8')
   if not net.qat:net.train()
 assert best_state is not None;net.load_state_dict(best_state);net.eval()
 torch.save(dict(state_dict=net.state_dict(),qat=True,architecture='A4 fixed 4KB',teacher_sha256=sha(cp)),out/'model_best.pth');layers=export(net,out)
 manifest=dict(style=args.style,teacher=str(cp),teacher_sha256=sha(cp),teacher_fraction=1,input_blend=0,display_aware=True,teacher_generation=[640,480],training_crop=[128,128],warm_steps=args.warm,qat_steps=args.qat,seed=20261023,best_display_teacher_mae=best,slot_sha256=sha(out/'slot.bin'),checkpoint_sha256=sha(out/'model_best.pth'),layers=layers,training_files=[dict(path=str(p),sha256=sha(p)) for p in tr],validation_files=[dict(path=str(p),sha256=sha(p)) for p in va],board_tested=False,quality_scope='Severely capacity-limited distillation candidate; not equivalent to the large teacher; needs human visual acceptance')
 (out/'TRAINING_MANIFEST.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8');print('COMPLETE',args.style,flush=True)
if __name__=='__main__':main()
