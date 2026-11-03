"""Evaluate final-slot software reference against supplied baseline images.

CPU reference timing is not FPGA latency. Baseline image filenames must match
inputs; reports state exactly which images and resolution were compared.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,math,time
import numpy as np
from PIL import Image
import torch
import torch.nn.functional as F
ROOT=Path(__file__).resolve().parents[1]
def metrics(a,b):
 x=torch.from_numpy(a.copy()).double().permute(2,0,1)[None]/255
 y=torch.from_numpy(b.copy()).double().permute(2,0,1)[None]/255
 mse=float((x-y).square().mean());psnr=None if mse==0 else -10*math.log10(mse)
 # Wang-style Gaussian 11x11 local SSIM, sigma1.5, RGB channel mean.
 t=torch.arange(11,dtype=torch.float64)-5;g=torch.exp(-t.square()/(2*1.5**2));g=g/g.sum()
 k=(g[:,None]*g[None,:]).expand(3,1,11,11)
 filt=lambda q:F.conv2d(F.pad(q,(5,5,5,5),mode='reflect'),k,groups=3)
 ux,uy=filt(x),filt(y);vx=filt(x*x)-ux*ux;vy=filt(y*y)-uy*uy;cov=filt(x*y)-ux*uy
 ssim=float((((2*ux*uy+.01**2)*(2*cov+.03**2))/((ux*ux+uy*uy+.01**2)*(vx+vy+.03**2))).mean())
 return {'psnr_db':psnr,'identical':mse==0,'ssim':ssim}
def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--input-dir',type=Path,required=True)
 ap.add_argument('--baseline-dir',type=Path,help='RGB reference outputs from a named standard model, same filenames')
 ap.add_argument('--baseline-name',default='user-supplied baseline')
 ap.add_argument('--slot',type=int,choices=range(5),required=True)
 ap.add_argument('--width',type=int,default=320);ap.add_argument('--height',type=int,default=240)
 ap.add_argument('--output',type=Path,required=True)
 a=ap.parse_args()
 if a.output.exists():raise SystemExit('Use a new output folder')
 if min(a.width,a.height)<24 or a.width%4 or a.height%4:raise SystemExit('Dimensions must be multiples of4, at least24')
 source=ROOT/'parameter_recipes/neon_board_core.py'
 spec=importlib.util.spec_from_file_location('slot_reference',source);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 slots=sorted((ROOT/'weights').glob('style*.bin'));slot=slots[a.slot].read_bytes()
 model=m.BoardA4(slot).double().cpu().eval();torch.set_num_threads(4)
 paths=sorted(p for p in a.input_dir.iterdir() if p.suffix.lower() in ['.png','.jpg','.jpeg','.bmp'])
 if not paths:raise SystemExit('No input images')
 a.output.mkdir(parents=True);rows=[]
 for path in paths:
  rgb=np.asarray(Image.open(path).convert('RGB').resize((a.width,a.height),Image.Resampling.BICUBIC)).copy()
  x=torch.from_numpy(rgb).double().permute(2,0,1)[None]/255
  with torch.inference_mode():
   start=time.perf_counter();y=model(x);milliseconds=(time.perf_counter()-start)*1000
  out=(y[0].permute(1,2,0).clamp(0,1)*255).round().byte().numpy()
  Image.fromarray(out).save(a.output/(path.stem+'.png'))
  row={'input':path.name,'input_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'software_reference_ms':milliseconds}
  if a.baseline_dir:
   reference=a.baseline_dir/path.name
   if not reference.exists():reference=a.baseline_dir/(path.stem+'.png')
   base=np.asarray(Image.open(reference).convert('RGB'))
   if base.shape!=out.shape:raise ValueError('Baseline must have exactly the evaluation resolution: '+str(reference))
   row.update(metrics(out,base));row['baseline_sha256']=hashlib.sha256(reference.read_bytes()).hexdigest()
  rows.append(row)
 report={'slot':a.slot,'slot_sha256':hashlib.sha256(slot).hexdigest(),'resolution':[a.width,a.height],
         'timing_scope':'PyTorch CPU reference, not FPGA inference latency','baseline_name':a.baseline_name if a.baseline_dir else None,
         'reference_scope':'Quantized A4 arithmetic with model-local LUT, no sensor ISP or HDMI display-tone simulation','images':rows}
 (a.output/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
 print('Wrote',a.output/'report.json')
if __name__=='__main__':main()
