"""Read-only model PTQ screening: signed int8, power-of-two scales, int32 bias.

Integer-valued FP32 convolutions simulate arithmetic; this is NOT an RTL reference.
Reflection padding and floating tanh remain; no Efinity files are generated.
"""
import argparse,copy,json,math,random,time
from pathlib import Path
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image,ImageDraw
from torchvision.transforms import functional as TF
from pruning import ROOT,A8
from support import files,digest

LAYERS=['enc.0','enc.1','enc.2','enc.3','res.c1','res.c2','res.add','dec.1','dec.3','out.1']
CONVS=[k for k in LAYERS if k!='res.add']

def pow2scale(maximum):
    return torch.pow(2.,torch.ceil(torch.log2(torch.as_tensor(maximum).clamp_min(1e-10)/127.)))

def load_net(path):
    n=A8().eval()
    for m in n.modules():
        if hasattr(m,'norm') and isinstance(m.norm,nn.BatchNorm2d):m.norm=nn.Identity()
    n.load_state_dict(torch.load(path,map_location='cpu',weights_only=True),strict=True)
    return n.cuda()

def walk(n,x,op,add):
    for i in range(4):x=op(f'enc.{i}',n.enc[i],x)
    skip=x
    x=op('res.c1',n.res.c1,x);x=op('res.c2',n.res.c2,x)
    x=add('res.add',skip,x)
    x=F.interpolate(x,scale_factor=2,mode='nearest');x=op('dec.1',n.dec[1],x)
    x=F.interpolate(x,scale_factor=2,mode='nearest');x=op('dec.3',n.dec[3],x)
    x=op('out.1',n.out[1],n.out[0](x))
    return torch.tanh(x)*.5+.5

class Observer:
    def __init__(self):self.maximum={k:0. for k in LAYERS};self.elements={k:0 for k in LAYERS}
    def observe(self,k,x):
        self.maximum[k]=max(self.maximum[k],x.abs().max().item());self.elements[k]+=x.numel();return x
    def op(self,k,m,x):return self.observe(k,m(x))
    def add(self,k,a,b):return self.observe(k,a+b)

class Quantized:
    def __init__(self,net,scales,mode):
        self.net=net;self.scales=scales;self.mode=mode;self.weights={};self.spec={}
        self.stats={k:{'values':0,'clipped':0,'max_acc_abs':0.,'fp32_integer_exact':True} for k in LAYERS}
        for k in CONVS:
            m=net.get_submodule(k);c=m.conv if hasattr(m,'conv') else m
            w=c.weight.detach()
            mx=w.abs().amax(dim=(1,2,3),keepdim=True) if mode=='per_channel' else w.abs().max().reshape(1,1,1,1)
            ws=pow2scale(mx);qw=torch.round(w/ws).clamp(-127,127)
            self.weights[k]=(qw,ws)
            self.spec[k]={'weight_scales':ws.flatten().cpu().tolist(),'weight_exponents':torch.log2(ws).flatten().int().cpu().tolist(),
                          'weight_max_abs':w.abs().max().item()}
    def quant(self,k,x):
        s=self.scales[k];q=torch.round(x/s)
        st=self.stats[k];st['values']+=q.numel();st['clipped']+=((q<-127)|(q>127)).sum().item()
        return q.clamp(-127,127)*s
    def conv(self,k,m,x,inscale):
        c=m.conv if hasattr(m,'conv') else m
        x=m.pad(x) if hasattr(m,'pad') else x
        qi=torch.round(x/inscale) # already quantized by preceding node
        qw,ws=self.weights[k];accscale=(ws.flatten()*inscale)
        biasq=torch.round(c.bias.detach()/accscale)
        if biasq.abs().max()>2147483647:raise RuntimeError('Bias overflows int32: '+k)
        acc=F.conv2d(qi,qw,None,c.stride,c.padding,c.dilation,c.groups)
        acc=acc+biasq.reshape(1,-1,1,1)
        ma=acc.abs().max().item();st=self.stats[k];st['max_acc_abs']=max(st['max_acc_abs'],ma)
        st['fp32_integer_exact'] &= ma<2**24
        if ma>=2**24:raise RuntimeError('FP32 integer exactness limit exceeded: '+k)
        if ma>=2**31:raise RuntimeError('int32 overflow: '+k)
        y=acc*accscale.reshape(1,-1,1,1)
        if hasattr(m,'act'):y=m.act(y)
        # All scales are powers of two. Real-valued simulation of shifts/rounding.
        return self.quant(k,y)
    def __call__(self,x):
        # Candidate input: 8-bit RGB >> 1, then scaled by 1/128, range [0,127/128].
        # This mapping is explicit; existing teacher/RTL input shifts differ.
        x=torch.floor(torch.round(x*255)/2)/128
        previous='input'
        def op(k,m,x):
            nonlocal previous
            y=self.conv(k,m,x,self.scales[previous]);previous=k;return y
        def add(k,a,b):
            nonlocal previous
            y=self.quant(k,a+b);previous=k;return y
        return walk(self.net,x,op,add)

