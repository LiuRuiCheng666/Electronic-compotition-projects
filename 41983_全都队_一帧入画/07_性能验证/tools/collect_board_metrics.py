"""Read final firmware diagnostics and measure switches/tasks through UART.
Run explicitly with --port. No FPGA programming, Flash writes or resets.
"""
from pathlib import Path
import argparse,csv,itertools,json,re,statistics,sys,time

DEFAULT_PROJECT=Path(__file__).resolve().parents[2]
BAD_COUNTERS=['abort','underflows','blank_frames','partial_frames']

def new_output_directory(requested):
 """Reserve a new sibling directory without changing previous measurements."""
 requested=Path(requested)
 requested.parent.mkdir(parents=True,exist_ok=True)
 for i in itertools.count():
  candidate=requested if i==0 else requested.with_name(requested.name+'_'+str(i+1))
  try:
   candidate.mkdir()
   return candidate
  except FileExistsError:continue

def fields(text):
 return {k:int(v,16) if v.lower().startswith('0x') else int(v)
         for k,v in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(0x[0-9a-fA-F]+|-?\d+)(?=\s|;|$)',text)}

def delta(a,b):
 out={}
 for k in ['uptime_ms','capture','nn','new','scans','preprocessed','skipped','stale']+BAD_COUNTERS:
  if k in a and k in b:out[k]=(b[k]-a[k])&((1<<16)-1 if k in ['underflows','blank_frames','partial_frames'] else (1<<32)-1)
 if out.get('uptime_ms',0)>0:
  for k in ['capture','nn','new','scans']:
   if k in out:out[k+'_per_second']=out[k]*1000/out['uptime_ms']
 out['errors_before']=a.get('errors');out['errors_after']=b.get('errors')
 return out

def distribution(values):
 if not values:return {}
 v=sorted(values)
 return {'count':len(v),'min':v[0],'mean':statistics.mean(v),'median':statistics.median(v),'p95':v[max(0,__import__('math').ceil(.95*len(v))-1)],'max':v[-1]}

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--port',help='Board UART COM port, e.g. COM9')
 ap.add_argument('--baud',type=int,default=115200)
 ap.add_argument('--project',type=Path,default=DEFAULT_PROJECT)
 ap.add_argument('--source',choices=['keep','camera','hdmi'],default='camera')
 ap.add_argument('--repeats',type=int,default=3)
 ap.add_argument('--steady-seconds',type=int,default=60)
 ap.add_argument('--tasks-per-style',type=int,default=30)
 ap.add_argument('--out',type=Path,required=True)
 ap.add_argument('--dry-run',action='store_true')
 a=ap.parse_args()
 if not (1<=a.repeats<=20 and 1<=a.tasks_per_style<=100 and 5<=a.steady_seconds<=3600):ap.error('Invalid repetitions, task count or duration')
 if a.dry_run:
  print('No serial port opened. Setup: version, probe, nnstatus, video, source status, mode auto, roi full, ui on.')
  print('20 directed style pairs x',a.repeats,'; steady video',a.steady_seconds,'seconds; run',a.tasks_per_style,'for each of 5 styles. Output',a.out)
  return
 if not a.port:ap.error('--port is required')
 sys.path.insert(0,str(a.project/'02_网页应用/vendor/pure'))
 try:import serial
 except ImportError as exc:
  raise SystemExit(f'Cannot import pyserial: {exc}\nInstall into the exact interpreter:\n& "{sys.executable}" -m pip install pyserial')
 requested_output=a.out
 a.out=new_output_directory(requested_output)
 if a.out!=requested_output:print('Previous results retained. New output:',a.out,flush=True)
 else:print('Output:',a.out,flush=True)
 report={'source':a.source,'serial_port':a.port,'baud':a.baud,'status':'RUNNING','switches':[],'steady_samples':[],'task_samples':[],
         'definitions':{'switch_us':'FPGA requested-model change to end of first complete visible target frame; UART transport excluded',
                        'task_ms':'Firmware CLINT timer: task start/admission to completion, including scheduling and IRQ wait; serial transport and result printing excluded; 1ms granularity',
                        'frame_continuity':'Counters and video are evidence of corruption/blanking/underflow; skipped/stale increments require comparison with the baseline, not an automatic zero-drop verdict'}}
 t0=time.monotonic()
 def save():(a.out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
 raw=(a.out/'serial_log.txt').open('w',encoding='utf-8')
 s=serial.Serial(port=None,baudrate=a.baud,timeout=.05,write_timeout=2)
 s.dtr=False;s.rts=False;s.port=a.port
 def command(cmd,timeout=5):
  raw.write(f'\n[{time.monotonic()-t0:.3f}s] >>> {cmd}\n');raw.flush()
  s.write((cmd+'\r').encode('ascii'));s.flush()
  b=bytearray();end=time.monotonic()+timeout
  while time.monotonic()<end:
   b.extend(s.read(max(1,s.in_waiting)))
   if b.endswith(b'C> '):
    text=b.decode('utf-8',errors='replace');raw.write(text);raw.flush();return text
  text=b.decode('utf-8',errors='replace');raw.write(text+'\nTIMEOUT\n');raw.flush()
  raise RuntimeError('UART response timeout for '+cmd+'; see serial_log.txt')
 def checked(cmd,timeout=5):
  text=command(cmd,timeout)
  if re.search(r'\bERR\b|\bSTOP\b|\b(?:style_command|ui_command|result)=(?!(?:OK|PASS)\b)\S+',text):raise RuntimeError('Command failed: '+cmd+'; inspect raw log')
  return text
 def video():
  text=checked('video');v=fields(text)
  if not {'uptime_ms','nn','new','scans','errors','blank_frames','partial_frames','underflows'}<=v.keys():raise RuntimeError('Video diagnostic ABI differs from final firmware')
  return v
 def switch_to(target):
  checked('style '+str(target));end=time.monotonic()+2
  last={}
  while time.monotonic()<end:
   text=checked('switch');last=fields(text)
   if last.get('target')==target and last.get('valid')==1 and last.get('pending')==0:
    return last
   if last.get('fault') or last.get('timeout'):break
   time.sleep(.03)
  raise RuntimeError('No complete switch record for style '+str(target)+': '+str(last))
 try:
  s.open();time.sleep(.2)
  # Obtain a fresh console prompt without resetting the device.
  s.reset_input_buffer();command('')
  report['version']=checked('version');report['probe']=checked('probe')
  initial=checked('nnstatus');report['initial_nnstatus']=initial
  n=fields(initial)
  if n.get('core_hz')!=160000000 or n.get('ddr_ready')!=1 or n.get('boot_ready')!=1 or n.get('boot_failed')!=0:
   raise RuntimeError('Board is not running the ready 160MHz final image; retain log and check deployment')
  if a.source!='keep':checked('source '+a.source);time.sleep(1)
  checked('mode auto');checked('roi full');checked('ui on');time.sleep(2)
  report['source_status']=checked('source status')
  print('Collecting 10-second baseline...',flush=True)
  first=video();time.sleep(10);last=video();report['baseline']={'before':first,'after':last,'delta':delta(first,last)};save()
  pairs=list(itertools.permutations(range(5),2))
  for repetition in range(a.repeats):
   for previous,target in pairs:
    # Prepare another style first when needed so the target measurement is fresh.
    now=fields(checked('nnstatus'))
    if now.get('requested_model')!=previous or now.get('active_model')!=previous:switch_to(previous)
    time.sleep(.25);before=video();began=time.monotonic();record=switch_to(target)
    elapsed=record['cycles']*1e6/record['core_hz']
    record.update(repetition=repetition+1,from_style=previous,to_style=target,switch_us_exact=elapsed,
                  latency_below_100ms=bool(record.get('below_100ms')==1 and elapsed<100000 and not any(record.get(k,0) for k in ['fault','timeout','superseded','pending'])))
    time.sleep(max(0,1.2-(time.monotonic()-began)));after=video()
    record['before']=before;record['after']=after;record['delta']=delta(before,after)
    report['switches'].append(record);save()
    print(f'Switch {len(report["switches"]):02d}/{20*a.repeats}: {previous}->{target}, {elapsed/1000:.3f} ms, below100={record["latency_below_100ms"]}',flush=True)
  print('Collecting continuous-video counters...',flush=True)
  end=time.monotonic()+a.steady_seconds
  while time.monotonic()<end:
   report['steady_samples'].append(video());save();time.sleep(1)
  report['steady_nnstatus']=checked('nnstatus')
  print('Collecting task latencies...',flush=True)
  checked('irq on')
  for style in range(5):
   now=fields(checked('nnstatus'))
   if now.get('requested_model')!=style or now.get('active_model')!=style:switch_to(style)
   text=checked('run '+str(a.tasks_per_style),timeout=max(20,a.tasks_per_style*.5))
   rows=re.findall(r'task=(\d+) accepted=(\d+) done=(\d+) result=PASS elapsed_ms=(\d+)',text)
   if len(rows)!=a.tasks_per_style or f'run_complete={a.tasks_per_style}' not in text:raise RuntimeError('Incomplete task-latency run; preserve board state and logs')
   for task,accepted,done,ms in rows:
    if accepted!=done:raise RuntimeError('Task frame identity mismatch')
    report['task_samples'].append({'style':style,'task':int(task),'accepted_frame':int(accepted),'done_frame':int(done),'elapsed_ms':int(ms)})
   save();checked('mode auto');time.sleep(.3)
  report['final_video']=video();report['final_nnstatus']=checked('nnstatus')
  report['switch_latency_us']=distribution([r['switch_us_exact'] for r in report['switches']])
  report['all_switch_latency_below_100ms']=all(r['latency_below_100ms'] for r in report['switches'])
  report['task_latency_ms_by_style']={str(i):distribution([r['elapsed_ms'] for r in report['task_samples'] if r['style']==i]) for i in range(5)}
  if len(report['steady_samples'])>=2:report['steady_delta']=delta(report['steady_samples'][0],report['steady_samples'][-1])
  report['status']='COLLECTION_COMPLETE';save()
  with (a.out/'switches.csv').open('w',newline='',encoding='utf-8-sig') as f:
   keys=['repetition','from_style','to_style','switch_us_exact','latency_below_100ms','cycles','core_hz','request_frame','shown_frame']
   w=csv.DictWriter(f,fieldnames=keys,extrasaction='ignore');w.writeheader();w.writerows(report['switches'])
  with (a.out/'tasks.csv').open('w',newline='',encoding='utf-8-sig') as f:
   w=csv.DictWriter(f,fieldnames=['style','task','accepted_frame','done_frame','elapsed_ms']);w.writeheader();w.writerows(report['task_samples'])
  print('Collection complete:',a.out,'; send the entire directory. Counter interpretation is recorded separately from switch latency.',flush=True)
 except BaseException as exc:
  report['status']='INTERRUPTED' if isinstance(exc,KeyboardInterrupt) else 'COLLECTION_ERROR';report['error']=str(exc);save()
  if isinstance(exc,serial.SerialException) and ('PermissionError' in str(exc) or 'Access is denied' in str(exc) or '拒绝访问' in str(exc)):
   raise SystemExit(f'{a.port} access denied. Close the serial connection in VOFA/serial terminal and the web-workspace server, then rerun the same command.\nSaved diagnostic: {a.out}')
  raise
 finally:
  s.close();raw.close()
if __name__=='__main__':main()
