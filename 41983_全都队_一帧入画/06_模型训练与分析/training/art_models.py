"""RGB style network using the BSD PyTorch example TransformerNet."""
import torch
from torch import nn
from teacher.transformer_net import TransformerNet
class ArtTransformer(nn.Module):
 def __init__(self):super().__init__();self.core=TransformerNet()
 def forward(self,x):return (self.core(x*255)/255).clamp(0,1)
