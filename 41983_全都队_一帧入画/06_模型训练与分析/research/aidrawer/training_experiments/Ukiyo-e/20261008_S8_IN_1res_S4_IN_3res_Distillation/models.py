import sys,math
from pathlib import Path
import torch
from torch import nn
sys.path.insert(0,'D:/aidrawer/training_plus')
from model import ConvNormAct,ResidualBlock,FastNeuralStyleNet

ROOT=Path('D:/aidrawer/output/Ukiyo-e/20261008_S8_IN_1res_S4_IN_3res_Distillation')
SPECS={'s8':(8,1),'s4':(4,3)}

class Student(nn.Module):
    def __init__(self,variant):
        super().__init__();channels,blocks=SPECS[variant]
        self.enc=nn.Sequential(ConvNormAct(3,4,stride=2,norm='instance'),
                               ConvNormAct(4,channels,stride=2,norm='instance'))
        self.res=nn.Sequential(*[ResidualBlock(channels,'instance') for _ in range(blocks)])
        self.dec=nn.Sequential(nn.Upsample(scale_factor=2,mode='nearest'),
                               ConvNormAct(channels,4,norm='instance'),
                               nn.Upsample(scale_factor=2,mode='nearest'))
        self.out=nn.Sequential(nn.ReflectionPad2d(1),nn.Conv2d(4,3,3))
    def forward(self,x):return torch.tanh(self.out(self.dec(self.res(self.enc(x)))))*.5+.5

def cost(variant,width=1280,height=720):
    ch,blocks=SPECS[variant]
    specs=[(3,4,2),(4,ch,4)]+[(ch,ch,4)]*(2*blocks)+[(ch,4,2),(4,3,1)]
    cycles=sum(width*height//div**2*math.ceil(ci/4)*math.ceil(co/4) for ci,co,div in specs)
    return {'conv_weights':sum(ci*co*9 for ci,co,_ in specs),'parameters':sum(p.numel() for p in Student(variant).parameters()),
            'mac_cycles':cycles,'mac_ms_at_100MHz':cycles/1e5,
            'limitations':'MAC only; excludes IN statistics/second pass, memory, control, quantization. No board FPS guarantee.'}
