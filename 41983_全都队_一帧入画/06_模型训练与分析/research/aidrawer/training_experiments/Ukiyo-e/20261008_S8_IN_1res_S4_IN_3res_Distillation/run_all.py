"""Sequential S8 then S4 screening, using the active Python environment."""
import argparse,json,subprocess,sys,hashlib
from pathlib import Path
from PIL import Image,ImageDraw
ROOT=Path('D:/aidrawer/output/Ukiyo-e/20261008_S8_IN_1res_S4_IN_3res_Distillation')
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def compare():
    snapshots=[]
    for variant in ['s8','s4']:
        d=json.loads((ROOT/'runs'/variant/'latest_evaluation.json').read_text());snapshots.append(Path(d['path']))
    out=ROOT/'comparisons_final';out.mkdir(exist_ok=True)
    for student in sorted(snapshots[0].glob('in_*.png')):
        suffix=student.name[len('in_'):]
        paths=[snapshots[0]/('input_'+suffix),snapshots[0]/('approved_'+suffix),student,snapshots[1]/('in_'+suffix)]
        sheet=Image.new('RGB',(1536,242),'white');draw=ImageDraw.Draw(sheet)
        for i,(label,path) in enumerate(zip(['Input','Approved IN teacher','S8 - 1 residual','S4 - 3 residual'],paths)):
            with Image.open(path) as im:sheet.paste(im.resize((384,216)),(384*i,26))
            draw.text((384*i+5,5),label,fill='black')
        sheet.save(out/suffix.replace('.png','.jpg'),quality=95)
    (out/'sources.json').write_text(json.dumps([str(p) for p in snapshots],indent=2),encoding='utf-8')
    print('Unified comparison panels:',out,flush=True)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--steps',type=int,default=1500)
    ap.add_argument('--width',type=int,default=1280);ap.add_argument('--height',type=int,default=720)
    ap.add_argument('--accum',type=int,default=4);ap.add_argument('--lr',type=float,default=.0002)
    ap.add_argument('--dry-run',action='store_true');a=ap.parse_args()
    identity=json.loads((ROOT/'frozen_teacher/identity.json').read_text())
    if digest(ROOT/'frozen_teacher/model.pth')!=identity['sha256']:raise RuntimeError('Teacher hash mismatch')
    for variant in ['s8','s4']:
        run=ROOT/'runs'/variant;done=run/'completed.json'
        if done.exists():
            cfg=json.loads((run/'config.json').read_text())
            for key in ['width','height','accum','lr']:
                if cfg[key]!=getattr(a,key):raise RuntimeError('Completed run config differs: '+key)
            report=json.loads(done.read_text())
            if report['step']>=a.steps:
                if digest(run/'model_final.pth')!=report['model_sha256']:raise RuntimeError('Completed model changed')
                print('Already completed:',variant,report['step'],flush=True);continue
        cmd=[sys.executable,str(Path('D:/aidrawer/training_experiments/Ukiyo-e/20261008_S8_IN_1res_S4_IN_3res_Distillation/train_candidates.py')),'--variant',variant,'--steps',str(a.steps),
             '--width',str(a.width),'--height',str(a.height),'--accum',str(a.accum),'--lr',str(a.lr),'--save-every','250']
        if (run/'last.pth').exists():cmd.append('--resume')
        print('Run:',subprocess.list2cmdline(cmd),flush=True)
        if a.dry_run:continue
        try:subprocess.run(cmd,check=True,cwd=ROOT)
        except KeyboardInterrupt:print('Stopped. Run the same command again to resume.',flush=True);return
        if not done.exists() or json.loads(done.read_text())['step']<a.steps:
            raise RuntimeError(variant+' stopped before completion; rerun launcher to resume. Next model was not started.')
    if not a.dry_run:compare()

if __name__=='__main__':main()
