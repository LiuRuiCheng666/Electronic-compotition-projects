"""Make per-image contact sheets from completed floating-point experiments."""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw

ap=argparse.ArgumentParser()
ap.add_argument('--runs',nargs='+',type=Path,required=True)
ap.add_argument('--out',type=Path,required=True)
a=ap.parse_args()
if a.out.exists():raise RuntimeError('Choose a new output directory')
import json
configs=[json.loads((r/'config.json').read_text(encoding='utf-8')) for r in a.runs]
for c in configs[1:]:
    if c['eval_files']!=configs[0]['eval_files'] or c['style_sha256']!=configs[0]['style_sha256']:raise RuntimeError('Dataset/style mismatch')
a.out.mkdir(parents=True)
for i,item in enumerate(configs[0]['eval_files']):
    p=Path(item['path']); panels=[('Input',p)]
    for r in a.runs:
        panels.append((r.name,r/'eval_final'/f'{i:02d}_{p.stem}.png'))
    canvas=Image.new('RGB',(320*len(panels),266),'white');draw=ImageDraw.Draw(canvas)
    for col,(label,f) in enumerate(panels):
        with Image.open(f) as im:canvas.paste(im.convert('RGB').resize((320,240)),(col*320,26))
        draw.text((col*320+5,5),label,fill='black')
    canvas.save(a.out/f'{i:02d}_{p.stem}.jpg',quality=95)
print(a.out)
