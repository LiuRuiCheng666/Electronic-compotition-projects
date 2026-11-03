"""Fresh synthesis, mapped CDC binding, physical implementation and independent STA."""
from pathlib import Path
import os,sys,json,shutil,subprocess,shlex,re
P=Path(__file__).resolve().parents[1];D=P/'closure_20261103/simple_osd';O=D/'outflow';A=D/'cdc';W=D/'work_pnr'
for p in [O,W,D/'work_syn',A/'outflow',A/'tools']:p.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env['EFINITY_HOME']='D:/efinity/2026.1';env['PATH']=env['EFINITY_HOME']+'/bin;'+env['PATH']
def state(s,**kw):
 (D/'FLOW_STATUS.json').write_text(json.dumps(dict(stage=s,**kw),indent=2));print(s,flush=True)
def run(label,args):
 with(D/(label+'.log')).open('w',encoding='utf-8')as f:r=subprocess.run([str(x)for x in args],cwd=P,env=env,stdout=f,stderr=subprocess.STDOUT)
 if r.returncode:state(label.upper()+'_FAILED',returncode=r.returncode);raise SystemExit(r.returncode)
for f in(P/'outflow').iterdir():
 if f.is_file()and f.suffix in {'.csi','.pbn','.qdelay','.cdo','.pb','.csv','.lpf'}:shutil.copy2(f,O/f.name)
cmd=shlex.split((P/'work_syn/run_efx_map.sh').read_text());cmd[0]='D:/efinity/2026.1/bin/efx_map.exe'
for key,value in [('write-efx-verilog',O/'ti60f225_oob.map.v'),('write-premap-module',O/'ti60f225_oob.elab.vdb'),('binary-db',O/'ti60f225_oob.vdb'),('work-dir',D/'work_syn'),('output-dir',O),('prj',P/'ti60f225_oob.xml')]:cmd[cmd.index('--'+key)+1]=str(value)
for i,arg in enumerate(cmd):
 if arg=='--I':cmd[i+1]=str(P/'ip/soc' if cmd[i+1].replace('\\','/').endswith('/ip/soc')else P)
(D/'map_command.json').write_text(json.dumps(cmd,indent=2));state('SYNTHESIS_RUNNING');run('map',cmd)
shutil.copytree(P/'rtl',A/'rtl',dirs_exist_ok=True);shutil.copy2(O/'ti60f225_oob.map.v',A/'outflow/ti60f225_oob.map.v');shutil.copy2(P/'ti60f225_oob.sdc',A/'ti60f225_oob.sdc')
for name in ['prepare_v69_reset_audit','prepare_v69_payload_audit','prepare_image_cdc','prepare_eth_cdc','prepare_image_route_margin']:shutil.copy2(P/f'tools/{name}.py',A/f'tools/{name}.py')
state('REBIND_CDC')
for name in ['prepare_v69_reset_audit','prepare_v69_payload_audit','prepare_eth_cdc','prepare_image_cdc','prepare_image_route_margin']:run(name,[sys.executable,'-X','utf8',A/f'tools/{name}.py'])
sdc=A/'ti60f225_oob.sdc';s=sdc.read_text(encoding='utf-8')
mapped=(O/'ti60f225_oob.map.v').read_text(encoding='utf-8')
assert 'network_osd_state['not in mapped
assert 'u_network_status_view/req_meta~FF' in mapped and 'u_network_status_view/ack_meta~FF' in mapped
s='\n'.join(line for line in s.splitlines()if not(line.startswith(('set_max_delay','set_min_delay'))and 'network_osd_state['in line))+'\n'
sdc.write_text(s,encoding='utf-8');shutil.copy2(sdc,A/'original_spec.sdc')
cmd=json.loads((P/'closure_20261103/barrel_seed13/pnr_command.json').read_text())
for key,value in [('prj',P/'ti60f225_oob.xml'),('vdb_file',O/'ti60f225_oob.vdb'),('place_file',O/'ti60f225_oob.place'),('route_file',O/'ti60f225_oob.troutingtraces'),('sdc_file',A/'ti60f225_oob.sdc'),('sync_file',O/'ti60f225_oob.interface.csv'),('work_dir',W),('output_dir',O)]:cmd[cmd.index('--'+key)+1]=str(value)
(D/'pnr_command.json').write_text(json.dumps(cmd,indent=2));state('PNR_RUNNING');run('pnr',cmd);state('PNR_COMPLETE_TIMING_PENDING',returncode=0)
run('independent_audit',[sys.executable,'-X','utf8',P/'tools/audit_closure_route.py','simple_osd'])
print('INDEPENDENT_TIMING_PASS',flush=True)
