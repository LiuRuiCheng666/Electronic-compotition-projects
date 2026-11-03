"""Tenth group: bronze/patina, jewel enamel and midnight blueprint graphics.
Procedural paired targets; no painting teacher, measured material or semantic CAD reconstruction.
"""
import torch
import torch.nn.functional as F
from train_hdmi_distinct_styles import blur,objective as structural_objective
STYLES=['bronze_patina','jewel_enamel','midnight_blueprint']
SOURCES=[]
def objective(y,t):
 return structural_objective(y,t)+.20*F.l1_loss(y.mean((2,3)),t.mean((2,3)))+.20*F.l1_loss(y[:,:2]-y[:,1:],t[:,:2]-t[:,1:])
def target(x,style):
 x=torch.floor((x*255).round()/2)*2/255
 sm=blur(x,3);y=(sm*x.new_tensor([.299,.587,.114])[None,:,None,None]).sum(1,keepdim=True)
 k=x.new_tensor([[-1,0,1],[-2,0,2],[-1,0,1]])[None,None]/4
 gx=F.conv2d(F.pad(y,(1,1,1,1),mode='reflect'),k);gy=F.conv2d(F.pad(y,(1,1,1,1),mode='reflect'),k.transpose(2,3))
 edge=((gx.abs()+gy.abs()-.018)/.13).clamp(0,1)
 def c(v):return x.new_tensor(v)[None,:,None,None]
 if style=='bronze_patina':
  mid=torch.sigmoid((y-.29)*19);light=torch.sigmoid((y-.66)*23)
  col=c([.035,.065,.055])*(1-mid)+c([.12,.49,.34])*mid
  col=col*(1-light)+c([.91,.62,.29])*light
  return (col*(1-.58*edge)+c([.84,.65,.29])*.30*edge).clamp(0,1)
 if style=='jewel_enamel':
  weights=torch.softmax((sm-sm.mean(1,keepdim=True))*10,dim=1)
  palette=x.new_tensor([[.94,.11,.34],[.035,.80,.58],[.31,.16,.95]])
  colour=torch.einsum('bchw,cd->bdhw',weights,palette)
  level=.20+.28*torch.sigmoid((y-.25)*22)+.28*torch.sigmoid((y-.54)*24)+.24*torch.sigmoid((y-.76)*26)
  colour=colour*(.20+.80*level)
  contour=edge*.88
  return (colour*(1-contour)+c([.97,.73,.27])*contour).clamp(0,1)
 if style=='midnight_blueprint':
  base=c([.018,.045,.16])+y*c([.025,.055,.16])
  line=edge.pow(.70)*.90
  return (base*(1-line)+c([.79,.94,1.])*line).clamp(0,1)
 raise ValueError(style)
