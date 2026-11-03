"""Source-bound component regressions, explicitly NOT full-image/bit acceptance."""
from pathlib import Path
import hashlib,json
P=Path(__file__).resolve().parents[1]
def sha(f):return hashlib.sha256(f.read_bytes()).hexdigest()
expected={n+'_VALIDATION':'RTL_UNIT_PASS_NOT_BOARD_INTEGRATED'for n in ['LINE_DMA','LEASE','MAILBOX','DISPATCH','CAPTURE_HOLD','NN_LAUNCHER']}
expected.update(SERVICE_VALIDATION='RTL_SUBSYSTEM_PASS_NOT_BOARD_INTEGRATED',
 PRIVATE_NN_VALIDATION='ACTUAL_NN_LAUNCHER_RTL_PASS_NOT_FULL_BOARD_INTEGRATED',
 HOST_CONTROL_WAIT_VALIDATION='PASS',IMAGE_SESSION_C_VALIDATION='PASS',IMAGE_TRANSFER_VALIDATION='PASS',
 C_IMAGE_BACKEND_VALIDATION='NATIVE_C_BACKEND_PASS_REGISTER_DDR_FIXTURE_NOT_BOARD',
 IMAGE_RV32_BACKEND_VALIDATION='PASS',IMAGE_TOP_CONTROL_VALIDATION='EXTRACTED_TOP_CONTROL_RTL_PASS_FULL_CHIP_TIMING_PENDING',
 IMAGE_C_RTL_NN_COSIM='LIVE_C_RTL_NN_32X24_ROUNDTRIP_PASS',IMAGE_VIDEO_HOLD_VALIDATION='PRODUCTION_VIDEO_HOLD_PASS',
 IMAGE_COLD_ADMISSION_VALIDATION='PRODUCTION_COLD_IMAGE_ADMISSION_PASS')
reports=[]
for name,wanted in expected.items():
 f=P/(name+'.json');r=json.loads(f.read_text());assert r['status']==wanted,(name,r['status'])
 assert not r.get('image_roundtrip_complete',False)and not r.get('board_image_roundtrip',False)
 bindings=r.get('sha256',r.get('sources'));assert bindings,('unbound evidence',name)
 for n,h in bindings.items():assert sha(P/n)==h,('stale evidence',name,n)
 reports.append(dict(report=f.name,sha256=sha(f),bound_sources=len(bindings)))
src=P/'embedded_sw/soc/software/standalone/uart/nnObserverDemo/src'
for n in ['a_image_session.c','a_image_session.h']:
 assert sha(src/n)==sha(P/'software'/n),('Production session differs from tested portable source',n)
(P/'IMAGE_OFFLINE_REGRESSIONS.json').write_text(json.dumps(dict(
 status='SEVENTEEN_SOURCE_BOUND_REPORTS_PASS_WITH_32X24_JOINT_TEST_PHYSICAL_PENDING',reports=reports,
 production_modified=True,board_connected=False,board_verified=False,bit_generated=False,
 image_roundtrip_complete=False,
 joint_image_test=dict(width=32,height=24,actual_c_rtl_nn=True,bytes_compared=2304,production_720p_jointly_tested=False),
 missing=['Production 720p combined image verification (C and NN separately covered through 720p)',
 'Current image branch physical resource fit, full route and independent setup/hold STA',
 'New bit generation and boot RAM readback','Physical startup, Ethernet/image loop and video recovery']
),indent=2))
print('PASS:',len(reports),'source-bound reports including live 32x24 C/RTL/NN roundtrip; 720p joint, bit and board NOT accepted')
