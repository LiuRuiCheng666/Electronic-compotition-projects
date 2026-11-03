"""Create a separate full board source fork; do not enable or claim image functionality."""
from pathlib import Path,PurePosixPath
import hashlib,json,shutil,zipfile
P=Path(__file__).resolve().parents[1]
Z=Path('D:/FPGA_C/FINAL_THREE_VERSIONS_20261030/02_融合网口修正版_实板待测/V6_9_NETFIX_SOURCE_002a56f3_20261030.zip')
D=Path('D:/FPGA_C/V6_9_IMAGE_BOARD_DEV_20261030')
assert not D.exists(),'Do not overwrite an existing board integration checkout'
assert hashlib.sha256(Z.read_bytes()).hexdigest()=='242f48472511711790852b63ee82be4c17007d2533fd8be49961f20aa90301af'
D.mkdir()
with zipfile.ZipFile(Z)as z:
    root='V6_9_NETFIX_SOURCE_002a56f3/'
    manifest=json.loads(z.read(root+'ARCHIVE_MANIFEST.json'))
    for name,digest in manifest['files'].items():
        parts=PurePosixPath(name).parts
        assert '..'not in parts and not PurePosixPath(name).is_absolute()
        out=D.joinpath(*parts)
        assert out.resolve().is_relative_to(D.resolve())
        data=z.read(root+name)
        assert hashlib.sha256(data).hexdigest()==digest,('Source archive mismatch',name)
        out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(data)
overlays=list((P/'rtl').glob('net_image_*.v'))+[P/'rtl/video/rgbx_ddr_capture.v']
for f in overlays:
    out=D/f.relative_to(P);out.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(f,out)
for folder in ['host','software']:
    shutil.copytree(P/folder,D/folder,dirs_exist_ok=True)
for f in (P/'tests').iterdir():
    if f.is_file()and f.suffix in ['.py','.sv','.c','.h']:
        (D/'tests').mkdir(exist_ok=True);shutil.copy2(f,D/'tests'/f.name)
for f in P.glob('*VALIDATION.json'):shutil.copy2(f,D/('IMAGE_DEV_INHERITED_'+f.name))
project=D/'ti60f225_oob.xml'
s=project.read_text(encoding='utf-8')
anchor='    <efx:top_module name="ti60f225_oob_top" />'
assert anchor in s
entries='\n'.join('    <efx:design_file name="'+f.relative_to(P).as_posix()+'" version="default" library="default" />'for f in overlays if f.parent==P/'rtl')
s=s.replace(anchor,anchor+'\n'+entries)
project.write_text(s,encoding='utf-8')
(D/'BOARD_INTEGRATION_STATUS.json').write_text(json.dumps(dict(
    status='SOURCE_FORK_PREPARED_IMAGE_NOT_WIRED_NOT_BUILT',source_bit_sha256=manifest['source_bit_sha256'],
    board_verified=False,bit_generated=False,image_roundtrip_complete=False,
    baseline_source_archive_sha256=hashlib.sha256(Z.read_bytes()).hexdigest(),
    baseline_source_files_verified=len(manifest['files']),
    overlays={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in overlays},
    missing=['Top-level APB decode, capture hold and AXI ownership mux',
             'Private NN reset/start/runtime mux and normal completion isolation',
             'Model metadata switch interlock','Actual C image backend, CRC/pixel/result conversion',
             'Firmware RAM/stack budget and host integration','Physical CDC constraints, full map/route/STA',
             'Real image roundtrip simulation and board acceptance'],
    warning='Inherited baseline PASS reports do not certify this modified fork. No image service is enabled.'
),indent=2),encoding='utf-8')
(D/'00_图片板级接入开发状态.md').write_text('''# 图片板级接入开发工程（尚未接线，不可作为新版本烧录）

从已通过离线门禁的网口修正版源码ZIP逐文件校验SHA256后建立，独立目录，不修改封存网口版或原稳定版。

已加入图片后端RTL模块到项目文件列表，并覆盖已通过仿真的capture hold实现；hold参数默认关闭，顶层尚未接入图片APB/AXI/NN控制。因此现有固件仍不提供实际图片上传后端。

根目录原有审计/测试结果属于继承的网口基准，不能用于证明本工程修改通过。图片子系统继承证据使用IMAGE_DEV_INHERITED前缀；还必须重新跑板级综合、时序、全链路仿真和实板验收。当前无新bit。

实际工作缺口见BOARD_INTEGRATION_STATUS.json。没有重新训练或替换四款模型，不更改LED/按键、网卡或下载驱动。
''',encoding='utf-8')
print('Created independent board integration source fork:',D)
