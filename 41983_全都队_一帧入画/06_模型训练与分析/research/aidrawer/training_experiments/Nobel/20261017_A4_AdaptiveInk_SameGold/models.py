"""Legacy deployment A4: same module names, shapes and arithmetic topology."""
import torch
from torch import nn


class ConvNormAct(nn.Module):
    def __init__(self, cin, cout, stride=1, act=True):
        super().__init__()
        self.pad = nn.ReflectionPad2d(1)
        self.conv = nn.Conv2d(cin, cout, 3, stride=stride, bias=True)
        self.norm = nn.BatchNorm2d(cout)
        self.act = nn.ReLU(inplace=True) if act else nn.Identity()

    def forward(self, x):
        return self.act(self.norm(self.conv(self.pad(x))))


class ResidualBlock(nn.Module):
    def __init__(self):
        super().__init__()
        self.c1 = ConvNormAct(4, 4)
        self.c2 = ConvNormAct(4, 4, act=False)

    def forward(self, x):
        return x + self.c2(self.c1(x))


class Student(nn.Module):
    def __init__(self):
        super().__init__()
        self.enc = nn.Sequential(ConvNormAct(3, 4), ConvNormAct(4, 4),
                                 ConvNormAct(4, 8, 2), ConvNormAct(8, 4, 2))
        self.res = ResidualBlock()
        self.dec = nn.Sequential(nn.Upsample(scale_factor=2, mode='nearest'),
                                 ConvNormAct(4, 4),
                                 nn.Upsample(scale_factor=2, mode='nearest'),
                                 ConvNormAct(4, 4))
        self.out = nn.Sequential(nn.ReflectionPad2d(1), nn.Conv2d(4, 3, 3))

    def forward(self, x):
        return torch.tanh(self.out(self.dec(self.res(self.enc(x))))) * .5 + .5
