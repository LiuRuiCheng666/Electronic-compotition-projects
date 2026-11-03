"""Independent float screening. Never writes Efinity or original teacher assets."""
import argparse
import hashlib
import json
import random
import sys
import time
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageDraw
from torch.utils.data import Dataset, DataLoader
from torchvision import transforms as T
from torchvision.transforms import functional as TF

sys.path.insert(0, 'D:/aidrawer/training_plus')
from model import FastNeuralStyleNet, ConvNormAct, ResidualBlock
from train import VggFeatures, tv_loss

ROOT = Path('D:/aidrawer/output/Ukiyo-e/20261006_B16_IN_BN_Teacher_Distillation')
STYLE = Path('D:/aidrawer/stylepicture/Ukiyo-e/Ukiyo-e.jpg')
ORIGINAL = Path('D:/aidrawer/output/VanGogh_SelfPortrait/Legacy_Teacher_IN_runs3_ins/model_final.pth')
EXT = {'.jpg', '.jpeg', '.png', '.bmp', '.webp'}

def digest(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def files(p):
    return sorted(x for x in Path(p).rglob('*') if x.suffix.lower() in EXT)

def gram(x):
    # Accumulate Gram in float32, including when convolutions use AMP.
    b,c,h,w = x.shape
    x = x.float().reshape(b,c,h*w)
    with torch.autocast('cuda', enabled=False):
        return torch.bmm(x,x.transpose(1,2))/(c*h*w)

class Student(nn.Module):
    def __init__(self, wide, norm):
        super().__init__()
        bottleneck = 16 if wide else 8
        self.enc = nn.Sequential(ConvNormAct(3,4,norm=norm), ConvNormAct(4,4,norm=norm),
            ConvNormAct(4,8,stride=2,norm=norm), ConvNormAct(8,bottleneck,stride=2,norm=norm))
        self.res = ResidualBlock(bottleneck,norm)
        self.dec = nn.Sequential(nn.Upsample(scale_factor=2,mode='nearest'),
            ConvNormAct(bottleneck,4,norm=norm), nn.Upsample(scale_factor=2,mode='nearest'),
            ConvNormAct(4,4,norm=norm))
        self.out = nn.Sequential(nn.ReflectionPad2d(1),nn.Conv2d(4,3,3))
    def forward(self,x):
        return torch.tanh(self.out(self.dec(self.res(self.enc(x)))))*.5+.5

def model(stage):
    return FastNeuralStyleNet(8,3,'instance') if stage=='teacher' else Student(stage=='b_bn','instance' if stage=='a_in' else 'batch')

class Photos(Dataset):
    def __init__(self, paths, width, height):
        self.paths, self.width, self.height = paths,width,height
    def __len__(self): return len(self.paths)
    def __getitem__(self,i):
        with Image.open(self.paths[i]) as im: im=im.convert('RGB')
        y,x,h,w = T.RandomResizedCrop.get_params(im,scale=(.5,1),ratio=(1,1.7))
        im=TF.resized_crop(im,y,x,h,w,[self.height,self.width],antialias=True)
        if random.random()<.5: im=TF.hflip(im)
        return TF.to_tensor(im)

def save(path,obj):
    tmp=path.with_suffix('.tmp'); torch.save(obj,tmp); tmp.replace(path)

def evaluate(net,paths,out):
    out.mkdir(parents=True,exist_ok=True)
    prior=net.training; net.eval()
    with torch.no_grad():
        for i,p in enumerate(paths):
            with Image.open(p) as im: x=TF.to_tensor(im.convert('RGB').resize((640,480),Image.Resampling.BICUBIC))
            y=net(x[None].cuda())[0].cpu().clamp(0,1)
            TF.to_pil_image(y).save(out/f'{i:02d}_{p.stem}.png')
    net.train(prior)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--stage',choices=['teacher','a_in','a_bn','b_bn'],required=True)
    ap.add_argument('--run',required=True,help='New run name; use --resume to continue it')
    ap.add_argument('--teacher',type=Path,help='Approved new-style teacher model_final.pth')
    ap.add_argument('--steps',type=int,default=3000,help='Total optimizer steps, including resumed steps')
    ap.add_argument('--batch',type=int,default=2)
    ap.add_argument('--accum',type=int,default=2)
    ap.add_argument('--width',type=int,default=320)
    ap.add_argument('--height',type=int,default=240)
    ap.add_argument('--lr',type=float,default=2e-4)
    ap.add_argument('--distill-weight',type=float,default=10.)
    ap.add_argument('--save-every',type=int,default=500)
    ap.add_argument('--train-dir',type=Path,default=Path('D:/aidrawer/data/val2017'))
    ap.add_argument('--eval-dir',type=Path,default=Path('D:/aidrawer/data/student_eval_external'))
    ap.add_argument('--resume',action='store_true')
    a=ap.parse_args()
    if not torch.cuda.is_available(): raise RuntimeError('CUDA unavailable; do not silently train on CPU')
    if min(a.steps,a.batch,a.accum,a.save_every)<1 or a.width%4 or a.height%4: raise ValueError('Invalid step/batch/size')
    if Path(a.run).name!=a.run or a.run in ('.','..'): raise ValueError('run must be a simple directory name')
    run=ROOT/'runs'/a.run
    if run.exists() and not a.resume: raise RuntimeError('Run already exists. Choose another name or use --resume')
    if a.resume and not (run/'last.pth').exists(): raise RuntimeError('Missing last.pth')
    trainpaths,evalpaths=files(a.train_dir),files(a.eval_dir)
    if not trainpaths or not evalpaths: raise RuntimeError('Empty dataset')
    evhash={digest(p) for p in evalpaths}
    trainpaths=[p for p in trainpaths if digest(p) not in evhash]
    if len(trainpaths)<a.batch: raise RuntimeError('Insufficient train images after excluding evaluation duplicates')
    random.seed(20261006);torch.manual_seed(20261006);torch.cuda.manual_seed_all(20261006)
    torch.backends.cudnn.benchmark=True
    net=model(a.stage).cuda(); teacher=None
    if a.stage=='teacher':
        if digest(ORIGINAL)!='a2c7ef8852833a14793edc7d60aab5ec730fa8a2c8f60857a1fb746d738649ed': raise RuntimeError('Original teacher changed')
        net.load_state_dict(torch.load(ORIGINAL,map_location='cpu',weights_only=True))
    else:
        if not a.teacher: raise RuntimeError('--teacher required for students')
        meta=json.loads((a.teacher.parent/'config.json').read_text(encoding='utf-8'))
        if meta['stage']!='teacher' or meta['style_sha256']!=digest(STYLE): raise RuntimeError('Wrong teacher/style')
        teacher=model('teacher').cuda().eval()
        teacher.load_state_dict(torch.load(a.teacher,map_location='cpu',weights_only=True))
        teacher.requires_grad_(False)
    cfg={**vars(a),'train_dir':str(a.train_dir),'eval_dir':str(a.eval_dir),'teacher':str(a.teacher) if a.teacher else None,
         'style':str(STYLE),'style_sha256':digest(STYLE),'teacher_sha256':digest(a.teacher or ORIGINAL),
         'torch':torch.__version__,'gpu':torch.cuda.get_device_name(0),'seed':20261006,
         'train_files':[str(p) for p in trainpaths], 'eval_files':[{'path':str(p),'sha256':digest(p)} for p in evalpaths],
         'quality_status':'float screening only; no quantization or hardware validation',
         'loss_weights':{'content':5.,'style':1e7,'tv':1e-5,'output_distill':a.distill_weight}}
    if a.resume:
        old=json.loads((run/'config.json').read_text(encoding='utf-8'))
        for key in ['stage','width','height','batch','accum','lr','distill_weight','style_sha256','teacher_sha256','train_files','eval_files']:
            if key in old and old[key]!=cfg[key]: raise RuntimeError('Resume configuration mismatch: '+key)
    run.mkdir(parents=True,exist_ok=True)
    (run/('resume_config.json' if a.resume else 'config.json')).write_text(json.dumps(cfg,ensure_ascii=False,indent=2),encoding='utf-8')
    vgg=VggFeatures(['relu1_2','relu2_2','relu3_3','relu4_3']).cuda().eval().requires_grad_(False)
    # Target style resized to training dimensions; held-out comparison always VGA.
    with Image.open(STYLE) as im: sx=TF.to_tensor(im.convert('RGB').resize((a.width,a.height),Image.Resampling.BICUBIC))[None].cuda()
    with torch.no_grad(): targets={k:gram(v) for k,v in vgg(sx).items()}
    loader=DataLoader(Photos(trainpaths,a.width,a.height),batch_size=a.batch,shuffle=True,drop_last=True,num_workers=0)
    opt=torch.optim.Adam(net.parameters(),lr=a.lr)
    scaler=torch.amp.GradScaler('cuda'); step=0
    if a.resume:
        ck=torch.load(run/'last.pth',map_location='cpu',weights_only=False)
        net.load_state_dict(ck['model']);opt.load_state_dict(ck['optim']);scaler.load_state_dict(ck['scaler']);step=ck['step']
        random.setstate(ck['python_rng']);torch.set_rng_state(ck['torch_rng']);torch.cuda.set_rng_state_all(ck['cuda_rng'])
        # DataLoader restarts its shuffled epoch; resume is not bitwise replay.
    def checkpoint():
        save(run/'last.pth',{'model':net.state_dict(),'optim':opt.state_dict(),'scaler':scaler.state_dict(),'step':step,
            'python_rng':random.getstate(),'torch_rng':torch.get_rng_state(),'cuda_rng':torch.cuda.get_rng_state_all()})
        save(run/f'model_step{step:06d}.pth',net.state_dict())
    net.train();it=iter(loader);start=time.time();startstep=step
    print(f'{a.stage}: train={len(trainpaths)}, eval={len(evalpaths)}, effective batch={a.batch*a.accum}',flush=True)
    try:
        while step<a.steps:
            opt.zero_grad(set_to_none=True); metrics=torch.zeros(5,device='cuda')
            for _ in range(a.accum):
                try:x=next(it)
                except StopIteration:it=iter(loader);x=next(it)
                x=x.cuda()
                with torch.autocast('cuda',dtype=torch.float16):
                    with torch.no_grad():cf=vgg(x); ty=teacher(x) if teacher is not None else None
                    y=net(x); yf=vgg(y)
                    lc=F.mse_loss(yf['relu3_3'].float(),cf['relu3_3'].float())
                    ls=sum(F.mse_loss(gram(v),targets[k]) for k,v in yf.items())/len(yf)
                    lt=tv_loss(y.float());ld=F.l1_loss(y.float(),ty.float()) if ty is not None else y.new_zeros(())
                    loss=5*lc+1e7*ls+1e-5*lt+a.distill_weight*ld
                if not torch.isfinite(loss):raise RuntimeError('Nonfinite loss; last valid checkpoint preserved')
                scaler.scale(loss/a.accum).backward()
                metrics+=torch.stack([loss.detach(),lc.detach(),ls.detach(),lt.detach(),ld.detach()])/a.accum
            scaler.unscale_(opt);torch.nn.utils.clip_grad_norm_(net.parameters(),5.)
            scaler.step(opt);scaler.update();step+=1
            if step%20==0:
                vals=metrics.cpu().tolist();rec=dict(step=step,loss=vals[0],content=vals[1],style=vals[2],tv=vals[3],distill=vals[4])
                with (run/'history.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(rec)+'\n')
                rate=(time.time()-start)/(step-startstep)
                print(f'step {step}/{a.steps}, loss={vals[0]:.4f}, {rate:.2f}s/step, remaining~{rate*(a.steps-step)/60:.1f}min, peak={torch.cuda.max_memory_allocated()/2**30:.2f}GiB',flush=True)
            if step%a.save_every==0 or step==a.steps:
                checkpoint();evaluate(net,evalpaths,run/f'eval_step{step:06d}')
    except KeyboardInterrupt:
        # Save model/optimizer only after completed optimizer steps. An interrupted
        # BN microbatch can affect running statistics; final calibration repairs it.
        checkpoint();print('Interrupted; checkpoint saved. Resume with --resume.',flush=True);return
    if a.stage in ('a_bn','b_bn'):
        # Preserve train-state checkpoint; calibrate inference BN using TRAIN images
        # at the actual deployment resolution, never the external evaluation set.
        net.eval()
        for mod in net.modules():
            if isinstance(mod,nn.BatchNorm2d):mod.reset_running_stats();mod.momentum=None;mod.train()
        cal=DataLoader(Photos(trainpaths,640,480),batch_size=1,shuffle=False,num_workers=0)
        with torch.no_grad():
            for i,x in enumerate(cal):
                net(x.cuda())
                if i==127:break
        net.eval()
    save(run/'model_final.pth',net.state_dict());evaluate(net,evalpaths,run/'eval_final')
    print('Finished:',run,flush=True)

if __name__=='__main__':main()
