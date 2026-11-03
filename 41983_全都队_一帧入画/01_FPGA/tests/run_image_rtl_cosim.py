"""Live local C<->Tcl<->actual APB/CDC/DMA/NN RTL, byte DDR model.

No prerecorded backend responses, identity output, DPI compiler or board.
The tiny 32x24 NN fixture is intentional; production firmware remains 720p.
"""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess
P=Path(__file__).resolve().parents[1];D=P/'tests/image_rtl_cosim_run';D.mkdir(exist_ok=True)
F=P/'integration_tests/eth_nn_final/NN_32x24_slot0_engine1'
base=P/'tests/private_nn_run/test.sv';assert base.exists(),'Run run_private_nn.py first'
for f in list(P.glob('*.mem'))+list(F.glob('*.mem')):shutil.copy2(f,D/f.name)
pixels=[int(x,16)for x in (F/'net_in32.mem').read_text().split()]
assert len(pixels)==768
original=bytes(((p>>(8*i))&127)*2 for p in pixels for i in range(3))
gold=bytes(int(x,16)for x in (F/'gold.mem').read_text().split());assert len(gold)==2304
(D/'input.rgb').write_bytes(original);(D/'gold.rgb').write_bytes(gold)
s=base.read_text()
s=s.replace('module tb_camera_nn_external;','module tb;')
s=s.replace('reg private_owner=0,private_req=0,weights_ready=0;','wire private_owner,private_req;reg weights_ready=0;')
s=s.replace('reg clk=0,rst_n=0,select_ext=1;wire start;','reg clk=0,rst_n=0;wire select_ext=private_owner;wire start;')
start=s.index('nn_ddr_selftest #(');end=s.index('nn_ddr_selftest #(',start+1)
s=s[:start]+s[end:]
# Remove the old two-frame launch/stimulus, retaining real AXI memory,
# configuration and actual NN monitors.
s,n=re.subn(r'task launch;begin.*?end endtask','',s,count=1,flags=re.S);assert n==1
line=' for(i=0;i<768;i=i+1)for(n=0;n<4;n=n+1)mem[mem_index(32\'h07800000+i*4+n)]=input_pixels[i][n*8+:8];'
assert line in s;s=s.replace(line,' // Raw input DDR is populated only by the real C upload path.')
a=s.index(' @(negedge clk);cfg_we=0;weights_ready=1;for(frame_number=')
b=s.index('\nend\n',a)
s=s[:a]+" @(negedge clk);cfg_we=0;weights_ready=1;setup_ready=1;"+s[b:]
wiring=r'''
 reg cpu_clk=0;always #5 cpu_clk=~cpu_clk;
 reg setup_ready=0,host_req=0,host_done=0;
 reg[255:0]host_q=0,host_response=0;
 wire[31:0]r0=host_response[31:0],r1=host_response[63:32],r2=host_response[95:64],r3=host_response[127:96];
 wire[31:0]r4=host_response[159:128],r5=host_response[191:160],r6=host_response[223:192],r7=host_response[255:224];
 reg[15:0]paddr=0;reg psel=0,penable=0,pwrite=0;reg[31:0]pwdata=0;
 wire[31:0]prdata;wire pready,pslverror;
 wire image_owner,image_active;wire[3:0]image_phase;wire[31:0]image_generation;
 net_image_service service(.cpu_clk(cpu_clk),.core_clk(clk),.root_reset_n(rst_n),.cpu_reset(1'b0),
  .PADDR(paddr),.PSEL(psel),.PENABLE(penable),.PWRITE(pwrite),.PWDATA(pwdata),
  .PRDATA(prdata),.PREADY(pready),.PSLVERROR(pslverror),
  .capture_hold_ack(1'b1),.capture_idle(1'b1),.video_idle(1'b1),.core_idle(!private_busy),.external_memory_quiet(private_quiet),
  .capture_hold(),.pause_video_jobs(),.use_upload_axi(image_owner),.lease_active(image_active),
  .nn_owner(private_owner),.nn_job_valid(private_req),.nn_job_ready(private_ready),
  .nn_job_done(private_done),.nn_job_drained(private_drained),.nn_job_error(private_error),
  .nn_style(),.nn_input_base(),.nn_output_base(),.generation(image_generation),.phase(image_phase),.terminal_status(),
  .awaddr(p_awaddr[0]),.awlen(p_awlen[0]),.awvalid(p_awvalid[0]),.awready(awready&&!select_ext),
  .wdata(p_wdata[0]),.wstrb(p_wstrb[0]),.wlast(p_wlast[0]),.wvalid(p_wvalid[0]),.wready(wready&&!select_ext),
  .bid(bid),.bresp(bresp),.bvalid(bvalid&&!select_ext),.bready(p_bready[0]),
  .araddr(p_araddr[0]),.arlen(p_arlen[0]),.arvalid(p_arvalid[0]),.arready(arready&&!select_ext),
  .rid(rid),.rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid&&!select_ext),.rready(p_rready[0]),
  .memory_busy(),.control_busy());
 assign p_awid[0]=0;assign p_arid[0]=0;assign p_awsize[0]=4;assign p_arsize[0]=4;
 assign p_awburst[0]=1;assign p_arburst[0]=1;assign p_awlock[0]=0;assign p_arlock[0]=0;
 assign p_awcache[0]=0;assign p_arcache[0]=0;assign p_awprot[0]=0;assign p_arprot[0]=0;
 task apb_put(input[15:0]a,input[31:0]v);
  begin @(negedge cpu_clk);paddr=a;pwdata=v;psel=1;penable=0;pwrite=1;
   @(negedge cpu_clk);penable=1;#1;if(pslverror||!pready)$fatal(1,"cosim APB write");
   @(negedge cpu_clk);psel=0;penable=0;pwrite=0;end
 endtask
 task apb_get(input[15:0]a,output[31:0]v);
  begin @(negedge cpu_clk);paddr=a;psel=1;penable=0;pwrite=0;
   @(negedge cpu_clk);penable=1;#1;if(pslverror||!pready)$fatal(1,"cosim APB read");v=prdata;
   @(negedge cpu_clk);psel=0;penable=0;end
 endtask
 integer host_index,host_wait;reg[31:0]host_status;
 initial forever begin
  wait(setup_ready&&host_req);
  for(host_index=0;host_index<8;host_index=host_index+1)apb_put(16'h2040+host_index*4,host_q[host_index*32+:32]);
  apb_put(16'h2008,1);host_status=0;host_wait=0;
  while(!host_status[1])begin
   apb_get(16'h2004,host_status);host_wait=host_wait+1;
   if(host_wait>100000)$fatal(1,"cosim mailbox stalled");
  end
  for(host_index=0;host_index<8;host_index=host_index+1)apb_get(16'h2040+host_index*4,host_response[host_index*32+:32]);
  apb_put(16'h2008,10);host_done=1;
  wait(!host_req);host_done=0;
 end
 always @(posedge clk)if(rst_n&&private_owner&&fail[1])$fatal(1,"actual NN reported fail");
'''
s=s.replace('    function integer mem_index',wiring+'\n    function integer mem_index')
(D/'test.sv').write_text(s)
S=P/'embedded_sw/soc/software/standalone/uart/nnObserverDemo/src'
cc=Path('D:/Quartus18.0/quartus/bin64/cygwin/bin/gcc.exe');env=os.environ.copy()
env['PATH']=str(cc.parent)+';D:/ModelSim/win64;'+env['PATH']
c_sources=[P/'tests/image_rtl_cosim.c',S/'c_image_backend.c',S/'a_image_session.c',S/'a_net_service.c']
r=subprocess.run([str(cc),'-std=c99','-O2','-Wall','-Wextra','-Werror','-I'+str(S),*map(str,c_sources),'-o',str(D/'cosim.exe')],env=env,capture_output=True,text=True,errors='replace')
(D/'compile_c.log').write_text(r.stdout+r.stderr);assert r.returncode==0,r.stdout+r.stderr
sources=sorted((P/'rtl/nn/rtl').glob('*.v'))+[P/'rtl/hdmi_reset_release.v']+sorted((P/'rtl').glob('net_image_*.v'))
E=Path('D:/Efinity/2026.1/sim_models/verilog');sources +=[E/n for n in ['efx_dsp48.v','efx_dpram10.v','efx_ram10.v']]+[D/'test.sv']
tcl=r'''
vsim -c -voptargs=+acc work.tb
set child [open "|./cosim.exe input.rgb gold.rgb" r+]
fconfigure $child -buffering line -translation lf
set rpc_count 0
set got_pass 0
while {[gets $child line]>=0} {
 if {[string match "RPC *" $line]} {
  set fields [split $line]
  if {[llength $fields]!=9} {error "Bad C RPC request"}
  set packed ""
  for {set i 8} {$i>=1} {incr i -1} {append packed [lindex $fields $i]}
  force -deposit sim:/tb/host_q 256'h$packed
  force -deposit sim:/tb/host_req 1
  when -label rpc_finished {sim:/tb/host_done == 1} {stop}
  run -all
  if {[examine -radix unsigned sim:/tb/host_done]!=1} {error "RTL did not complete C request"}
  nowhen rpc_finished
  set response "RSP"
  for {set i 0} {$i<8} {incr i} {
   set value [string trim [examine -radix hex sim:/tb/r$i]]
   if {![regexp {^[0-9a-fA-F]+$} $value]} {error "Unknown RTL response: $value"}
   append response " " $value
  }
  force -deposit sim:/tb/host_req 0
  run 20 ns
  puts $child $response
  flush $child
  incr rpc_count
 } elseif {[string match "PASS actual_C_RTL_NN_roundtrip *" $line]} {
  puts $line
  set got_pass 1
 } else {error "Unexpected C output: $line"}
}
close $child
if {!$got_pass} {error "C did not verify actual NN result"}
if {[examine -radix unsigned sim:/tb/private_starts]!=1} {error "NN started more or less than once"}
if {[examine -radix unsigned sim:/tb/image_active]!=0} {error "Image lease not released"}
puts "PASS: live C session + production callbacks + actual APB CDC AXI and NN; all 2304 result bytes and CRC verified; RPC=$rpc_count"
quit -code 0
'''
(D/'run.do').write_text('\n'.join(['onerror {quit -code 1}','vlib work','vmap work work','vlog -sv -timescale 1ns/1ps '+' '.join('"'+f.as_posix()+'"'for f in sources),tcl]),encoding='ascii')
r=subprocess.run(['D:/ModelSim/win64/vsim.exe','-c','-l','sim.log','-do','run.do'],cwd=D,env=env,capture_output=True,text=True,errors='replace')
log=r.stdout+r.stderr;(D/'output.log').write_text(log,encoding='utf-8')
print('\n'.join(x for x in log.splitlines()if any(k in x for k in ['PASS:','PASS actual','Fatal','Error:'])),flush=True)
assert r.returncode==0 and 'PASS: live C session'in log and '** Fatal'not in log
sources+=c_sources+[S/'c_image_backend.h',S/'a_image_session.h',S/'a_net_service.h',Path(__file__),D/'cosim.exe',D/'input.rgb',D/'gold.rgb',D/'run.do']+list(D.glob('*.mem'))
(P/'IMAGE_C_RTL_NN_COSIM.json').write_text(json.dumps(dict(status='LIVE_C_RTL_NN_32X24_ROUNDTRIP_PASS',
 width=32,height=24,bytes_compared=2304,models_tested=[0],nn_starts=1,ddr='Byte-addressed behavioral model with real AXI backpressure',
 real_c_backend=True,real_apb_cdc_dma_nn=True,recorded_or_identity_backend=False,
 production_720p_jointly_tested=False,physical_udp_tested=False,board_verified=False,bit_generated=False,
 scope='Live actual portable C session and production backend RPCs through actual SV APB/CDC/lease/DMA/NN. Tiny deterministic fixture; no physical Ethernet or board. Native C, not RV32 execution in this coupled test.',
 sha256={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources if f.is_relative_to(P)}),indent=2))
