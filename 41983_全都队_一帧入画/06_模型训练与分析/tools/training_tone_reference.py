"""Training helper copied to board_reference/tools/board_exact_infer.py.

Read the exact display-tone constants from the supplied final RTL. This module
only supplies tone_table to the two portable trainers; it performs no inference,
training, board access, or reads from an earlier project directory.
"""
from pathlib import Path
import re
import numpy as np


def tone_table():
    root=Path(__file__).resolve().parents[1]
    text=(root/'rtl/nn/rtl/camera_tone_mapper.v').read_text('utf-8')
    pairs=re.findall(r"8'd(\d+):tone_gain=12'd(\d+);",text)
    if len(pairs)!=256 or {int(i) for i,_ in pairs}!=set(range(256)):
        raise ValueError('Expected all 256 final display-tone gain entries')
    table=np.zeros(256,dtype=np.uint32)
    for i,v in pairs:table[int(i)]=int(v)
    return table
