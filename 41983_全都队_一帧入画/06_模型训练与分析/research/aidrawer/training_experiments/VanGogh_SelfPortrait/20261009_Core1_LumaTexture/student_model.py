"""Untrained deployment-oriented design prototype; not an FPGA-ready model."""
import math
import torch
from torch import nn
import torch.nn.functional as F


def conv(cin, cout, kernel=1, stride=1, groups=1, dilation=1):
    return nn.Conv2d(cin, cout, kernel, stride, padding=dilation*(kernel//2),
                     groups=groups, dilation=dilation, padding_mode='replicate')


class ContextBlock(nn.Module):
    def __init__(self, dilation):
        super().__init__()
        self.spatial = conv(40,40,3,groups=40,dilation=dilation)
        self.mix = conv(40,40)

    def forward(self,x,gain,shift):
        z=self.mix(F.leaky_relu(self.spatial(x),negative_slope=.125))
        return x+.5*(gain[:,:,None,None]*z+shift[:,:,None,None])


class StyleContextDetail(nn.Module):
    """Learn frame context once, then predict global color and spatial texture.

    There is no BN and no per-layer IN. Exactly one low-resolution per-image
    standardization requires retaining its feature map, not redoing convolutions.
    Each frame is processed independently, with no previous-frame statistics.
    """
    def __init__(self):
        super().__init__()
        self.stem=nn.Sequential(conv(3,8),nn.LeakyReLU(.125),conv(8,8,3,groups=8))
        self.e8_spatial=conv(8,8,3,stride=2,groups=8)
        self.e8_mix=conv(8,24)
        self.e16_spatial=conv(24,24,3,stride=2,groups=24)
        self.e16_mix=conv(24,40)
        self.condition=nn.Sequential(nn.Linear(80,96),nn.LeakyReLU(.125),nn.Linear(96,332))
        self.context=nn.ModuleList([ContextBlock(d) for d in [1,2,4,1]])
        self.context_reduce=conv(40,24)
        self.texture_spatial=conv(24,24,3,groups=24)
        self.texture_mix=conv(24,24)
        self.detail_reduce=conv(24,8)
        self.detail_spatial=conv(8,8,3,groups=8)
        self.detail_output=conv(8,48)
        self.local_color=conv(24,3)
        # Starting near the input is an optimization aid, not a frozen identity skip.
        nn.init.zeros_(self.condition[-1].weight)
        nn.init.zeros_(self.condition[-1].bias)
        # Equal phase kernels initially avoid an arbitrary 4x4 checkerboard.
        with torch.no_grad():
            phase_weight=self.detail_output.weight[:3].clone()
            phase_bias=self.detail_output.bias[:3].clone()
            self.detail_output.weight.copy_(phase_weight.repeat_interleave(16,dim=0))
            self.detail_output.bias.copy_(phase_bias.repeat_interleave(16))

    def forward(self,x):
        if x.ndim!=4 or x.shape[1]!=3 or x.shape[2]%16 or x.shape[3]%16:
            raise ValueError('RGB input dimensions must be multiples of 16')
        e4=F.leaky_relu(self.stem(F.avg_pool2d(x,4)),negative_slope=.125)
        e8=F.leaky_relu(self.e8_mix(self.e8_spatial(e4)),negative_slope=.125)
        e16=F.leaky_relu(self.e16_mix(self.e16_spatial(e8)),negative_slope=.125)
        # Accumulate in FP32 even under BF16/INT8-oriented training.
        z=e16.float();mean=z.mean((2,3));variance=(z.square().mean((2,3))-mean.square()).clamp_min(0)
        inv_std=torch.rsqrt(variance+1e-4)
        context=(z-mean[:,:,None,None])*inv_std[:,:,None,None]
        controls=self.condition(torch.cat([mean,torch.sqrt(variance+1e-4)],dim=1))
        film=controls[:,:320].reshape(-1,4,2,40)
        for i,block in enumerate(self.context):
            gain=(1+film[:,i,0]).clamp(.5,1.5)
            shift=film[:,i,1].clamp(-.25,.25)
            context=block(context,gain,shift)
        context8=F.interpolate(self.context_reduce(context),size=e8.shape[-2:],mode='bilinear',align_corners=False)
        texture=e8+context8
        texture=texture+.5*self.texture_mix(F.leaky_relu(self.texture_spatial(texture),negative_slope=.125))
        detail=e4+F.interpolate(self.detail_reduce(texture),size=e4.shape[-2:],mode='bilinear',align_corners=False)
        detail=self.detail_output(F.leaky_relu(self.detail_spatial(detail),negative_slope=.125))
        fine_rgb=F.pixel_shuffle(detail,4)
        local=F.interpolate(self.local_color(texture),size=x.shape[-2:],mode='bilinear',align_corners=False)
        color=controls[:,320:]
        matrix=color[:,:9].reshape(-1,3,3).clamp(-2,2)+torch.eye(3,device=x.device,dtype=color.dtype)[None]
        bias=color[:,9:].clamp(-1,1)
        base=torch.einsum('bij,bjhw->bihw',matrix,x)+bias[:,:,None,None]
        return (base+local+fine_rgb).clamp(0,1)


def budget(width=1280,height=720):
    """Dense and grouped convolution MACs from real output shapes, no lane padding.

    The hardware scheduler must support a 64-lane pointwise mode and a 72-lane
    spatial mode. These are NOT the existing PCI2/PCO4-only convolution FSM.
    """
    if width%16 or height%16:raise ValueError('shape')
    net=StyleContextDetail().eval();ledger=[];hooks=[]
    def record(name):
        def hook(m,args,out):
            if isinstance(m,nn.Conv2d):
                mac=out.numel()*(m.in_channels//m.groups)*m.kernel_size[0]*m.kernel_size[1]
                pixels=out.shape[-1]*out.shape[-2]
                if m.groups==m.in_channels:
                    cycles=pixels*math.ceil(m.out_channels/8)
                    mode='DW3x3: 8 channels x 9 taps'
                elif m.kernel_size==(1,1):
                    cycles=pixels*math.ceil(m.in_channels/8)*math.ceil(m.out_channels/8)
                    mode='PW1x1: 8 input x 8 output'
                else:
                    cycles=pixels*math.ceil(m.in_channels/2)*math.ceil(m.out_channels/4)
                    mode='Conv3x3: 2 input x 4 output x 9 taps'
            else:
                mac=out.numel()*m.in_features;cycles=math.ceil(mac/64);mode='linear64'
            ledger.append({'layer':name,'shape':list(out.shape),'logical_mac':mac,'issue_cycles':cycles,'mode':mode})
        return hook
    for name,m in net.named_modules():
        if isinstance(m,(nn.Conv2d,nn.Linear)):hooks.append(m.register_forward_hook(record(name)))
    with torch.no_grad():net(torch.zeros(1,3,height,width))
    for h in hooks:h.remove()
    p=width*height
    # Bilinear interpolation counted conservatively as four multiplies/output.
    interpolation_mac=4*(24*p//64+8*p//16+3*p)
    affine_mac=9*p+4*40*p//256+40*p//256
    statistics_mac=40*p//256
    auxiliary_mac=interpolation_mac+affine_mac+statistics_mac
    auxiliary_cycles=math.ceil(auxiliary_mac/64)
    cycles=sum(r['issue_cycles'] for r in ledger)+auxiliary_cycles
    return {'resolution':[width,height],'parameters':sum(v.numel() for v in net.parameters()),
            'int8_parameter_payload_bytes':sum(v.numel() for v in net.parameters()),
            'logical_convolution_and_linear_mac':sum(r['logical_mac'] for r in ledger),
            'auxiliary_multiplies':auxiliary_mac,'issue_cycles':cycles,
            'ideal_compute_ms_100MHz':cycles/100000,
            'compute_ms_65_percent_utilization':cycles/100000/.65,
            'extra_memory_control_allowance_ms':4,'estimated_frame_ms_at_65_percent':cycles/100000/.65+4,
            'lowres_stats_feature_bytes_int8':40*p//256,
            'fullres_rgb_read_plus_write_bytes':6*p,
            'minimum_rgb_two_reads_one_write_bytes':9*p,
            'rgbx_two_reads_one_write_bytes':12*p,
            'ledger':ledger,'status':'Analytical target only; no synthesis, scheduler, DDR, quantization or quality proof'}
