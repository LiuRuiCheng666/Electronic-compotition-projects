"""Compare frozen teacher and latest completed calibrated student snapshots."""
import argparse,json
from pathlib import Path
import torch
from PIL import Image,ImageDraw
from torchvision.transforms import functional as TF
from train_round2 import ROOT,TEACHER,model,Student,digest

ap=argparse.ArgumentParser()
ap.add_argument('--runs',nargs='+',required=True)
ap.add_argument('--out',default='comparisons/round2_01')
a=ap.parse_args()
out=ROOT/a.out
if out.exists():raise RuntimeError('Output exists; choose another --out')
identity=json.loads((TEACHER.parent/'identity.json').read_text())
if digest(TEACHER)!=identity['sha256']:raise RuntimeError('Teacher changed')
configs=[];nets=[]
for name in a.runs:
    run=ROOT/'runs'/name;cfg=json.loads((run/'config.json').read_text(encoding='utf-8'))
    if cfg['teacher_sha256']!=identity['sha256']:raise RuntimeError('Teacher mismatch')
    if configs and configs[0]['eval_files']!=cfg['eval_files']:raise RuntimeError('Evaluation set mismatch')
    complete=[p for p in run.glob('eval_step*') if (p/'metrics.json').exists() and (p/'inference_model.pth').exists()]
    if not complete:raise RuntimeError('No completed evaluation: '+name)
    snapshot=max(complete,key=lambda p:(int(p.name.split('_')[1][4:]),p.stat().st_mtime_ns))
    n=Student(True,cfg['norm']).cuda().eval()
    n.load_state_dict(torch.load(snapshot/'inference_model.pth',map_location='cpu',weights_only=True))
    nets.append((name,n));configs.append(cfg)
teacher=model('teacher').cuda().eval();teacher.load_state_dict(torch.load(TEACHER,map_location='cpu',weights_only=True))
out.mkdir(parents=True)
with torch.no_grad():
    for i,item in enumerate(configs[0]['eval_files']):
        p=Path(item['path'])
        if digest(p)!=item['sha256']:raise RuntimeError('Evaluation image changed: '+str(p))
        with Image.open(p) as im:inp=im.convert('RGB').resize((640,480),Image.Resampling.BICUBIC)
        x=TF.to_tensor(inp)[None].cuda()
        panels=[('Input',inp),('Approved teacher',TF.to_pil_image(teacher(x)[0].cpu().clamp(0,1)))]
        for name,n in nets:panels.append((name,TF.to_pil_image(n(x)[0].cpu().clamp(0,1))))
        sheet=Image.new('RGB',(320*len(panels),266),'white');draw=ImageDraw.Draw(sheet)
        for col,(label,im) in enumerate(panels):
            sheet.paste(im.resize((320,240)),(320*col,26));draw.text((320*col+5,5),label,fill='black')
        sheet.save(out/f'{i:02d}_{p.stem}.jpg',quality=95)
print(out)
