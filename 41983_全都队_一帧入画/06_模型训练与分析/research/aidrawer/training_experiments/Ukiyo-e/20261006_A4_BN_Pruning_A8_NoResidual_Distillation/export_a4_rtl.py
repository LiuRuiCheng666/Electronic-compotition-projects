"""Generate isolated A4 assets and integer references; never overwrite teacher files."""
from pathlib import Path
import json,math,zlib
import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
import quant_screen_a4 as q

ROOT=q.ROOT/'a4_rtl_assets';PROJECT=Path('D:/efinity/Ti60f225_v6_3')

def rne(v,shift):
    base=v>>shift;remainder=v-(base<<shift);half=1<<(shift-1)
    return base+((remainder>half)|((remainder==half)&((base&1)!=0))) if shift else v

def mem(path,values,digits):path.write_text(''.join(f'{int(v)&((1<<(digits*4))-1):0{digits}x}\n' for v in values))

def main():
    ROOT.mkdir(exist_ok=False)
    n=q.load_net(q.ROOT/'a4_deployment_review_3000/a4_bn_folded_fp32.pth')
    r=json.loads((q.ROOT/'ptq_a4_3000/report.json').read_text());quant=q.Quantized(n,r['activation_scales'],'per_tensor')
    torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
    # name, op, input H/W divisor, stride, source, destination, skip
    specs=[('enc.0',0,1,1,0,1,0),('enc.1',0,1,1,1,2,0),('enc.2',0,1,2,2,3,0),('enc.3',0,2,2,3,0,0),
           ('res.c1',0,4,1,0,1,0),('res.c2',0,4,1,1,2,0),('res.add',2,4,1,2,3,0),('up1',1,4,1,3,1,0),
           ('dec.1',0,2,1,1,2,0),('up2',1,2,1,2,3,0),('dec.3',0,1,1,3,1,0),('out.1',0,1,1,1,2,0),('tanh',3,1,1,2,0,0)]
    rows=[];packed=bytearray();gb=[];weights={};prev='input'
    for index,(name,op,div,stride,src,dst,skip) in enumerate(specs):
        wb=len(packed);gbase=len(gb)
        if op==0:
            m=n.get_submodule(name);c=m.conv if hasattr(m,'conv') else m
            ci=4 if index==0 else c.in_channels;co=math.ceil(c.out_channels/4)*4;rc=c.out_channels
            qw,ws=quant.weights[name];arr=np.zeros((co,ci,3,3),dtype=np.int8);arr[:rc,:c.in_channels]=qw.cpu().numpy().astype(np.int8);weights[name]=arr
            for og in range(0,co,4):
                for ig in range(0,ci,2):packed.extend(arr[og:og+4,ig:ig+2].tobytes());packed.extend(bytes(24))
            si=r['activation_scales'][prev];so=r['activation_scales'][name];sw=float(ws.flatten()[0]);A=round(si*sw/so*2**24)
            biasq=torch.round(c.bias.detach().cpu()/(si*sw)).to(torch.int64).tolist();Bs=[v*A for v in biasq]+[0]*(co-rc)
            assert A>0 and all(-2**31<=v<2**31 for v in Bs)
            for ch in range(co):gb.append(((Bs[ch]&0xffffffff)<<32)|((A if ch<rc else 0)&0xffffffff))
            relu=hasattr(m,'act') and isinstance(m.act,torch.nn.ReLU);flags=stride|(int(relu)<<17)
            prev=name
        else:
            ci=co=rc=3 if op==3 else 4;flags=1
            A=0;Bs=[]
            if op==2:
                assert r['activation_scales']['enc.3']==r['activation_scales']['res.c2']==r['activation_scales']['res.add']
                prev='res.add'
        banks=(src<<16)|(dst<<8)|skip
        word=(op<<200)|((24//div)<<184)|((32//div)<<168)|(co<<152)|(ci<<136)|(flags<<104)|(banks<<72)|(wb<<40)|(gbase<<8)|rc
        rows.append({'index':index,'name':name,'op':op,'div':div,'stride':stride,'src':src,'dst':dst,'skip':skip,'ci':ci,'co':co,'rc':rc,'relu':bool(flags&(1<<17)),'wb':wb,'gb':gbase,'A':A,'B':Bs,'descriptor':f'{word:052x}'})
    assert len(packed)==2112
    mem(ROOT/'a4_weights.mem',[int.from_bytes(packed[i:i+32],'little') for i in range(0,len(packed),32)],64)
    mem(ROOT/'a4_coeff.mem',gb+[0]*(64-len(gb)),16)
    lut=np.array([round((math.tanh((i-128)*r['activation_scales']['out.1'])*.5+.5)*255) for i in range(256)],dtype=np.int64)
    mem(ROOT/'a4_tanh.mem',lut,2)
    (ROOT/'descriptors.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
    def reference(codes,width,height,label):
        banks={0:torch.tensor(codes.transpose(2,0,1),dtype=torch.float32,device='cuda')[None]};details=[]
        folder=ROOT/label;folder.mkdir()
        for d in rows:
            x=banks[d['src']]
            if d['op']==0:
                w=torch.tensor(weights[d['name']],dtype=torch.float32,device='cuda')
                acc=F.conv2d(F.pad(x,(1,1,1,1),mode='reflect'),w,stride=d['stride']).cpu().numpy().astype(np.int64)
                b=np.array(d['B'],dtype=np.int64)[None,:,None,None]
                y=rne(acc*d['A']+b,24)
                if d['relu']:y=np.maximum(y,0)
                y=np.clip(y,-127,127)[:,:d['rc']]
            elif d['op']==1:y=F.interpolate(x,scale_factor=2,mode='nearest').cpu().numpy().astype(np.int64)
            elif d['op']==2:y=np.clip(x.cpu().numpy().astype(np.int64)+banks[d['skip']].cpu().numpy().astype(np.int64),-127,127)
            else:y=lut[x.cpu().numpy().astype(np.int64)+128]
            raw=(y[0].transpose(1,2,0)&255).astype(np.uint8).tobytes()
            (folder/f'layer{d["index"]:02d}.bin').write_bytes(raw)
            mem(folder/f'layer{d["index"]:02d}.mem',raw,2)
            details.append({'index':d['index'],'shape':list(y.shape[1:]),'crc32':f'{zlib.crc32(raw):08X}'})
            banks[d['dst']]=torch.tensor(y,dtype=torch.float32,device='cuda')
        mem(folder/'input.mem',codes.tobytes(),2)
        (folder/'input.bin').write_bytes(codes.tobytes())
        (folder/'layers.json').write_text(json.dumps(details,indent=2),encoding='utf-8')
        Image.fromarray(y[0].transpose(1,2,0).astype(np.uint8)).save(folder/'output.png')
        return details[-1]['crc32']
    # Small-image operator/network tests, independent of the validation/calibration sets.
    for scale in [1,2]:
        width,height=32*scale,24*scale
        with Image.open('D:/aidrawer/data/val2017/000000000139.jpg') as im:rgb=np.array(im.convert('RGB').resize((width,height),Image.Resampling.BICUBIC))
        codes=np.concatenate([rgb>>1,np.zeros((height,width,1),dtype=np.uint8)],axis=2)
        reference(codes,width,height,f'test{width}x{height}')
    golden=[]
    for i in [0,1]:
        asset=PROJECT/'slideshow_assets'/f'nn_picture{i}_flash.bin';data=asset.read_bytes()[32:]
        codes=np.frombuffer(data,dtype=np.uint8).reshape(480,640,4).copy()
        crc=reference(codes,640,480,f'picture{i}_640')
        golden.append({'index':i,'input_crc32':f'{zlib.crc32(data):08X}','output_crc32':crc})
    (ROOT/'golden_crc.json').write_text(json.dumps(golden,indent=2),encoding='utf-8')
    (ROOT/'manifest.json').write_text(json.dumps({'model_sha256':q.digest(q.ROOT/'a4_deployment_review_3000/a4_bn_folded_fp32.pth'),'weight_bytes':2112,'coefficient_entries':len(gb),'layers':13,'arithmetic':'RNE int8, bias folded into fixed SA24 A/B, reflection padding, same-scale saturating residual, RGB888 tanh LUT','golden':golden},indent=2),encoding='utf-8')
    print(ROOT,json.dumps(golden),flush=True)

if __name__=='__main__':main()
