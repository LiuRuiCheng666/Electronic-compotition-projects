"""Independent float screening. Never writes Efinity or original teacher assets."""
import argparse
import hashlib
import json
import random
import sys
import time
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageDraw
from torch.utils.data import Dataset, DataLoader
from torchvision import transforms as T
from torchvision.transforms import functional as TF

sys.path.insert(0, 'D:/aidrawer/training_plus')
from model import FastNeuralStyleNet, ConvNormAct, ResidualBlock
from train import VggFeatures, tv_loss

ROOT = Path('D:/aidrawer/output/bright_aaa/20261007_Teacher_Palette_Texture_B16_to_A4_Distillation/distill_b16_a4')
STYLE = Path('D:/aidrawer/stylepicture/bright/aaa.jpg')
ORIGINAL = Path('D:/aidrawer/output/VanGogh_SelfPortrait/Legacy_Teacher_IN_runs3_ins/model_final.pth')
EXT = {'.jpg', '.jpeg', '.png', '.bmp', '.webp'}

def digest(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def files(p):
    return sorted(x for x in Path(p).rglob('*') if x.suffix.lower() in EXT)

def gram(x):
    # Accumulate Gram in float32, including when convolutions use AMP.
    b,c,h,w = x.shape
    x = x.float().reshape(b,c,h*w)
    with torch.autocast('cuda', enabled=False):
        return torch.bmm(x,x.transpose(1,2))/(c*h*w)

class Student(nn.Module):
    def __init__(self, wide, norm):
        super().__init__()
        bottleneck = 16 if wide else 8
        self.enc = nn.Sequential(ConvNormAct(3,4,norm=norm), ConvNormAct(4,4,norm=norm),
            ConvNormAct(4,8,stride=2,norm=norm), ConvNormAct(8,bottleneck,stride=2,norm=norm))
        self.res = ResidualBlock(bottleneck,norm)
        self.dec = nn.Sequential(nn.Upsample(scale_factor=2,mode='nearest'),
            ConvNormAct(bottleneck,4,norm=norm), nn.Upsample(scale_factor=2,mode='nearest'),
            ConvNormAct(4,4,norm=norm))
        self.out = nn.Sequential(nn.ReflectionPad2d(1),nn.Conv2d(4,3,3))
    def forward(self,x):
        return torch.tanh(self.out(self.dec(self.res(self.enc(x)))))*.5+.5

def model(stage):
    return FastNeuralStyleNet(8,3,'instance') if stage=='teacher' else Student(stage=='b_bn','instance' if stage=='a_in' else 'batch')

class Photos(Dataset):
    def __init__(self, paths, width, height):
        self.paths, self.width, self.height = paths,width,height
    def __len__(self): return len(self.paths)
    def __getitem__(self,i):
        with Image.open(self.paths[i]) as im: im=im.convert('RGB')
        y,x,h,w = T.RandomResizedCrop.get_params(im,scale=(.5,1),ratio=(1,1.7))
        im=TF.resized_crop(im,y,x,h,w,[self.height,self.width],antialias=True)
        if random.random()<.5: im=TF.hflip(im)
        return TF.to_tensor(im)

def save(path,obj):
    tmp=path.with_suffix('.tmp'); torch.save(obj,tmp); tmp.replace(path)
