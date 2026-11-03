"""Offline verification of submitted sources, final Flash and Efinity references."""
from pathlib import Path
import json,hashlib,struct,zlib,xml.etree.ElementTree as ET
P=Path(__file__).resolve().parent
manifest=json.loads((P/'MANIFEST.json').read_text('utf-8'))
for f in manifest['files']:
    p=P/f['path'];assert p.is_file(),f['path']
    assert p.stat().st_size==f['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==f['sha256'],f['path']
F=P/'01_FPGA';missing=[]
for node in ET.parse(F/'ti60f225_oob.xml').iter():
    tag=node.tag.split('}')[-1]
    if tag in ['design_file','sdc_file','peri_file','default_peri_file']:
        name=node.get('name');
        if name and not (F/name).is_file():missing.append(name)
assert not missing,missing
raw=(P/'04_烧录文件/OSD_SIMPLE_SELECTED5_FULL_FLASH.bin').read_bytes()
assert bytes.fromhex((P/'04_烧录文件/OSD_SIMPLE_SELECTED5_FULL_FLASH.hex').read_text('ascii'))==raw
weights=(F/'flash_assets/a4_dual_models_flash.bin').read_bytes()
assert len(raw)==4214816 and raw[0x400000:]==weights
assert weights[:4]==b'NNW1' and len(weights)==20512
version,length,crc=struct.unpack_from('<III',weights,4)
assert version==1 and length==20480 and zlib.crc32(weights[32:])==crc
slots=json.loads((F/'flash_assets/dual_model_manifest.json').read_text('utf-8'))['slots']
assert len(slots)==5
for i,s in enumerate(slots):assert hashlib.sha256(weights[32+i*4096:32+(i+1)*4096]).hexdigest()==s['sha256']
assert len(set(s['sha256'] for s in slots))==5
N=P/'06_模型训练与分析';names=['retro','blueprint','emboss','fine_pixel_first','glitch']
for i,name in enumerate(names):
    assert (N/f'weights/style{i}_{name}.bin').read_bytes()==weights[32+i*4096:32+(i+1)*4096],name
for i,name in [(1,'blueprint'),(2,'emboss')]:
    assert (N/f'runs/{name}/slot.bin').read_bytes()==weights[32+i*4096:32+(i+1)*4096],name
    assert (N/f'runs/{name}/model_best.pth').is_file()
for rel in ['software/a_image_session.c','software/a_image_session.h','software/a_net_service.c','software/c_image_backend.c',
            'outflow/ti60f225_oob.place','outflow/ti60f225_oob.troutingtraces','outflow/ti60f225_oob.vdb',
            'implementation_reference/ti60f225_oob.lbf','tools/rebuild.py','tools/verify_rtl.py',
            'verification/five_style_slots/test.sv','verification/simple_metrics_osd/test.sv']:
    assert (F/rel).is_file(),rel
binary=(F/'embedded_sw/soc/software/standalone/uart/nnObserverDemo/build/nnObserverDemo.bin').read_bytes()
rom=bytearray(32768)
for i in range(4):
    tokens=(F/f'ip/soc/EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin').read_text('ascii').split()
    assert len(tokens)==8192
    rom[i::4]=bytes(int(v,2) for v in tokens)
assert bytes(rom)==binary+bytes(32768-len(binary))
print('PASS: manifest, Efinity dependencies, full Flash, five-slot sources/checkpoints, CRC and 32KiB CPU ROM')
