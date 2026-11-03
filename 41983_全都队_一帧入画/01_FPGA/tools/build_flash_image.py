"""Combine freshly built Efinity configuration and matching A4 flash weights (five active slots).
Only creates local files. Does not erase or program the board.
"""
from pathlib import Path
import argparse,re,struct,zlib,hashlib,json
def config_bytes(path):
    if path.suffix.lower() not in ('.bit','.hex'):raise ValueError('Use Efinity byte-per-line .hex or .bit')
    tokens=path.read_text(encoding='ascii').split()
    if not tokens or any(re.fullmatch(r'[0-9a-fA-F]{2}',v)is None for v in tokens):
        raise ValueError('Expected Efinity byte-per-line hex, not Intel HEX/S-record')
    data=bytes(int(v,16)for v in tokens)
    if re.search(rb'(?m)^Mode:\s*active\s*$',data[:256]) is None:
        raise ValueError('Full Flash image requires native SPI-active outflow .hex. JTAG .bit is passive and has different configuration commands; do not use it for SPI boot.')
    return data
def build(config,weights,extra=()):
    if not config or len(config)>0x400000:raise ValueError('FPGA configuration overlaps weight address 0x400000')
    if weights[:4]!=b'NNW1' or len(weights)<32:raise ValueError('Invalid NNW1 header')
    version,count,crc=struct.unpack_from('<III',weights,4)
    if version!=1 or count not in (8192,12288,16384,20480) or len(weights)!=count+32 or zlib.crc32(weights[32:])!=crc:
        raise ValueError('Weight version/size/CRC mismatch for A4 model slots')
    regions=[(0,config,'FPGA configuration'),(0x400000,weights,'A4 kernels, coefficients and tanh')]+list(extra)
    regions.sort()
    for a,b in zip(regions,regions[1:]):
        if a[0]+len(a[1])>b[0]:raise ValueError('Flash region overlap')
    end=max(a+len(v)for a,v,_ in regions)
    if end>0x800000:raise ValueError('8 MiB board Flash capacity exceeded')
    image=bytearray(b'\xff')*end
    for a,v,_ in regions:image[a:a+len(v)]=v
    return bytes(image),regions
def validate_camera_weight_length(root,weights):
    # Match the instantiated loader, not the legacy asset filename.
    top=(root/'rtl/ti60f225_oob_top.v').read_text(encoding='latin1')
    match=re.search(r'camera_nn_weight_boot_mux\s*#\((.*?)\)\s*u_weight_boot\s*\(',top,re.S)
    if match is None:raise ValueError('Cannot find active camera weight loader parameters')
    size=re.search(r'\.WEIGHT_BYTES\s*\(\s*(\d+)\s*\)',match.group(1))
    if size is None:raise ValueError('Cannot determine active WEIGHT_BYTES; refusing ambiguous image')
    expected=int(size.group(1))
    if len(weights)<32:raise ValueError('Missing NNW1 weight header')
    actual=struct.unpack_from('<I',weights,8)[0]
    if actual!=expected:
        raise ValueError(f'Weight header has {actual} bytes; active RTL requires {expected}. This causes boot fault NN:2. Use matching model assets.')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config',type=Path,required=True,help='Fresh Efinity SPI-active byte-per-line outflow/ti60f225_oob.hex (not JTAG .bit)')
    p.add_argument('--output',type=Path,default=Path('flash_assets/camera_nn_dual_model_combined'))
    p.add_argument('--weights',type=Path,help='Optional isolated candidate NNW1 weights; default is active project weights')
    p.add_argument('--manifest',type=Path,help='Manifest for selected weights; default is beside weights')
    p.add_argument('--include-test-pictures',action='store_true',help='Also retain the supplied picture assets at 0x500000/0x640000')
    a=p.parse_args();root=Path(__file__).resolve().parents[1]
    active_sources=list((root/'rtl').rglob('*.v'))+[root/'ti60f225_oob.sdc',root/'ti60f225_oob.peri.xml']
    newest=max(f.stat().st_mtime for f in active_sources)
    if a.config.stat().st_mtime < newest:
        raise ValueError('Configuration predates current RTL/clock/pin changes. Compile this project first; do not use the old outflow bitstream.')
    config=config_bytes(a.config)
    weight_file=a.weights or root/'flash_assets/a4_dual_models_flash.bin'
    manifest_file=a.manifest or weight_file.parent/'dual_model_manifest.json'
    w=weight_file.read_bytes()
    validate_camera_weight_length(root,w)
    manifest=json.loads(manifest_file.read_text(encoding='utf-8'))
    if hashlib.sha256(w[32:]).hexdigest()!=manifest['payload_sha256']:raise ValueError('Weights differ from delivered model')
    extra=[]
    if a.include_test_pictures:
        for i,addr in [(0,0x500000),(1,0x640000)]:
            f=root/f'slideshow_assets/nn_picture{i}_flash.bin';extra.append((addr,f.read_bytes(),f'legacy test picture{i}'))
    image,regions=build(config,w,extra);a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.with_suffix('.bin').write_bytes(image)
    with a.output.with_suffix('.hex').open('w',encoding='ascii',newline='\n')as f:
        for v in image:f.write(f'{v:02X}\n')
    report={'regions':[{'name':n,'start':f'0x{s:08X}','bytes':len(v),'end':f'0x{s+len(v)-1:08X}'}for s,v,n in regions],
            'weights_file':str(weight_file.resolve()),'weights_payload_sha256':hashlib.sha256(w[32:]).hexdigest(),
            'configuration_mode':'SPI active','configuration_source_file_sha256':hashlib.sha256(a.config.read_bytes()).hexdigest(),
            'configuration_file':str(a.config.resolve()),'configuration_sha256':hashlib.sha256(config).hexdigest(),
            'combined_sha256':hashlib.sha256(image).hexdigest(),'note':'Use SPI programmer at address0; includes configuration and weights. Compile current project first.'}
    a.output.with_suffix('.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('Created',a.output.with_suffix('.hex'),'and .bin;',len(image),'bytes')
if __name__=='__main__':main()
