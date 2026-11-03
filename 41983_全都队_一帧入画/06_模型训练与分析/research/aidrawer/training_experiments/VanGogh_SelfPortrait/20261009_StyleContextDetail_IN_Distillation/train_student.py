"""Original-IN-teacher distillation; palette quotas are reporting only."""
import argparse,hashlib,json,math,random,sys,time
from pathlib import Path
import torch
import torch.nn.functional as F
from torch.utils.data import Dataset,DataLoader
from PIL import Image,ImageDraw
from torchvision import transforms as T
from torchvision.transforms import functional as TF
from student_model import StyleContextDetail
from palette_report import palette_report
sys.path.insert(0,'D:/aidrawer/training_plus')
from model import FastNeuralStyleNet
from train import VggFeatures

ROOT=Path('D:/aidrawer/output/VanGogh_SelfPortrait/20261009_StyleContextDetail_IN_Distillation')
TERMS=['pixel','feature','teacher_gram','palette','regional_palette','gradient']
RATIOS=[.5,1.,.2,.3,.3,.1]
LAYERS=['relu1_2','relu2_2','relu3_3']
FEATURE_WEIGHTS=[.5,.3,.2]

def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def files(p):return sorted(q for q in Path(p).rglob('*') if q.suffix.lower() in ['.jpg','.jpeg','.png','.bmp','.webp'])
def save(p,value):
    p=Path(p);tmp=p.with_suffix('.tmp');torch.save(value,tmp);tmp.replace(p)

class Photos(Dataset):
    def __init__(self,paths,w,h):self.paths,self.w,self.h=paths,w,h
    def __len__(self):return len(self.paths)
    def __getitem__(self,i):
        with Image.open(self.paths[i]) as im:
            im=im.convert('RGB');r=self.w/self.h
            top,left,h,w=T.RandomResizedCrop.get_params(im,scale=(.5,1.),ratio=(r*.9,r*1.1))
            im=TF.resized_crop(im,top,left,h,w,[self.h,self.w],interpolation=T.InterpolationMode.BICUBIC,antialias=True)
            if random.random()<.5:im=TF.hflip(im)
            return TF.to_tensor(im)

def initialize(net):
    # Keep phase-equal initialization but start residual RGB heads near zero.
    with torch.no_grad():
        for head in [net.detail_output,net.local_color]:
            head.weight.mul_(.01);head.bias.zero_()

def gram(x):
    z=x.float().flatten(2)
    with torch.autocast('cuda',enabled=False):return torch.bmm(z,z.transpose(1,2))/(z.shape[1]*z.shape[2])

def projections(y,t):
    a=y.float().flatten(2);b=t.float().flatten(2)
    idx=torch.linspace(0,a.shape[-1]-1,min(2048,a.shape[-1]),device=a.device).long()
    dirs=F.normalize(a.new_tensor([[1,0,0],[0,1,0],[0,0,1],[1,1,1],[1,-1,0],[0,1,-1],[1,0,-1]]),dim=1)
    # Full FP32 ranking, independent of surrounding convolution autocast.
    with torch.autocast('cuda',enabled=False):
        pa=torch.einsum('dc,bcn->bdn',dirs,a[:,:,idx]).sort(-1).values
        pb=torch.einsum('dc,bcn->bdn',dirs,b[:,:,idx]).sort(-1).values
        return F.l1_loss(pa,pb)

def targets(teacher,vgg,x):
    with torch.no_grad(),torch.autocast('cuda',enabled=False):ty=teacher(x.float())
    with torch.no_grad(),torch.autocast('cuda',dtype=torch.bfloat16):tf=vgg(ty)
    return ty,tf

