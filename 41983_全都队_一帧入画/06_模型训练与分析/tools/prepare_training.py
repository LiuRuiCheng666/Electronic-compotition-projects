"""Prepare an isolated portable training copy; do not start training or copy datasets."""
from pathlib import Path
import argparse,ast,json,shutil
ROOT=Path(__file__).resolve().parents[1]
def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--data',type=Path,required=True,help='External dataset root with train/ and val/ JPEG folders')
 ap.add_argument('--output',type=Path,required=True,help='New work directory outside the submitted package')
 a=ap.parse_args();out=a.output.resolve();data=a.data.resolve()
 if out.exists() or out.is_relative_to(ROOT):raise SystemExit('Choose a new directory outside this package')
 if not (data/'train').is_dir() or not (data/'val').is_dir():raise SystemExit('Dataset needs train/ and val/')
 shutil.copytree(ROOT/'training',out)
 teacher=out/'architecture_experiments/glass_mosaic_rgb_v1/model_best.pth';teacher.parent.mkdir(parents=True)
 shutil.copy2(out/'teacher/glass.pth',teacher)
 remaps={'D:/FPGA_C/ABC_best_current_20261022':str(out/'board_reference'),
         'D:/FPGA_C/FOUR_STYLES_COLORFIX_20261023':str(out/'board_reference'),
         'D:/FPGA_C/V6_8_HDMI_FOUR_STYLES_20261023':str(out/'board_reference'),
         'dataset/train':(data/'train').as_posix(),'dataset/val':(data/'val').as_posix()}
 class Mapper(ast.NodeTransformer):
  def visit_Constant(self,n):
   if isinstance(n.value,str):
    value=n.value.replace('\\','/')
    for old,new in remaps.items():
     if value==old or value.startswith(old+'/'):
      return ast.copy_location(ast.Constant(new+value[len(old):]),n)
   return n
 changed=[]
 for p in out.glob('*.py'):
  original=ast.parse(p.read_text('utf-8-sig'));before=ast.dump(original)
  tree=Mapper().visit(original)
  if before!=ast.dump(tree):p.write_text(ast.unparse(ast.fix_missing_locations(tree))+'\n',encoding='utf-8');changed.append(p.name)
 launcher='''from pathlib import Path
import argparse,sys
ap=argparse.ArgumentParser();ap.add_argument('--style',choices=['blueprint','emboss'],required=True)
args,extra=ap.parse_known_args()
if args.style=='blueprint':
 import train_batch10_styles as m
 m.STYLES=['midnight_blueprint'];sys.argv=[sys.argv[0],'--domain','camera']+extra
else:
 import train_portable_candidates as m
 sys.argv=[sys.argv[0],'--style','glass']+extra
m.main()
'''
 (out/'train_local.py').write_text(launcher,encoding='utf-8')
 (out/'PATH_REMAP_REPORT.json').write_text(json.dumps({'data':str(data),'changed':changed,'training_started':False,'note':'Blueprint uses 200 train, 12 validation and 8 reserved images; submitted weights remain untouched. GPU/CUDA needed by original trainers.'},ensure_ascii=False,indent=2),encoding='utf-8')
 print('Prepared',out,'without starting training. Use python train_local.py --style blueprint or --style emboss.')
if __name__=='__main__':main()
