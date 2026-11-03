"""A4 direct dependency-consistent pruning from the selected portrait B16."""
import copy,json,math
from pathlib import Path
import torch
import torch.nn as nn
from support import Student,ConvNormAct,ResidualBlock,digest
ROOT=Path('D:/aidrawer/output/VanGogh_SelfPortrait/20261007_B16_BN_to_A4_Distillation/a4_from_b16')

class B16(Student):
    def __init__(self):super().__init__(True,'batch')

class A8(Student):
    def __init__(self):super().__init__(False,'batch')

class A4(A8):
    def __init__(self):
        super().__init__()
        self.enc[3]=ConvNormAct(8,4,stride=2,norm='batch')
        self.res=ResidualBlock(4,'batch')
        self.dec[1]=ConvNormAct(4,4,norm='batch')

class A8NoRes(A8):
    def __init__(self):
        super().__init__();self.res=nn.Identity()

def candidate(variant):return {'a4':A4,'a8_nores':A8NoRes}[variant]()

def folded_weight(m):return m.conv.weight.detach()*(m.norm.weight.detach()/torch.sqrt(m.norm.running_var+m.norm.eps))[:,None,None,None]
def normalized(x):return x/x.mean().clamp_min(1e-12)

def pick(n):
    a,b,c,d=[folded_weight(m) for m in [n.enc[3],n.res.c1,n.res.c2,n.dec[1]]]
    main=normalized(a.abs().mean((1,2,3)))+normalized(c.abs().mean((1,2,3)))+normalized(b.abs().mean((0,2,3)))+normalized(d.abs().mean((0,2,3)))
    hidden=normalized(b.abs().mean((1,2,3)))+normalized(c.abs().mean((0,2,3)))
    take=lambda s:sorted(sorted(range(n.enc[3].conv.out_channels),key=lambda i:(-s[i].item(),i))[:4])
    return take(main),take(hidden),main.tolist(),hidden.tolist()

def slice_state(n,main,hidden):
    out={}
    for k,v in n.state_dict().items():
        row,col=next(((r,c) for p,r,c in [('enc.3',main,None),('res.c1',hidden,main),('res.c2',main,hidden),('dec.1',None,main)] if k.startswith(p+'.')),(None,None))
        z=v.clone()
        if k.endswith('conv.weight'):
            if row is not None:z=z[row]
            if col is not None:z=z[:,col]
        elif z.ndim==1 and row is not None:z=z[row]
        out[k]=z.contiguous()
    return out

def cost(ch,nres):
    specs=[(3,4,1),(4,4,1),(4,8,2),(8,ch,4)]+[(ch,ch,4)]*(2*nres)+[(ch,4,2),(4,4,1),(4,3,1)]
    issued=sum(307200//z**2*math.ceil(a/2)*math.ceil(b/4)*72 for a,b,z in specs)
    return {'vga_logical_MAC':sum(307200//z**2*a*b*9 for a,b,z in specs),'vga_issued_MAC':issued,'MAC_only_ms_100MHz':issued/72/1e5,
        'kernel_weights':sum(a*b*9 for a,b,z in specs),'group_packed_weight_bytes':sum(math.ceil(a/2)*math.ceil(b/4)*96 for a,b,z in specs),
        'assumptions':'single pass, PCI2 PCO4, 100MHz, no traffic/postprocess; not board FPS'}

def main():
    if (ROOT/'pruning_report.json').exists() or any((ROOT/f'{v}_init.pth').exists() for v in ['a4']):raise RuntimeError('Initialization already exists')
    path=ROOT/'frozen_b16/model_final.pth';identity=json.loads((path.parent/'identity.json').read_text())
    if digest(path)!=identity['sha256']:raise RuntimeError('Frozen B16 changed')
    teacher=B16().eval();teacher.load_state_dict(torch.load(path,map_location='cpu',weights_only=True))
    mainidx,hiddenidx,main_scores,hidden_scores=pick(teacher)
    variants={}
    for variant in ['a4']:
        net=candidate(variant).eval();reference=copy.deepcopy(teacher);hooks=[]
        if variant=='a4':
            net.load_state_dict(slice_state(teacher,mainidx,hiddenidx),strict=True)
            for m,idx in [(reference.enc[3],mainidx),(reference.res.c1,hiddenidx),(reference.res.c2,mainidx)]:
                mask=torch.zeros(1,16,1,1);mask[:,idx]=1
                hooks.append(m.register_forward_hook(lambda module,args,y,mask=mask:y*mask))
            detail={'main_indices':mainidx,'hidden_indices':hiddenidx,'main_scores':main_scores,'hidden_scores':hidden_scores,
                'selection':'normalized BN-folded weight magnitude and consumers; heuristic, not optimum'}
        else:
            net.load_state_dict({k:v.clone() for k,v in teacher.state_dict().items() if not k.startswith('res.')},strict=True)
            reference.res=nn.Identity();detail={'change':'remove residual block only; all surviving weights copied exactly'}
        torch.manual_seed(20261006)
        with torch.no_grad():
            x=torch.rand(2,3,48,64);delta=(net(x)-reference(x)).abs().max().item()
        for h in hooks:h.remove()
        if delta>1e-4:raise RuntimeError('Migration mismatch: '+variant)
        p=ROOT/f'{variant}_init.pth';torch.save(net.state_dict(),p)
        variants[variant]={'source_sha256':identity['sha256'],'init_sha256':digest(p),'migration_max_abs':delta,
            'details':detail,'parameter_count':sum(v.numel() for v in net.parameters()),'status':'untrained initialization; quality not accepted'}
    report={'baseline_B16':{'parameter_count':sum(v.numel() for v in teacher.parameters())},'variants':variants,'preserved':'full-resolution/half-resolution layers, padding, upsampling, BN, RGB output; no combined a4+nores experiment'}
    (ROOT/'pruning_report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
