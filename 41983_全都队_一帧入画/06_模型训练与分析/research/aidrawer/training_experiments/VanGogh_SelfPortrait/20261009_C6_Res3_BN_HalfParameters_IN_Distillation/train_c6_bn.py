"""Direct C6 BN fixed-BN distillation from the selected VanGogh IN teacher."""
import argparse,hashlib,json,math,random,time
from pathlib import Path
import torch
from torch import nn
import torch.nn.functional as F
from torch.utils.data import Dataset,DataLoader
from PIL import Image,ImageDraw
from torchvision import transforms as T
from torchvision.transforms import functional as TF
from models import ROOT,Student,FastNeuralStyleNet,cost
from train import VggFeatures

TERMS=['pixel','feature','teacher_gram','content','palette','brightness_chroma','texture','palette_restore','area_floor','area_distribution','regional_palette']
RATIOS=[.05,.7,.5,.05,.5,.3,.03,3.,3.,1.,1.]
FEATURE_WEIGHTS={'relu1_2':.4,'relu2_2':.3,'relu3_3':.2,'relu4_3':.1}
STYLE_WEIGHTS={'relu1_2':.55,'relu2_2':.35,'relu3_3':.08,'relu4_3':.02}

def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def files(p):return sorted(v for v in Path(p).rglob('*') if v.suffix.lower() in ['.jpg','.jpeg','.png','.bmp','.webp'])
def save(p,obj):
    tmp=p.with_suffix('.tmp');torch.save(obj,tmp);tmp.replace(p)
def gram(x):
    b,c,h,w=x.shape;x=x.float().reshape(b,c,h*w)
    with torch.autocast('cuda',enabled=False):return torch.bmm(x,x.transpose(1,2))/(c*h*w)

class Photos(Dataset):
    def __init__(self,paths,width,height):self.paths,self.width,self.height=paths,width,height
    def __len__(self):return len(self.paths)
    def __getitem__(self,i):
        with Image.open(self.paths[i]) as im:
            im=im.convert('RGB');y,x,h,w=T.RandomResizedCrop.get_params(im,scale=(.5,1.),ratio=(1.6,1.95))
            im=TF.resized_crop(im,y,x,h,w,[self.height,self.width],antialias=True)
            if random.random()<.5:im=TF.hflip(im)
            return TF.to_tensor(im)

def targets(teacher,vgg,x):
    with torch.no_grad():
        ty=teacher(x)  # Approved teacher FP32, no extra gamma or style-image loss.
        with torch.autocast('cuda',dtype=torch.bfloat16):tf=vgg(ty);cf=vgg(x)
    return ty,tf,cf

