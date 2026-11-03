"""Actual NN RTL at private DDR addresses via the reset/start/drain launcher.

This is not network upload nor the board: DDR is a byte-addressed behavioral
model, but NN arithmetic and launch sequencing are actual production RTL.
"""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess
P=Path(__file__).resolve().parents[1]
S=P if (P/'integration_tests/eth_nn_final/NN_32x24_slot0_engine1/test.sv').is_file() else Path('D:/FPGA_C/V6_9_ETH_NETFIX_DEV_20261029')
F=S/'integration_tests/eth_nn_final/NN_32x24_slot0_engine1'
D=P/'tests/private_nn_run';D.mkdir(exist_ok=True)
for f in list(P.glob('*.mem'))+list(F.glob('*.mem')):shutil.copy2(f,D/f.name)
s=(F/'test.sv').read_text(encoding='utf-8')
old="reg clk=0,rst_n=0,select_ext=1,start=0;"
assert old in s
s=s.replace(old,"reg clk=0,rst_n=0,select_ext=1;wire start;")
bind='.done(done[1]),.pass(pass[1]),.fail(fail[1]),.busy(),'
assert bind in s
s=s.replace(bind,bind.replace('.busy(),','.busy(private_busy),'))
s=s.replace('.rst_n(rst_n)', '.rst_n(rst_n && private_reset_n)')
s=s.replace('.rst_n(rst_n && select_ext)', '.rst_n(rst_n && select_ext && private_reset_n)')
s=s.replace('.rst_n(rst_n && !select_ext)', '.rst_n(rst_n && !select_ext && private_reset_n)')
s=s.replace('if(rst_n)', 'if(rst_n && private_reset_n)').replace('if(rst_n && dut1.', 'if(rst_n && private_reset_n && dut1.')
for old,new in [('02000000','07800000'),('02400000','07c00000'),('06000000','07c00000'),('06400000','08000000')]:
    s=s.replace("32'h"+old,"32'h"+new)
declarations='''
reg private_owner=0,private_req=0,weights_ready=0;
wire private_ready,private_reset_n,private_busy,private_done,private_drained,private_error;
wire private_quiet;
integer private_starts=0;
'''
wiring='''
assign private_quiet=!wr_active&&!rd_active&&!bvalid&&!rvalid&&!awvalid&&!arvalid&&!wvalid;
net_image_nn_launcher launcher(.clk(clk),.root_reset_n(rst_n),.owner(private_owner),
 .request_valid(private_req),.request_ready(private_ready),.weights_ready(weights_ready),.weights_failed(1'b0),
 .core_busy(private_busy),.core_done(done[1]),.core_pass(pass[1]),.core_fail(fail[1]),.core_fault(3'd0),
 .memory_quiet(private_quiet),.local_reset_n(private_reset_n),.core_start(start),
 .job_done(private_done),.job_drained(private_drained),.job_error(private_error),.debug_state());
always @(posedge clk)if(rst_n&&start)private_starts=private_starts+1;
'''
s=s.replace('module tb_camera_nn_external;', 'module tb_camera_nn_external;\n'+declarations)
s=s.replace('task launch;begin',wiring+'\ntask launch;begin')
new_launch='''task launch;begin
 @(negedge clk);private_owner=1;private_req=1;
 for(t=0;t<1000&&!private_ready;t=t+1)@(negedge clk);
 if(!private_ready)$fatal(1,"private launcher did not arm");
 @(negedge clk);private_req=0;
 for(t=0;t<30000000&&!private_done;t=t+1)@(posedge clk);
 if(!private_done||!private_drained||private_error||!pass[1]||fail[1]||errors[1]!=0)
  $fatal(1,"private actual NN completion failed");
 $display("METRIC private_NN input=%h output=%h cycles_including_launch=%0d",runtime_input,runtime_output,t);
 @(negedge clk);private_owner=0;repeat(5)@(negedge clk);
end endtask'''
s,n=re.subn(r'task launch;begin.*?end endtask',lambda _:new_launch,s,count=1,flags=re.S);assert n==1
old="@(negedge clk);cfg_we=0;for(frame_number=0;frame_number<2;frame_number=frame_number+1)begin"
assert old in s;s=s.replace(old,old.replace('cfg_we=0;','cfg_we=0;weights_ready=1;'))
old="@(negedge clk);rst_n=0;repeat(5)@(negedge clk);rst_n=1;repeat(5)@(negedge clk);"
assert old in s;s=s.replace(old,'repeat(5)@(negedge clk);')
s=s.replace('$display("PASS: complete32x24 NN',
    'if(private_starts!=2)$fatal(1,"private model ran more/less than twice");\n $display("PASS: actual private launcher + complete32x24 NN')
s=s.replace('FRAMES count=2 per_frame_reset=1 metadata_retained=1','FRAMES count=2 launcher_reset=1 root_reset_between_frames=0 metadata_retained=1')
(D/'test.sv').write_text(s,encoding='utf-8')
sources=sorted((P/'rtl/nn/rtl').glob('*.v'))+[P/'rtl/net_image_nn_launcher.v']
E=Path('D:/Efinity/2026.1/sim_models/verilog')
sources += [E/n for n in ['efx_dsp48.v','efx_dpram10.v','efx_ram10.v']]+[D/'test.sv']
(D/'run.do').write_text('\n'.join(['onerror {quit -code 1}','vlib work','vmap work work',
    'vlog -sv -timescale 1ns/1ps '+' '.join('"'+f.as_posix()+'"'for f in sources),
    'vsim -c work.tb_camera_nn_external','run -all','quit -code 0']),encoding='ascii')
r=subprocess.run([str(Path(os.environ.get('MODELSIM_BIN','D:/ModelSim/win64'))/'vsim.exe'),
    '-c','-l','sim.log','-do','run.do'],cwd=D,capture_output=True,text=True,errors='replace')
log=r.stdout+r.stderr;(D/'output.log').write_text(log,encoding='utf-8')
print('\n'.join(x for x in log.splitlines()if any(k in x for k in ['PASS:','Fatal','Error:','METRIC private_NN','FRAMES count'])),flush=True)
assert r.returncode==0 and 'PASS: actual private launcher' in log and '** Fatal'not in log
(P/'PRIVATE_NN_VALIDATION.json').write_text(json.dumps(dict(
    status='ACTUAL_NN_LAUNCHER_RTL_PASS_NOT_FULL_BOARD_INTEGRATED',board_verified=False,
    image_roundtrip_complete=False,frames=2,width=32,height=24,
    input_base='0x07800000',output_base='0x07c00000',root_reset_between_frames=False,
    golden_sha256=hashlib.sha256((D/'gold.mem').read_bytes()).hexdigest(),
    sha256={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in sources+list(D.glob('*.mem'))+[Path(__file__)]if f.is_relative_to(P)},
    scope='Actual production NN and private reset/start/drain launcher at private DDR addresses; integer byte comparison across two tasks. DDR behavioral model; network, conversion and board not integrated.'
),indent=2),encoding='utf-8')
