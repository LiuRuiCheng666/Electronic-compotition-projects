"""Fine-tune shipped int8 A4 with STE; no PC style preview or image judging.
Uses the shipped fixed shifts, saturation, residual and tanh table. Exported
int8 weights are candidates for board A/B tests, never automatic acceptance.
"""
from pathlib import Path
import argparse, copy, hashlib, json, math, random, struct, time, zlib
import numpy as np
from PIL import Image
import torch
from torch import nn
import torch.nn.functional as F

P=Path(__file__).resolve().parents[1]
CINS=[4,4,4,8,4,4,4,4,4]
COUTS=[4,4,8,4,4,4,4,4,3]
STRIDES=[1,1,2,2,1,1,1,1,1]
RELUS=[1,1,1,1,1,0,1,1,0]
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()

def ste_round(x):return x+(x.round()-x).detach()

class BoardA4(nn.Module):
    def __init__(self,slot):
        super().__init__();self.slot=slot;self.weights=nn.ParameterList();self.biases=nn.ParameterList()
        self.coefficients=[];self.divisors=[];offset=0;coeff_offset=0
        for ci,co in zip(CINS,COUTS):
            padded=(co+3)//4*4;w=np.zeros((padded,ci,3,3),dtype=np.int8)
            for og in range(0,padded,4):
                for ig in range(0,ci,4):
                    w[og:og+4,ig:ig+4]=np.frombuffer(slot[offset:offset+144],dtype=np.int8).reshape(4,4,3,3)
                    assert slot[offset+144:offset+160]==bytes(16)
                    offset+=160
            ab=[struct.unpack_from('<Ii',slot,0x800+(coeff_offset+j)*8) for j in range(co)]
            assert all(a in (32768,65536,131072,262144) and b%a==0 for a,b in ab)
            div=torch.tensor([2**24//a for a,b in ab],dtype=torch.float32)[None,:,None,None]
            self.register_buffer('div'+str(len(self.weights)),div)
            self.coefficients.append(ab);self.divisors.append(div)
            self.weights.append(nn.Parameter(torch.tensor(w[:co].copy(),dtype=torch.float32)))
            self.biases.append(nn.Parameter(torch.tensor([b/a/(2**24//a) for a,b in ab],dtype=torch.float32)[None,:,None,None]))
            coeff_offset+=padded
        assert offset==1760 and coeff_offset==40
        self.register_buffer('lut',torch.tensor(list(slot[0xa00:0xb00]),dtype=torch.float32)/255)

    def forward_codes(self,codes):
        q=torch.cat((codes,torch.zeros_like(codes[:,:1])),1);skip=None
        for i,(w,b) in enumerate(zip(self.weights,self.biases)):
            if i in (6,7):q=F.interpolate(q,scale_factor=2,mode='nearest')
            divisor=getattr(self,'div'+str(i))
            bias_code=ste_round(b.clamp(-127.9,127.9)*divisor)
            acc=F.conv2d(F.pad(q,(1,1,1,1),mode='reflect'),ste_round(w.clamp(-127,127)),stride=STRIDES[i])
            q=ste_round((acc+bias_code)/divisor)
            if RELUS[i]:q=q.clamp_min(0)
            q=q.clamp(-127,127)
            if i==3:skip=q
            if i==5:q=(q+skip).clamp(-127,127)
        return q

    def forward(self,x):
        codes=torch.floor((x*255).round()/2)
        q=self.forward_codes(codes)+128
        # Interpolated LUT has exactly the deployed values at integer codes,
        # while exposing local LUT slopes to training gradients.
        low=q.detach().floor().long().clamp(0,254);frac=q-low
        return self.lut[low]+frac*(self.lut[low+1]-self.lut[low])

    @torch.no_grad()
    def export(self):
        slot=bytearray(self.slot);offset=0;coeff_offset=0
        for i,(ci,co) in enumerate(zip(CINS,COUTS)):
            padded=(co+3)//4*4
            w=np.zeros((padded,ci,3,3),dtype=np.int8)
            w[:co]=self.weights[i].clamp(-127,127).round().cpu().numpy().astype(np.int8)
            for og in range(0,padded,4):
                for ig in range(0,ci,4):
                    slot[offset:offset+144]=w[og:og+4,ig:ig+4].tobytes();offset+=160
            div=getattr(self,'div'+str(i)).flatten().cpu()
            bias=(self.biases[i].clamp(-127.9,127.9).flatten().cpu()*div).round().long().tolist()
            for c,code in enumerate(bias):
                a=self.coefficients[i][c][0];b=code*a
                assert -65536<=code<65536 and -2**31<=b<2**31
                struct.pack_into('<Ii',slot,0x800+(coeff_offset+c)*8,a,b)
            coeff_offset+=padded
        return bytes(slot)

def neon_target(x):
    """Continuous cyan/magenta lighting, navy shadows, input-aligned contours."""
    luma=(x[:,0:1]*.2126+x[:,1:2]*.7152+x[:,2:3]*.0722)
    # Preserve local luminance detail, avoid a hard posterization threshold.
    smooth=F.avg_pool2d(F.pad(luma,(2,2,2,2),mode='reflect'),5,1)
    detail=luma-smooth
    gx=F.pad(luma.diff(dim=3),(0,1,0,0));gy=F.pad(luma.diff(dim=2),(0,0,0,1))
    edge=(gx.square()+gy.square()+1e-8).sqrt().clamp(0,.5)*2
    warm=torch.sigmoid((x[:,0:1]-x[:,2:3])*3+detail*4)
    cyan=x.new_tensor([.05,.82,1.0])[None,:,None,None]
    purple=x.new_tensor([.95,.12,.85])[None,:,None,None]
    navy=x.new_tensor([.025,.035,.11])[None,:,None,None]
    color=cyan*(1-warm)+purple*warm
    brightness=(luma*.85+edge*.4+detail*.25).clamp(0,1)
    return (navy*(1-brightness)+color*brightness+.12*x).clamp(0,1)

def losses(y,target):
    pixel=F.l1_loss(y,target)
    scales=sum(F.l1_loss(F.avg_pool2d(y,s),F.avg_pool2d(target,s)) for s in (4,16))/2
    gradient=sum(F.l1_loss(y.diff(dim=d),target.diff(dim=d)) for d in (2,3))/2
    return pixel+.3*scales+.25*gradient

def write_slot(folder,slot,metadata):
    folder.mkdir(parents=True,exist_ok=False);(folder/'slot.bin').write_bytes(slot)
    (folder/'a4_weights_pci4.mem').write_text(''.join(f'{int.from_bytes(slot[i:i+32],"little"):064x}\n' for i in range(0,1760,32)),encoding='ascii')
    coeff=slot[0x800:0x940]+bytes(24*8)
    (folder/'a4_coeff.mem').write_text(''.join(f'{int.from_bytes(coeff[i:i+8],"little"):016x}\n' for i in range(0,512,8)),encoding='ascii')
    (folder/'a4_tanh.mem').write_text(''.join(f'{b:02x}\n' for b in slot[0xa00:0xb00]),encoding='ascii')
    metadata.update(slot_sha256=hashlib.sha256(slot).hexdigest(),board_verified=False,
                    visual_evaluation='Pending physical FPGA capture; no PC preview images generated')
    (folder/'candidate.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2),encoding='utf-8')

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--data',type=Path,default=Path('D:/aidrawer/data/val2017'))
    ap.add_argument('--output',type=Path,default=P/'neon_trials')
    ap.add_argument('--steps',type=int,default=600);ap.add_argument('--images',type=int,default=384)
    ap.add_argument('--seed',type=int,default=20261028);ap.add_argument('--variants',nargs='+',choices=['structure','vivid'],default=['structure','vivid'])
    args=ap.parse_args()
    if args.output.exists():raise ValueError('Preserve previous training; select a new output directory')
    if args.steps<1 or args.images<1:raise ValueError('Positive step/image counts required')
    torch.manual_seed(args.seed);random.seed(args.seed);torch.cuda.manual_seed_all(args.seed)
    torch.backends.cuda.matmul.fp32_precision='ieee';torch.backends.cudnn.conv.fp32_precision='ieee'
    torch.set_num_threads(4)
    blob=(P/'flash_assets/a4_dual_models_flash.bin').read_bytes();version,size,crc=struct.unpack_from('<III',blob,4)
    assert blob[:4]==b'NNW1' and version==1 and size==16384 and zlib.crc32(blob[32:])==crc
    initial=blob[32:4128];teacher=BoardA4(initial).cuda().eval();teacher.requires_grad_(False)
    paths=sorted(p for p in args.data.iterdir() if p.suffix.lower() in ('.jpg','.png','.jpeg'))
    random.shuffle(paths);paths=paths[:args.images]
    if not paths:raise ValueError('No training images')
    args.output.mkdir(parents=True)
    # Cache full 720p training frames at the same RGB7 code precision as board
    # input. No inference previews or evaluation contact sheets are produced.
    images=[];manifest=[]
    for p in paths:
        with Image.open(p) as im:a=np.array(im.convert('RGB').resize((1280,720),Image.Resampling.BICUBIC))
        images.append(torch.from_numpy(a.copy()).permute(2,0,1))
        manifest.append(dict(path=str(p),sha256=sha(p)))
    common=dict(initial_payload_sha256=sha(P/'flash_assets/a4_dual_models_flash.bin'),
        initial_slot_sha256=hashlib.sha256(initial).hexdigest(),seed=args.seed,steps=args.steps,
        training_resolution=[1280,720],hardware_architecture='Unchanged A4; shipped fixed shifts, RGB7, round-even, saturation, residual and LUT',
        source_sha256=sha(__file__),training_images=manifest,
        normalization='No BatchNorm state or post-training BN recalibration; start directly from shipped int8 graph',
        notes='Training forward passes are required for gradient optimization; style acceptance is deferred to FPGA. No claim of improved visuals.')
    (args.output/'training_config.json').write_text(json.dumps(common,ensure_ascii=False,indent=2),encoding='utf-8')
    for variant in args.variants:
        net=BoardA4(initial).cuda().train();strength=.25 if variant=='structure' else .5
        optimizer=torch.optim.Adam([dict(params=net.weights,lr=.035),dict(params=net.biases,lr=.003)])
        start=time.monotonic();history=[];folder=args.output/variant;folder.mkdir()
        for step in range(1,args.steps+1):
            x=images[random.randrange(len(images))].unsqueeze(0).cuda().float()/255
            if random.random()<.5:x=x.flip(-1)
            x=(x*random.uniform(.85,1.12)+random.uniform(-.012,.012)).clamp(0,1)
            optimizer.zero_grad(set_to_none=True)
            with torch.no_grad():
                anchor=teacher(x);target=anchor*(1-strength)+neon_target(x)*strength
            y=net(x);loss=losses(y,target)
            if not torch.isfinite(loss):raise ValueError('Nonfinite training loss')
            loss.backward();nn.utils.clip_grad_norm_(net.parameters(),2.0,error_if_nonfinite=True);optimizer.step()
            if step%20==0 or step==1:
                record=dict(step=step,loss=float(loss.detach()),seconds=time.monotonic()-start);history.append(record)
                print(f'{variant} {step}/{args.steps} loss={record["loss"]:.5f} time={record["seconds"]:.1f}s',flush=True)
                (folder/'history.json').write_text(json.dumps(history,indent=2))
        checkpoint=folder/'model_final.pth';torch.save(net.cpu().state_dict(),checkpoint)
        slot=net.export()
        metadata={k:v for k,v in common.items() if k!='training_images'}
        metadata.update(variant=variant,rule_target_mix=strength,checkpoint=str(checkpoint),checkpoint_sha256=sha(checkpoint),
                        final_training_loss=history[-1]['loss'],changed_slot_bytes=sum(a!=b for a,b in zip(initial,slot)),
                        training_seconds=time.monotonic()-start)
        write_slot(folder/'export',slot,metadata)
        del net,optimizer,x,y,target,anchor,loss;torch.cuda.empty_cache()
    print('Training finished. Candidates require board capture; no aesthetic acceptance inferred from loss.',flush=True)

if __name__=='__main__':main()