def losses(vgg,y,ty,tf,cf):
    yf=vgg(y)
    pixel=F.l1_loss(y.float(),ty.float())
    feature=sum(FEATURE_WEIGHTS[k]*F.mse_loss(yf[k].float(),tf[k].float())/tf[k].float().square().mean().clamp_min(1e-4) for k in yf)
    style=sum(STYLE_WEIGHTS[k]*F.mse_loss(gram(yf[k]),gram(tf[k]))/gram(tf[k]).square().mean().clamp_min(1e-8) for k in yf)
    content=F.mse_loss(yf['relu3_3'].float(),cf['relu3_3'].float())/cf['relu3_3'].float().square().mean().clamp_min(1e-4)
    
    # Sliced RGB distribution includes the three RGB axes and mixed projections.
    # Matching sorted samples preserves multimodal palettes without pixel pairing.
    ys=y.float().flatten(2)[:,:,::max(1,y.shape[-1]*y.shape[-2]//2048)]
    ts=ty.float().flatten(2)[:,:,::max(1,ty.shape[-1]*ty.shape[-2]//2048)]
    dirs=y.new_tensor([[1,0,0],[0,1,0],[0,0,1],[1,1,1],[1,-1,0],[0,1,-1],[1,0,-1],[1,1,-1]],dtype=torch.float32)
    dirs=F.normalize(dirs,dim=1)
    palette=F.l1_loss(torch.einsum('dc,bcn->bdn',dirs,ys).sort(-1).values,torch.einsum('dc,bcn->bdn',dirs,ts).sort(-1).values)
    # Match teacher luminance and chroma; no arbitrary saturation/brightness boost.
    lum=y.new_tensor([.2126,.7152,.0722],dtype=torch.float32)[None,:,None]
    ly=(ys*lum).sum(1);lt=(ts*lum).sum(1)
    cy=ys.max(1).values-ys.min(1).values;ct=ts.max(1).values-ts.min(1).values
    bc=F.l1_loss(ly.sort(-1).values,lt.sort(-1).values)+F.l1_loss(cy.sort(-1).values,ct.sort(-1).values)
    texture=y.float().sum()*0
    for scale in [1,2,4]:
        a=F.avg_pool2d(y.float(),scale);b=F.avg_pool2d(ty.float(),scale)
        for axis in [2,3]:
            ga=a.diff(dim=axis);gb=b.diff(dim=axis)
            texture=texture+F.l1_loss(ga,gb)/6
    restore,floor,distribution=palette_terms(y,ty)
    return [pixel,feature,style,content,palette,bc,texture,restore,floor,distribution,regional_palette(y,ty)]

def calibrate(net,teacher,vgg,paths,width,height,count=4):
    net.eval();norms=torch.zeros(len(TERMS),device='cuda');actual=0
    for x in DataLoader(Photos(paths,width,height),batch_size=1,shuffle=False):
        x=x.cuda();ty,tf,cf=targets(teacher,vgg,x)
        with torch.no_grad(),torch.autocast('cuda',dtype=torch.bfloat16):y=net(x).float()
        y=y.detach().requires_grad_(True)
        with torch.autocast('cuda',dtype=torch.bfloat16):ts=losses(vgg,y,ty,tf,cf)
        for k,t in enumerate(ts):
            grad=torch.autograd.grad(t,y,retain_graph=k<len(TERMS)-1)[0]
            norms[k]+=grad.float().square().mean().sqrt().detach()
        actual+=1
        if actual>=count:break
    norms=(norms/actual).cpu().tolist()
    if not all(math.isfinite(v) and v>=0 for v in norms):raise RuntimeError('Invalid gradient calibration')
    weights=[ratio*norms[1]/max(norm,1e-7) for ratio,norm in zip(RATIOS,norms)]
    if not all(math.isfinite(v) and 0<v<1e8 for v in weights):raise RuntimeError('Unstable calibrated weights')
    net.train();return {'gradient_rms':dict(zip(TERMS,norms)),'desired_relative_gradients':dict(zip(TERMS,RATIOS)),
                        'weights':dict(zip(TERMS,weights)),'batches':actual}

def calibrate_bn_fixed(net,paths,width,height):
    # Sequential layer calibration: preceding BN layers use their final statistics.
    net.eval()
    for bn in [m for m in net.modules() if isinstance(m,nn.BatchNorm2d)]:
        sums=None;squares=None;count=0
        def collect(module,args):
            nonlocal sums,squares,count
            z=args[0].detach().double()
            ss=z.sum((0,2,3));sq=z.square().sum((0,2,3))
            sums=ss if sums is None else sums+ss;squares=sq if squares is None else squares+sq
            count+=z.shape[0]*z.shape[2]*z.shape[3]
        hook=bn.register_forward_pre_hook(collect)
        with torch.no_grad():
            for p in paths[:64]:
                with Image.open(p) as im:x=TF.to_tensor(im.convert('RGB').resize((width,height),Image.Resampling.BICUBIC))[None].cuda()
                net(x)
        hook.remove();mean=sums/count;var=(squares/count-mean.square()).clamp_min(1e-6)
        bn.running_mean.copy_(mean.float());bn.running_var.copy_(var.float())
    print('BN statistics calibrated and frozen; affine parameters remain trainable',flush=True)


PALETTE_SIZE=8
MIN_AREA=.05
COLOR_RADIUS=.15  # Euclidean distance in RGB [0,1], not a perceptual Delta-E.

def sampled_rgb(x,count=4096):
    z=x.float().flatten(2).transpose(1,2)
    idx=torch.linspace(0,z.shape[1]-1,min(count,z.shape[1]),device=z.device).long()
    return z[:,idx]

@torch.no_grad()
def teacher_palette(rgb):
    # Deterministic farthest-first seeds, followed by Lloyd k-means on teacher only.
    centers=[rgb.mean(0)]
    for _ in range(PALETTE_SIZE-1):
        d=torch.cdist(rgb,torch.stack(centers),compute_mode='donot_use_mm_for_euclid_dist').min(1).values
        candidate=rgb[d.argmax()]
        if d.max()<.08:break  # Do not invent eight distinct colors in a neutral image.
        centers.append(candidate)
    c=torch.stack(centers)
    for _ in range(12):
        ix=torch.cdist(rgb,c,compute_mode='donot_use_mm_for_euclid_dist').argmin(1)
        c=torch.stack([rgb[ix==k].mean(0) if (ix==k).any() else c[k] for k in range(len(c))])
    # Merge redundant representatives so one color is not counted repeatedly.
    kept=[]
    for center in c:
        if not kept or torch.cdist(center[None],torch.stack(kept)).min()>=.08:kept.append(center)
    c=torch.stack(kept)
    ix=torch.cdist(rgb,c,compute_mode='donot_use_mm_for_euclid_dist').argmin(1)
    area=torch.bincount(ix,minlength=len(c)).float()/len(rgb)
    # Water filling: floor rare classes, retain teacher proportions in the remainder.
    fixed=torch.zeros_like(area,dtype=torch.bool);quota=area.clone()
    for _ in range(len(c)+1):
        rest=~fixed
        quota[fixed]=MIN_AREA
        quota[rest]=area[rest]/area[rest].sum().clamp_min(1e-8)*(1-MIN_AREA*fixed.sum())
        new=rest & (quota<MIN_AREA)
        if not new.any():break
        fixed|=new
    return c,area,quota

def palette_terms(y,ty):
    with torch.autocast('cuda',enabled=False):
        students=sampled_rgb(y);teachers=sampled_rgb(ty).detach()
        coverage=y.float().sum()*0;area_loss=coverage;distribution=coverage
        for s,t in zip(students,teachers):
            centers,teacher_area,quota=teacher_palette(t)
            d=torch.cdist(s,centers,compute_mode='donot_use_mm_for_euclid_dist')
            # A pixel receives at most total mass one, discounted if its RGB is far
            # from every representative. Blue cannot count as red merely by argmin.
            assignment=torch.softmax(-d/.025,dim=1)
            accepted=torch.sigmoid((COLOR_RADIUS-d)/.02)
            mass=(assignment*accepted).mean(0)
            area_loss=area_loss+F.relu((MIN_AREA-mass)/MIN_AREA).square().mean()
            distribution=distribution+(mass-quota).abs().mean()
            # Restoring gradients for completely absent colors: pull the nearest
            # 5% of sampled pixels towards each under-covered representative.
            # Detached deficit prevents fully covered classes from being recolored.
            deficit=((MIN_AREA-mass.detach())/MIN_AREA).clamp(0,1)
            count=max(1,math.ceil(MIN_AREA*len(s)))
            closest=d.topk(count,dim=0,largest=False).values.mean(0)
            coverage=coverage+(closest*deficit).mean()
        b=len(students)
        return coverage/b,area_loss/b,distribution/b

def regional_palette(y,teacher):
    total=y.float().sum()*0
    dirs=F.normalize(y.new_tensor([[1,0,0],[0,1,0],[0,0,1],[1,1,1],[1,-1,0],[0,1,-1],[1,0,-1]],dtype=torch.float32),dim=1)
    for row in range(3):
        for col in range(4):
            h0,h1=row*y.shape[2]//3,(row+1)*y.shape[2]//3
            w0,w1=col*y.shape[3]//4,(col+1)*y.shape[3]//4
            a=y.float()[:,:,h0:h1,w0:w1].flatten(2)
            b=teacher.float()[:,:,h0:h1,w0:w1].flatten(2)
            idx=torch.linspace(0,a.shape[-1]-1,min(512,a.shape[-1]),device=a.device).long()
            aa=torch.einsum('dc,bcn->bdn',dirs,a[:,:,idx]).sort(-1).values
            bb=torch.einsum('dc,bcn->bdn',dirs,b[:,:,idx]).sort(-1).values
            total=total+F.l1_loss(aa,bb)/12
    return total

@torch.no_grad()
def palette_report(y,teacher):
    centers,area,quota=teacher_palette(sampled_rgb(teacher)[0])
    nearest=torch.zeros(len(centers),device=y.device);valid=nearest.clone();distance_sum=nearest.clone()
    pixels=y.float().flatten(2).transpose(1,2)[0]
    for chunk in pixels.split(32768):
        d=torch.cdist(chunk,centers,compute_mode='donot_use_mm_for_euclid_dist')
        distance,ix=d.min(1)
        nearest+=torch.bincount(ix,minlength=len(centers))
        valid+=torch.bincount(ix[distance<=COLOR_RADIUS],minlength=len(centers))
        distance_sum.scatter_add_(0,ix,distance)
    rows=[]
    for k,c in enumerate(centers):
        share=(valid[k]/len(pixels)).item()
        rows.append({'rgb_u8':(c*255).round().int().tolist(),'teacher_sample_area':area[k].item(),
                     'target_area':quota[k].item(),'nearest_area':(nearest[k]/len(pixels)).item(),
                     'distance_qualified_area':share,'mean_nearest_rgb_distance':(distance_sum[k]/nearest[k].clamp_min(1)).item(),
                     'passes_5_percent':share+1e-8>=MIN_AREA})
    return {'palette_count':len(centers),'rgb_distance_radius':COLOR_RADIUS,'all_colors_pass':all(r['passes_5_percent'] for r in rows),
            'uncovered_pixel_fraction':(1-valid.sum()/len(pixels)).item(),'colors':rows}

def evaluate(net,teacher,paths,out,width,height):
    out.mkdir(parents=True,exist_ok=False);net.eval();rows=[]
    with torch.no_grad():
        for i,p in enumerate(paths):
            with Image.open(p) as im:inp=im.convert('RGB').resize((width,height),Image.Resampling.BICUBIC)
            x=TF.to_tensor(inp)[None].cuda();ty=teacher(x);y=net(x)
            report=palette_report(y,ty)
            rows.append({'image':str(p),'mae_u8':255*(y-ty).abs().mean().item(),**report})
            ims=[inp,TF.to_pil_image(ty[0].cpu().clamp(0,1)),TF.to_pil_image(y[0].cpu().clamp(0,1))]
            panel=Image.new('RGB',(960,360),'white');draw=ImageDraw.Draw(panel)
            for c,(label,im) in enumerate(zip(['Input','Original IN teacher','C6 BN palette coverage'],ims)):
                im.save(out/f'{["input","teacher","student"][c]}_{i:02d}_{p.stem}.png')
                panel.paste(im.resize((320,240)),(320*c,26));draw.text((320*c+5,5),label,fill='black')
            for k,color in enumerate(report['colors']):
                col=k%4;row=k//4;left=col*240;top=274+row*38
                draw.rectangle((left+4,top,left+30,top+26),fill=tuple(color['rgb_u8']),outline='black')
                label=f"{color['distance_qualified_area']*100:.1f}% / min 5% " + ('PASS' if color['passes_5_percent'] else 'FAIL')
                draw.text((left+36,top+5),label,fill='black' if color['passes_5_percent'] else 'red')
            panel.save(out/f'panel_{i:02d}_{p.stem}.jpg',quality=95)
    summary={'images':len(rows),'all_color_pass_images':sum(r['all_colors_pass'] for r in rows),
             'all_images_pass':all(r['all_colors_pass'] for r in rows),'rule':'nearest teacher representative AND RGB distance <= .15; each >= 5% of full image'}
    (out/'metrics.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
    (out/'coverage_summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print('Coverage evaluation:',summary,flush=True)
    save(out/'inference_model.pth',net.state_dict());net.train()

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--variant',choices=['c6_bn'],default='c6_bn')
    ap.add_argument('--bn-warmup',type=int,default=250);ap.add_argument('--check-only',action='store_true')
    ap.add_argument('--steps',type=int,default=3000);ap.add_argument('--width',type=int,default=640);ap.add_argument('--height',type=int,default=480)
    ap.add_argument('--accum',type=int,default=4);ap.add_argument('--lr',type=float,default=0.0002)
    ap.add_argument('--save-every',type=int,default=250);ap.add_argument('--resume',action='store_true')
    ap.add_argument('--train-dir',default='D:/aidrawer/data/val2017');ap.add_argument('--eval-dir',default='D:/aidrawer/data/student_eval_external')
    a=ap.parse_args()
    if not torch.cuda.is_available():raise RuntimeError('CUDA unavailable: activate fns')
    if min(a.steps,a.width,a.height,a.accum,a.save_every)<1 or a.width%4 or a.height%4 or a.lr<=0:raise ValueError('Invalid arguments')
    run=ROOT/'runs'/a.variant
    if run.exists() and not a.resume:raise RuntimeError('Run exists: use --resume')
    identity=json.loads((ROOT/'frozen_teacher/identity.json').read_text())
    tp=ROOT/'frozen_teacher/model.pth'
    if digest(tp)!=identity['sha256']:raise RuntimeError('Frozen teacher changed')
    if a.check_only:
        teacher=FastNeuralStyleNet(8,3,'instance').cuda().eval()
        teacher.load_state_dict(torch.load(tp,map_location='cpu',weights_only=True),strict=True)
        net=Student().cuda().eval();x=torch.rand(1,3,48,64,device='cuda')
        with torch.no_grad():y=net(x);ty=teacher(x)
        assert y.shape==ty.shape and torch.isfinite(y).all()
        print('Teacher strict load and C6 BN forward PASS',cost('c6_bn',640,480));return
    ev=files(a.eval_dir);paths=files(a.train_dir)
    if not ev or not paths:raise RuntimeError('Empty dataset')
    evmanifest=[{'path':str(p),'sha256':digest(p)} for p in ev];evhash={d['sha256'] for d in evmanifest}
    manifest=[{'path':str(p),'sha256':digest(p)} for p in paths];manifest=[d for d in manifest if d['sha256'] not in evhash]
    paths=[Path(d['path']) for d in manifest]
    if not paths:raise RuntimeError('No train images after excluding eval duplicates')
    cfg={**vars(a),'teacher_sha256':identity['sha256'],'architecture':'FastNeuralStyleNet_C6_Res3_BN','initialization':'random; direct distillation from selected original C8 Res3 IN teacher',
         'train_files':manifest,'eval_files':evmanifest,'seed':20261008,'loss_ratios':RATIOS,
         'feature_layer_weights':FEATURE_WEIGHTS,'teacher_gram_layer_weights':STYLE_WEIGHTS,
         'budget':cost(a.variant,a.width,a.height),'status':'Fresh C6 BN, original IN teacher, no vivid recoloring; unchanged hardware', 'palette_rule':{'max_colors':8,'min_area':.05,'radius_rgb':.15,'merge_distance_rgb':.08,'exception':'fewer representatives for genuinely indistinct colors; no invented colors','guarantee':'soft training target, full-image distance-qualified evaluation required'}}
    if a.resume:
        old=json.loads((run/'config.json').read_text(encoding='utf-8'))
        for k in cfg:
            if k not in ['steps','resume','check_only'] and old[k]!=cfg[k]:raise RuntimeError('Resume config mismatch: '+k)
        if not (run/'last.pth').exists():raise RuntimeError('Missing checkpoint')
    random.seed(20261008);torch.manual_seed(20261008);torch.cuda.manual_seed_all(20261008)
    torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    teacher=FastNeuralStyleNet(8,3,'instance').cuda().eval().requires_grad_(False)
    teacher.load_state_dict(torch.load(tp,map_location='cpu',weights_only=True))
    net=Student(a.variant).cuda();vgg=VggFeatures(['relu1_2','relu2_2','relu3_3','relu4_3']).cuda().eval().requires_grad_(False)
    opt=torch.optim.Adam(net.parameters(),lr=a.lr);step=0;weights=None
    if a.resume:
        ck=torch.load(run/'last.pth',map_location='cpu',weights_only=False);net.load_state_dict(ck['model']);opt.load_state_dict(ck['optim'])
        step=ck['step'];weights=ck['weights'];random.setstate(ck['python_rng']);torch.set_rng_state(ck['torch_rng']);torch.cuda.set_rng_state_all(ck['cuda_rng'])
    if step>a.steps:raise RuntimeError('Requested steps below saved step')
    run.mkdir(parents=True,exist_ok=True)
    if not a.resume:(run/'config.json').write_text(json.dumps(cfg,indent=2),encoding='utf-8')
    if weights is None:
        info=calibrate(net,teacher,vgg,paths,a.width,a.height);weights=[info['weights'][k] for k in TERMS]
        (run/'gradient_balance.json').write_text(json.dumps(info,indent=2),encoding='utf-8');print('Loss calibration:',info,flush=True)
    loader=DataLoader(Photos(paths,a.width,a.height),batch_size=1,shuffle=True,num_workers=0);it=iter(loader);start=time.time();startstep=step
    net.train()
    def checkpoint():
        save(run/'last.pth',{'step':step,'model':net.state_dict(),'optim':opt.state_dict(),'weights':weights,
                            'python_rng':random.getstate(),'torch_rng':torch.get_rng_state(),'cuda_rng':torch.cuda.get_rng_state_all()})
        save(run/f'model_step{step:06d}.pth',net.state_dict())
    if step==a.steps:
        # Finish evaluation if interrupted after the final training checkpoint.
        out=run/f'eval_step{step:06d}_recovered_{time.time_ns()}'
        evaluate(net,teacher,ev,out,a.width,a.height);save(run/'model_final.pth',net.state_dict())
        (run/'latest_evaluation.json').write_text(json.dumps({'step':step,'path':str(out),'model_sha256':digest(run/'model_final.pth')}),encoding='utf-8')
        (run/'completed.json').write_text(json.dumps({'step':step,'model_sha256':digest(run/'model_final.pth')}),encoding='utf-8')
        return
    try:
        while step<a.steps:
            if step==a.bn_warmup:
                calibrate_bn_fixed(net,paths,a.width,a.height)
                info=calibrate(net,teacher,vgg,paths,a.width,a.height);weights=[info['weights'][k] for k in TERMS]
                (run/'gradient_balance_fixed_bn.json').write_text(json.dumps(info,indent=2),encoding='utf-8')
            if step>=a.bn_warmup:
                for m in net.modules():
                    if isinstance(m,nn.BatchNorm2d):m.eval()
            opt.zero_grad(set_to_none=True);values=torch.zeros(len(TERMS)+1,device='cuda')
            for _ in range(a.accum):
                try:x=next(it)
                except StopIteration:it=iter(loader);x=next(it)
                x=x.cuda();ty,tf,cf=targets(teacher,vgg,x)
                with torch.autocast('cuda',dtype=torch.bfloat16):
                    y=net(x);ts=losses(vgg,y,ty,tf,cf)
                    tv=(y.float()[:,:,1:,:]-y.float()[:,:,:-1,:]).abs().mean()+(y.float()[:,:,:,1:]-y.float()[:,:,:,:-1]).abs().mean()
                    loss=sum(w*t for w,t in zip(weights,ts))+1e-6*tv
                if not torch.isfinite(loss):raise RuntimeError('Nonfinite loss')
                (loss/a.accum).backward();values+=torch.stack([loss.detach()]+[t.detach() for t in ts])/a.accum
            gn=torch.nn.utils.clip_grad_norm_(net.parameters(),5.)
            if not torch.isfinite(gn):raise RuntimeError('Nonfinite gradient')
            opt.step();step+=1
            if step%20==0:
                vs=values.cpu().tolist();rec={'step':step,'loss':vs[0],**dict(zip(TERMS,vs[1:])), 'weighted':dict(zip(TERMS,[w*v for w,v in zip(weights,vs[1:])]))}
                with (run/'history.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(rec)+'\n')
                print(f'{a.variant} {step}/{a.steps} loss={vs[0]:.4f} {(time.time()-start)/(step-startstep):.2f}s/step peak={torch.cuda.max_memory_allocated()/2**30:.2f}GiB',flush=True)
            if step%a.save_every==0 or step==a.steps:
                checkpoint();del x,ty,tf,cf,y,ts,tv,loss
                out=run/f'eval_step{step:06d}'
                if out.exists():out=run/f'eval_step{step:06d}_{time.time_ns()}'
                evaluate(net,teacher,ev,out,a.width,a.height);save(run/'model_final.pth',net.state_dict())
                (run/'latest_evaluation.json').write_text(json.dumps({'step':step,'path':str(out),'model_sha256':digest(run/'model_final.pth')}),encoding='utf-8')
    except KeyboardInterrupt:
        print('Stopped; rerun launcher to resume from last periodic checkpoint.',flush=True);return
    (run/'completed.json').write_text(json.dumps({'step':step,'model_sha256':digest(run/'model_final.pth')}),encoding='utf-8')
    print('Completed:',run,flush=True)

if __name__=='__main__':main()
