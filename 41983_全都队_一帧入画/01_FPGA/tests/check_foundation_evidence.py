"""Verify only source-bound foundation tests; this is not a board/full-image gate."""
from pathlib import Path
import hashlib
import json
P=Path(__file__).resolve().parents[1]
reports=[]
expected={n:'RTL_UNIT_PASS_NOT_BOARD_INTEGRATED' for n in ['LINE_DMA','LEASE','MAILBOX','DISPATCH','CAPTURE_HOLD','NN_LAUNCHER']}
expected.update(SERVICE='RTL_SUBSYSTEM_PASS_NOT_BOARD_INTEGRATED',PRIVATE_NN='ACTUAL_NN_LAUNCHER_RTL_PASS_NOT_FULL_BOARD_INTEGRATED',
                HOST_CONTROL_WAIT='PASS',IMAGE_SESSION_C='PASS',IMAGE_TRANSFER='PASS')
for n,wanted in expected.items():
    f=P/(n+'_VALIDATION.json')
    r=json.loads(f.read_text(encoding='utf-8'))
    assert r['status']==wanted
    assert not r.get('image_roundtrip_complete',False) and not r.get('board_image_roundtrip',False)
    for name,digest in r['sha256'].items():
        assert hashlib.sha256((P/name).read_bytes()).hexdigest()==digest,('stale evidence',name)
    reports.append(dict(report=f.name,sha256=hashlib.sha256(f.read_bytes()).hexdigest()))
(P/'FOUNDATION_STATUS.json').write_text(json.dumps(dict(
    status='ELEVEN_SOURCE_BOUND_TEST_REPORTS_PASS_NOT_FULL_INTEGRATION',
    board_connected=False,board_verified=False,bit_generated=False,
    image_roundtrip_complete=False,production_modified=False,reports=reports,
    private_nn=dict(width=32,height=24,frames=2,actual_nn=True,ddr_behavioral_model=True),
    missing=['Board APB decode and CDC constraints','Capture hold board wiring and AXI port ownership',
             'Actual NN task runtime mux and completion isolation','Original-byte CRC, pixel conversion and result encoding',
             'Registered production protocol backend and real firmware RAM budget',
             'Full-chip resource/map/route/STA','Physical upload/inference/download and video recovery']
),indent=2),encoding='utf-8')
print('PASS: eleven source-bound test reports; full image integration and board test NOT complete')
