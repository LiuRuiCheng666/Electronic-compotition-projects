"""Four weights-only reference-inspired local art recipes; no public uploads.

Rotoscope, pooled three-image Van-Gogh-inspired blue/gold strokes, cyber
oriental colour/light and red/cream layered paper cut. Original scene retained.
"""
from pathlib import Path
import hashlib,json,shutil,struct
import numpy as np
from PIL import Image
from neon_board_core import write_slot
from train_sunny import neutral_slot

P=Path(__file__).resolve().parents[1]
E=P/'style_experiments/reference4_v2_20261102'
TEMP=Path('C:/Users/letus/AppData/Local/Temp')
sha=lambda b:hashlib.sha256(b).hexdigest()
REFS=dict(rotoscope=['4429b118-58b0-4af1-a941-2122ada90f61'],
          vangogh=['658092e9-ad4e-41b6-8c1e-209c242f3c0f','b33ea233-c065-4962-b0ce-fa9de4c6c754','f81b7162-d0d8-433a-9ecd-d6b91fc18374'],
          cyber=['44992837-cf6e-40a1-898c-6b4871821185'],paper=['78042ec4-4bb1-47bf-a359-f52775f51554'])
NAMES=dict(rotoscope='转描动画·轮廓与赛璐璐色块',vangogh='梵高星夜方向·蓝金局部笔触',cyber='赛博东方·冷影暖灯',paper='剪纸艺术·红米色分层')
ROTO_LEVELS=np.array([0,18,38,60,83,106,130,154,179,203,228,250],np.uint8)


def reference_stats():
    result={}
    for style,ids in REFS.items():
        entries=[];pixels=[]
        for id in ids:
            path=TEMP/f'codex-clipboard-{id}.jpg'
            with Image.open(path) as image:a=np.asarray(image.convert('RGB')).astype(float)/255
            h,w=a.shape[:2]
            rects=[(.01,.35,.99,.618)] if style=='vangogh' else [(.26,.06,.97,.65),(.035,.30,.35,.65)]
            for x0,y0,x1,y1 in rects:pixels.append(a[int(y0*h):int(y1*h),int(x0*w):int(x1*w)].reshape(-1,3))
            entries.append(dict(path=str(path),sha256=sha(path.read_bytes()),size=[w,h],sample_rectangles=rects))
        px=np.concatenate(pixels);r,g,b=px.T;l=px@np.array([.2126,.7152,.0722])
        masks=dict(navy=(l<.22)&(b>r),blue=(b>r+.055)&(b>g+.01)&(l>.15)&(l<.65),
                   gold=(r>b+.14)&(g>b+.10)&(l>.4),cream=(l>.72)&(r>b+.04),
                   red=(r>g+.13)&(r>b+.12)&(l>.20),darkred=(r>g+.06)&(l<.28))
        defaults=dict(navy=[.025,.045,.12],blue=[.12,.26,.52],gold=[.94,.72,.25],cream=[.98,.91,.69],red=[.78,.12,.075],darkred=[.25,.035,.025])
        palette={key:(.30*np.median(px[m],axis=0)+.70*np.array(defaults[key])).tolist() if m.sum()>32 else defaults[key] for key,m in masks.items()}
        result[style]=dict(images=entries,pooled_image_count=len(entries),palette=palette,
                           sample_counts={key:int(m.sum()) for key,m in masks.items()},uploaded=False,
                           use='Local artwork-only colour statistics; screenshot UI/prompt text excluded; no copied content or text')
    return result


def layer(b,index,w):
    offsets={4:960,5:1120,6:1280,7:1440,8:1600}
    assert w.shape==(4,4,3,3) and np.abs(w.astype(int)).max()<=127
    b[offsets[index]:offsets[index]+144]=w.astype(np.int8).tobytes()


