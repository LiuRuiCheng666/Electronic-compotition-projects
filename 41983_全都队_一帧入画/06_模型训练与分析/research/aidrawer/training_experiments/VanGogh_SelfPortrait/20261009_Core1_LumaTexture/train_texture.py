"""Only train an additive luminance texture head; never train the color trunk."""
import argparse,json,random,time
from pathlib import Path
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader
import train_compact as helpers
from luma_texture_model import LumaTextureStudent

ROOT=Path('D:/aidrawer/output/VanGogh_SelfPortrait/20261009_Core1_LumaTexture')

def luma(x):return (x.float()*x.new_tensor([.299,.587,.114])[None,:,None,None]).sum(1,keepdim=True)
def high(x,k):
    return x-F.avg_pool2d(F.pad(x,(k//2,)*4,mode='replicate'),k,stride=1)
def terms(y,t):
    a,b=luma(y),luma(t)
    signed=sum(F.l1_loss(high(a,k),high(b,k)) for k in [5,9])/2
    energy=sum(F.l1_loss(F.avg_pool2d(high(a,k).abs(),16),F.avg_pool2d(high(b,k).abs(),16)) for k in [5,9])/2
    grad=(F.l1_loss(a[:,:,:,1:]-a[:,:,:,:-1],b[:,:,:,1:]-b[:,:,:,:-1])+F.l1_loss(a[:,:,1:,:]-a[:,:,:-1,:],b[:,:,1:,:]-b[:,:,:-1,:]))/2
    return [signed,energy,grad]

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--run',default='luma_v1');ap.add_argument('--steps',type=int,default=1000)
    ap.add_argument('--accum',type=int,default=4);ap.add_argument('--save-every',type=int,default=250)
    ap.add_argument('--lr',type=float,default=1e-4);ap.add_argument('--resume',action='store_true');ap.add_argument('--check-only',action='store_true')
    ap.add_argument('--train-dir',default='D:/aidrawer/data/val2017');ap.add_argument('--eval-dir',default='D:/aidrawer/data/student_eval_external')
    a=ap.parse_args()
    if Path(a.run).name!=a.run or a.run in ['.','..'] or min(a.steps,a.accum,a.save_every)<=0 or a.lr<=0:raise ValueError('Invalid arguments')
    random.seed(20261009);torch.manual_seed(20261009);torch.cuda.manual_seed_all(20261009)
    torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    identity=json.loads((ROOT/'identity.json').read_text())
    for name,key in [('core1.pth','core1_sha256'),('original_in_teacher/model.pth','in_sha256')]:
        if helpers.digest(ROOT/name)!=identity[key]:raise RuntimeError('Frozen weights changed: '+name)
    net=LumaTextureStudent(identity['keep_blocks'],identity['detail_mode']).cuda()
    frozen=torch.load(ROOT/'core1.pth',map_location='cpu',weights_only=True)
    net.trunk.load_state_dict(frozen,strict=True);net.train()
    teacher=helpers.FastNeuralStyleNet(8,3,'instance').cuda().eval().requires_grad_(False)
    teacher.load_state_dict(torch.load(ROOT/'original_in_teacher/model.pth',map_location='cpu',weights_only=True),strict=True)
    helpers.IN_EVAL=teacher
    train,ev=helpers.files(a.train_dir),helpers.files(a.eval_dir)
    if not train or not ev:raise RuntimeError('Empty dataset')
    ev_manifest=[{'path':str(p),'sha256':helpers.digest(p)} for p in ev];excluded={r['sha256'] for r in ev_manifest}
    train_manifest=[{'path':str(p),'sha256':helpers.digest(p)} for p in train]
    train_manifest=[r for r in train_manifest if r['sha256'] not in excluded];train=[Path(r['path']) for r in train_manifest]
    if not train:raise RuntimeError('No independent training images')
    params=[p for p in net.parameters() if p.requires_grad]
    def target(x):
        with torch.no_grad():return teacher(x.float())
    if a.check_only:
        x=helpers.Photos(train,1280,720)[0][None].cuda()
        with torch.no_grad():base=net.trunk(x)
        with torch.autocast('cuda',enabled=False):initial=net(x)
        assert torch.equal(initial,base.float()),'Zero head must preserve accepted core1 exactly'
        with torch.autocast('cuda',dtype=torch.bfloat16):y=net(x);ts=terms(y,target(x));loss=ts[0]+.5*ts[1]+.25*ts[2]
        loss.backward()
        assert all(p.grad is None for p in net.trunk.parameters())
        assert all(p.grad is not None and torch.isfinite(p.grad).all() for p in params)
        assert any(p.grad.abs().max()>0 for p in net.phase.parameters()),'Head received no learning signal'
        with torch.no_grad():
            net.phase.weight.normal_(0,.02);z=net(x);offset=z-base
            assert (offset[:,0]-offset[:,1]).abs().max()<2e-6 and (offset[:,1]-offset[:,2]).abs().max()<2e-6
            assert z.min()>=0 and z.max()<=1 and offset.abs().max()<=.080001
        print('PASS:720p loss/backward, exact zero initialization, frozen trunk, nonzero head gradient, RGB difference preservation, bounded gamut. Trainable parameters:',sum(p.numel() for p in params));return
    run=ROOT/'runs'/a.run
    if run.exists() and not a.resume:raise RuntimeError('Run exists: choose another --run or add --resume')
    cfg={**vars(a),'identity':identity,'resolution':[1280,720],'train_files':train_manifest,'eval_files':ev_manifest,
         'teacher':'original approved IN teacher, luminance texture targets only','loss_weights':[1,.5,.25],
         'trainable_parameters':sum(p.numel() for p in params),
         'code_sha256':{p.name:helpers.digest(p) for p in Path(__file__).parent.glob('*.py')},
         'limit':.08,'strength':1.,'note':'phase zero mean before gamut limiting; no exact zero mean after limiting; chroma differences preserved'}
    opt=torch.optim.Adam(params,lr=a.lr);step=0
    if a.resume:
        old=json.loads((run/'config.json').read_text())
        for k,v in cfg.items():
            if k not in ['steps','resume','check_only'] and old[k]!=v:raise RuntimeError('Resume mismatch: '+k)
        ck=torch.load(run/'last.pth',map_location='cpu',weights_only=False)
        net.load_state_dict(ck['model']);opt.load_state_dict(ck['optim']);step=ck['step']
        random.setstate(ck['python_rng']);torch.set_rng_state(ck['torch_rng']);torch.cuda.set_rng_state_all(ck['cuda_rng'])
    if step>a.steps:raise RuntimeError('Requested steps below saved checkpoint')
    run.mkdir(parents=True,exist_ok=True)
    if not a.resume:(run/'config.json').write_text(json.dumps(cfg,indent=2),encoding='utf-8')
    loader=DataLoader(helpers.Photos(train,1280,720),batch_size=1,shuffle=True,num_workers=0);it=iter(loader)
    def verify_frozen():
        for k,v in net.trunk.state_dict().items():
            if not torch.equal(v.cpu(),frozen[k]):raise RuntimeError('Frozen trunk changed: '+k)
    def checkpoint():
        verify_frozen()
        helpers.save(run/'last.pth',{'model':net.state_dict(),'optim':opt.state_dict(),'step':step,
          'python_rng':random.getstate(),'torch_rng':torch.get_rng_state(),'cuda_rng':torch.cuda.get_rng_state_all()})
        helpers.save(run/f'model_step{step:06d}.pth',net.state_dict())
        out=run/f'eval_step{step:06d}'
        if out.exists():out=run/f'eval_step{step:06d}_{time.time_ns()}'
        helpers.evaluate(net,net.trunk,ev,out,1280,720)
        # Evaluate high-frequency changes separately; RGB palette reports alone cannot assess texture.
        texture_rows=[]
        from PIL import Image
        from torchvision.transforms.functional import to_tensor
        with torch.no_grad():
            for p in ev:
                with Image.open(p) as im:x=to_tensor(im.convert('RGB').resize((1280,720),Image.Resampling.BICUBIC))[None].cuda()
                t=teacher(x);base=net.trunk(x);y=net(x)
                texture_rows.append({'image':str(p),'core1_texture_losses':[z.item() for z in terms(base,t)],
                  'new_texture_losses':[z.item() for z in terms(y,t)],'luminance_change_u8':255*(luma(y)-luma(base)).abs().mean().item()})
        (out/'texture_metrics.json').write_text(json.dumps(texture_rows,indent=2),encoding='utf-8')
        helpers.save(run/'model_final.pth',net.state_dict())
        (run/'latest_evaluation.json').write_text(json.dumps({'step':step,'path':str(out),'model_sha256':helpers.digest(run/'model_final.pth')}),encoding='utf-8')
    start=time.time();startstep=step
    print('Only luminance head trains;224 parameters. Original IN targets. True1280x720.',flush=True)
    try:
        while step<a.steps:
            opt.zero_grad(set_to_none=True);values=torch.zeros(3,device='cuda')
            for _ in range(a.accum):
                try:x=next(it)
                except StopIteration:it=iter(loader);x=next(it)
                x=x.cuda();t=target(x)
                with torch.autocast('cuda',dtype=torch.bfloat16):y=net(x);ts=terms(y,t);loss=ts[0]+.5*ts[1]+.25*ts[2]
                if not torch.isfinite(loss):raise RuntimeError('Nonfinite loss')
                (loss/a.accum).backward();values+=torch.stack([v.detach() for v in ts])/a.accum
            gn=torch.nn.utils.clip_grad_norm_(params,1.)
            if not torch.isfinite(gn):raise RuntimeError('Nonfinite gradient')
            opt.step();step+=1
            if step%20==0:
                record={'step':step,'signed_highpass':values[0].item(),'local_energy':values[1].item(),'gradient':values[2].item()}
                with (run/'history.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(record)+'\n')
                print(record,'seconds/step',round((time.time()-start)/(step-startstep),2),flush=True)
            if step%a.save_every==0 or step==a.steps:checkpoint()
        if step==startstep:checkpoint()
    except KeyboardInterrupt:
        print('Stopped. Resume restores latest complete periodic checkpoint; partial step discarded.');return
    (run/'completed.json').write_text(json.dumps({'step':step}),encoding='utf-8')

if __name__=='__main__':main()
