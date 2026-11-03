"""Run B16 distillation, dependent A4 pruning and A4 recovery. No hardware edits."""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
import torch

ROOT=Path('D:/aidrawer/output/bright_aaa/20261007_Teacher_Palette_Texture_B16_to_A4_Distillation/distill_b16_a4')

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def train(script,run,steps,args,dry):
    command=[sys.executable,str(script),*args,'--run',run.name,'--steps',str(steps)]
    if (run/'last.pth').exists():
        saved=torch.load(run/'last.pth',map_location='cpu',weights_only=False)['step']
        if saved>=steps and (run/'model_final.pth').exists():
            print('Completed:',run,'step',saved,flush=True);return
        command.append('--resume')
    print('Run:',subprocess.list2cmdline(command),flush=True)
    if dry:return
    subprocess.run(command,check=True,cwd=script.parent)
    if not (run/'last.pth').exists() or torch.load(run/'last.pth',map_location='cpu',weights_only=False)['step']<steps:
        raise RuntimeError('Training stopped before completion. Run this launcher again to resume.')
    if not (run/'model_final.pth').exists():raise RuntimeError('Missing calibrated inference model')

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--b16-steps',type=int,default=8000)
    ap.add_argument('--a4-steps',type=int,default=3000)
    ap.add_argument('--only',choices=['all','b16','a4'],default='all')
    ap.add_argument('--dry-run',action='store_true')
    a=ap.parse_args()
    if min(a.b16_steps,a.a4_steps)<1:raise ValueError('Positive step counts required')
    b16=ROOT/'runs'/'bright_b16_bn'
    if a.only!='a4':
        train(Path('D:/aidrawer/training_experiments/bright_aaa/20261007_Teacher_Palette_Texture_B16_to_A4_Distillation/distill_b16_a4/train_b16.py'),b16,a.b16_steps,
              ['--norm','batch','--vga-start','0','--vga-batch','1','--vga-accum','4','--lr','0.0001','--save-every','500'],a.dry_run)
    if a.only=='b16':return
    a4root=ROOT/'a4_from_b16'
    if not a.dry_run:
        source=b16/'model_final.pth'
        if not source.exists():raise RuntimeError('Complete B16 first')
        frozen=a4root/'frozen_b16'/'identity.json'
        if frozen.exists():
            if json.loads(frozen.read_text())['sha256']!=digest(source):
                raise RuntimeError('B16 changed after A4 initialization; keep this experiment and create a new one')
        else:
            subprocess.run([sys.executable,str(Path('D:/aidrawer/training_experiments/bright_aaa/20261007_Teacher_Palette_Texture_B16_to_A4_Distillation/distill_b16_a4/a4_from_b16/prepare_a4.py')),'--source',str(source)],check=True,cwd=a4root)
    else:print('Then freeze completed B16 and prepare dependency-consistent 16-to-4 pruning',flush=True)
    train(Path('D:/aidrawer/training_experiments/bright_aaa/20261007_Teacher_Palette_Texture_B16_to_A4_Distillation/distill_b16_a4/a4_from_b16/train_a4.py'),a4root/'runs'/'bright_a4',a.a4_steps,
          ['--variant','a4','--vga-start','0','--vga-batch','1','--vga-accum','4','--lr','0.00005','--save-every','500'],a.dry_run)
    print('A4 output:',a4root/'runs'/'bright_a4',flush=True)
    print('Next: compare float outputs, fold BN, validate INT8 and export board ROM assets.',flush=True)

if __name__=='__main__':main()
