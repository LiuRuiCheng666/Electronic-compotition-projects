"""Four reference-inspired parameter recipes in the unmodified RGB7/A4 graph.

Reference images stay local. These are analytic model candidates, not a claim
of semantic redraw or general neural style-transfer training.
"""
from pathlib import Path
import hashlib,json,shutil,struct
import numpy as np
from PIL import Image
from neon_board_core import write_slot
from train_sunny import neutral_slot
from build_reference4 import layer

P=Path(__file__).resolve().parents[1]
E=P/'style_experiments/illustration4_20261102'
TEMP=Path('C:/Users/letus/AppData/Local/Temp')
sha=lambda b:hashlib.sha256(b).hexdigest()
REFS=dict(flat='1a1a1d41-eff8-4f0e-bb1d-cbc5fc62a005',gongbi='0e34c1bd-6eca-4f81-b700-e93badcf17bc',
          retro='ee6e0b61-a197-425b-aaa3-bd886c7133c5',hologram='191f367f-192e-490e-a956-a73f90901c12')
NAMES=dict(flat='扁平矢量插画·鲜艳色块黑轮廓',gongbi='工笔方向·细线与雅致淡彩',retro='复古建筑版画·深蓝米白',hologram='全息投影·青蓝亮边暗底')
RECTS=dict(flat=[(.58,.304,.921,.506)],gongbi=[(.06,.485,.455,.77),(.52,.485,.94,.77)],
           retro=[(.59,.33,.93,.51)],hologram=[(.05,.465,.475,.74),(.51,.465,.97,.74)])
FLAT_LEVELS=np.array([0,36,94,162,220,255],np.uint8)


def reference_stats():
    result={}
    for name,id in REFS.items():
        path=TEMP/f'codex-clipboard-{id}.jpg'
        with Image.open(path) as im:a=np.asarray(im.convert('RGB')).astype(float)/255
        h,w=a.shape[:2]
        px=np.concatenate([a[int(y0*h):int(y1*h),int(x0*w):int(x1*w)].reshape(-1,3) for x0,y0,x1,y1 in RECTS[name]])
        r,g,b=px.T;l=px@np.array([.2126,.7152,.0722])
        masks=dict(cream=(l>.78)&(r>b+.025),navy=(l<.30)&(b>r+.025),
                   jade=(g>r+.05)&(b>r+.02)&(l>.3),cyan=(b>r+.12)&(g>r+.08)&(l>.45),
                   ochre=(r>b+.15)&(g>b+.10)&(l>.45)&(l<.8))
        colors={k:np.median(px[m],axis=0).tolist() if m.sum()>32 else None for k,m in masks.items()}
        result[name]=dict(images=[dict(path=str(path),sha256=sha(path.read_bytes()),size=[w,h],sample_rectangles=RECTS[name])],
                          pooled_image_count=1,palette=colors,sample_counts={k:int(m.sum()) for k,m in masks.items()},
                          uploaded=False,use='Local numerical artwork palette sampling only; screenshot UI, instructions and source-photo panels excluded')
    return result


def mixed(refs,name,key,default,amount=.2):
    found=refs[name]['palette'][key]
    return np.array(default) if found is None else (1-amount)*np.array(default)+amount*np.array(found)


