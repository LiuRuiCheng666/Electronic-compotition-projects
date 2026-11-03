"""Independent camera-domain A4 QAT candidates; no claim of real-sensor calibration."""
from pathlib import Path
import sys,json,time,copy,random,argparse,hashlib
import numpy as np
from PIL import Image
import torch
from torch import nn
import torch.nn.functional as F
import shutil
from train_students import P,Student,export,seed,sha
from batch10_styles import STYLES,target,objective
from train_students import image

ROOT=P/'runs/camera_distinct_20261023'
BASE=Path('D:/FPGA_C/FOUR_STYLES_COLORFIX_20261023')

def camera_image(p):
 im=np.asarray(Image.open(p).convert('RGB').resize((1920,1080),Image.Resampling.BICUBIC))
 x=240+(9*np.arange(640))//4;y=(9*np.arange(480))//4
 return torch.from_numpy(im[y[:,None],x[None,:]].transpose(2,0,1).copy())

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--domain',choices=['hdmi','camera'],required=True);ap.add_argument('--warm',type=int,default=1200);ap.add_argument('--qat',type=int,default=24000);ap.add_argument('--continue-run',action='store_true');ap.add_argument('--resume-stage',action='store_true');ap.add_argument('--gpu-cache',action='store_true');args=ap.parse_args()
 global ROOT,BASE
 ROOT=P/'runs'/f'{args.domain}_distinct_batch10_20261024'
 BASE=Path('D:/FPGA_C/FOUR_STYLES_COLORFIX_20261023')if args.domain=='camera'else Path('D:/FPGA_C/V6_8_HDMI_FOUR_STYLES_20261023')
 assert args.warm==1200 and args.qat>=8000,'Convergence run needs warm1200 and at least8000 QAT steps'
 ROOT.mkdir(exist_ok=args.continue_run,parents=True);seed(2026102410);torch.set_num_threads(1 if args.gpu_cache else 4);torch.backends.cudnn.benchmark=True
 torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
 sys.path.insert(0,str(BASE/'tools'));from board_exact_infer import tone_table
 table=torch.tensor(tone_table(),device='cuda',dtype=torch.float32)/256
 def render(y):
  if args.domain=='hdmi':return y
  level=y.amax(1,keepdim=True)*255;lo=level.floor().long().clamp(0,255);hi=(lo+1).clamp(0,255);f=level-lo
  return (y*(table[lo]*(1-f)+table[hi]*f)).clamp(0,1)
 tr=sorted((P/'dataset/train').glob('*.jpg'));va=sorted((P/'dataset/val').glob('*.jpg'))[:12];reserved=sorted((P/'dataset/val').glob('*.jpg'))[40:48]
 assert len(tr)==200 and len(va)==12 and len(reserved)==8
 assert not {sha(p)for p in tr}&{sha(p)for p in va+reserved}
 X=torch.stack([camera_image(p)if args.domain=='camera'else(image(p,640,480)*255).round().byte()for p in tr+va]);train_n=len(tr)
 if args.gpu_cache:X=X.cuda()
 provenance=dict(seed=2026102410,training=[dict(path=str(p),sha256=sha(p))for p in tr],validation=[dict(path=str(p),sha256=sha(p))for p in va],reserved=[dict(path=str(p),sha256=sha(p))for p in reserved],
  camera_preprocess='Resize source to1920x1080; crop/sample x=240+floor(9*u/4), y=floor(9*v/4); RGB7 model input.'if args.domain=='camera'else'Not used for HDMI',
  tone_source=str(Path('D:/FPGA_C/FOUR_STYLES_COLORFIX_20261023/rtl/nn/rtl/camera_tone_mapper.v')),tone_sha256=sha(Path('D:/FPGA_C/FOUR_STYLES_COLORFIX_20261023/rtl/nn/rtl/camera_tone_mapper.v')),
  real_sensor_frames_used=False,physical_white_balance_calibrated=False,
  augmentation='Independent per-channel gain0.90..1.10, global exposure0.88..1.12, gamma0.92..1.08, noise std0..1.2/255; paired target stays clean.'if args.domain=='camera'else'No photometric augmentation; digital HDMI RGB',
  supervision='Procedural bronze/patina, jewel enamel and midnight blueprint targets; no paintings or neural teacher.', target_code_sha256=sha(P/'batch10_styles.py'), trainer_sha256=sha(Path(__file__)), inspiration_sources=__import__('batch10_styles').SOURCES, methodology='Adaptive QAT: minimum8000 steps, maximum24000, evaluate every400. Stop only with <0.5% best-validation improvement over2000 steps and latest score within6% of best; learning-rate halves each4000 QAT steps. Manual visual and exact integer/RTL gates follow. All three targets are mirror-equivariant. Camera QAT base LR0.00015; HDMI0.00025. Restore best weights and reduce LR4x after3 consecutive validations >12% above best after8000 QAT steps, requiring2000 further steps before stopping.',
  hardware_accessed=False,latest_teammate_camera_source='User confirmed FOUR_STYLES_COLORFIX1_BURN_20261023.zip matches camera baseline', domain=args.domain, batch='tenth distinctive styles', input_preprocess='exact camera crop/sample'if args.domain=='camera'else'640x480 RGB7', display_curve='fixed camera tone'if args.domain=='camera'else'none')
 if not(ROOT/'DATA_AND_METHOD.json').exists():(ROOT/'DATA_AND_METHOD.json').write_text(json.dumps(provenance,indent=2),encoding='utf-8')
 (ROOT/'CONTINUE_SESSION.json').write_text(json.dumps(dict(script_sha256=sha(Path(__file__)),continue_run=args.continue_run,resume_stage=args.resume_stage,gpu_cache=args.gpu_cache,resume_optimizer='Adam restarted; learned weights and best validation snapshot preserved'),indent=2),encoding='utf-8')
 for style in STYLES:
  out=ROOT/style
  if(out/'TRAINING_MANIFEST.json').exists():print('PRESERVE COMPLETED',args.domain,style,flush=True);continue
  out.mkdir(exist_ok=True);T=[];start=time.time()
  if(out/'training_log.json').exists():shutil.copy2(out/'training_log.json',out/f'interrupted_log_{time.time_ns()}.json')
  with torch.inference_mode():
   for batch in X.split(8):T.append((target(batch.cuda().float()/255,style)*255).round().byte().cpu())
  T=torch.cat(T)
  if args.gpu_cache:T=T.cuda()
  net=Student().cuda();best=1e9;best_state=None;records=[];start_step=0;best_step=0;convergence=None
  resume_file=out/'recovery_checkpoint.pth'
  if args.resume_stage and resume_file.exists():
   cp=torch.load(resume_file,map_location='cuda',weights_only=True)
   net.qat=cp['qat']
   if net.qat:net.norms=nn.ModuleList([nn.Identity()for _ in range(9)])
   net.load_state_dict(cp['state_dict']);best=cp['best_validation'];best_state=cp['best_state'];start_step=cp['step']
   records=json.loads((out/'training_log.json').read_text())
   if net.qat:net.eval()
   print('RESUME',style,start_step,flush=True)
  if args.resume_stage:raise RuntimeError('Use explicit staged continuation, not legacy resume, for adaptive convergence training')
  base_lr=.00015 if args.domain=='camera'else .00025
  lr_multiplier=1.;recoveries=[];last_recovery=0
  opt=torch.optim.Adam(net.parameters(),lr=base_lr if net.qat else .002)
  for step in range(start_step,args.warm+args.qat):
   if step==args.warm:net.fold_qat();net.project();opt=torch.optim.Adam(net.parameters(),lr=base_lr)
   if net.qat:
    rate=base_lr*lr_multiplier*(.5**((step-args.warm)//4000))
    for group in opt.param_groups:group['lr']=rate
   ids=torch.randint(0,train_n,(12,),device='cuda'if args.gpu_cache else'cpu');top=random.randrange(0,353,4);left=random.randrange(0,513,4)
   x=X[ids,:,top:top+128,left:left+128].cuda().float()/255;t=T[ids,:,top:top+128,left:left+128].cuda().float()/255
   if random.random()<.5:x=x.flip(3);t=t.flip(3)
   if args.domain=='camera':
    gain=.9+.2*torch.rand((12,3,1,1),device='cuda');exposure=.88+.24*torch.rand((12,1,1,1),device='cuda');gamma=.92+.16*torch.rand((12,1,1,1),device='cuda')
    x=(x.pow(gamma)*gain*exposure+torch.randn_like(x)*torch.rand((),device='cuda')*(1.2/255)).clamp(0,1)
   loss=objective(render(net(x)),t);opt.zero_grad(set_to_none=True);loss.backward();torch.nn.utils.clip_grad_norm_(net.parameters(),5);opt.step();net.project()
   if (step+1)%400==0:
    net.eval();scores=[]
    with torch.inference_mode():
     for j in range(train_n,len(X)):scores.append(float(objective(render(net(X[j:j+1].cuda().float()/255)),T[j:j+1].cuda().float()/255)))
    score=float(np.mean(scores));r=dict(domain=args.domain,style=style,step=step+1,qat=net.qat,validation_display_objective=score,seconds=time.time()-start);records.append(r);print(json.dumps(r),flush=True)
    if net.qat and score<best:best=score;best_state=copy.deepcopy(net.state_dict());best_step=step+1
    (out/'training_log.json').write_text(json.dumps(records,indent=2),encoding='utf-8')
    torch.save(dict(state_dict=net.state_dict(),qat=net.qat,step=step+1,style=style,best_state=best_state,best_validation=best),out/'stage_checkpoint.pth')
    if net.qat and step+1-args.warm>=8000 and len(records)>=3 and all(v['validation_display_objective']>best*1.12 for v in records[-3:]) and step+1-last_recovery>=2000:
     shutil.copy2(out/'stage_checkpoint.pth',out/f'pre_restore_{step+1}.pth')
     event=dict(step=step+1,best_step=best_step,best_validation=best,latest_validation=score,action='Restore best; reset Adam; reduce LR4x',checkpoint_sha256=sha(out/f'pre_restore_{step+1}.pth'))
     recoveries.append(event);last_recovery=step+1;lr_multiplier*=.25;net.load_state_dict(best_state);opt=torch.optim.Adam(net.parameters(),lr=rate*.25)
     (out/'RECOVERY_EVENTS.json').write_text(json.dumps(recoveries,indent=2),encoding='utf-8');print('RESTORE_BEST',json.dumps(event),flush=True)
    if net.qat and step+1-args.warm>=8000 and (not recoveries or step+1-last_recovery>=2000):
     qs=[v for v in records if v['qat']]
     old_best=min(v['validation_display_objective']for v in qs[:-5])
     relative=(old_best-best)/max(old_best,1e-12)
     if relative<.005 and score<=best*1.06:
      convergence=dict(status='VALIDATION_PLATEAU_REACHED',actual_total_steps=step+1,actual_qat_steps=step+1-args.warm,best_step=best_step,best_validation=best,window_steps=2000,relative_best_improvement=relative,threshold=.005,latest_validation=score,learning_rate=opt.param_groups[0]['lr'],scope='Validation plateau for fixed A4 and procedural target; not global optimum or board/aesthetic acceptance')
      convergence['recovery_events']=recoveries
      print('CONVERGED',json.dumps(convergence),flush=True);break
    if not net.qat:net.train()
  if convergence is None:raise RuntimeError(f'{style}: plateau not reached; retain checkpoints, do not release')
  (out/'CONVERGENCE.json').write_text(json.dumps(convergence,indent=2),encoding='utf-8')
  assert best_state is not None;net.load_state_dict(best_state);net.eval()
  torch.save(dict(state_dict=net.state_dict(),qat=True,style=style,domain=args.domain,architecture='A4 fixed4KB',supervision='Procedural paired targets; no painting teacher'),out/'model_best.pth');layers=export(net,out)
  (out/'TRAINING_MANIFEST.json').write_text(json.dumps(dict(style=style,domain=args.domain,status='TRAINED_QAT_EXACT_AND_VISUAL_REVIEW_PENDING',warm=args.warm,qat=convergence['actual_qat_steps'],actual_total_steps=convergence['actual_total_steps'],maximum_qat_budget=args.qat,validation_plateau_reached=True,best_step=best_step,best_validation_objective=best,slot_bytes=4096,slot_sha256=sha(out/'slot.bin'),checkpoint_sha256=sha(out/'model_best.pth'),layers=layers,board_tested=False,display_tone_applied=args.domain=='camera',real_sensor_frames_used=False),indent=2),encoding='utf-8')
  print('COMPLETE',args.domain,style,flush=True)
 (ROOT/'TRAINING_COMPLETE.json').write_text(json.dumps(dict(status='THREE_MODELS_TRAINED',domain=args.domain,styles=STYLES,board_tested=False),indent=2),encoding='utf-8')
if __name__=='__main__':main()
