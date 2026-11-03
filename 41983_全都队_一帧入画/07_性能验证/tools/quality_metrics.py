"""RGB PSNR and valid-interior Gaussian SSIM used by the recorded benchmark."""
from pathlib import Path
import argparse,json,hashlib,math,struct,zlib
import numpy as np
from PIL import Image

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def valid_blur(a):
 x=np.arange(-5,6,dtype=np.float64);k=np.exp(-(x*x)/(2*1.5*1.5));k/=k.sum()
 v=np.lib.stride_tricks.sliding_window_view(a,11,axis=0)
 v=np.einsum('hwck,k->hwc',v,k,optimize=True)
 v=np.lib.stride_tricks.sliding_window_view(v,11,axis=1)
 return np.einsum('hwck,k->hwc',v,k,optimize=True)
def metrics(a,b):
 a=np.asarray(a,dtype=np.float64)/255.;b=np.asarray(b,dtype=np.float64)/255.
 if a.shape!=b.shape or a.ndim!=3 or a.shape[2]!=3 or min(a.shape[:2])<11:raise ValueError('Equal RGB dimensions >=11 required; no implicit resize/crop')
 if not np.isfinite(a).all() or not np.isfinite(b).all() or a.min()<0 or b.min()<0 or a.max()>1 or b.max()>1:raise ValueError('Expected finite RGB values0..255')
 mse=float(np.mean((a-b)**2));psnr=None if mse==0 else -10*math.log10(mse)
 ma=valid_blur(a);mb=valid_blur(b)
 va=np.maximum(valid_blur(a*a)-ma*ma,0);vb=np.maximum(valid_blur(b*b)-mb*mb,0);cov=valid_blur(a*b)-ma*mb
 score=((2*ma*mb+0.01**2)*(2*cov+0.03**2))/((ma*ma+mb*mb+0.01**2)*(va+vb+0.03**2))
 return {'mse_normalized':mse,'psnr_db':psnr,'psnr_identical':mse==0,'ssim_rgb_mean':float(score.mean()),'ssim_per_channel':score.mean(axis=(0,1)).tolist()}
