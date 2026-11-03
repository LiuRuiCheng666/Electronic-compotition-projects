"""Compile the actual connected top's control slices with real image RTL.
Whole-chip native map is separate; external NN/capture are behavioral here.
"""
from pathlib import Path
import hashlib,json,os,re,subprocess
P=Path(__file__).resolve().parents[1];D=P/'tests/top_control_run';D.mkdir(exist_ok=True)
top=P/'rtl/ti60f225_oob_top.v';t=top.read_text(encoding='utf-8')
def between(a,b):return t[t.index(a):t.index(b,t.index(a))]
decl=between('// Image task ownership','wire [1:0] m_awvalid, m_awready;')
control=between('// Do not withdraw any command','wire [3:0] boot_m_awid,boot_m_arid;')
instances=between('        assign image_sel=c_addr[15:8]','        assign c_rdata=image_sel?')
reset=between('wire live_nn_core_reset_n;','nn_ddr_selftest #(')
assert '.req_valid(copy_in_req_valid&&c_admit_enable&&!image_pause)'in t
assert '.req_ready(video_scheduler_req_ready)'in t
assert '.select_model(image_active?image_style:style_requested)'in t
assert '.inference_idle(style_inference_idle && image_phase!=5)'in t
assert '.can_lock(c_capture_allowed && snapshot_pipeline_ready && !image_pause)'in t
assert all('image_sel?image_apb_'+n in t for n in ['data','ready','error'])
body=(P/'tests/top_control_body.sv').read_text(encoding='utf-8')
for key,value in [('DECL',decl),('CONTROL',control),('INST',instances),('RESET',reset)]:body=body.replace('@@'+key+'@@',value)
(D/'test.sv').write_text(body,encoding='utf-8')
sources=[P/'rtl/hdmi_reset_release.v']+list((P/'rtl').glob('net_image_*.v'))+[D/'test.sv']
(D/'run.do').write_text('\n'.join(['onerror {quit -code 1}','vlib work','vmap work work',
 'vlog -sv '+' '.join('"'+f.as_posix()+'"'for f in sources),'vsim -c work.tb','run -all','quit -code 0']),encoding='ascii')
r=subprocess.run([str(Path(os.environ.get('MODELSIM_BIN','D:/ModelSim/win64'))/'vsim.exe'),'-c','-l','sim.log','-do','run.do'],cwd=D,capture_output=True,text=True,errors='replace')
log=r.stdout+r.stderr;(D/'output.log').write_text(log,encoding='utf-8')
print('\n'.join(x for x in log.splitlines()if any(n in x for n in ['PASS:','Fatal','Error:'])),flush=True)
assert r.returncode==0 and 'PASS:'in log and '** Fatal'not in log
sources += [top,P/'tests/top_control_body.sv',Path(__file__)]
(P/'IMAGE_TOP_CONTROL_VALIDATION.json').write_text(json.dumps(dict(
 status='EXTRACTED_TOP_CONTROL_RTL_PASS_FULL_CHIP_TIMING_PENDING',board_verified=False,image_roundtrip_complete=False,
 scope='Actual production top control blocks and real image RTL. External core/capture behavior, not pixel/model inference or full-chip simulation.',
 sha256={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources}
),indent=2),encoding='utf-8')
