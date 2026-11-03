"""Weights-only source-driven RGB split/streaks and discontinuous glitch colour."""
from pathlib import Path
import hashlib,json,shutil,struct
import numpy as np
from neon_board_core import write_slot
from train_sunny import neutral_slot
from train_art_exploration import reference_stats

P=Path(__file__).resolve().parents[1]
E=P/'style_experiments/glitch_20261102'
PALETTES=np.array([[4,18,114,235,220,78,242,255],
                   [3,30,200,42,80,232,190,255],
                   [14,104,226,206,58,220,244,255]],np.uint8)
sha=lambda b:hashlib.sha256(b).hexdigest()


def main():
    if E.exists():raise ValueError('Preserve earlier glitch candidates')
    b=bytearray(neutral_slot())
    w=np.zeros((4,4,3,3),np.int8)
    for c in range(3):w[c,c,1,1]=64
    for c,v in enumerate((8,16,8)):w[3,c,1,1]=v;w[3,c,1,0]=-v
    b[960:1104]=w.tobytes()
    w=np.zeros((4,4,3,3),np.int8)
    w[0,0,1,0]=64;w[0,0,1,1]=-64;w[0,3,1,1]=32
    w[1,3,1,1]=-96
    w[2,2,1,2]=64;w[2,2,1,1]=-64;w[2,3,1,1]=48
    b[1120:1264]=w.tobytes()
    for offset in (1280,1440):
        w=np.zeros((4,4,3,3),np.int8)
        for c in range(3):w[c,c,1,1]=64
        b[offset:offset+144]=w.tobytes()
    w=np.zeros((4,4,3,3),np.int8)
    for c in range(3):w[c,c,1,1]=40
    b[1600:1744]=w.tobytes()
    b[0xa00:0xb00]=bytes(256)
    for c,(offset,start) in enumerate(zip((-127,-40,48),(1,88,176))):
        struct.pack_into('<Ii',b,0x800+(36+c)*8,262144,offset*64*262144)
        for code in range(80):b[0xa00+start+code]=int(PALETTES[c,int(np.rint(code*7/79))])
    slot=bytes(b);E.mkdir(parents=True)
    meta=dict(variant='glitch',initialization='Analytic independent neutral model; no P5',
        model_code_sha256=sha(Path(__file__).read_bytes()),graph_code_sha256=sha((P/'tools/neon_board_core.py').read_bytes()),
        reference=reference_stats()['glitch'],channel_palettes=PALETTES.tolist(),
        construction='Opposed red/blue quarter-grid shifts, source-driven horizontal edge streaks, green-channel dropouts and discontinuous per-channel palettes',
        hardware_changed=False,coordinate_input=False,pc_style_previews=False,
        limitation='Content-driven local glitch approximation; no autonomous random full-screen scanlines, arbitrary long tearing bands or added text')
    write_slot(E/'glitch/export',slot,meta);shutil.copy2(Path(__file__),E/Path(__file__).name)
    print(json.dumps(dict(experiment=str(E),slot_sha256=sha(slot)),indent=2))


if __name__=='__main__':main()
