"""Create a deterministic 4x4 pixel-art model using existing A4 parameters only.

Two existing stride-2 layers perform RGB 2x2 means. The residual bypass and
existing nearest upsamplers restore a constant 4x4 tile; the per-model LUT
maps each RGB channel to six levels. No RTL or firmware modification.
"""
from pathlib import Path
import hashlib, json, shutil, struct
import numpy as np
from neon_board_core import CINS, COUTS, write_slot
from train_neon_round2 import validate_blob

P=Path(__file__).resolve().parents[1]
E=P/'style_experiments/pixel_mosaic_20261030'
sha=lambda b:hashlib.sha256(b).hexdigest()


def main():
    if E.exists():raise ValueError('Preserve previous experiments')
    source=P/'release/pencil_sketch_20261030/PENCIL_SKETCH_weights.bin'
    blob=validate_blob(source)
    records=json.loads((source.parent/'dual_model_manifest.json').read_text(encoding='utf-8'))['slots']
    parents=[blob[32+i*4096:32+(i+1)*4096] for i in range(4)]
    for b,r in zip(parents,records):assert sha(b)==r['sha256']
    # Complete model slot, including kernels, per-layer affine parameters and
    # model-local output lookup. All bytes remain in the existing model format.
    slot=bytearray(4096);offset=0;description=[]
    for i,(ci,co) in enumerate(zip(CINS,COUTS)):
        padded=(co+3)//4*4
        weights=np.zeros((padded,ci,3,3),dtype=np.int8)
        if i in (2,3):
            for c in range(3):weights[c,c,1:3,1:3]=16
            operation='2x2 mean, stride2, nearest-even intermediate rounding'
        elif i in (4,5):
            operation='zero residual branch; unchanged built-in residual adds encoder3 skip at layer5'
        else:
            for c in range(3):weights[c,c,1,1]=64
            operation='RGB identity; layers6/7 use existing nearest-neighbour x2 upsampling'
        for og in range(0,padded,4):
            for ig in range(0,ci,4):
                slot[offset:offset+144]=weights[og:og+4,ig:ig+4].tobytes()
                offset+=160
        description.append(dict(layer=i,input_channels=ci,output_channels=co,operation=operation))
    assert offset==1760
    for i in range(40):struct.pack_into('<Ii',slot,0x800+i*8,262144,0)
    palette=[0,51,102,153,204,255]
    for i in range(256):
        code=max(0,min(127,i-128))
        slot[0xa00+i]=palette[int(np.rint(code*5/127))]
    slot=bytes(slot)
    E.mkdir(parents=True)
    for i,b in enumerate(parents):(E/f'parent_style{i}.slot.bin').write_bytes(b)
    meta=dict(variant='pixel',destination_style=0,parent_style=0,parent_slot_sha256=sha(parents[0]),
              source_weight_file=str(source),source_weight_sha256=sha(blob),
              construction='Analytic legal model parameters, no stochastic training',
              model_code_sha256=sha(Path(__file__).read_bytes()),
              graph_code_sha256=sha((P/'tools/neon_board_core.py').read_bytes()),
              tile_size_input_pixels=[4,4],palette_channel_levels=palette,total_possible_colours=216,
              hardware_changed=False,firmware_changed=False,coordinate_input=False,pc_style_previews=False,
              architecture='Unchanged RGB7 A4 graph; existing strides, residual and nearest upsampling',
              rounding='Two nearest-even 2x2 stages, then per-model 6-level LUT. Not a single exact 4x4 division.',
              limitation='4x4 source-grid blocks. Arbitrary 8x8/16x16 screen grids are outside this unchanged graph.',
              layers=description,changed_slot_bytes=sum(a!=b for a,b in zip(parents[0],slot)))
    write_slot(E/'pixel/export',slot,meta)
    shutil.copy2(Path(__file__),E/Path(__file__).name)
    (E/'MODEL_CONSTRUCTION.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(dict(experiment=str(E),slot_sha256=sha(slot),tile=[4,4],palette=palette),indent=2))


if __name__=='__main__':main()
