"""Structural color-focused compression; new modes require matching new RTL."""
import math
import torch
from torch import nn
import torch.nn.functional as F
from student_model import StyleContextDetail,conv


class CompactStyleContextDetail(StyleContextDetail):
    def __init__(self,keep_blocks=(0,1,2,3),detail_mode='phase_nearest'):
        if not keep_blocks or sorted(set(keep_blocks))!=list(keep_blocks) or max(keep_blocks)>3:
            raise ValueError('Invalid retained context blocks')
        if detail_mode not in ['phase_nearest','phase_bilinear','none']:raise ValueError(detail_mode)
        super().__init__()
        self.keep_blocks=tuple(keep_blocks);self.detail_mode=detail_mode
        self.context=nn.ModuleList([self.context[i] for i in keep_blocks])
        self.condition[-1]=nn.Linear(96,len(keep_blocks)*80+12)
        if detail_mode=='none':
            del self.detail_reduce,self.detail_spatial,self.detail_output
        else:self.detail_output=conv(8,3)

    def forward(self,x):
        if x.ndim!=4 or x.shape[1]!=3 or x.shape[2]%16 or x.shape[3]%16:raise ValueError('RGB multiples of16 required')
        e4=F.leaky_relu(self.stem(F.avg_pool2d(x,4)),negative_slope=.125)
        e8=F.leaky_relu(self.e8_mix(self.e8_spatial(e4)),negative_slope=.125)
        e16=F.leaky_relu(self.e16_mix(self.e16_spatial(e8)),negative_slope=.125)
        z=e16.float();mean=z.mean((2,3));variance=(z.square().mean((2,3))-mean.square()).clamp_min(0)
        context=(z-mean[:,:,None,None])*torch.rsqrt(variance[:,:,None,None]+1e-4)
        controls=self.condition(torch.cat([mean,torch.sqrt(variance+1e-4)],dim=1))
        n=len(self.context);film=controls[:,:80*n].reshape(-1,n,2,40)
        for i,block in enumerate(self.context):
            context=block(context,(1+film[:,i,0]).clamp(.5,1.5),film[:,i,1].clamp(-.25,.25))
        texture=e8+F.interpolate(self.context_reduce(context),size=e8.shape[-2:],mode='bilinear',align_corners=False)
        texture=texture+.5*self.texture_mix(F.leaky_relu(self.texture_spatial(texture),negative_slope=.125))
        local=F.interpolate(self.local_color(texture),size=x.shape[-2:],mode='bilinear',align_corners=False)
        color=controls[:,80*n:]
        matrix=color[:,:9].reshape(-1,3,3).clamp(-2,2)+torch.eye(3,device=x.device,dtype=color.dtype)[None]
        base=torch.einsum('bij,bjhw->bihw',matrix,x)+color[:,9:].clamp(-1,1)[:,:,None,None]
        if self.detail_mode=='none':return (base+local).clamp(0,1)
        detail=e4+F.interpolate(self.detail_reduce(texture),size=e4.shape[-2:],mode='bilinear',align_corners=False)
        rgb=self.detail_output(F.leaky_relu(self.detail_spatial(detail),negative_slope=.125))
        if self.detail_mode=='phase_nearest':fine=F.interpolate(rgb,size=x.shape[-2:],mode='nearest')
        else:fine=F.interpolate(rgb,size=x.shape[-2:],mode='bilinear',align_corners=False)
        return (base+local+fine).clamp(0,1)


def migrate(reference,keep_blocks,detail_mode):
    net=CompactStyleContextDetail(keep_blocks,detail_mode)
    original=reference.state_dict();state={}
    rows=[j for i in keep_blocks for j in range(i*80,(i+1)*80)]+list(range(320,332))
    for name in net.state_dict():
        old_name=name
        if name.startswith('context.'):
            pieces=name.split('.');pieces[1]=str(keep_blocks[int(pieces[1])]);old_name='.'.join(pieces)
        value=original[old_name].detach().cpu().clone()
        if name in ['condition.2.weight','condition.2.bias']:value=value[rows]
        if name=='detail_output.weight':value=value.reshape(3,16,8,1,1).mean(1)
        if name=='detail_output.bias':value=value.reshape(3,16).mean(1)
        state[name]=value
    net.load_state_dict(state,strict=True)
    return net


def verify_migration(reference,compact,x):
    """Compare to an explicitly masked/phase-averaged original network."""
    import copy
    manual=copy.deepcopy(reference).eval();hooks=[]
    for i,block in enumerate(manual.context):
        if i not in compact.keep_blocks:
            hooks.append(block.register_forward_hook(lambda m,args,out:args[0]))
    def replace_head(module,args,out):
        if compact.detail_mode=='none':return torch.zeros_like(out)
        b,c,h,w=out.shape;rgb=out.reshape(b,3,16,h,w).mean(2)
        if compact.detail_mode=='phase_nearest':return rgb.repeat_interleave(16,dim=1)
        up=F.interpolate(rgb,scale_factor=4,mode='bilinear',align_corners=False)
        return F.pixel_unshuffle(up,4)
    hooks.append(manual.detail_output.register_forward_hook(replace_head))
    with torch.no_grad():delta=(manual(x)-compact(x)).abs().max().item()
    for h in hooks:h.remove()
    if delta>2e-5:raise RuntimeError('Migration mismatch: '+str(delta))
    return delta


def compact_budget(net,width=1280,height=720):
    ledger=[];hooks=[]
    def record(name):
        def hook(m,args,out):
            if isinstance(m,nn.Conv2d):
                mac=out.numel()*(m.in_channels//m.groups)*m.kernel_size[0]*m.kernel_size[1]
                px=out.shape[-1]*out.shape[-2]
                if m.groups==m.in_channels:cycles=px*math.ceil(m.out_channels/8)
                elif m.kernel_size==(1,1):cycles=px*math.ceil(m.in_channels/8)*math.ceil(m.out_channels/8)
                else:cycles=px*math.ceil(m.in_channels/2)*math.ceil(m.out_channels/4)
            else:mac=out.numel()*m.in_features;cycles=math.ceil(mac/64)
            ledger.append({'layer':name,'logical_mac':mac,'issue_cycles':cycles,'shape':list(out.shape)})
        return hook
    for name,m in net.named_modules():
        if isinstance(m,(nn.Conv2d,nn.Linear)):hooks.append(m.register_forward_hook(record(name)))
    net.eval()
    with torch.no_grad():net(torch.zeros(1,3,height,width,device=next(net.parameters()).device))
    for h in hooks:h.remove()
    p=width*height;n=len(net.context)
    interpolation=4*(24*p//64+3*p)
    if net.detail_mode!='none':interpolation+=4*8*p//16
    if net.detail_mode=='phase_bilinear':interpolation+=4*3*p
    aux=interpolation+9*p+(n+2)*40*p//256
    cycles=sum(r['issue_cycles'] for r in ledger)+math.ceil(aux/64)
    return {'resolution':[width,height],'keep_blocks':list(net.keep_blocks),'detail_mode':net.detail_mode,
            'parameters':sum(p.numel() for p in net.parameters()),'logical_conv_linear_mac':sum(r['logical_mac'] for r in ledger),
            'auxiliary_multiplies':aux,'issue_cycles':cycles,'ideal_compute_ms_100MHz':cycles/1e5,
            'ledger':ledger,'status':'analytical new-DW/PW-engine budget, not current RTL or measured board FPS'}
