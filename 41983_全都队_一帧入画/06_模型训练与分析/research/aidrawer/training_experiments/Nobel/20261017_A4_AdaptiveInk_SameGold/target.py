"""Independent paired teacher; never consumes any old model output."""
import json
from pathlib import Path
import torch
import torch.nn.functional as F

def load_rules(path=None):
 r=json.loads(Path(path or Path(__file__).with_name('rules.json')).read_text(encoding='utf-8'))
 for name in ['paper_rgb','ink_rgb','gold_rgb','deep_gold_rgb']:
  assert len(r[name])==3 and all(0<=c<=255 for c in r[name])
 assert r['edge_threshold']>0 and r['local_shadow_range']>0
 assert 0<r['edge_low_floor']<=r['edge_low_ceiling']<r['edge_threshold']
 assert r['edge_contrast_gain']>=0 and r['edge_high_ratio']>1 and 0<r['edge_high_floor']<r['edge_threshold']
 assert isinstance(r['edge_link_steps'],int) and 0<=r['edge_link_steps']<=12
 assert r.get('ink_dilation_kernel',3) in (3,4,5,7)
 assert r.get('shadow_erosion_kernel',1) in (1,3,5)
 return r

def blur(x,k):return F.avg_pool2d(F.pad(x,(k//2,)*4,mode='reflect'),k,stride=1)

@torch.no_grad()
def nobel_render(x,r):
 x=x.float().clamp(0,1);l=(x[:,0:1]+2*x[:,1:2]+x[:,2:3])/4
 sm=blur(l,5);local=blur(sm,31)
 def gradient(z):
  k=x.new_tensor([[-1,0,1],[-2,0,2],[-1,0,1]]).view(1,1,3,3)
  pad=F.pad(z,(1,1,1,1),mode='reflect')
  return F.conv2d(pad,k),F.conv2d(pad,k.transpose(2,3))
 def nonmax(m,gx,gy):
  z=F.pad(m,(1,1,1,1),mode='replicate')
  left=z[:,:,1:-1,:-2];right=z[:,:,1:-1,2:];up=z[:,:,:-2,1:-1];down=z[:,:,2:,1:-1]
  return torch.where(gx.abs()>=gy.abs(),(m>=left)&(m>right),(m>=up)&(m>down))
 # Only the ink detector changes. sm/local below remain the old shadow inputs.
 fine=blur(l,3)
 gx,gy=gradient(fine);cx,cy=gradient(sm)
 mag=gx.abs()+gy.abs();coarse=cx.abs()+cy.abs()
 mean=blur(fine,15)
 contrast=(blur(fine.square(),15)-mean.square()).clamp_min(0).sqrt()
 low=(r['edge_low_floor']+r['edge_contrast_gain']*contrast).clamp(r['edge_low_floor'],r['edge_low_ceiling'])
 high=(low*r['edge_high_ratio']).clamp_min(r['edge_high_floor'])
 peak=nonmax(mag,gx,gy)
 direction_agrees=(gx*cx+gy*cy)>0
 # Coherent edges visible at both scales can seed a weak portrait contour;
 # isolated fine-scale sensor noise cannot. Strong old edges remain included.
 weak=peak&(mag>low)&(coarse>low*.45)&direction_agrees
 ink=peak&((mag>high)|((mag>low*1.35)&(coarse>low*.8)&direction_agrees))
 for _ in range(r['edge_link_steps']):
  near=F.max_pool2d(ink.float(),3,stride=1,padding=1)>0
  ink=ink|(near&weak)
 ink=ink|((coarse>r['edge_threshold'])&nonmax(coarse,cx,cy))
 width=r.get('ink_dilation_kernel',3)
 low=(width-1)//2;high=width//2
 ink=F.max_pool2d(F.pad(ink.float(),(low,high,low,high)),width,stride=1)>0
 shade=torch.maximum((local-sm-r['local_shadow_margin'])/r['local_shadow_range'],(.25-sm)/.16).clamp(0,1)
 shadow=(shade>r['shadow_threshold'])&(sm<.78)
 erosion=r.get('shadow_erosion_kernel',1)
 if erosion>1:
  # Retain the centres of shade patches; remove small gold flecks.
  shadow=F.max_pool2d(F.pad((~shadow).float(),(erosion//2,)*4,mode='replicate'),erosion,stride=1)==0
 def color(name):return x.new_tensor(r[name]).view(1,3,1,1)/255
 out=color('paper_rgb').expand_as(x).clone()
 out=torch.where(shadow.expand_as(x),color('gold_rgb'),out)
 out=torch.where((shadow&(shade>.8)).expand_as(x),color('deep_gold_rgb'),out)
 # Black wins at every contour, even when that contour borders a gold area.
 return torch.where(ink.expand_as(x),color('ink_rgb'),out)
