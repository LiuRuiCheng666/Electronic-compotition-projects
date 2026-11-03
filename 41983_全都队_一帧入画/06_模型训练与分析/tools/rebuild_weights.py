"""Regenerate the three analytic recipes and export two learned checkpoints.

Always keep the final submitted order: retro, blueprint, emboss, pixel, glitch.
No training, FPGA compilation, Flash write or board access occurs here.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,struct,sys,tempfile,zlib
ROOT=Path(__file__).resolve().parents[1]
PROJECT=ROOT.parent
NAMES=['retro','blueprint','emboss','fine_pixel_first','glitch']
def digest(b):return hashlib.sha256(b).hexdigest()
def analytic():
 path=ROOT/'parameter_recipes/nn5_regenerator_original.py'
 spec=importlib.util.spec_from_file_location('nn5_analytic',path)
 mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
 mod.TOOLS=ROOT/'parameter_recipes';mod.ROOT=ROOT
 # The original regenerator reads this exact numeric reference by relative name.
 # Pass a proxy root for the single reference-data read, keeping source untouched.
 class RefRoot:
  def __truediv__(self,part):
   if str(part)=='provenance/retro_REFERENCE_STATS.json':return ROOT/'parameter_recipes/retro_REFERENCE_STATS.json'
   return ROOT/part
 mod.ROOT=RefRoot()
 values=mod.regenerate()
 return {0:values[0],3:values[1],4:values[4]}
def learned():
 import torch
 from torch import nn
 sys.path.insert(0,str(ROOT/'training'))
 from train_students import Student,export
 result={}
 for index,style in [(1,'blueprint'),(2,'emboss')]:
  cp=torch.load(ROOT/f'runs/{style}/model_best.pth',map_location='cpu',weights_only=True)
  net=Student();net.norms=nn.ModuleList([nn.Identity() for _ in range(9)])
  net.qat=True;net.load_state_dict(cp['state_dict'],strict=True);net.eval()
  with tempfile.TemporaryDirectory(prefix='yizhen_export_') as td:
   export(net,Path(td));result[index]=(Path(td)/'slot.bin').read_bytes()
 return result
def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--output',type=Path,required=True)
 ap.add_argument('--regenerate',action='store_true',help='Regenerate retro/pixel/glitch from parameter source; needs NumPy')
 ap.add_argument('--export-trained',action='store_true',help='Export exact blueprint/emboss learned checkpoints; needs PyTorch and NumPy')
 args=ap.parse_args()
 if args.output.exists():raise SystemExit('Output must be a new directory')
 rebuilt={}
 if args.regenerate:rebuilt.update(analytic())
 if args.export_trained:rebuilt.update(learned())
 active=(PROJECT/'01_FPGA/flash_assets/a4_dual_models_flash.bin').read_bytes()
 assert len(active)==20512 and active[:4]==b'NNW1'
 slots=[];report=[]
 for i,name in enumerate(NAMES):
  stored=(ROOT/f'weights/style{i}_{name}.bin').read_bytes()
  b=rebuilt.get(i,stored)
  assert b==stored==active[32+i*4096:32+(i+1)*4096],name+' differs from final FPGA weights'
  slots.append(b)
  method='parameter_source_regenerated' if i in rebuilt and i in [0,3,4] else 'learned_checkpoint_exported' if i in rebuilt else 'archived_slot_copied'
  report.append({'slot':i,'name':name,'bytes':len(b),'sha256':digest(b),'method':method})
 payload=b''.join(slots);header=bytearray(active[:32]);struct.pack_into('<II',header,8,len(payload),zlib.crc32(payload));blob=bytes(header)+payload
 assert blob==active
 args.output.mkdir(parents=True)
 for i,b in enumerate(slots):(args.output/f'style{i}_{NAMES[i]}.bin').write_bytes(b)
 (args.output/'a4_dual_models_payload.bin').write_bytes(payload)
 (args.output/'a4_dual_models_flash.bin').write_bytes(blob)
 result={'status':'PASS','current_submission_order':True,'styles':report,'payload_sha256':digest(payload),'weights_sha256':digest(blob),'bytes':len(blob),'training_performed':False,'board_accessed':False}
 (args.output/'rebuild_report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
 print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
