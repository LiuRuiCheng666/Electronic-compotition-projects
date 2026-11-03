"""Bounded serial image stress test; optional UART verifies live-video recovery after every job."""
from pathlib import Path
from dataclasses import replace
import argparse,datetime,json,hashlib,re,subprocess,sys,time,zlib
from a_image_transfer import ImageClient,load_image,save_image
from a_image_batch import atomic_json

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('input');ap.add_argument('--out',required=True);g=ap.add_mutually_exclusive_group();g.add_argument('--rounds',type=int);g.add_argument('--duration-seconds',type=float);ap.add_argument('--ip',default='192.168.0.2');ap.add_argument('--bind-ip',default='192.168.0.3');ap.add_argument('--interface-index',type=int,default=3);ap.add_argument('--serial');ap.add_argument('--uart-tool');ap.add_argument('--reference-dir');a=ap.parse_args()
 if a.rounds is not None and not 1<=a.rounds<=10000:ap.error('rounds 1..10000')
 if a.duration_seconds is not None and not 1<=a.duration_seconds<=86400:ap.error('duration 1..86400 seconds')
 if a.serial and not a.uart_tool:ap.error('--serial requires --uart-tool')
 root=Path(a.out).resolve();root.mkdir(parents=True,exist_ok=False);raw,base=load_image(a.input,0,(1280,720));references={};observed=set();rows=[];start=time.monotonic();last=None
 if a.reference_dir:
  from PIL import Image
  for slot in range(4):references[slot]=Image.open(Path(a.reference_dir)/f'001_slot{slot}.png').convert('RGB').tobytes()
 report=dict(status='RUNNING',scope='Real image transactions, deterministic results, and optional UART recovery checks; physical cable unplug and artistic quality not covered.',started=datetime.datetime.now().astimezone().isoformat(),input_sha256=hashlib.sha256(Path(a.input).read_bytes()).hexdigest(),rounds=rows,serial_verified=bool(a.serial),reset_or_mode_commands_sent=False)
 def flush():report['elapsed_seconds']=time.monotonic()-start;atomic_json(root/'stress.json',report)
 def snapshot(label):
  q=subprocess.run([sys.executable,'-X','utf8',a.uart_tool,'--port',a.serial,'--commands','version;video;nnstatus;ctrl','--initial','.2','--wait','.3','--log',str(root/(label+'.txt'))],capture_output=True,text=True,errors='replace');assert q.returncode==0,q.stderr
  f={k:int(v,16 if v.startswith('0x')else 10)for k,v in re.findall(r'\b([A-Za-z_]\w*)=(0x[0-9a-fA-F]+|\d+)',q.stdout)}
  for key in ['errors','underflows','bad_row','blank_frames','partial_frames','compute_fault','scheduler_fault','display_fault']:assert f[key]==0,(label,key,f[key])
  assert f['NEW']>=25 and f['CAP']>=25 and f['HDMI']>=55 and f['cpu_mode']==0,(label,f)
  return f
 try:
  initial=snapshot('initial')if a.serial else None
  number=0
  while True:
   if a.duration_seconds is not None:
    if number and time.monotonic()-start>=a.duration_seconds:break
   elif number>=(a.rounds or 20):break
   slot=number%4;c=ImageClient(a.ip,bind_ip=a.bind_ip,interface_index=a.interface_index,job_timeout=60)
   try:
    output,d=c.transfer(raw,replace(base,style=slot));stats=dict(c.stats)
   finally:c.close()
   assert d.width==1280 and d.height==720 and d.format==1 and d.style==slot and len(output)==2764800
   assert zlib.crc32(output)==d.crc32
   if slot in references:assert output==references[slot],('pixel mismatch',number,slot)
   else:references[slot]=output
   if last is not None:assert stats['generation']==last+1,('generation mismatch',last,stats['generation'])
   last=stats['generation'];observed.add(slot);number+=1
   if number<=4:save_image(root/f'reference_slot{slot}.png',output,d)
   row=dict(round=number,slot=slot,stats=stats,pixel_sha256=hashlib.sha256(output).hexdigest())
   if a.serial:
    time.sleep(2.5);f=snapshot(f'round{number:04d}_recovery');row['video']=f
    assert f['active_model']==f['requested_model']==initial['requested_model'],'private style leaked into live UI'
   rows.append(row);flush();print(json.dumps(dict(round=number,slot=slot,total_ms=stats['total_ms'],crc32=stats['output_crc32'],recovered_new_fps=row.get('video',{}).get('NEW'))),flush=True)
  report.update(status='PASS',completed_rounds=number,completed_styles=sorted(observed),distinct_outputs=len({hashlib.sha256(references[x]).hexdigest()for x in observed}))
 except BaseException as e:
  report.update(status='INTERRUPTED'if isinstance(e,KeyboardInterrupt)else'FAIL',error=f'{type(e).__name__}: {e}');raise
 finally:
  report['finished']=datetime.datetime.now().astimezone().isoformat();flush()
 print('PASS',str(root/'stress.json'))
if __name__=='__main__':main()
