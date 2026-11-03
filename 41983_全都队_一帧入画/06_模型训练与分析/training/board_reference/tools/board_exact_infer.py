"""A4 integer reference from deployed Flash bytes, plus training/display comparisons.
No export, training, FPGA configuration edits or hardware access.
"""
import argparse, hashlib, json, math, re, struct, sys, zlib
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
import torch
import torch.nn.functional as F

PROJECT=Path(__file__).resolve().parents[1]
TRAIN_CODE=Path('D:/aidrawer/training_experiments/MantisShrimp/20261009_A4_Paired_Pseudocolor')
RUN=Path('D:/aidrawer/output/MantisShrimp/20261009_A4_Paired_Pseudocolor/runs/a4')
NAMES=['enc.0','enc.1','enc.2','enc.3','res.c1','res.c2','dec.1','dec.3','out.1']
CINS=[4,4,4,8,4,4,4,4,4]
COUTS=[4,4,8,4,4,4,4,4,3]
STRIDES=[1,1,2,2,1,1,1,1,1]
RELU=[True,True,True,True,True,False,True,True,False]

def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def load_slots(device,asset_dir=None):
    asset_dir=asset_dir or PROJECT/'flash_assets'
    blob=(asset_dir/'a4_dual_models_flash.bin').read_bytes()
    version,size,crc=struct.unpack_from('<III',blob,4)
    assert blob[:4]==b'NNW1' and version==1 and size in (8192,12288,16384)
    payload=blob[32:];assert len(payload)==size and zlib.crc32(payload)==crc
    manifest=json.loads((asset_dir/'dual_model_manifest.json').read_text(encoding='utf-8'))
    assert hashlib.sha256(payload).hexdigest()==manifest['payload_sha256']
    result=[]
    assert len(manifest['slots'])==size//4096
    assert manifest.get('model_count',size//4096)==size//4096
    for slot in range(size//4096):
        data=payload[slot*4096:(slot+1)*4096]
        assert hashlib.sha256(data).hexdigest()==manifest['slots'][slot]['sha256']
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
    text=(PROJECT/'rtl/nn/rtl/camera_tone_mapper.v').read_text()
    pairs=re.findall(r"8'd(\d+):tone_gain=12'd(\d+);",text)
    table=np.zeros(256,dtype=np.uint32)
    assert len(pairs)==256
    for index,value in pairs:table[int(index)]=int(value)
    return table

def displayed(rgb,table):
    gain=table[rgb.max(axis=2)]
    return np.minimum((rgb.astype(np.uint32)*gain[:,:,None])>>8,255).astype(np.uint8)

def color_stats(rgb):
    flat=rgb.reshape(-1,3)
    keys=(flat[:,0].astype(np.uint32)<<16)|(flat[:,1].astype(np.uint32)<<8)|flat[:,2]
    unique,counts=np.unique(keys,return_counts=True);order=counts.argsort()[-5:][::-1]
    return {'unique_rgb_colors':len(unique),'unique_channel_levels':[len(np.unique(flat[:,i])) for i in range(3)],
            'near_black_channel_fraction':[float((flat[:,i]<8).mean()) for i in range(3)],
            'near_white_channel_fraction':[float((flat[:,i]>247).mean()) for i in range(3)],
            'top5_exact_color_fraction':float(counts[order].sum()/len(flat)),
            'top_colors':[{'rgb':[int(k>>16),int((k>>8)&255),int(k&255)],'fraction':float(n/len(flat))}
                          for k,n in zip(unique[order],counts[order])]}

def preprocess(path,mode):
    with Image.open(path) as im:
        im=im.convert('RGB')
        if mode=='camera1080':
            im=im.resize((1920,1080),Image.Resampling.BICUBIC)
            array=np.array(im)
            x=240+(9*np.arange(640))//4;y=(9*np.arange(480))//4
            return array[y[:,None],x[None,:]]
        return np.array(im.resize((640,480),Image.Resampling.BICUBIC))

def panel(images,labels,footer):
    p=Image.new('RGB',(320*len(images),278),'white');d=ImageDraw.Draw(p)
    for i,(rgb,label) in enumerate(zip(images,labels)):
        d.text((i*320+6,5),label,fill='black')
        p.paste(Image.fromarray(rgb).resize((320,240)),(i*320,24))
    d.text((6,265),footer,fill='black')
    return p

def write_mem(p,data):p.write_text(''.join(f'{int(v):02x}\n' for v in data),encoding='ascii')

def write_gallery(output,report):
    import html
    text='''<!doctype html><html><meta charset="utf-8"><title>A4板上逻辑推理对照</title><style>body{font:16px sans-serif;background:#f4f6f8;margin:24px}img{max-width:100%;border:1px solid #ddd}article{background:white;padding:14px;margin:18px 0}a{color:#1565c0}</style>'''
    text+=f'<h1>A4板上逻辑：{len(report["images"])}张图片对照</h1><p>五列：原图 → 规则目标（NOT A4）→ 最终导出A4浮点 → 板上整数A4 → 板上显示色调曲线。</p>'
    text+=f'<p>浮点与整数平均MAE {report["mean_mae_u8"]:.2f}/255，PSNR {report["mean_psnr_db"]:.2f}dB。使用真实Flash数据；没有模拟摄像头ISP或板上时序/内存异常。</p>'
    bn=report.get('bn_checkpoint_audit')
    if bn:
        text+=f'<p><b>BN校准前后只有运行均值/方差不同，可学习参数全部相同。对规则目标的误差从{bn["mean_step3000_vs_target_mae_u8"]:.2f}升到{bn["mean_final_vs_target_mae_u8"]:.2f}/255。</b></p><p>BN四列：规则目标 → 第3000步、最终BN校准前 → 最终BN校准后 → 板上整数输出。</p>'
    for row in report['images']:
        folder=html.escape(Path(row['folder']).name,quote=True)
        name=html.escape(Path(row['input']).name)
        text+=f'<article><h2>{name}</h2><a href="{folder}/comparison.png"><img src="{folder}/comparison.png"></a>'
        if bn:text+=f'<p>BN校准前后：</p><a href="{folder}/BN_calibration_comparison.png"><img src="{folder}/BN_calibration_comparison.png"></a>'
        text+=f'<p><a href="{folder}/board_integer_mantis.png">螳螂虾整数输出</a> · <a href="{folder}/board_HDMI_tone_mantis.png">螳螂虾显示颜色</a> · <a href="{folder}/board_integer_original.png">原风格整数输出</a> · <a href="{folder}/diagnostics.json">逐层统计</a></p></article>'
    (output/'index.html').write_text(text+'</html>',encoding='utf-8')

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--input',type=Path)
    ap.add_argument('--input-dir',type=Path,default=Path('D:/aidrawer/data/student_eval_external'))
    ap.add_argument('--count',type=int,default=0,help='0 processes every external image')
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--preprocess',choices=['nn640','camera1080'],default='nn640')
    ap.add_argument('--rgbx-dump',type=Path,help='640x480x4 DDR input bytes: already quantized R,G,B,0')
    ap.add_argument('--device',default='cuda' if torch.cuda.is_available() else 'cpu')
    ap.add_argument('--trace',action='store_true',help='Save every integer activation as a compressed NPZ')
    ap.add_argument('--asset-dir',type=Path,default=PROJECT/'flash_assets',help='Active or isolated candidate Flash asset directory')
    a=ap.parse_args()
    if a.output.exists():raise RuntimeError('Preserve existing results; choose a new output directory')
    a.output.mkdir(parents=True)
    torch.set_num_threads(4)
    slots,manifest=load_slots(a.device,a.asset_dir);tone=tone_table()
    sys.path.insert(0,str(TRAIN_CODE))
    from models import Student
    from target import pseudocolor,load_rules
    model=Student().to(a.device).eval()
    checkpoint=Path(manifest['model_source'])
    assert sha(checkpoint)==manifest['model_sha256']
    model.load_state_dict(torch.load(checkpoint,map_location=a.device,weights_only=True),strict=True)
    rules=load_rules(RUN/'rules.json')
    # This independent stored reference was previously compared to actual RTL.
    golden_dir=Path(manifest['slots'][1]['export_directory']) if manifest['slots'][1].get('export_directory') else (a.asset_dir if (a.asset_dir/'input32.mem').exists() else Path(manifest.get('export_directory',PROJECT/'flash_assets/mantis_export_20261011')))
    golden_in=np.array([int(x,16) for x in (golden_dir/'input32.mem').read_text().split()],dtype=np.uint8).reshape(24,32,4)
    actual,_,_=infer_codes(golden_in,slots[1])
    expected=bytes(int(x,16) for x in (golden_dir/'output32.mem').read_text().split())
    assert actual.tobytes()==expected, 'Mantis32x24 golden mismatch'
    print('PASS: Flash-decoded integer inference matches all2304 bytes of the RTL-checked mantis golden',flush=True)
    # Export both current slots for an actual RTL comparison below.
    oracle=a.output/'rtl_oracle';oracle.mkdir()
    for index,slot in enumerate(slots):
        out,_,_=infer_codes(golden_in,slot)
        write_mem(oracle/f'model{index}_input.mem',golden_in.ravel())
        write_mem(oracle/f'model{index}_output.mem',out.ravel())
    paths=[a.input] if a.input else sorted(p for p in a.input_dir.iterdir() if p.suffix.lower() in ['.jpg','.jpeg','.png','.bmp'])
    if a.count:paths=paths[:a.count]
    if a.rgbx_dump:paths=[a.rgbx_dump]
    assert paths
    results=[];panels=[]
    with torch.no_grad():
        for i,path in enumerate(paths):
            folder=a.output/f'{i:02d}_{path.stem}';folder.mkdir()
            if a.rgbx_dump:
                codes=np.frombuffer(path.read_bytes(),np.uint8).reshape(480,640,4).copy()
                assert np.max(codes[:,:,:3])<=127 and not codes[:,:,3].any()
                rgb=(codes[:,:,:3].astype(np.uint16)*2).astype(np.uint8)
            else:
                rgb=preprocess(path,a.preprocess)
                codes=np.concatenate([rgb>>1,np.zeros((480,640,1),np.uint8)],2)
            x=torch.tensor(rgb.transpose(2,0,1).copy(),device=a.device,dtype=torch.float32)[None]/255
            fp=model(x).clamp(0,1)
            target=pseudocolor(x,rules).clamp(0,1)
            fp_u8=torch.round(fp*255).byte()[0].permute(1,2,0).cpu().numpy()
            target_u8=torch.round(target*255).byte()[0].permute(1,2,0).cpu().numpy()
            out,stats,trace=infer_codes(codes,slots[1],a.trace)
            original,original_stats,_=infer_codes(codes,slots[0])
            if len(slots)>2:
                ukiyo,ukiyo_stats,_=infer_codes(codes,slots[2])
                Image.fromarray(ukiyo).save(folder/'board_integer_ukiyo.png')
                Image.fromarray(displayed(ukiyo,tone)).save(folder/'board_HDMI_tone_ukiyo.png')
                (folder/'expected_ukiyo_rgb.bin').write_bytes(ukiyo.tobytes())
                (folder/'ukiyo_diagnostics.json').write_text(json.dumps(ukiyo_stats,indent=2),encoding='utf-8')
            hdmi=displayed(out,tone)
            for name,img in [('input',rgb),('board_input_reconstructed',codes[:,:,:3]*2),('rule_target_NOT_A4',target_u8),
                             ('trained_A4_float',fp_u8),('board_integer_mantis',out),('board_HDMI_tone_mantis',hdmi),
                             ('board_integer_original',original),('board_HDMI_tone_original',displayed(original,tone))]:
                Image.fromarray(img).save(folder/(name+'.png'))
            (folder/'input_rgbx.bin').write_bytes(codes.tobytes())
            (folder/'expected_mantis_rgb.bin').write_bytes(out.tobytes())
            (folder/'expected_original_rgb.bin').write_bytes(original.tobytes())
            mse=float(np.mean(((fp_u8.astype(np.float64)-out)/255)**2))
            mae=float(np.abs(fp_u8.astype(np.float64)-out).mean())
            row={'input':str(path),'input_sha256':sha(path),'preprocess':a.preprocess if not a.rgbx_dump else 'exact_DDR_RGBX_dump',
                 'folder':str(folder),'float_vs_integer_psnr_db':-10*math.log10(max(mse,1e-12)),
                 'float_vs_integer_mae_u8':mae,'integer_mantis_crc32':f'{zlib.crc32(out.tobytes()):08X}',
                 'stages':stats,'original_stages':original_stats,
                 'colors':{name:color_stats(img) for name,img in [('float',fp_u8),('integer',out),('HDMI_tone',hdmi),('rule_target',target_u8)]}}
            (folder/'diagnostics.json').write_text(json.dumps(row,indent=2),encoding='utf-8')
            if a.trace:np.savez_compressed(folder/'integer_activations.npz',**trace)
            pic=panel([rgb,target_u8,fp_u8,out,hdmi],['Input RGB','Rule target (NOT A4)','Trained A4 float','Board integer (DDR RGB)','Board display tone'],
                f'{path.name} | FP vs integer PSNR={row["float_vs_integer_psnr_db"]:.2f}dB MAE={mae:.2f}/255')
            pic.save(folder/'comparison.png');panels.append(pic);results.append(row)
            print(f'{i+1}/{len(paths)} {path.name}: PSNR={row["float_vs_integer_psnr_db"]:.2f}dB MAE={mae:.2f}',flush=True)
    report={'model_checkpoint':str(checkpoint),'checkpoint_sha256':manifest['model_sha256'],
            'flash_asset_sha256':sha(a.asset_dir/'a4_dual_models_flash.bin'),
            'arithmetic':'signed8 kernel/activation; exact integer accumulator; signed ties-to-even division; symmetric[-127,127]clamp; actual256entry tanh table; actualdisplay gain table',
            'preprocess_note':'nn640 uses training bicubic resize, then exactRGB>>1. camera1080 uses board coordinate crop/sample. Neither simulates sensor Bayer/ISP.',
            'rtl_golden_match':True,'images':results,'mean_psnr_db':float(np.mean([r['float_vs_integer_psnr_db'] for r in results])),
            'mean_mae_u8':float(np.mean([r['float_vs_integer_mae_u8'] for r in results]))}
    (a.output/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    write_gallery(a.output,report)
    sheet=Image.new('RGB',(1600,278*len(panels)),'white')
    for i,img in enumerate(panels):sheet.paste(img,(0,i*278))
    sheet.save(a.output/'contact_sheet.jpg',quality=95)
    worst=max(range(len(results)),key=lambda i:results[i]['float_vs_integer_mae_u8'])
    panels[worst].save(a.output/'largest_quantization_difference.png')
    print(f'COMPLETE: {a.output}; meanPSNR={report["mean_psnr_db"]:.2f}dB meanMAE={report["mean_mae_u8"]:.2f}',flush=True)

if __name__=='__main__':main()
