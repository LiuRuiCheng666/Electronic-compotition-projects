import sys,math
from pathlib import Path
import torch
from torch import nn
sys.path.insert(0,'D:/aidrawer/training_plus')
from model import ConvNormAct,ResidualBlock,FastNeuralStyleNet
ROOT=Path('D:\\aidrawer\\output\\VanGogh_SelfPortrait\\20261009_A4_BN_Teacher_Palette8_MinArea5')
class Student(nn.Module):
    def __init__(self,variant='a4'):
        super().__init__()
        self.enc=nn.Sequential(ConvNormAct(3,4,norm='batch'),ConvNormAct(4,4,norm='batch'),ConvNormAct(4,8,stride=2,norm='batch'),ConvNormAct(8,4,stride=2,norm='batch'))
        self.res=ResidualBlock(4,'batch')
        self.dec=nn.Sequential(nn.Upsample(scale_factor=2,mode='nearest'),ConvNormAct(4,4,norm='batch'),nn.Upsample(scale_factor=2,mode='nearest'),ConvNormAct(4,4,norm='batch'))
        self.out=nn.Sequential(nn.ReflectionPad2d(1),nn.Conv2d(4,3,3))
    def forward(self,x):return torch.tanh(self.out(self.dec(self.res(self.enc(x)))))*.5+.5
def cost(variant,width,height):
    specs=[(3,4,1),(4,4,1),(4,8,2),(8,4,4),(4,4,4),(4,4,4),(4,4,2),(4,4,1),(4,3,1)]
    cycles=sum(width*height//d**2*math.ceil(a/4)*math.ceil(b/4) for a,b,d in specs)
    return {'conv_weights':1584,'parameters':1629,'mac_cycles':cycles,'mac_ms_at_100MHz':cycles/1e5,'limitations':'MAC only, not board FPS; unchanged legacy A4 architecture'}