def losses(vgg,y,ty,tf):
    yf=vgg(y)
    pixel=F.l1_loss(y.float(),ty.float())
    feature=sum(w*F.mse_loss(yf[k].float(),tf[k].float())/tf[k].float().square().mean().clamp_min(1e-4) for w,k in zip(FEATURE_WEIGHTS,LAYERS))
    style=sum(w*F.mse_loss(gram(yf[k]),gram(tf[k]))/gram(tf[k]).square().mean().clamp_min(1e-8) for w,k in zip([.65,.35],LAYERS[:2]))
    palette=projections(y,ty);regional=y.float().sum()*0
    for row in range(3):
        for col in range(4):
            h0,h1=row*y.shape[2]//3,(row+1)*y.shape[2]//3
            w0,w1=col*y.shape[3]//4,(col+1)*y.shape[3]//4
            regional=regional+projections(y[:,:,h0:h1,w0:w1],ty[:,:,h0:h1,w0:w1])/12
    gradient=y.float().sum()*0
    for scale in [1,2,4]:
        a=F.avg_pool2d(y.float(),scale);b=F.avg_pool2d(ty.float(),scale)
        for axis in [2,3]:gradient=gradient+F.l1_loss(a.diff(dim=axis),b.diff(dim=axis))/6
    # No quota, area floor, brightening, saturation floor or raw-input content loss.
    return [pixel,feature,style,palette,regional,gradient]

def calibrate(net,teacher,vgg,paths,w,h,count=4):
    net.eval();norms=torch.zeros(len(TERMS),device='cuda');actual=0
    for x in DataLoader(Photos(paths,w,h),batch_size=1,shuffle=False):
        x=x.cuda();ty,tf=targets(teacher,vgg,x)
        with torch.no_grad(),torch.autocast('cuda',dtype=torch.bfloat16):y=net(x).float()
        y=y.detach().requires_grad_(True)
        with torch.autocast('cuda',dtype=torch.bfloat16):ts=losses(vgg,y,ty,tf)
        for k,t in enumerate(ts):
            g=torch.autograd.grad(t,y,retain_graph=k<len(ts)-1)[0]
            norms[k]+=g.float().square().mean().sqrt().detach()
        actual+=1
        if actual>=count:break
    norms=(norms/actual).cpu().tolist()
    if not all(math.isfinite(v) and v>0 for v in norms):raise RuntimeError('Invalid loss gradient calibration')
    weights=[ratio*norms[1]/v for ratio,v in zip(RATIOS,norms)]
    if not all(math.isfinite(v) and 0<v<1e7 for v in weights):raise RuntimeError('Unstable loss balance')
    net.train()
    return {'gradient_rms':dict(zip(TERMS,norms)),'initial_relative_gradient_targets':dict(zip(TERMS,RATIOS)),
            'weights':dict(zip(TERMS,weights)),'batches':actual,'note':'initial output gradients; not a guarantee throughout training'}

