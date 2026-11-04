"""Offline verification of submitted sources, final Flash and Efinity references."""
from pathlib import Path
import json,hashlib,struct,zlib,re,xml.etree.ElementTree as ET
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
model_manifest=json.loads((F/'flash_assets/dual_model_manifest.json').read_text('utf-8'))
assert weights[32:]==(F/'flash_assets/a4_dual_models_payload.bin').read_bytes()
assert hashlib.sha256(weights[32:]).hexdigest()==model_manifest['payload_sha256']
assert len(slots)==5
for i,s in enumerate(slots):assert hashlib.sha256(weights[32+i*4096:32+(i+1)*4096]).hexdigest()==s['sha256']
assert len(set(s['sha256'] for s in slots))==5
N=P/'06_模型训练与分析';names=['retro','blueprint','emboss','fine_pixel_first','glitch']
for i,name in enumerate(names):
    assert (N/f'weights/style{i}_{name}.bin').read_bytes()==weights[32+i*4096:32+(i+1)*4096],name
for i,name in [(1,'blueprint'),(2,'emboss')]:
    assert (N/f'runs/{name}/slot.bin').read_bytes()==weights[32+i*4096:32+(i+1)*4096],name
    assert (N/f'runs/{name}/model_best.pth').is_file()
for record in json.loads((N/'SOURCE_INDEX.json').read_text('utf-8'))['files']:
    source=N/record['path']
    assert source.stat().st_size==record['bytes'] and hashlib.sha256(source.read_bytes()).hexdigest()==record['sha256'],record['path']
for rel in ['software/a_image_session.c','software/a_image_session.h','software/a_net_service.c','software/c_image_backend.c',
            'outflow/ti60f225_oob.place','outflow/ti60f225_oob.troutingtraces','outflow/ti60f225_oob.vdb',
            'implementation_reference/ti60f225_oob.lbf','tools/rebuild.py','tools/verify_rtl.py',
            'verification/five_style_slots/test.sv','verification/simple_metrics_osd/test.sv']:
    assert (F/rel).is_file(),rel
for host in (F/'host').glob('*.py'):
    assert host.read_text('utf-8')==(P/'03_网口工具/host'/host.name).read_text('utf-8'),host.name+' host copies differ'
assert (F/'host/a_image_transfer.py').read_text('utf-8')==(P/'02_网页应用/protocol/a_image_transfer.py').read_text('utf-8')
binary=(F/'embedded_sw/soc/software/standalone/uart/nnObserverDemo/build/nnObserverDemo.bin').read_bytes()
rom=bytearray(32768)
for i in range(4):
    tokens=(F/f'ip/soc/EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin').read_text('ascii').split()
    assert len(tokens)==8192
    rom[i::4]=bytes(int(v,2) for v in tokens)
assert bytes(rom)==binary+bytes(32768-len(binary))
for rel in ['05_技术资料/赛题提交总览.md','06_模型训练与分析/network.svg',
            '06_模型训练与分析/network_layers.csv','06_模型训练与分析/网络与参数统计.md',
            '07_性能验证/README.md','07_性能验证/原始证据/result.json',
            '07_性能验证/原始证据/现场录像.mp4','07_性能验证/浮雕标准网络对比/REPORT.json',
            '07_性能验证/tools/benchmark_matched_teacher.py','07_性能验证/evaluation_inputs.json']:
    assert (P/rel).is_file(),rel
for rel in ['01_FPGA/tools/rebuild.py','01_FPGA/tools/build_light_merge_firmware.py',
            '06_模型训练与分析/tools/prepare_training.py','06_模型训练与分析/tools/training_tone_reference.py',
            '06_模型训练与分析/tools/verify_training_copy.py',
            '07_性能验证/源码完整性终审/SOURCE_AUDIT.json',
            '07_性能验证/烧录重建复查/RECONSTRUCTION_CHECK.json',
            '07_性能验证/全流程重建核验/FULL_SOURCE_BUILD_CHECK.json']:
    assert (P/rel).is_file(),rel
timing=(P/'05_技术资料/ti60f225_oob.timing.rpt').read_text('utf-8')
setup,hold=timing.split('Setup (Max) Clock Relationship',1)[1].split('Hold (Min) Clock Relationship',1)
hold=hold.split('Clock Relationship Summary (end)',1)[0]
metrics=json.loads((P/'05_技术资料/实现指标.json').read_text('utf-8'))
for kind,section in [('setup',setup),('hold',hold)]:
    slack=[float(m[1]) for line in section.splitlines() if (m:=re.match(r'\s*\S+\s+\S+\s+-?\d+\.\d+\s+(-?\d+\.\d+)\s+\(',line))]
    assert slack and min(slack)>=0
    assert metrics['minimum_'+kind+'_slack_ns']==min(slack),(kind,min(slack))
print('PASS: manifest, Efinity dependencies, full Flash, five-slot sources/checkpoints/payload, CRC and 32KiB CPU ROM')
print('PASS: training provenance hashes and archived setup/hold summary match original timing report')
import runpy
runpy.run_path(str(P/'07_性能验证/tools/verify_evidence.py'),run_name='__main__')
