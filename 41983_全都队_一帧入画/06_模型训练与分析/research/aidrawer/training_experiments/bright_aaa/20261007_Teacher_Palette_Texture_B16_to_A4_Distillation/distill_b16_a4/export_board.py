"""Fold/calibrate/export the selected A4; no quality screening or Efinity calls."""
import argparse,copy,hashlib,json,math,random,sys
from pathlib import Path
import numpy as np
import torch
from PIL import Image
from torchvision.transforms import functional as TF
ROOT=Path('D:/aidrawer/output/bright_aaa/20261007_Teacher_Palette_Texture_B16_to_A4_Distillation/distill_b16_a4')
sys.path.insert(0,str(Path('D:/aidrawer/training_experiments/bright_aaa/20261007_Teacher_Palette_Texture_B16_to_A4_Distillation/distill_b16_a4/a4_from_b16')))
from structure import A4
from support import digest,files
sys.path.append('D:/aidrawer/training_experiments/Ukiyo-e/20261006_A4_BN_Pruning_A8_NoResidual_Distillation')
from quant_screen_a4 import Observer,walk,pow2scale

def mem(p,items,digits):
    p.write_text(''.join(f'{int(v)&((1<<(digits*4))-1):0{digits}x}\n' for v in items),encoding='ascii')

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--calibration-count',type=int,default=256)
    a=ap.parse_args()
    src=ROOT/'a4_from_b16/runs/bright_a4/eval_step001500/inference_model.pth'
    out=ROOT/'board_a4_1500'
    if out.exists():raise RuntimeError('Output exists; preserve exported assets')
    if not torch.cuda.is_available():raise RuntimeError('CUDA required')
    cfg=json.loads((src.parent.parent/'config.json').read_text(encoding='utf-8'))
    n=A4().eval();n.load_state_dict(torch.load(src,map_location='cpu',weights_only=True))
    for m in n.modules():
        if hasattr(m,'norm') and isinstance(m.norm,torch.nn.BatchNorm2d):
            m.conv=torch.nn.utils.fusion.fuse_conv_bn_eval(m.conv,m.norm)
            m.norm=torch.nn.Identity()
    n=n.cuda();torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    evhash={v['sha256'] for v in cfg['eval_files']}
    paths=[p for p in files(cfg['train_dir']) if digest(p) not in evhash]
    random.Random(20261006).shuffle(paths);paths=paths[:a.calibration_count]
    if not paths:raise RuntimeError('Empty calibration set')
    obs=Observer()
    with torch.no_grad():
        for i,p in enumerate(paths):
            with Image.open(p) as im:x=TF.to_tensor(im.convert('RGB').resize((640,480),Image.Resampling.BICUBIC))[None].cuda()
            walk(n,x,obs.op,obs.add)
            if (i+1)%32==0:print('Calibrating',i+1,'/',len(paths),flush=True)
    scales={k:float(pow2scale(v)) for k,v in obs.maximum.items()};scales['input']=1/128
    shared=max(scales[k] for k in ['enc.3','res.c2','res.add'])
    for k in ['enc.3','res.c2','res.add']:scales[k]=shared
    names=['enc.0','enc.1','enc.2','enc.3','res.c1','res.c2','dec.1','dec.3','out.1']
    previous=['input','enc.0','enc.1','enc.2','enc.3','res.c1','res.add','dec.1','dec.3']
    coefficients=[];packed2=bytearray();packed4=bytearray();records=[];unsupported=[]
    for name,prev in zip(names,previous):
        m=n.get_submodule(name);c=m.conv if hasattr(m,'conv') else m
        ws=float(pow2scale(c.weight.detach().abs().max()))
        si,so=scales[prev],scales[name]
        factor=round(si*ws/so*2**24)
        if factor not in [65536,131072,262144]:unsupported.append({'layer':name,'A':factor})
        biasq=torch.round(c.bias.detach().cpu()/(si*ws)).to(torch.int64).tolist()
        co=math.ceil(c.out_channels/4)*4;ci=4 if name=='enc.0' else c.in_channels
        bs=[b*factor for b in biasq]+[0]*(co-c.out_channels)
        if not all(-2**31<=b<2**31 for b in bs):raise RuntimeError('Bias coefficient overflow: '+name)
        coefficients.extend(((b&0xffffffff)<<32)|((factor if j<c.out_channels else 0)&0xffffffff) for j,b in enumerate(bs))
        qw=torch.round(c.weight.detach()/ws).clamp(-127,127).cpu().numpy().astype(np.int8)
        arr=np.zeros((co,ci,3,3),dtype=np.int8);arr[:c.out_channels,:c.in_channels]=qw
        for pci,packed in [(2,packed2),(4,packed4)]:
            for og in range(0,co,4):
                for ig in range(0,ci,pci):
                    block=arr[og:og+4,ig:ig+pci].tobytes()
                    packed.extend(block);packed.extend(bytes((-len(block))%32))
        records.append({'layer':name,'A':factor,'weight_scale':ws,'input_scale':si,'output_scale':so})
    assert len(packed2)==2112 and len(packed4)==1760 and len(coefficients)==40
    out.mkdir()
    torch.save({k:v.cpu() for k,v in n.state_dict().items()},out/'a4_bn_folded_fp32.pth')
    for name,packed in [('a4_weights.mem',packed2),('a4_weights_pci4.mem',packed4)]:
        mem(out/name,[int.from_bytes(packed[i:i+32],'little') for i in range(0,len(packed),32)],64)
    mem(out/'a4_coeff.mem',coefficients+[0]*24,16)
    mem(out/'a4_tanh.mem',[round((math.tanh((i-128)*scales['out.1'])*.5+.5)*255) for i in range(256)],2)
    report={'source':str(src),'source_sha256':digest(src),'step':1500,'activation_scales':scales,
            'calibration_images':[{'path':str(p),'sha256':digest(p)} for p in paths],
            'layers':records,'unsupported_fixed_shift_coefficients':unsupported,
            'current_v64_coefficients_compatible':not unsupported,'quantization_quality_validation':'SKIPPED by user request',
            'efinity_compiled':False,'board_programmed':False}
    (out/'manifest.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('Export:',out,'Current v6_4 compatibility:',not unsupported,'Unsupported:',unsupported,flush=True)

if __name__=='__main__':main()
