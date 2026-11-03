"""A4 integer reference from deployed Flash bytes, plus training/display comparisons.
No export, training, FPGA configuration edits or hardware access.
"""
import argparse, hashlib, json, math, re, struct, sys, zlib
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
import torch
import torch.nn.functional as F

PROJECT=Path(__file__).resolve().parents[2]
NAMES=['enc.0','enc.1','enc.2','enc.3','res.c1','res.c2','dec.1','dec.3','out.1']
CINS=[4,4,4,8,4,4,4,4,4]
COUTS=[4,4,8,4,4,4,4,4,3]
STRIDES=[1,1,2,2,1,1,1,1,1]
RELU=[True,True,True,True,True,False,True,True,False]

def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def load_slots(device,asset_dir=None):
    asset_dir=asset_dir or PROJECT/'01_FPGA/flash_assets'
    blob=(asset_dir/'a4_dual_models_flash.bin').read_bytes()
    version,size,crc=struct.unpack_from('<III',blob,4)
    assert blob[:4]==b'NNW1' and version==1 and size == 20480
    payload=blob[32:];assert len(payload)==size and zlib.crc32(payload)==crc
    manifest=json.loads((asset_dir/'dual_model_manifest.json').read_text(encoding='utf-8'))
    assert hashlib.sha256(payload).hexdigest()==manifest['payload_sha256']
    result=[]
    assert len(manifest['slots'])==size//4096
    assert manifest.get('model_count',size//4096)==size//4096
    for slot in range(size//4096):
        data=payload[slot*4096:(slot+1)*4096]
        assert hashlib.sha256(data).hexdigest()==manifest['slots'][slot]['sha256']
        if slot != 2:
            result.append(None)
            continue
        weights=[];coeffs=[];offset=0;coeff_offset=0
        for ci,co in zip(CINS,COUTS):
            padded=(co+3)//4*4
            w=np.zeros((padded,ci,3,3),dtype=np.int8)
            for og in range(0,padded,4):
                for ig in range(0,ci,4):
                    w[og:og+4,ig:ig+4]=np.frombuffer(data[offset:offset+144],dtype=np.int8).reshape(4,4,3,3)
                    assert data[offset+144:offset+160]==bytes(16)
                    offset+=160
            weights.append(torch.tensor(w[:co].copy(),dtype=torch.float64,device=device))
            ab=np.array([struct.unpack_from('<Ii',data,0x800+(coeff_offset+j)*8) for j in range(co)],dtype=np.int64)
            assert all(int(a) in [32768,65536,131072,262144] for a,b in ab)
            assert all(int(b)%int(a)==0 and -65536<=int(b)//int(a)<65536 for a,b in ab)
            coeffs.append(torch.tensor(ab,device=device))
            coeff_offset+=padded
        assert offset==1760 and coeff_offset==40
        lut=np.frombuffer(data[0xa00:0xb00],dtype=np.uint8).copy()
        assert lut[128]==128 and all(int(lut[i])+int(lut[256-i])==255 for i in range(1,128))
        result.append({'weights':weights,'coeffs':coeffs,'lut':torch.tensor(lut,device=device),
                       'name':manifest['slots'][slot]['name']})
    return result,manifest

def round_even_div(n,shift):
    denominator=1<<shift
    floor=torch.div(n,denominator,rounding_mode='floor')
    rem=n-floor*denominator
    return floor+((rem>denominator//2)|((rem==denominator//2)&((floor&1)!=0))).long()

def infer_codes(codes,slot,trace=False):
    # Integer arithmetic is carried in double precision convolution: all
    # inputs/products/sums fit exactly, then converted to int64. No FP32/TF32.
    device=slot['weights'][0].device
    q=torch.tensor(codes.transpose(2,0,1).copy(),device=device,dtype=torch.int64)[None]
    stats=[];arrays={}
    def record(name,v,before=None):
        d={'layer':name,'shape':list(v.shape),'min':int(v.min()),'max':int(v.max()),
           'low_endpoint_fraction':float((v==-127).double().mean()),
           'high_endpoint_fraction':float((v==127).double().mean())}
        if before is not None:d['clipped_fraction']=float(((before<-127)|(before>127)).double().mean())
        stats.append(d)
        if trace:arrays[name]=v[0].permute(1,2,0).cpu().numpy().astype(np.int8)
        return v
    skip=None
    for i,name in enumerate(NAMES):
        if i in [6,7]:q=q.repeat_interleave(2,2).repeat_interleave(2,3)
        raw=F.conv2d(F.pad(q.double(),(1,1,1,1),mode='reflect'),slot['weights'][i],stride=STRIDES[i])
        if float((raw-raw.round()).abs().max())>1e-8:raise RuntimeError('Non-exact convolution '+name)
        acc=raw.round().long()
        assert int(acc.abs().max())<2**31
        ab=slot['coeffs'][i];channels=[]
        for c,(a,b) in enumerate(ab.tolist()):
            shift=24-(int(a).bit_length()-1)
            v=round_even_div(acc[:,c]+int(b)//int(a),shift)
            if RELU[i]:v=v.clamp_min(0)
            channels.append(v)
        unclipped=torch.stack(channels,1)
        q=record(name,unclipped.clamp(-127,127),unclipped)
        if i==3:skip=q.clone()
        if i==5:
            unclipped=skip+q;q=record('res.add',unclipped.clamp(-127,127),unclipped)
    out=slot['lut'][q+128][0].permute(1,2,0).cpu().numpy().astype(np.uint8)
    return out,stats,arrays

def tone_table():
    text=(PROJECT/'01_FPGA/rtl/nn/rtl/camera_tone_mapper.v').read_text()
    pairs=re.findall(r"8'd(\d+):tone_gain=12'd(\d+);",text)
    table=np.zeros(256,dtype=np.uint32)
    assert len(pairs)==256
    for index,value in pairs:table[int(index)]=int(value)
    return table

def displayed(rgb,table):
    gain=table[rgb.max(axis=2)]
    return np.minimum((rgb.astype(np.uint32)*gain[:,:,None])>>8,255).astype(np.uint8)
