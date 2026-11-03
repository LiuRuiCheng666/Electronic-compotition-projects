"""Actual extracted top/RTL admission without any camera/HDMI frame."""
from pathlib import Path
import hashlib,json,re,subprocess
P=Path(__file__).resolve().parents[1];D=P/'tests/image_cold_admission_run';D.mkdir(exist_ok=True)
base=P/'tests/top_control_run/test.sv';assert base.exists(),'Run run_top_control.py first'
s=base.read_text();a=s.index(' initial begin\n  repeat(5)');b=s.index('\n initial begin #2000000',a)
s=s[:a]+''' initial begin
  snapshot_pipeline_ready=0;
  repeat(5)@(negedge mipi_tx_feedback100);vid_rst_n=1;repeat(10)@(negedge core_clk);
  command(0,0,0,0,0,1);repeat(20)@(negedge core_clk);
  $display("COLD phase=%0d capture_ack=%b capture_idle=%b snapshot_ready=%b weights_ready=%b",image_phase,image_hold_ack,image_capture_idle,snapshot_pipeline_ready,weights_boot_ready);
  command(1,0,0,0,0,0);
  if(!image_active||!image_axi_owner)$fatal(1,"cold network lease not granted");
  g=image_generation;command(4,g,0,0,0,1);repeat(20)@(negedge core_clk);
  if(image_active||image_pause||image_axi_owner||starts!=0)$fatal(1,"cold cancel or NN accounting");
  // A real normal compute task still blocks acquisition. A mere pending
  // publication is independent because private buffers are disjoint.
  style_inference_idle=0;
  command(0,0,0,0,0,1);repeat(20)@(negedge core_clk);
  command(1,0,0,0,0,1);
  if(image_active||image_phase!=1)$fatal(1,"normal compute fence bypassed");
  style_inference_idle=1;snapshot_locked=1;repeat(20)@(negedge core_clk);
  command(1,0,0,0,0,1);
  if(image_active||image_phase!=1)$fatal(1,"snapshot lock bypassed");
  snapshot_locked=0;repeat(20)@(negedge core_clk);
  command(1,0,0,0,0,0);g=image_generation;
  command(4,g,0,0,0,1);repeat(20)@(negedge core_clk);
  if(image_active||image_pause||image_axi_owner||starts!=0)$fatal(1,"second cancel failed");
  $display("PASS: actual extracted top admits and releases private network lease before any video frame");$finish;
 end
'''+s[b:]
(D/'test.sv').write_text(s)
sources=[P/'rtl/hdmi_reset_release.v']+sorted((P/'rtl').glob('net_image_*.v'))+[D/'test.sv']
(D/'run.do').write_text('\n'.join(['onerror {quit -code 1}','vlib work','vmap work work','vlog -sv '+' '.join('"'+f.as_posix()+'"'for f in sources),'vsim -c work.tb','run -all','quit -code 0']))
r=subprocess.run(['D:/ModelSim/win64/vsim.exe','-c','-l','sim.log','-do','run.do'],cwd=D,capture_output=True,text=True,errors='replace');log=r.stdout+r.stderr
(D/'output.log').write_text(log);print('\n'.join(x for x in log.splitlines()if any(k in x for k in ['PASS:','COLD','Fatal','Error:'])),flush=True)
passed=r.returncode==0 and 'PASS:'in log and '** Fatal'not in log
sources +=[P/'rtl/ti60f225_oob_top.v',base,Path(__file__)]
(P/'IMAGE_COLD_ADMISSION_VALIDATION.json').write_text(json.dumps(dict(status='PRODUCTION_COLD_IMAGE_ADMISSION_PASS'if passed else'FAIL_COLD_NETWORK_ADMISSION_BLOCKS_FINAL_RELEASE',
 board_verified=False,scope='Actual top control slices and image RTL, no prior video frame. External capture and NN behavioral; no physical board.',
 sha256={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources}),indent=2))
assert passed,'Network-only cold admission failed; no final image release'
