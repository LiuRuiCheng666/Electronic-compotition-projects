from pathlib import Path
import json,html,hashlib
import numpy as np,torch
from PIL import Image,ImageDraw
from target import load_rules,nobel_render
P=Path(__file__).resolve().parent
out=Path('D:/efinity/Ti60f225_v6_6/integration_tests/nobel_independent_20261017/gallery');out.mkdir(parents=True,exist_ok=True)
r=load_rules();device='cuda' if torch.cuda.is_available() else 'cpu';torch.set_num_threads(4)
paths=sorted(p for p in Path('D:/aidrawer/data/student_eval_external').iterdir() if p.is_file() and p.suffix.lower() in ['.jpg','.jpeg','.png','.bmp','.webp'])
page='<meta charset="utf-8"><title>独立黑金新风格目标</title><style>body{font:16px system-ui;background:#f6f3e8;margin:24px}img{width:100%}article{background:white;padding:12px;margin:20px 0}</style><h1>原图直接生成：黑线、金色阴影区域、米白底</h1><p>此处是新风格的训练目标预览，不是已训练的A4输出，也不是板上实拍。不经过红黑、螳螂虾或浮世绘模型。保留A4结构，需训练独立权重后才能上板。黑色描线和金色阴影区域使用不同掩膜，描线始终优先为黑色。</p>'
records=[]
for i,path in enumerate(paths):
 a=np.array(Image.open(path).convert('RGB').resize((896,504),Image.Resampling.BICUBIC));x=torch.tensor(a.transpose(2,0,1).copy(),dtype=torch.float32,device=device)[None]/255
 with torch.no_grad():b=(nobel_render(x,r)[0].permute(1,2,0).cpu().numpy()*255).round().astype(np.uint8)
 d=out/f'{i:02d}_{path.stem}';d.mkdir(exist_ok=True);Image.fromarray(a).save(d/'input.png');Image.fromarray(b).save(d/'target.png')
 sheet=Image.new('RGB',(1792,534),'white');draw=ImageDraw.Draw(sheet)
 for k,(im,label) in enumerate([(a,'Original photo'),(b,'NEW independent target (not A4 output yet)')]):sheet.paste(Image.fromarray(im),(896*k,30));draw.text((896*k+8,8),label,fill='black')
 sheet.save(d/'comparison.jpg',quality=95);sheet.resize((1280,381)).save(d/'thumbnail.jpg',quality=92)
 page+=f'<article><h2>{html.escape(path.name)}</h2><a href="{d.name}/comparison.jpg"><img loading="lazy" src="{d.name}/thumbnail.jpg"></a><a href="{d.name}/target.png">新风格目标原图</a></article>'
 records.append({'input':str(path),'source_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'folder':d.name})
(out/'index.html').write_text(page,encoding='utf-8');(out/'report.json').write_text(json.dumps({'kind':'independent_training_targets_NOT_model_outputs','rules':r,'images':records},indent=2),encoding='utf-8');print('Generated',len(records),'independent target pairs')
