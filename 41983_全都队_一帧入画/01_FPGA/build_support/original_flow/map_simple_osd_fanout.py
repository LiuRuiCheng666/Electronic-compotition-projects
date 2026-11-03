"""Isolated synthesis option comparison; no RTL or active project edits."""
from pathlib import Path
import json,subprocess,os,shutil,xml.etree.ElementTree as ET
P=Path(__file__).resolve().parents[1];S=P/'closure_20261103/simple_osd';D=P/'closure_20261103/simple_osd_fanout128'
for n in ['outflow','work_syn','work_pnr']:(D/n).mkdir(parents=True,exist_ok=True)
tree=ET.parse(P/'ti60f225_oob.xml')
for e in tree.getroot().iter():
 if e.tag.endswith('synthesis'):
  for c in e:
   if c.get('name')=='fanout-limit':c.set('value','128')
config=P/'closure_simple_osd_fanout128.xml';tree.write(config,encoding='utf-8',xml_declaration=True)
cmd=json.loads((S/'map_command.json').read_text())
for k,v in [('write-efx-verilog',D/'outflow/ti60f225_oob.map.v'),('write-premap-module',D/'outflow/ti60f225_oob.elab.vdb'),('binary-db',D/'outflow/ti60f225_oob.vdb'),('work-dir',D/'work_syn'),('output-dir',D/'outflow'),('prj',config)]:cmd[cmd.index('--'+k)+1]=str(v)
for f in(P/'outflow').iterdir():
 if f.is_file()and f.suffix in {'.csi','.pbn','.qdelay','.cdo','.pb','.csv','.lpf'}:shutil.copy2(f,D/'outflow'/f.name)
(D/'map_command.json').write_text(json.dumps(cmd,indent=2));state=D/'FLOW_STATUS.json';state.write_text(json.dumps(dict(stage='SYNTHESIS_RUNNING')))
env=os.environ.copy();env['EFINITY_HOME']='D:/efinity/2026.1';env['PATH']=env['EFINITY_HOME']+'/bin;'+env['PATH']
with(D/'map.log').open('w',encoding='utf-8')as f:r=subprocess.run(cmd,cwd=P,env=env,stdout=f,stderr=subprocess.STDOUT)
state.write_text(json.dumps(dict(stage='SYNTHESIS_COMPLETE'if r.returncode==0 else'SYNTHESIS_FAILED',returncode=r.returncode)));assert r.returncode==0
print('FANOUT_SYNTHESIS_COMPLETE',flush=True)
