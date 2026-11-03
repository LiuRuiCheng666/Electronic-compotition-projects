"""Natural sunny-light enhancement, initialized from an analytic neutral model.

Only existing A4 model parameters. Synthetic overcast degradation is used for
paired training; this is not semantic sky replacement or physically new sun.
"""
from pathlib import Path
import argparse,hashlib,json,math,random,shutil,struct,time
import numpy as np
from PIL import Image
import torch
from torch import nn
import torch.nn.functional as F
from neon_board_core import BoardA4,CINS,COUTS,STRIDES,RELUS,ste_round,write_slot
from train_neon_round2 import luma,blur

P=Path(__file__).resolve().parents[1]
E=P/'style_experiments/sunny_20261102'
sha=lambda b:hashlib.sha256(b).hexdigest()


def neutral_slot():
    b=bytearray(4096);offset=0
    for i,(ci,co) in enumerate(zip(CINS,COUTS)):
        padded=(co+3)//4*4;w=np.zeros((padded,ci,3,3),np.int8)
        for c in range(min(4,co,ci)):
            if i in (2,3):w[c,c,1:3,1:3]=16
            elif i in (6,7):w[c,c]=np.array([[4,8,4],[8,16,8],[4,8,4]],np.int8)
            elif i!=5:w[c,c,1,1]=64
        if i==0:w[3,:3,1,1]=[14,46,4];w[3,3,1,1]=0
        for og in range(0,padded,4):
            for ig in range(0,ci,4):
                b[offset:offset+144]=w[og:og+4,ig:ig+4].tobytes();offset+=160
    assert offset==1760
    for i in range(40):struct.pack_into('<Ii',b,0x800+i*8,262144,0)
    for i in range(256):b[0xa00+i]=int(np.rint(max(0,min(127,i-128))*255/127))
    return bytes(b)


def bound(x,lo=None,hi=None):
    y=x.clamp(min=lo,max=hi)
    outside=torch.zeros_like(x,dtype=torch.bool)
    if lo is not None:outside|=x<lo
    if hi is not None:outside|=x>hi
    return y+.15*outside.detach()*(x-x.detach())


class NaturalA4(BoardA4):
    def forward_codes(self,codes):
        q=torch.cat((codes,torch.zeros_like(codes[:,:1])),1);skip=None
        for i,(w,b) in enumerate(zip(self.weights,self.biases)):
            if i in (6,7):q=F.interpolate(q,scale_factor=2,mode='nearest')
            div=getattr(self,'div'+str(i));bias=ste_round(b.clamp(-127.9,127.9)*div)
            acc=F.conv2d(F.pad(q,(1,1,1,1),mode='reflect'),ste_round(w.clamp(-127,127)),stride=STRIDES[i])
            q=ste_round((acc+bias)/div)
            if RELUS[i]:q=bound(q,0,None)
            q=bound(q,-127,127)
            if i==3:skip=q
            if i==5:q=bound(q+skip,-127,127)
        return q


@torch.no_grad()
def sunny_target(x):
    gray=luma(x);mid=4*gray*(1-gray)
    local=gray-blur(gray,9)
    light=gray+.048*mid+.025*torch.tanh(local*12)
    warm=x.new_tensor([.012,.002,-.009])[None,:,None,None]*mid
    return (light+1.10*(x-gray)+warm).clamp(0,1)


@torch.no_grad()
def overcast(x,exposure=.87,contrast=.82,saturation=.70,cool=.006):
    gray=luma(x)
    dim=(.5+(gray-.5)*contrast)*exposure
    cast=x.new_tensor([-cool*.4,0,cool])[None,:,None,None]
    return (dim+saturation*exposure*(x-gray)+cast).clamp(0,1)