def get_image(p):
    with Image.open(p) as im:im=im.convert('RGB').resize((640,480),Image.Resampling.BICUBIC)
    return im,TF.to_tensor(im)[None].cuda()

def ssim(x,y):
    # Standard local SSIM: 11x11 Gaussian, sigma1.5, valid spatial support.
    grid=torch.arange(11,device=x.device,dtype=x.dtype)-5
    g=torch.exp(-grid.square()/(2*1.5**2));g=g/g.sum();kernel=(g[:,None]*g[None,:]).expand(3,1,11,11)
    avg=lambda z:F.conv2d(z,kernel,groups=3)
    ux,uy=avg(x),avg(y);vx=avg(x*x)-ux*ux;vy=avg(y*y)-uy*uy;cov=avg(x*y)-ux*uy
    return (((2*ux*uy+.01**2)*(2*cov+.03**2))/((ux.square()+uy.square()+.01**2)*(vx+vy+.03**2))).mean().item()

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--out',default='ptq_a8_3000')
    ap.add_argument('--calibration-count',type=int,default=256)
    ap.add_argument('--train-dir',default='D:/aidrawer/data/val2017')
    ap.add_argument('--eval-dir',default='D:/aidrawer/data/student_eval_external')
    a=ap.parse_args()
    if not torch.cuda.is_available():raise RuntimeError('CUDA required')
    if a.calibration_count<1:raise ValueError('Positive calibration count required')
    out=ROOT/a.out
    if out.exists():raise RuntimeError('Output exists. Use a new --out')
    src=ROOT/'a8_deployment_review_3000/a8_bn_folded_fp32.pth'
    baseline=json.loads((src.parent/'bn_fold_report.json').read_text(encoding='utf-8'))
    if digest(src)!=baseline['folded_sha256']:raise RuntimeError('Folded model hash changed')
    paths,ev=files(a.train_dir),files(a.eval_dir)
    expected=json.loads((src.parent/'config.json').read_text(encoding='utf-8'))['eval_files']
    if [{'path':str(p),'sha256':digest(p)} for p in ev]!=expected:raise RuntimeError('Evaluation set differs from accepted A8')
    hashes={digest(p) for p in ev};paths=[p for p in paths if digest(p) not in hashes]
    random.Random(20261006).shuffle(paths);paths=paths[:a.calibration_count]
    if not paths:raise RuntimeError('Empty calibration set')
    torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
    torch.backends.cudnn.benchmark=False;torch.use_deterministic_algorithms(True)
    n=load_net(src);out.mkdir(parents=True,exist_ok=False)
    obs=Observer();t=time.time()
    with torch.no_grad():
        for i,p in enumerate(paths):
            _,x=get_image(p);walk(n,x,obs.op,obs.add)
            if (i+1)%32==0:print('Calibrating',i+1,'/',len(paths),flush=True)
    scales={k:float(pow2scale(v)) for k,v in obs.maximum.items()};scales['input']=1/128
    quantizers={mode:Quantized(n,scales,mode) for mode in ['per_tensor','per_channel']}
    reports={mode:[] for mode in quantizers}
    for mode in quantizers:(out/mode).mkdir()
    (out/'float').mkdir();(out/'comparisons').mkdir()
    with torch.no_grad():
        for i,p in enumerate(ev):
            inp,x=get_image(p);ref=n(x);name=f'{i:02d}_{p.stem}'
            refim=TF.to_pil_image(ref[0].cpu().clamp(0,1));refim.save(out/'float'/f'{name}.png')
            panels=[('Input',inp),('A8 float',refim)]
            for mode,q in quantizers.items():
                y=q(x);mse=(y-ref).square().mean().item();d=(y-ref).abs()
                reports[mode].append({'image':str(p),'mae_u8':255*d.mean().item(),'max_error_u8':255*d.max().item(),
                    'psnr_db':-10*math.log10(max(mse,1e-12)),'ssim':ssim(ref,y),
                    'mean_RGB_delta_u8':((y-ref).mean(dim=(0,2,3))*255).cpu().tolist()})
                im=TF.to_pil_image(y[0].cpu().clamp(0,1));im.save(out/mode/f'{name}.png');panels.append((f'INT8 {mode}',im))
            sheet=Image.new('RGB',(320*len(panels),266),'white');draw=ImageDraw.Draw(sheet)
            for col,(label,im) in enumerate(panels):
                sheet.paste(im.resize((320,240)),(320*col,26));draw.text((320*col+5,5),label,fill='black')
            sheet.save(out/'comparisons'/f'{name}.jpg',quality=95)
            print('Evaluated',i+1,'/',len(ev),flush=True)
    summary={}
    for mode,q in quantizers.items():
        rows=reports[mode]
        summary[mode]={'mean_mae_u8':float(np.mean([r['mae_u8'] for r in rows])),
            'mean_psnr_db':float(np.mean([r['psnr_db'] for r in rows])),
            'min_psnr_db':min(r['psnr_db'] for r in rows),'mean_ssim':float(np.mean([r['ssim'] for r in rows])),
            'max_layer_clip_fraction':max(st['clipped']/max(st['values'],1) for st in q.stats.values())}
        (out/mode/'metrics.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2),encoding='utf-8')
        (out/mode/'layer_stats.json').write_text(json.dumps(q.stats,indent=2),encoding='utf-8')
        (out/mode/'quantization_spec.json').write_text(json.dumps(q.spec,indent=2),encoding='utf-8')
    report={'model_sha256':digest(src),'resolution':[640,480],'calibration_count':len(paths),
        'calibration_images':[{'path':str(p),'sha256':digest(p)} for p in paths],
        'eval_images':[{'path':str(p),'sha256':digest(p)} for p in ev],
        'activation_scales':scales,'observed_max_abs':obs.maximum,'summary':summary,'elapsed_seconds':time.time()-t,
        'arithmetic':{'weight':'symmetric signed int8 [-127,127], power-of-two scale; per-tensor and per-output-channel',
            'activation':'per-tensor signed int8 [-127,127], calibrated maximum, power-of-two scale',
            'bias':'int32 rounded at input_scale*weight_scale','rounding':'nearest, ties to even',
            'conv':'integer-valued FP32 simulation, TF32 disabled; asserts accumulated absolute value < 2^24',
            'input':'RGB888 >> 1, dequantized by 1/128',
            'residual':'both branches requantized to residual output scale; simulated via exact power-of-two scales',
            'padding':'ReflectionPad2d, preserving student; must compare with real RTL',
            'tanh':'floating point; LUT and output packing NOT modeled'},
        'validation_status':'PTQ feasibility screening only; NOT current RTL arithmetic, not FPGA performance or final quality acceptance'}
    (out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print('SUMMARY',json.dumps(summary,indent=2),flush=True);print('OUTPUT',out,flush=True)

if __name__=='__main__':main()
