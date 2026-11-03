"""Compare pre/post-area service RTL under identical APB and stalled DDR inputs."""
from pathlib import Path
import hashlib,json,re,subprocess
P=Path(__file__).resolve().parents[1];D=P/'tests/service_area_equivalence_run';D.mkdir(exist_ok=True)
service=(P/'rtl/net_image_service.v').read_text().replace('module net_image_service #','module reference_service #').replace(' net_image_dispatch dispatcher(',' original_dispatch dispatcher(').replace(' net_image_line_dma #',' original_dma #')
(D/'reference_service.v').write_text(service)
tb=(P/'tests/tb_net_image_service.sv').read_text()
m=re.search(r' net_image_service #\(.*?\);',tb,re.S);assert m
outputs={'PRDATA':32,'PREADY':1,'PSLVERROR':1,'capture_hold':1,'pause_video_jobs':1,'use_upload_axi':1,'lease_active':1,'nn_owner':1,'nn_job_valid':1,'nn_style':2,'nn_input_base':32,'nn_output_base':32,'generation':32,'phase':4,'terminal_status':8,'memory_busy':1,'control_busy':1,'awaddr':32,'awlen':8,'awvalid':1,'wdata':128,'wstrb':16,'wlast':1,'wvalid':1,'bready':1,'araddr':32,'arlen':8,'arvalid':1,'rready':1}
connections=dict(re.findall(r'\.(\w+)\(([^()]*)\)',m[0][m[0].index(' dut('):]))
ref=m[0].replace('net_image_service #','reference_service #').replace(' dut(',' ref_dut(')
for n in outputs:
 assert n in connections,n
 ref=ref.replace('.'+n+'('+connections[n]+')','.'+n+'(ref_'+n+')')
decls='\n'.join(' wire '+('['+str(w-1)+':0]'if w>1 else'')+'ref_'+n+';'for n,w in outputs.items())
checks=[]
for n in outputs:
 if n in ['PRDATA','awaddr','awlen','wdata','wstrb','wlast','araddr','arlen']:continue
 checks.append('if('+connections[n]+'!==ref_'+n+')$fatal(1,"area equivalence '+n+'");')
checks+=['if(sel&&en&&!wr && rd!==ref_PRDATA)$fatal(1,"area equivalence APB read");',
 'if(av && {aw,awl}!=={ref_awaddr,ref_awlen})$fatal(1,"area equivalence AW");',
 'if(wv && {wdata,strb,wl}!=={ref_wdata,ref_wstrb,ref_wlast})$fatal(1,"area equivalence W");',
 'if(arv && {ar,arl}!=={ref_araddr,ref_arlen})$fatal(1,"area equivalence AR");']
monitor='\n integer compared_core_cycles=0;always @(negedge kc)if(rst)begin compared_core_cycles=compared_core_cycles+1;'+ '\n'.join(checks)+'\n end\n'
tb=tb[:m.start()]+decls+'\n'+m[0]+'\n'+ref+monitor+tb[m.end():]
tb=tb.replace('$display("PASS: actual APB+', '$display("PASS: pre/post-area service cycle equivalence; actual APB+')
(D/'test.sv').write_text(tb)
sources=[P/'rtl/hdmi/hdmi_reset_release.v']
reset=list((P/'rtl').rglob('hdmi_reset_release.v'));assert len(reset)==1;sources=reset
sources +=[P/'rtl/net_image_mailbox.v',P/'rtl/net_image_lease.v',P/'rtl/net_image_line_dma.v',P/'rtl/net_image_dispatch.v',P/'rtl/net_image_service.v',P/'integration_tests/image_dma_address_experiment/original.v',P/'integration_tests/image_dispatch_data_experiment/original.v',D/'reference_service.v',D/'test.sv']
(D/'run.do').write_text('onerror {quit -code 1}\nvlib work\nvmap work work\nvlog -sv '+' '.join('"'+f.as_posix()+'"'for f in sources)+'\nvsim -c work.tb\nrun -all\nquit -code 0\n')
r=subprocess.run(['D:/ModelSim/win64/vsim.exe','-c','-l','sim.log','-do','run.do'],cwd=D,capture_output=True,text=True,errors='replace');log=r.stdout+r.stderr;(D/'output.log').write_text(log)
print('\n'.join(x for x in log.splitlines()if 'PASS:'in x or 'Fatal'in x or 'Error:'in x))
assert r.returncode==0 and 'PASS: pre/post-area'in log and '** Fatal'not in log
(P/'IMAGE_SERVICE_AREA_EQUIVALENCE.json').write_text(json.dumps(dict(status='PRE_POST_AREA_SERVICE_CYCLE_EQUIVALENCE_PASS',board_verified=False,
 scope='Identical APB commands, DDR model and stalls; cycle equality of APB reads, valid AXI payloads, lease and NN controls; invalid inactive bus values intentionally not compared.',
 sources={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources+[Path(__file__)]}),indent=2))
