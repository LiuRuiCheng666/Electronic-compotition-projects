"""A8 structured-pruning recovery against accepted B12; no deployment edits."""
import argparse
import copy
import json
import random
import time
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader
from PIL import Image, ImageDraw
from torchvision.transforms import functional as TF
from pruning import B12,A8
from support import Student, Photos, files, digest, save, VggFeatures, gram, tv_loss, model

ROOT=Path('D:/aidrawer/output/Ukiyo-e/20261006_A8_BN_Structured_Pruning_Distillation')
TEACHER=ROOT/'frozen_b12/model_final.pth'
TERMS=['pixel','feature','teacher_gram','content']
RATIOS=[1.,.7,.15,.05]

def seed():
    random.seed(20261006);torch.manual_seed(20261006);torch.cuda.manual_seed_all(20261006)

def make_losses(vgg,y,ty,tf,cf):
    yf=vgg(y)
    pixel=F.l1_loss(y.float(),ty.float())
    feature=sum(F.mse_loss(yf[k].float(),tf[k].float()) / tf[k].float().square().mean().clamp_min(1e-4) for k in yf)/len(yf)
    style=sum(F.mse_loss(gram(yf[k]),gram(tf[k])) / gram(tf[k]).square().mean().clamp_min(1e-8) for k in yf)/len(yf)
    content=F.mse_loss(yf['relu3_3'].float(),cf['relu3_3'].float()) / cf['relu3_3'].float().square().mean().clamp_min(1e-4)
    return [pixel,feature,style,content]

def get_targets(teacher,vgg,x):
    with torch.no_grad(),torch.autocast('cuda',dtype=torch.bfloat16):
        ty=teacher(x).float();tf=vgg(ty);cf=vgg(x)
    return ty,tf,cf

def calibrate_weights(net,teacher,vgg,paths,width,height,batch,count=8):
    # Measure gradients at RGB output, NOT parameter-gradient norms. Fixed weights
    # are an initial balance, not a guarantee throughout training.
    was=net.training;net.eval();loader=DataLoader(Photos(paths,width,height),batch_size=batch,shuffle=False)
    norms=torch.zeros(4,device='cuda');actual=0
    for x in loader:
        x=x.cuda();ty,tf,cf=get_targets(teacher,vgg,x)
        with torch.no_grad(),torch.autocast('cuda',dtype=torch.bfloat16):y=net(x).float()
        y=y.detach().requires_grad_(True)
        with torch.autocast('cuda',dtype=torch.bfloat16):terms=make_losses(vgg,y,ty,tf,cf)
        for k,term in enumerate(terms):
            g=torch.autograd.grad(term,y,retain_graph=k<3)[0]
            norms[k]+=g.float().square().mean().sqrt().detach()
        actual+=1
        if actual>=count:break
    net.train(was)
    norms=(norms/actual).cpu().tolist()
    if not all(torch.isfinite(torch.tensor(norms))) or min(norms)<=0:raise RuntimeError('Invalid gradient calibration')
    weights=[min(1e5,max(1e-3,r*norms[0]/n)) for r,n in zip(RATIOS,norms)]
    return {'output_gradient_rms':dict(zip(TERMS,norms)), 'desired_relative_output_gradients':dict(zip(TERMS,RATIOS)),
            'weights':dict(zip(TERMS,weights)), 'batches':actual,'width':width,'height':height}

def calibrate_bn(net,paths):
    net.eval()
    for m in net.modules():
        if isinstance(m,nn.BatchNorm2d):m.reset_running_stats();m.momentum=None;m.train()
    with torch.no_grad():
        for p in paths[:128]:
            with Image.open(p) as im:x=TF.to_tensor(im.convert('RGB').resize((640,480),Image.Resampling.BICUBIC))[None].cuda()
            net(x)
    net.eval()

