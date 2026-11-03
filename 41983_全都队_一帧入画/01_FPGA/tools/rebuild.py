"""Portable wrapper for the selected final Efinity map/bind/pnr flow. No board I/O."""
from pathlib import Path
import argparse,json,os,shutil,subprocess,sys,re
P=Path(__file__).resolve().parents[1];B=P/'build_support';A=B/'cdc'
ap=argparse.ArgumentParser();ap.add_argument('--stage',choices=['plan','map','bind','pnr','pgm','reference-pgm','all'],default='plan');ap.add_argument('--efinity-home',type=Path,default=Path(os.environ.get('EFINITY_HOME','D:/Efinity/2026.1')));a=ap.parse_args()
E=a.efinity_home.resolve();env=os.environ.copy();env['EFINITY_HOME']=str(E);env['PATH']=str(E/'bin')+os.pathsep+env['PATH']
def command(name):
    args=json.loads((B/(name+'_command.json')).read_text('utf-8'))
    return [str(E/'bin'/Path(x).name) if i==0 else str((P/x).resolve()) if x.startswith(('./','outflow/','work_syn','work_pnr','build_support/','ip/')) or x=='ti60f225_oob.xml' else x for i,x in enumerate(args)]
def run(name,args):
    (P/'build_logs').mkdir(exist_ok=True)
    print(name,flush=True)
    with (P/'build_logs'/(name+'.log')).open('w',encoding='utf-8') as f:
        subprocess.run(args,cwd=P,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
if a.stage=='plan':
    print(json.dumps({k:command(k) for k in ['map','pnr']},ensure_ascii=False,indent=2));raise SystemExit(0)
for path in [P/'outflow',P/'work_syn',P/'work_pnr',A/'outflow']:path.mkdir(parents=True,exist_ok=True)
if a.stage in ['map','all']:run('map',command('map'))
if a.stage in ['bind','all']:
    shutil.copytree(P/'rtl',A/'rtl',dirs_exist_ok=True)
    shutil.copy2(P/'outflow/ti60f225_oob.map.v',A/'outflow/ti60f225_oob.map.v')
    shutil.copy2(P/'ti60f225_oob.sdc',A/'ti60f225_oob.sdc')
    for name in ['prepare_v69_reset_audit','prepare_v69_payload_audit','prepare_eth_cdc','prepare_image_cdc','prepare_image_route_margin']:
        run(name,[sys.executable,'-X','utf8',str(A/'tools'/(name+'.py'))])
    f=A/'ti60f225_oob.sdc';s=f.read_text('utf-8')
    s='\n'.join(line for line in s.splitlines() if not(line.startswith(('set_max_delay','set_min_delay')) and 'network_osd_state[' in line))+'\n'
    f.write_text(s,encoding='utf-8');shutil.copy2(f,A/'original_spec.sdc')
    run('prove_replicas',[sys.executable,'-X','utf8',str(A/'tools/prove_replicas_and_rebind.py')])
    with f.open('a',encoding='utf-8') as out:out.write('\nset_clock_uncertainty -from [get_clocks {rx_cal_clk}] -to [get_clocks {rx_cal_clk}] -setup 0.150\n')
if a.stage in ['pnr','all']:run('pnr',command('pnr'))
if a.stage=='reference-pgm':
    reference=P/'implementation_reference/ti60f225_oob.lbf'
    if not reference.is_file():raise SystemExit('Missing delivered native LBF: '+str(reference))
    shutil.copy2(reference,P/'work_pnr/ti60f225_oob.lbf')
if a.stage in ['pgm','reference-pgm']:
    if not (P/'work_pnr/ti60f225_oob.lbf').is_file():
        raise SystemExit('No routed LBF. Run map/bind/pnr first, or use reference-pgm for the delivered implementation.')
    if not (P/'outflow/ti60f225_oob.lpf').is_file():raise SystemExit('Missing peripheral LPF')
    env['PYTHONHOME']=str(E/'python311');env['PYTHONUTF8']='1'
    run('pgm',[str(E/'python311/bin/python.exe'),'-X','utf8',str(P/'tools/run_efinity.py'),'ti60f225_oob.xml','--prj','-f','pgm','--work_dir','work_pnr','--output_dir','outflow'])
    if not (P/'outflow/ti60f225_oob.hex').is_file():raise SystemExit('Efinity returned without generating a configuration HEX')
