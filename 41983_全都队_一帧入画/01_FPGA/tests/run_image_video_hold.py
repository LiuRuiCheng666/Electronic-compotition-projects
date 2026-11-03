"""Actual scheduler with enable expression extracted from production top.
--proposed tests a not-yet-installed pause/restore gate, explicitly separately.
"""
from pathlib import Path
import argparse,hashlib,json,re,subprocess
P=Path(__file__).resolve().parents[1];ap=argparse.ArgumentParser();ap.add_argument('--proposed',action='store_true');a=ap.parse_args()
top=P/'rtl/ti60f225_oob_top.v';text=top.read_text();start=text.index('u_camera_nn_scheduler(')
expression=re.search(r'\.enable\(([^\n]+?)\),',text[start:])[1]
restore=''
if a.proposed:
 expression='shared_test_start && (weights_boot_ready || image_pause)'
 restore='''reg image_restore_wait=0;
 always @(posedge clk or negedge rst)if(!rst)image_restore_wait<=0;
 else if(image_active)image_restore_wait<=1;
 else if(weights_boot_ready)image_restore_wait<=0;
 assign image_pause=service_pause||image_restore_wait;
 '''
else:
 restore='assign image_pause=service_pause;'
 if '// BEGIN IMAGE_VIDEO_RESTORE' in text:
  restore=text.split('// BEGIN IMAGE_VIDEO_RESTORE',1)[1].split('// END IMAGE_VIDEO_RESTORE',1)[0]
  restore=restore.replace('core_clk','clk').replace('vid_rst_n','rst').replace('image_service_pause','service_pause')
D=P/'tests'/('image_video_hold_proposed'if a.proposed else'image_video_hold_run');D.mkdir(exist_ok=True)
s=r'''`timescale 1ns/1ps
module tb;
reg clk=0,rst=0;always #3.125 clk=~clk;
reg shared_test_start=1,weights_boot_ready=1,service_pause=0,image_active=0;
wire image_pause;
@@RESTORE@@
reg input_valid=0,nn_done=0;reg[31:0]input_id=1;
wire ready,start,display_enable;wire[31:0]display_base,display_id;wire fault;
integer nn_timer=0,starts=0;
camera_nn_compare_pipeline #(.FRAME_ATOMIC(1),.STYLE_TAG_EN(1),.CAT_FISHEYE_EN(0),.WARP_OVERLAP(0),.RUNTIME_FISHEYE(0)) dut(
 .clk(clk),.rst_n(rst),.enable(@@ENABLE@@),.current_model_id(2'd0),.roi_requested(2'd0),.fisheye_enable(1'b0),
 .req_valid(input_valid&&!image_pause),.req_ready(ready),.req_bank(2'd0),.req_addr(32'h02000000),.req_frame_id(input_id),
 .done_valid(),.done_ready(1'b1),.done_bank(),.done_frame_id(),.done_error(),
 .nn_start(start),.nn_reset_n(),.nn_done(nn_done),.nn_pass(1'b1),.nn_fail(1'b0),.display_fault(1'b0),
 .nn_input_base(),.nn_output_base(),.display_enable(display_enable),.display_base(display_base),.display_input_base(),
 .display_buffer(),.display_frame_id(display_id),.frame_shown(display_enable),.quiescent(1'b1),.publication_window(1'b1),.fault(fault),.inference_idle(),
 .display_model_id(),.display_roi_mode(),.display_fisheye_enable(),.warp_model_id(),.warp_fisheye_enable(),
 .warp_start(),.warp_done(1'b0),.warp_pass(1'b0),.warp_fail(1'b0),.warp_source_base(),.warp_dest_base());
always @(posedge clk)if(rst)begin
 nn_done<=0;
 if(start)begin nn_timer<=4;starts<=starts+1;end
 else if(nn_timer>0)begin nn_timer<=nn_timer-1;if(nn_timer==1)nn_done<=1;end
end
task send_frame(input[31:0]id);
 integer n;begin
  @(negedge clk);input_valid=1;input_id=id;n=0;
  while(!ready)begin @(negedge clk);n=n+1;if(n>1000)$fatal(1,"video admit stalled");end
  @(negedge clk);input_valid=0;
  n=0;while(!display_enable||display_id!=id)begin @(negedge clk);n=n+1;if(n>1000)$fatal(1,"video publication stalled");end
  repeat(5)@(negedge clk);
 end
endtask
reg[31:0]held_base;
initial begin
 repeat(5)@(negedge clk);rst=1;send_frame(1);held_base=display_base;
 // Private style metadata reload drops weights ready, but the immutable
 // video front must keep scanning while all new normal work is paused.
 service_pause=1;image_active=1;weights_boot_ready=0;input_valid=1;
 repeat(50)begin @(negedge clk);if(!display_enable||display_id!=1||display_base!=held_base||starts!=1)$fatal(1,"private metadata blanked/changed video front");end
 weights_boot_ready=1;repeat(5)@(negedge clk);
 // On release, normal-style metadata may need reloading as well.
 service_pause=0;image_active=0;weights_boot_ready=0;
 repeat(50)begin @(negedge clk);if(!display_enable||display_id!=1||display_base!=held_base||starts!=1||(input_valid&&!image_pause&&ready))$fatal(1,"restore metadata blanked video or admitted early");end
 input_valid=0;weights_boot_ready=1;repeat(5)@(negedge clk);if(image_pause)$fatal(1,"restore gate stuck");
 send_frame(2);if(starts!=2||fault)$fatal(1,"video did not resume exactly once");
 $display("PASS: real video scheduler retains front during private/restore metadata, rejects paused normal requests and resumes");$finish;
end
initial begin #1000000;$fatal(1,"video hold watchdog");end
endmodule'''.replace('@@RESTORE@@',restore).replace('@@ENABLE@@',expression)
(D/'test.sv').write_text(s)
sources=[P/'rtl/nn/rtl/camera_nn_compare_pipeline.v',D/'test.sv']
(D/'run.do').write_text('\n'.join(['onerror {quit -code 1}','vlib work','vmap work work','vlog -sv '+' '.join('"'+f.as_posix()+'"'for f in sources),'vsim -c work.tb','run -all','quit -code 0']))
r=subprocess.run(['D:/ModelSim/win64/vsim.exe','-c','-l','sim.log','-do','run.do'],cwd=D,capture_output=True,text=True,errors='replace');log=r.stdout+r.stderr
(D/'output.log').write_text(log);print('\n'.join(x for x in log.splitlines()if any(k in x for k in ['PASS:','Fatal','Error:'])),flush=True)
passed=r.returncode==0 and 'PASS:'in log and '** Fatal'not in log
report=dict(status=('ISOLATED_PROPOSAL_PASS_NOT_INSTALLED'if a.proposed else'PRODUCTION_VIDEO_HOLD_PASS')if passed else'FAIL',
 proposed_only=a.proposed,board_verified=False,scheduler_enable=expression,
 sha256={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources+[top,Path(__file__)]})
(P/('IMAGE_VIDEO_HOLD_PROPOSAL.json'if a.proposed else'IMAGE_VIDEO_HOLD_VALIDATION.json')).write_text(json.dumps(report,indent=2))
assert passed,'Image video hold failed; no final image release permitted'