def objective(y,t):
    pixel=F.l1_loss(y,t)
    yl,tl=luma(y),luma(t)
    tone=F.l1_loss(yl,tl)
    chroma=F.l1_loss(y-yl,t-tl)
    scales=sum(F.l1_loss(F.avg_pool2d(y,s),F.avg_pool2d(t,s)) for s in (4,16))/2
    gradient=sum(F.l1_loss(y.diff(dim=d),t.diff(dim=d)) for d in (2,3))/2
    detail=F.l1_loss(yl-blur(yl,5),tl-blur(tl,5))
    return pixel+.35*tone+.60*chroma+.25*scales+.50*gradient+.25*detail,dict(pixel=pixel,tone=tone,chroma=chroma,gradient=gradient,detail=detail)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output',type=Path,default=E);ap.add_argument('--steps',type=int,default=6000)
    ap.add_argument('--images',type=int,default=384);args=ap.parse_args()
    if args.output.exists():raise ValueError('Preserve experiments')
    assert torch.cuda.is_available() and min(args.steps,args.images)>0
    torch.set_num_threads(4);seed=20261102;torch.manual_seed(seed);torch.cuda.manual_seed_all(seed)
    torch.backends.cuda.matmul.fp32_precision='ieee';torch.backends.cudnn.conv.fp32_precision='ieee'
    initial=neutral_slot();args.output.mkdir(parents=True);(args.output/'neutral_initial.slot.bin').write_bytes(initial)
    for name in ('train_sunny.py','neon_board_core.py','train_neon_round2.py'):shutil.copy2(P/'tools'/name,args.output/name)
    rng=random.Random(seed);paths=sorted(Path('D:/aidrawer/data/val2017').glob('*.jpg'));rng.shuffle(paths)
    assert len(paths)>=args.images+16
    images=[];records=[];print('Caching384 full720p source images',flush=True)
    for path in paths[:args.images]:
        with Image.open(path) as im:a=np.array(im.convert('RGB').resize((1280,720),Image.Resampling.BICUBIC))
        images.append(torch.from_numpy(a.copy()).permute(2,0,1));records.append(dict(path=str(path),sha256=sha(path.read_bytes())))
    common=dict(variant='sunny',destination_style=3,initial_slot_sha256=sha(initial),
                initialization='Analytic neutral RGB/luma autoencoder; no P5 or artistic style model weights',
                training_resolution=[1280,720],steps=args.steps,images=args.images,seed=seed,
                training_code_sha256=sha(Path(__file__).read_bytes()),graph_code_sha256=sha((P/'tools/neon_board_core.py').read_bytes()),
                paired_data='Synthetic low contrast/desaturation/exposure/cool-cast inputs from natural photos; not real paired overcast/sunny captures',
                objective='Natural mild warm daylight, shadow lift, saturation/detail restoration, white/highlight protection',
                hardware_changed=False,firmware_changed=False,coordinate_input=False,pc_style_previews=False,
                architecture='Unchanged A4/RGB7; analytic262144 affine multipliers and continuous neutral output LUT',
                limitation='Local RGB light/colour enhancement; no semantic sky selection, real new sun/cloud geometry, or guarantee of physical outdoor relighting')
    cfg=dict(**common,training_images=records,heldout_images=[dict(path=str(p),sha256=sha(p.read_bytes())) for p in paths[args.images:args.images+16]])
    (args.output/'training_config.json').write_text(json.dumps(cfg,ensure_ascii=False,indent=2),encoding='utf-8')
    net=NaturalA4(initial).cuda().train();ema=[p.detach().clone() for p in net.parameters()]
    opt=torch.optim.Adam([dict(params=net.weights,lr=.012),dict(params=net.biases,lr=.0015)])
    folder=args.output/'sunny';folder.mkdir();history=[];torch.cuda.synchronize();began=time.monotonic()
    for step in range(1,args.steps+1):
        rate=.10+.90*.5*(1+math.cos(math.pi*(step-1)/args.steps))
        opt.param_groups[0]['lr']=.012*rate;opt.param_groups[1]['lr']=.0015*rate
        clean=images[rng.randrange(len(images))][None].cuda().float()/255
        if rng.random()<.5:clean=clean.flip(-1)
        clean=(clean*rng.uniform(.85,1.10)).clamp(0,1)
        with torch.no_grad():
            target=sunny_target(clean)
            if rng.random()<.75:
                x=overcast(clean,rng.uniform(.80,.96),rng.uniform(.77,.93),rng.uniform(.62,.84),rng.uniform(.002,.009))
            else:x=clean
            x=torch.floor((x*255).round()/2)*2/255
        opt.zero_grad(set_to_none=True);y=net(x);loss,parts=objective(y,target)
        levels=x.new_tensor([0,4,8,16,32,48,64,80,96,112,127])[:,None,None,None]
        probes=levels.expand(-1,3,24,32)*2/255
        with torch.no_grad():pt=sunny_target(probes)
        calibration=F.l1_loss(net(probes),pt)
        loss=loss+.70*calibration
        assert torch.isfinite(loss)
        loss.backward();nn.utils.clip_grad_norm_(net.parameters(),2.,error_if_nonfinite=True);opt.step()
        with torch.no_grad():
            for avg,p in zip(ema,net.parameters()):avg.mul_(.98).add_(p,alpha=.02)
        if step==1 or step%100==0 or step==args.steps:
            torch.cuda.synchronize();row=dict(step=step,seconds=time.monotonic()-began,loss=float(loss.detach()),
                calibration_mae_u8=float(calibration.detach())*255,**{k:float(v.detach()) for k,v in parts.items()})
            history.append(row);(folder/'history.json').write_text(json.dumps(history,indent=2),encoding='utf-8')
            print('sunny',json.dumps(row),flush=True)
    net.cpu()
    with torch.no_grad():
        for p,avg in zip(net.parameters(),ema):p.copy_(avg.cpu())
    checkpoint=folder/'model_final_ema.pth';torch.save(net.state_dict(),checkpoint)
    slot=net.export();assert sha(slot)!=sha(initial)
    write_slot(folder/'export',slot,dict(**common,checkpoint=str(checkpoint),checkpoint_sha256=sha(checkpoint.read_bytes()),
               training_seconds=history[-1]['seconds'],final_loss=history[-1]['loss'],
               changed_slot_bytes=sum(a!=b for a,b in zip(slot,initial))))
    print('Exported sunny candidate; independent checks required; no board I/O',flush=True)


if __name__=='__main__':main()