@torch.no_grad()
def evaluate(net,teacher,paths,out,w,h):
    out.mkdir(parents=True,exist_ok=False);net.eval();rows=[]
    for i,p in enumerate(paths):
        with Image.open(p) as im:inp=im.convert('RGB').resize((w,h),Image.Resampling.BICUBIC)
        x=TF.to_tensor(inp)[None].cuda();ty=teacher(x)
        # Actual inference FP32, no training-mode difference and no post-recoloring.
        y=net(x);mse=(y-ty).square().mean().item()
        report=palette_report(y,ty)
        rows.append({'image':str(p),'mae_u8':255*(y-ty).abs().mean().item(),'psnr_db':-10*math.log10(max(mse,1e-12)),**report})
        ims=[inp,TF.to_pil_image(ty[0].cpu().clamp(0,1)),TF.to_pil_image(y[0].cpu().clamp(0,1))]
        panel=Image.new('RGB',(1152,328),'white');draw=ImageDraw.Draw(panel)
        for c,(label,im) in enumerate(zip(['Input','Original IN teacher','Style Context Detail'],ims)):
            im.save(out/f'{["input","teacher","student"][c]}_{i:02d}_{p.stem}.png')
            panel.paste(im.resize((384,216)),(384*c,26));draw.text((384*c+5,5),label,fill='black')
        for k,color in enumerate(report['colors']):
            left=k%4*288;top=250+k//4*36
            draw.rectangle((left+4,top,left+28,top+24),fill=tuple(color['rgb_u8']),outline='black')
            draw.text((left+34,top+5),f"{color['distance_qualified_area']*100:.1f}%  5% report: "+('PASS' if color['passes_5_percent'] else 'FAIL'),fill='black')
        panel.save(out/f'panel_{i:02d}_{p.stem}.jpg',quality=95)
    summary={'images':len(rows),'mean_mae_u8':sum(r['mae_u8'] for r in rows)/len(rows),
             'all_colors_5percent_images':sum(r['all_colors_pass'] for r in rows),
             'coverage_rule':'report only, not loss or quality acceptance','quality':'requires user visual acceptance'}
    (out/'metrics.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
    (out/'summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    save(out/'inference_model.pth',net.state_dict());net.train();print('Evaluation:',summary,flush=True)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--run',default='scd_v1');ap.add_argument('--steps',type=int,default=3000)
    ap.add_argument('--width',type=int,default=1280);ap.add_argument('--height',type=int,default=720)
    ap.add_argument('--accum',type=int,default=4);ap.add_argument('--lr',type=float,default=.0002)
    ap.add_argument('--save-every',type=int,default=250);ap.add_argument('--resume',action='store_true')
    ap.add_argument('--check-only',action='store_true')
    ap.add_argument('--train-dir',default='D:/aidrawer/data/val2017');ap.add_argument('--eval-dir',default='D:/aidrawer/data/student_eval_external')
    a=ap.parse_args()
    if not torch.cuda.is_available():raise RuntimeError('CUDA unavailable: activate fns')
    if min(a.steps,a.width,a.height,a.accum,a.save_every)<=0 or a.width%16 or a.height%16 or a.lr<=0:raise ValueError('Invalid dimensions/arguments')
    if Path(a.run).name!=a.run or a.run in ['.','..']:raise ValueError('Use a simple run directory name')
    random.seed(20261009);torch.manual_seed(20261009);torch.cuda.manual_seed_all(20261009)
    torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    identity=json.loads((ROOT/'frozen_teacher/identity.json').read_text());tp=ROOT/'frozen_teacher/model.pth'
    if digest(tp)!=identity['sha256']:raise RuntimeError('Frozen teacher changed')
    teacher=FastNeuralStyleNet(8,3,'instance').cuda().eval().requires_grad_(False)
    teacher.load_state_dict(torch.load(tp,map_location='cpu',weights_only=True),strict=True)
    net=StyleContextDetail().cuda();initialize(net)
    vgg=VggFeatures(LAYERS).cuda().eval().requires_grad_(False)
    if a.check_only:
        paths=files(a.train_dir)
        if not paths:raise RuntimeError('Empty training data')
        x=Photos(paths,a.width,a.height)[0][None].cuda();ty,tf=targets(teacher,vgg,x)
        with torch.autocast('cuda',dtype=torch.bfloat16):y=net(x);ts=losses(vgg,y,ty,tf)
        sum(ts).backward()
        assert all(torch.isfinite(t) for t in ts) and all(torch.isfinite(p.grad).all() for p in net.parameters() if p.grad is not None)
        print('Real-resolution complete teacher/student losses/backward PASS',list(y.shape),'peak GiB',torch.cuda.max_memory_allocated()/2**30);return
    run=ROOT/'runs'/a.run
    if run.exists() and not a.resume:raise RuntimeError('Run exists: add --resume or choose a new --run')
    paths,ev=files(a.train_dir),files(a.eval_dir)
    if not paths or not ev:raise RuntimeError('Empty dataset')
    eval_manifest=[{'path':str(p),'sha256':digest(p)} for p in ev];evhash={d['sha256'] for d in eval_manifest}
    train_manifest=[{'path':str(p),'sha256':digest(p)} for p in paths]
    train_manifest=[d for d in train_manifest if d['sha256'] not in evhash];paths=[Path(d['path']) for d in train_manifest]
    if not paths:raise RuntimeError('No training images after duplicate exclusion')
    cfg={**vars(a),'teacher_identity':identity,'architecture':'StyleContextDetail_v1','parameters':sum(p.numel() for p in net.parameters()),
         'train_files':train_manifest,'eval_files':eval_manifest,'seed':20261009,'loss_ratios':dict(zip(TERMS,RATIOS)),
         'palette_5percent':'report only, absent from losses','targets':'original IN teacher only, no style image or color enhancement',
         'student_code_sha256':digest(Path(__file__).parent/'student_model.py'),'trainer_code_sha256':digest(__file__),
         'report_code_sha256':digest(Path(__file__).parent/'palette_report.py'),'deployment':'float experiment, no INT8/RTL/FPS validation'}
    opt=torch.optim.Adam(net.parameters(),lr=a.lr);step=0;weights=None
    if a.resume:
        old=json.loads((run/'config.json').read_text())
        for k in cfg:
            if k not in ['steps','resume','check_only'] and cfg[k]!=old[k]:raise RuntimeError('Resume mismatch: '+k)
        ck=torch.load(run/'last.pth',map_location='cpu',weights_only=False)
        net.load_state_dict(ck['model']);opt.load_state_dict(ck['optim']);step=ck['step'];weights=ck['weights']
        random.setstate(ck['python_rng']);torch.set_rng_state(ck['torch_rng']);torch.cuda.set_rng_state_all(ck['cuda_rng'])
    if step>a.steps:raise RuntimeError('Requested steps below saved checkpoint')
    run.mkdir(parents=True,exist_ok=True)
    if not a.resume:(run/'config.json').write_text(json.dumps(cfg,indent=2),encoding='utf-8')
    if weights is None:
        info=calibrate(net,teacher,vgg,paths,a.width,a.height);weights=[info['weights'][k] for k in TERMS]
        (run/'gradient_balance.json').write_text(json.dumps(info,indent=2),encoding='utf-8');print('Loss balance:',info,flush=True)
    loader=DataLoader(Photos(paths,a.width,a.height),batch_size=1,shuffle=True,num_workers=0);it=iter(loader)
    net.train();start=time.time();startstep=step
    def checkpoint():
        save(run/'last.pth',{'step':step,'model':net.state_dict(),'optim':opt.state_dict(),'weights':weights,
             'python_rng':random.getstate(),'torch_rng':torch.get_rng_state(),'cuda_rng':torch.cuda.get_rng_state_all()})
        save(run/f'model_step{step:06d}.pth',net.state_dict())
    def finish_eval():
        out=run/f'eval_step{step:06d}'
        if out.exists():out=run/f'eval_step{step:06d}_{time.time_ns()}'
        evaluate(net,teacher,ev,out,a.width,a.height);save(run/'model_final.pth',net.state_dict())
        (run/'latest_evaluation.json').write_text(json.dumps({'step':step,'path':str(out),'model_sha256':digest(run/'model_final.pth')}),encoding='utf-8')
    if step==a.steps:
        finish_eval();(run/'completed.json').write_text(json.dumps({'step':step}),encoding='utf-8');return
    print(f'Train={len(paths)}, eval={len(ev)}, {a.width}x{a.height}, accumulation={a.accum}, 5% coverage REPORT ONLY',flush=True)
    try:
        while step<a.steps:
            opt.zero_grad(set_to_none=True);values=torch.zeros(len(TERMS)+1,device='cuda')
            for _ in range(a.accum):
                try:x=next(it)
                except StopIteration:it=iter(loader);x=next(it)
                x=x.cuda();ty,tf=targets(teacher,vgg,x)
                with torch.autocast('cuda',dtype=torch.bfloat16):
                    y=net(x);ts=losses(vgg,y,ty,tf);loss=sum(w*t for w,t in zip(weights,ts))
                if not torch.isfinite(loss):raise RuntimeError('Nonfinite loss; previous complete checkpoint preserved')
                (loss/a.accum).backward();values+=torch.stack([loss.detach()]+[t.detach() for t in ts])/a.accum
            gn=torch.nn.utils.clip_grad_norm_(net.parameters(),5.)
            if not torch.isfinite(gn):raise RuntimeError('Nonfinite gradient; previous complete checkpoint preserved')
            opt.step();step+=1
            if step%20==0:
                vs=values.cpu().tolist();record={'step':step,'loss':vs[0],**dict(zip(TERMS,vs[1:])),
                    'weighted':dict(zip(TERMS,[v*w for v,w in zip(vs[1:],weights)]))}
                with (run/'history.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(record)+'\n')
                elapsed=(time.time()-start)/(step-startstep)
                print(f'{step}/{a.steps} loss={vs[0]:.4f} {elapsed:.2f}s/step ETA~{elapsed*(a.steps-step)/60:.1f}min peak={torch.cuda.max_memory_allocated()/2**30:.2f}GiB',flush=True)
            if step%a.save_every==0 or step==a.steps:
                checkpoint();del x,ty,tf,y,ts,loss;finish_eval()
    except KeyboardInterrupt:
        print('Stopped; add --resume to restore the latest complete periodic checkpoint. Partial step discarded.',flush=True);return
    (run/'completed.json').write_text(json.dumps({'step':step,'model_sha256':digest(run/'model_final.pth')}),encoding='utf-8')
    print('Completed:',run,flush=True)

if __name__=='__main__':main()
