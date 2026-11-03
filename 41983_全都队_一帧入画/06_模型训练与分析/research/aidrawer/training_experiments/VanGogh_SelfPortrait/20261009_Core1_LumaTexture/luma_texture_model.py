"""Frozen color trunk plus a small phase-resolved luminance residual."""
import torch
from torch import nn
import torch.nn.functional as F
from compact_model import CompactStyleContextDetail
from student_model import conv

class LumaTextureStudent(nn.Module):
    def __init__(self,keep_blocks=(0,),detail_mode='phase_nearest',strength=1.,limit=.08):
        super().__init__()
        self.trunk=CompactStyleContextDetail(keep_blocks,detail_mode)
        self.trunk.requires_grad_(False)
        self.spatial=conv(8,8,3,groups=8)
        self.phase=conv(8,16)
        nn.init.zeros_(self.phase.weight);nn.init.zeros_(self.phase.bias)
        self.strength=strength;self.limit=limit

    def train(self,mode=True):
        super().train(mode);self.trunk.eval();return self

    def forward(self,x):
        features=[]
        hook=self.trunk.detail_spatial.register_forward_hook(lambda m,args,out:features.append(out.detach()))
        try:
            with torch.no_grad():base=self.trunk(x)
        finally:hook.remove()
        z=F.leaky_relu(features[0],negative_slope=.125)
        phases=self.phase(F.leaky_relu(self.spatial(z),negative_slope=.125)).float()
        # Bound first, then zero the 16 phase values in each 4x4 output cell.
        phases=phases.clamp(-self.limit,self.limit)
        phases=.5*(phases-phases.mean(1,keepdim=True))
        delta=F.pixel_shuffle(phases,4)*self.strength
        # A common RGB offset preserves R-G and G-B exactly. Limit the offset
        # jointly to the available RGB gamut; avoid per-channel clipping.
        lower=-base.amin(1,keepdim=True);upper=1-base.amax(1,keepdim=True)
        delta=torch.maximum(lower,torch.minimum(upper,delta))
        return base.float()+delta
