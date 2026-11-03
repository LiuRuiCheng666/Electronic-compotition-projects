"""Dependency-consistent B12 -> A8 channel slicing and initialization."""
import copy,json,math
from pathlib import Path
import torch
import torch.nn as nn
from support import Student,ConvNormAct,ResidualBlock,digest

ROOT=Path('D:/aidrawer/output/Ukiyo-e/20261006_A8_BN_Structured_Pruning_Distillation')

class B12(Student):
    def __init__(self):
        super().__init__(True,'batch')
        self.enc[3]=ConvNormAct(8,12,stride=2,norm='batch')
        self.res=ResidualBlock(12,'batch')
        self.dec[1]=ConvNormAct(12,4,norm='batch')

class A8(Student):
    def __init__(self):
        super().__init__(False,'batch')

def folded_weight(m):
    return m.conv.weight.detach()* (m.norm.weight.detach()/torch.sqrt(m.norm.running_var+m.norm.eps))[:,None,None,None]

def normalized(v):return v/v.mean().clamp_min(1e-12)

def choose(net):
    a,b,c,d=[folded_weight(m) for m in [net.enc[3],net.res.c1,net.res.c2,net.dec[1]]]
    # Main gate is shared by encoded features, residual output and decoder input.
    main=normalized(a.abs().mean((1,2,3)))+normalized(c.abs().mean((1,2,3)))+normalized(b.abs().mean((0,2,3)))+normalized(d.abs().mean((0,2,3)))
    inner=normalized(b.abs().mean((1,2,3)))+normalized(c.abs().mean((0,2,3)))
    # Deterministic tie breaking by original channel number; retain original order.
    take=lambda s:sorted(sorted(range(12),key=lambda i:(-s[i].item(),i))[:8])
    return take(main),take(inner),main.tolist(),inner.tolist()

def sliced_state(net,main,inner):
    old=net.state_dict();result={}
    for k,v in old.items():
        groups=[('enc.3',main,None),('res.c1',inner,main),('res.c2',main,inner),('dec.1',None,main)]
        row,col=next(((r,c) for prefix,r,c in groups if k.startswith(prefix+'.')),(None,None))
        z=v.clone()
        if k.endswith('conv.weight'):
            if row is not None:z=z[row]
            if col is not None:z=z[:,col]
        elif z.ndim==1 and row is not None:z=z[row]
        result[k]=z.contiguous()
    return result

def cost(ch):
    specs=[(3,4,1),(4,4,1),(4,8,2),(8,ch,4),(ch,ch,4),(ch,ch,4),(ch,4,2),(4,4,1),(4,3,1)]
    issued=sum(307200//(z*z)*math.ceil(a/2)*math.ceil(b/4)*72 for a,b,z in specs)
    return {'logical_mac':sum(307200//(z*z)*a*b*9 for a,b,z in specs),'issued_mac':issued,
        'mac_only_ms_100MHz':issued/72/1e5,'kernel_weights':sum(a*b*9 for a,b,z in specs),
        'group_packed_kernel_bytes':sum(math.ceil(a/2)*math.ceil(b/4)*96 for a,b,z in specs),
        'assumptions':'single pass with folded BN, PCI2 PCO4; excludes traffic/postprocess; not measured FPS'}

def main():
    if (ROOT/'a8_init.pth').exists() or (ROOT/'pruning_report.json').exists():raise RuntimeError('Initialization exists; do not overwrite')
    path=ROOT/'frozen_b12/model_final.pth';identity=json.loads((path.parent/'identity.json').read_text())
    if digest(path)!=identity['sha256']:raise RuntimeError('Frozen B12 changed')
    net=B12().eval();net.load_state_dict(torch.load(path,map_location='cpu',weights_only=True))
    mainidx,inneridx,main_scores,inner_scores=choose(net)
    small=A8().eval();small.load_state_dict(sliced_state(net,mainidx,inneridx),strict=True)
    # Pruned graph must match full B16 with removed intermediate channels masked.
    masked=copy.deepcopy(net);hooks=[]
    for m,idx in [(masked.enc[3],mainidx),(masked.res.c1,inneridx),(masked.res.c2,mainidx)]:
        mask=torch.zeros(1,12,1,1);mask[:,idx]=1
        hooks.append(m.register_forward_hook(lambda module,args,y,mask=mask:y*mask))
    torch.manual_seed(20261006)
    with torch.no_grad():
        x=torch.rand(2,3,48,64);err=(masked(x)-small(x)).abs().max().item()
    for h in hooks:h.remove()
    if err>1e-4:raise RuntimeError('Channel dependency/migration check failed')
    torch.save(small.state_dict(),ROOT/'a8_init.pth')
    report={'source_sha256':identity['sha256'],'main_indices':mainidx,'residual_hidden_indices':inneridx,
        'main_scores':main_scores,'hidden_scores':inner_scores,
        'selection':'normalized BN-folded weight mean-absolute row/column scores; heuristic, not measured saliency optimum',
        'dependency_rule':'main indices shared by enc3 outputs, res1 inputs, res2 outputs, residual skip and decoder inputs; hidden indices shared by res1 outputs and res2 inputs',
        'migrated':'convolution weights/biases, BN affine and running statistics; no random initialization of retained weights',
        'masked_B12_vs_A8_max_abs':err,'init_sha256':digest(ROOT/'a8_init.pth'),
        'B12_vga_cost':cost(12),'A8_vga_cost':cost(8),'quality_status':'untrained pruned initialization; no quality or int8 acceptance yet'}
    (ROOT/'pruning_report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