def build(style,refs):
    b=bytearray(neutral_slot());w=np.zeros((4,4,3,3),np.int8)
    for c in range(3):w[c,c,1,1]=64
    if style=='rotoscope':
        for c,k in enumerate((2,4,1)):
            w[3,c,:,:]=k;w[3,c,1,1]=-8*k
    elif style=='vangogh':
        for c,k in enumerate((9,18,5)):w[3,c,0,0]=k;w[3,c,2,2]=-k
    elif style=='cyber':
        for c,k in enumerate((8,16,8)):w[3,c,1,1]=k;w[3,c,1,0]=-k
    else:
        for c,k in enumerate((8,20,4)):w[3,c,0,0]=k;w[3,c,1,1]=-k
    layer(b,4,w)
    w=np.zeros((4,4,3,3),np.int8)
    if style=='rotoscope':
        for c in range(3):w[c,3,1,1]=-64
    elif style=='vangogh':
        for c in range(3):
            w[c,c,1,1]=16;w[c,c,0,0]=-8;w[c,c,2,2]=-8;w[c,3,1,1]=32
    elif style=='cyber':
        matrix=np.array([[15,-14,-1],[-4,6,-2],[-4,-14,18]],np.int8)
        for c in range(3):w[c,:3,1,1]=matrix[c];w[c,3,1,1]=[20,32,48][c]
    else:
        for c in range(3):w[c,c,1,1]=12;w[c,c,0,0]=-12;w[c,3,1,1]=-32
    layer(b,5,w)
    if style=='vangogh':
        w=np.zeros((4,4,3,3),np.int8);kernel=np.array([[4,4,0],[4,40,4],[0,4,4]],np.int8)
        for c in range(3):w[c,c]=kernel
        layer(b,6,w)
    if style=='rotoscope':
        for i in range(256):
            q=max(0,min(127,i-128));b[0xa00+i]=int(ROTO_LEVELS[int(np.rint(q*11/127))])
        return bytes(b),dict(levels=ROTO_LEVELS.tolist(),cell_shading='12 channel levels; content-driven valley ink; original hue retained')
    w=np.zeros((4,4,3,3),np.int8)
    for c in range(3):
        if style=='cyber':w[c,c,1,1]=32
        else:w[c,:3,1,1]=[7,23,2]
    layer(b,8,w)
    b[0xa00:0xb00]=bytes(256)
    p=refs[style]['palette']
    if style=='vangogh':
        knots=[0,.16,.36,.52,.68,.84,1]
        colors=np.array([p['navy'],np.array(p['navy'])*.45+np.array(p['blue'])*.55,p['blue'],
                         np.array(p['blue'])*.60+np.array(p['cream'])*.40,
                         np.array(p['gold'])*.80+np.array(p['red'])*.20,p['gold'],p['cream']])
    elif style=='cyber':
        knots=[0,.12,.28,.45,.62,.82,1]
        colors=np.array([[.008,.02,.055],[.02,.055,.13],[.025,.16,.25],[.045,.30,.43],
                         [.30,.35,.45],[.88,.45,.27],[1.,.86,.65]])
        colors[0]=np.array(p['navy'])*.55
        colors[-2]=np.array(p['red'])*.55+np.array(p['gold'])*.45
    else:
        knots=[0,.25,.50,.75,1]
        colors=np.array([p['darkred'],np.array(p['red'])*.70+np.array(p['darkred'])*.30,p['red'],
                         np.array(p['cream'])*.70+np.array(p['gold'])*.30,p['cream']])
    rgb=np.clip(np.rint(colors*255),0,255).astype(np.uint8)
    for c,(offset,start) in enumerate(zip((-120,-40,40),(8,88,168))):
        struct.pack_into('<Ii',b,0x800+(36+c)*8,262144,offset*64*262144)
        for q in range(65):
            u=q/64
            if style=='paper':value=int(rgb[int(np.rint(u*4)),c])
            else:value=int(np.rint(np.interp(u,knots,rgb[:,c])))
            b[0xa00+start+q]=value
    return bytes(b),dict(knots=knots,palette_rgb_u8=rgb.tolist(),channel_band_starts=[8,88,168],channel_offsets=[-120,-40,40],paper_discrete_layers=style=='paper')


def main():
    if E.exists():raise ValueError('Preserve prior models')
    E.mkdir(parents=True);refs=reference_stats()
    (E/'REFERENCE_STATS.json').write_text(json.dumps(refs,ensure_ascii=False,indent=2),encoding='utf-8')
    for index,style in enumerate(REFS):
        b,recipe=build(style,refs)
        meta=dict(variant=style,destination_style=index,display_name=NAMES[style],reference=refs[style],recipe=recipe,
            construction='Independent analytic local art recipe in existing A4/RGB7 graph, model kernels/affine/LUT only',
            model_code_sha256=sha(Path(__file__).read_bytes()),graph_code_sha256=sha((P/'tools/neon_board_core.py').read_bytes()),
            hardware_changed=False,firmware_changed=False,coordinate_input=False,pc_style_previews=False,
            limitation='Local colour/contour/stroke approximation. No semantic face redraw, large starry swirls, new buildings/lanterns or full paper-scene geometry.')
        write_slot(E/style/'export',b,meta)
        print(json.dumps(dict(style=index,name=NAMES[style],sha256=sha(b)),ensure_ascii=False),flush=True)
    shutil.copy2(Path(__file__),E/Path(__file__).name)


if __name__=='__main__':main()