def build(name,refs):
    b=bytearray(neutral_slot());w=np.zeros((4,4,3,3),np.int8)
    for c in range(3):w[c,c,1,1]=64
    scales=dict(flat=[3,6,1],gongbi=[1,3,1],retro=[2,6,1],hologram=[4,8,2])[name]
    for c,k in enumerate(scales):w[3,c]=k;w[3,c,1,1]=-8*k
    layer(b,4,w);w=np.zeros((4,4,3,3),np.int8)
    if name=='flat':
        matrix=np.array([[24,-12,-12],[-12,24,-12],[-12,-12,24]],np.int8)
        for c in range(3):w[c,:3,1,1]=matrix[c];w[c,3,1,1]=-96
    elif name=='gongbi':
        for c in range(3):w[c,c,1,1]=6;w[c,c,0,0]=-6;w[c,3,1,1]=-32
    elif name=='retro':
        for c in range(3):w[c,c,1,1]=12;w[c,c,0,0]=-12;w[c,3,1,1]=72
    else:
        for c in range(3):w[c,c,1,1]=-48;w[c,3,1,1]=96
    layer(b,5,w)
    if name in ('flat','gongbi','retro'):
        w=np.zeros((4,4,3,3),np.int8)
        kernel=[[0,4,0],[4,48,4],[0,4,0]]
        for c in range(3):w[c,c]=kernel
        layer(b,6,w)
    if name=='flat':
        for i in range(256):
            q=max(0,min(127,i-128));b[0xa00+i]=int(FLAT_LEVELS[int(np.rint(q*5/127))])
        return bytes(b),dict(levels=FLAT_LEVELS.tolist(),ink='positive local valley curvature, RGB saturation + black contour',
                             source_hue=True,large_shape_generation=False)
    w=np.zeros((4,4,3,3),np.int8)
    for c in range(3):
        if name=='gongbi':w[c,c,1,1]=32
        else:w[c,:3,1,1]=[7,23,2]
    layer(b,8,w);b[0xa00:0xb00]=bytes(256)
    if name=='gongbi':
        knots=[0,.18,.38,.58,.78,1]
        colors=np.array([[.14,.19,.17],[.34,.43,.37],[.56,.64,.53],[.75,.81,.68],[.9,.92,.81],[.98,.97,.9]])
        colors[-1]=mixed(refs,name,'cream',colors[-1],.15)
    elif name=='retro':
        knots=[0,.34375,.421875,1]
        colors=np.array([mixed(refs,name,'navy',[.075,.17,.23],.15),
                         mixed(refs,name,'ochre',[.77,.63,.35],.15),
                         mixed(refs,name,'cream',[.96,.94,.84],.15)])
    else:
        knots=[0,.10,.22,.36,.56,.78,1]
        colors=np.array([[.006,.018,.055],[.012,.055,.16],[.015,.27,.52],[.025,.60,.80],
                         [.22,.84,.97],[.57,.94,1],[.92,.99,1]])
        colors[4]=mixed(refs,name,'cyan',colors[4],.15)
    rgb=np.clip(np.rint(colors*255),0,255).astype(np.uint8)
    for c,(offset,start) in enumerate(zip((-120,-40,40),(8,88,168))):
        struct.pack_into('<Ii',b,0x800+(36+c)*8,262144,offset*64*262144)
        for q in range(65):
            value=int(rgb[(q>=22)+(q>=27),c]) if name=='retro' else int(np.rint(np.interp(q/64,knots,rgb[:,c])))
            b[0xa00+start+q]=value
    return bytes(b),dict(knots=knots,palette_rgb_u8=rgb.tolist(),channel_band_starts=[8,88,168],channel_offsets=[-120,-40,40],
                         head='per_channel' if name=='gongbi' else 'luminance',discrete_threshold_codes=[22,27] if name=='retro' else None)


def main():
    if E.exists():raise ValueError('Preserve prior models')
    E.mkdir(parents=True);refs=reference_stats()
    (E/'REFERENCE_STATS.json').write_text(json.dumps(refs,ensure_ascii=False,indent=2),encoding='utf-8')
    for index,name in enumerate(REFS):
        slot,recipe=build(name,refs)
        meta=dict(variant=name,destination_style=index,display_name=NAMES[name],reference=refs[name],recipe=recipe,
                  construction='Analytic local style candidate, existing A4 model kernels/affine/LUT only; no training claim',
                  model_code_sha256=sha(Path(__file__).read_bytes()),graph_code_sha256=sha((P/'tools/neon_board_core.py').read_bytes()),
                  helper_code_sha256=sha((P/'tools/build_reference4.py').read_bytes()),
                  hardware_changed=False,firmware_changed=False,coordinate_input=False,pc_style_previews=False,
                  limitation='Local palette/contour/tone approximation. No semantic redraw, new geometry/sun, real transparency or invented scene content.')
        write_slot(E/name/'export',slot,meta)
        print(json.dumps(dict(style=index,name=NAMES[name],sha256=sha(slot)),ensure_ascii=False),flush=True)
    shutil.copy2(Path(__file__),E/Path(__file__).name)


if __name__=='__main__':main()