def evaluate(net,teacher,paths,out,bnpaths=None):
    state={k:v.detach().cpu().clone() for k,v in net.state_dict().items()}
    was=net.training
    if bnpaths:calibrate_bn(net,bnpaths)
    net.eval();out.mkdir(parents=True,exist_ok=False)
    records=[]
    with torch.no_grad():
        for i,p in enumerate(paths):
            with Image.open(p) as im:inp=im.convert('RGB').resize((640,480),Image.Resampling.BICUBIC)
            x=TF.to_tensor(inp)[None].cuda();ty=teacher(x);y=net(x)
            mse=(y-ty).square().mean().item();mae=(y-ty).abs().mean().item()
            records.append({'image':str(p),'teacher_mae':mae,'teacher_psnr_db':-10*__import__('math').log10(max(mse,1e-12))})
            student=TF.to_pil_image(y[0].cpu().clamp(0,1));ref=TF.to_pil_image(ty[0].cpu().clamp(0,1))
            student.save(out/f'{i:02d}_{p.stem}.png')
            sheet=Image.new('RGB',(960,266),'white');draw=ImageDraw.Draw(sheet)
            for col,(label,im) in enumerate([('Input',inp),('Approved teacher',ref),('Student',student)]):
                sheet.paste(im.resize((320,240)),(col*320,26));draw.text((col*320+5,5),label,fill='black')
            sheet.save(out/f'panel_{i:02d}_{p.stem}.jpg',quality=95)
    (out/'metrics.json').write_text(json.dumps(records,indent=2),encoding='utf-8')
    # Save calibrated inference weights separately. Never replace training state.
    save(out/'inference_model.pth',net.state_dict())
    net.load_state_dict(state);net.train(was)
    for m in net.modules():
        if isinstance(m,nn.BatchNorm2d):m.momentum=.1

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--norm',choices=['batch'],default='batch')
    ap.add_argument('--run',required=True)
    ap.add_argument('--steps',type=int,default=3000)
    ap.add_argument('--vga-start',type=int,default=0)
    ap.add_argument('--batch',type=int,default=2)
    ap.add_argument('--accum',type=int,default=2)
    ap.add_argument('--vga-batch',type=int,default=1)
    ap.add_argument('--vga-accum',type=int,default=4)
    ap.add_argument('--lr',type=float,default=5e-5)
    ap.add_argument('--save-every',type=int,default=500)
    ap.add_argument('--train-dir',default='D:/aidrawer/data/val2017')
    ap.add_argument('--eval-dir',default='D:/aidrawer/data/student_eval_external')
    ap.add_argument('--resume',action='store_true')
    a=ap.parse_args()
    if not torch.cuda.is_available():raise RuntimeError('CUDA unavailable')
    if min(a.steps,a.batch,a.accum,a.vga_batch,a.vga_accum,a.save_every)<=0 or a.vga_start<0:raise ValueError('Arguments must be positive')
    if Path(a.run).name!=a.run or a.run in ('.','..'):raise ValueError('Invalid run name')
    run=ROOT/'runs'/a.run
    if run.exists() and not a.resume:raise RuntimeError('Run exists: use new name or --resume')
    if a.resume and not (run/'last.pth').exists():raise RuntimeError('Missing checkpoint')
    identity=json.loads((TEACHER.parent/'identity.json').read_text())
    if digest(TEACHER)!=identity['sha256']:raise RuntimeError('Frozen teacher hash mismatch')
    prune=json.loads((ROOT/'pruning_report.json').read_text())
    if digest(ROOT/'a8_init.pth')!=prune['init_sha256'] or prune['source_sha256']!=identity['sha256']:raise RuntimeError('Pruned initialization identity mismatch')
    paths,ev=files(a.train_dir),files(a.eval_dir)
    if not paths or not ev:raise RuntimeError('Empty dataset')
    evhash={digest(p) for p in ev};paths=[p for p in paths if digest(p) not in evhash]
    if len(paths)<max(a.batch,a.vga_batch):raise RuntimeError('Insufficient training images')
    # Hash training files as well, so a resumed experiment cannot silently change data.
    manifest=[{'path':str(p),'sha256':digest(p)} for p in paths]
    cfg={**vars(a),'stage':'a8_bn','style_sha256':identity['style_sha256'],
         'teacher_sha256':identity['sha256'],'train_files':manifest,'eval_files':[{'path':str(p),'sha256':digest(p)} for p in ev],
         'seed':20261006,'initialization':'structured channel slicing from frozen accepted B12', 'init_sha256':digest(ROOT/'a8_init.pth'), 'pruning_sha256':digest(ROOT/'pruning_report.json'),
         'loss_design':'teacher RGB + normalized VGG feature + teacher Gram + weak content; output-gradient calibration',
         'quality_status':'float only; no int8 or hardware validation'}
    if a.resume:
        old=json.loads((run/'config.json').read_text(encoding='utf-8'))
        for k in cfg:
            if k not in ['steps','resume'] and cfg[k]!=old[k]:raise RuntimeError('Resume mismatch: '+k)
    run.mkdir(parents=True,exist_ok=True)
    if not a.resume:(run/'config.json').write_text(json.dumps(cfg,ensure_ascii=False,indent=2),encoding='utf-8')
    seed();torch.backends.cudnn.benchmark=True
    net=A8().cuda();net.load_state_dict(torch.load(ROOT/'a8_init.pth',map_location='cpu',weights_only=True));teacher=B12().cuda().eval().requires_grad_(False)
    teacher.load_state_dict(torch.load(TEACHER,map_location='cpu',weights_only=True))
    vgg=VggFeatures(['relu1_2','relu2_2','relu3_3','relu4_3']).cuda().eval().requires_grad_(False)
    opt=torch.optim.Adam(net.parameters(),lr=a.lr);scaler=torch.amp.GradScaler('cuda', enabled=False)
    step=0;weights=None;phase=None
    if a.resume:
        ck=torch.load(run/'last.pth',map_location='cpu',weights_only=False)
        net.load_state_dict(ck['model']);opt.load_state_dict(ck['optim']);scaler.load_state_dict(ck['scaler'])
        step=ck['step'];weights=ck['weights'];phase=ck['phase']
        random.setstate(ck['python_rng']);torch.set_rng_state(ck['torch_rng']);torch.cuda.set_rng_state_all(ck['cuda_rng'])
    if step>=a.steps:raise RuntimeError('Increase --steps above saved step')
    def checkpoint():
        save(run/'last.pth',{'step':step,'model':net.state_dict(),'optim':opt.state_dict(),'scaler':scaler.state_dict(),
            'weights':weights,'phase':phase,'python_rng':random.getstate(),'torch_rng':torch.get_rng_state(),'cuda_rng':torch.cuda.get_rng_state_all()})
        save(run/f'model_step{step:06d}.pth',net.state_dict())
    net.train();loader=None;it=None;start=time.time();startstep=step
    print(f'A8 {a.norm}; train={len(paths)} eval={len(ev)}; frozen teacher {identity["sha256"]}',flush=True)
    try:
        while step<a.steps:
            newphase='vga' if step>=a.vga_start else 'small'
            if loader is None or newphase!=phase:
                changed=newphase!=phase;phase=newphase
                w,h=(640,480) if phase=='vga' else (320,240)
                batch=a.vga_batch if phase=='vga' else a.batch
                accum=a.vga_accum if phase=='vga' else a.accum
                if weights is None or changed:
                    info=calibrate_weights(net,teacher,vgg,paths,w,h,batch)
                    weights=[info['weights'][k] for k in TERMS]
                    info['step']=step;info['phase']=phase
                    (run/f'gradient_balance_{phase}.json').write_text(json.dumps(info,indent=2),encoding='utf-8')
                    print('Gradient balance:',info,flush=True)
                loader=DataLoader(Photos(paths,w,h),batch_size=batch,shuffle=True,drop_last=True,num_workers=0);it=iter(loader)
                for g in opt.param_groups:g['lr']=a.lr
                print(f'Phase={phase}, {w}x{h}, microbatch={batch}, accumulation={accum}',flush=True)
            opt.zero_grad(set_to_none=True);values=torch.zeros(5,device='cuda')
            for _ in range(accum):
                try:x=next(it)
                except StopIteration:it=iter(loader);x=next(it)
                x=x.cuda();ty,tf,cf=get_targets(teacher,vgg,x)
                with torch.autocast('cuda',dtype=torch.bfloat16):
                    y=net(x);terms=make_losses(vgg,y,ty,tf,cf)
                    loss=sum(c*t for c,t in zip(weights,terms))+1e-5*tv_loss(y.float())
                if not torch.isfinite(loss):raise RuntimeError('Nonfinite loss; stop and inspect')
                scaler.scale(loss/accum).backward()
                values+=torch.stack([loss.detach()]+[t.detach() for t in terms])/accum
            scaler.unscale_(opt);gn=torch.nn.utils.clip_grad_norm_(net.parameters(),5.)
            if not torch.isfinite(gn):raise RuntimeError('Nonfinite parameter gradients; last checkpoint preserved')
            scale_before=scaler.get_scale();scaler.step(opt);scaler.update()
            if scaler.get_scale()<scale_before:raise RuntimeError('AMP optimizer step skipped; inspect loss and reduce precision risk')
            step+=1
            if step%20==0:
                vs=values.cpu().tolist();record={'step':step,'phase':phase,'loss':vs[0],**dict(zip(TERMS,vs[1:])),
                    'weighted':dict(zip(TERMS,[x*c for x,c in zip(vs[1:],weights)]))}
                with (run/'history.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(record)+'\n')
                rate=(time.time()-start)/(step-startstep)
                print(f'{step}/{a.steps} {phase} loss={vs[0]:.4f} pixel={vs[1]:.4f} {rate:.2f}s/step ETA~{rate*(a.steps-step)/60:.1f}min peak={torch.cuda.max_memory_allocated()/2**30:.2f}GiB',flush=True)
            if step%a.save_every==0 or step==a.steps:
                checkpoint()
                # Release last training graph before VGA evaluation/calibration.
                del x,ty,tf,cf,y,terms,loss
                out=run/f'eval_step{step:06d}'
                if out.exists(): out=run/f'eval_step{step:06d}_{time.time_ns()}'
                evaluate(net,teacher,ev,out,paths if a.norm=='batch' else None)
                save(run/'model_final.pth',torch.load(out/'inference_model.pth',map_location='cpu',weights_only=True))
                print('VGA comparison panels:',out,flush=True)
    except KeyboardInterrupt:
        # Existing last.pth is always a complete optimizer-step checkpoint.
        print('Stopped. Resume from the last periodic checkpoint; partial step was not saved.',flush=True)
        return
    print('Done:',run,'; inspect panels before extending training.',flush=True)

if __name__=='__main__':main()
