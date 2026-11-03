"""Audit saved stress logs. Does not access the board or certify untested functions."""
from pathlib import Path
import argparse,json,math,statistics,html

def percentile(values,p):
 if not values:return None
 v=sorted(values);x=(len(v)-1)*p;lo=int(x);return v[lo]+(v[min(lo+1,len(v)-1)]-v[lo])*(x-lo)

def _audit(data,min_seconds=0):
 rows=data.get('rounds',[]);issues=[];known={};previous=None;values=[];slots={};replay_known=True;control=packets=retrans=0
 if not isinstance(rows,list):raise ValueError('rounds must be a list')
 for i,row in enumerate(rows,1):
  def check(condition,message):
   if not condition:issues.append(f'round {i}: {message}')
  check(row.get('round')==i,'missing/reordered round')
  slot=row.get('slot');check(slot in range(4)and slot==(i-1)%4,'slot order/bounds')
  stats=row.get('stats',{});digest=row.get('pixel_sha256');crc=stats.get('output_crc32')
  check(isinstance(digest,str)and len(digest)==64 and all(c in '0123456789abcdef'for c in digest),'invalid raw pixel SHA256')
  check(isinstance(crc,str)and len(crc)==8 and all(c in '0123456789abcdef'for c in crc),'invalid frame CRC')
  if slot in known:check(known[slot]==(digest,crc),'slot output changed between rounds')
  else:known[slot]=(digest,crc)
  check(stats.get('input_bytes')==2764800 and stats.get('output_bytes')==2764800,'720p RGB byte count')
  ms=stats.get('total_ms');check(isinstance(ms,(int,float))and math.isfinite(ms)and ms>0,'invalid elapsed time')
  if isinstance(ms,(int,float))and math.isfinite(ms)and ms>0:values.append(ms);slots.setdefault(slot,[]).append(ms)
  gen=stats.get('generation');check(type(gen)is int and 0<gen<=0xffffffff,'invalid generation')
  if previous is not None:check(gen==((previous['stats']['generation']+1)&0xffffffff or 1),'generation discontinuity')
  retrans+=stats.get('retransmissions',0)
  if 'control_replays'in stats and 'packet_retries'in stats:
   check(stats['control_replays']+stats['packet_retries']==stats.get('retransmissions'),'retry accounting mismatch');control+=stats['control_replays'];packets+=stats['packet_retries']
  else:replay_known=False
  if data.get('serial_verified'):
   f=row.get('video',{})
   for key in ['errors','underflows','bad_row','blank_frames','partial_frames','compute_fault','scheduler_fault','display_fault','boot_fault','boot_failed','fault']:
    check(f.get(key)==0,key+' nonzero or missing')
   for key in ['ddr_ready','boot_ready']:check(f.get(key)==1,key+' not ready')
   check(f.get('NEW',0)>=25 and f.get('CAP',0)>=25 and f.get('HDMI',0)>=55,'video did not recover')
   check(f.get('cpu_mode')==0,'left automatic CPU mode')
   check(f.get('active_model')==f.get('requested_model'),'UI style not settled')
   check(f.get('start_count',0)-f.get('done_count',0)in(0,1),'NN outstanding count')
   check(f.get('core_hz')==160000000,'unexpected core frequency')
   check(0x02000000<=f.get('input',0)<0x03000000 and 0x06000000<=f.get('output',0)<0x07800000,'private DDR address leaked into live video')
   if previous is not None:
    prev=previous.get('video',{});check(f.get('uptime_ms',0)>prev.get('uptime_ms',0),'uptime reset/reversed');check(f.get('new',0)>prev.get('new',0),'no fresh video frames between tasks')
  previous=row
 if data.get('reset_or_mode_commands_sent')is not False:issues.append('reset/mode changes were used or not recorded')
 elapsed=data.get('elapsed_seconds',0)
 if data.get('status')=='PASS':
  if elapsed<min_seconds:issues.append('declared PASS shorter than required duration')
  if data.get('completed_rounds')!=len(rows):issues.append('completed round count differs from log')
  if not rows:issues.append('empty test cannot pass')
 status='FAIL'if issues or data.get('status')in('FAIL','INTERRUPTED')else'PASS'if data.get('status')=='PASS'else'RUNNING'
 return dict(status=status,source_status=data.get('status'),scope='Saved log audit only; physical disconnection, cold boot and artistic quality are not certified.',elapsed_seconds=elapsed,required_seconds=min_seconds,completed_rounds=len(rows),slots=sorted(known),video_checked=bool(data.get('serial_verified')),reset_or_mode_commands_sent=data.get('reset_or_mode_commands_sent'),issues=issues,latency_ms=dict(min=min(values)if values else None,median=statistics.median(values)if values else None,p95=percentile(values,.95),max=max(values)if values else None),per_slot_ms={str(k):dict(count=len(v),mean=statistics.mean(v))for k,v in slots.items()},retransmissions=retrans,retry_breakdown_available=replay_known,control_replays=control if replay_known else None,packet_retries=packets if replay_known else None)

def audit(data,min_seconds=0):
 try:return _audit(data,min_seconds)
 except(TypeError,KeyError,ValueError,AttributeError)as error:
  return dict(status='FAIL',source_status=data.get('status')if isinstance(data,dict)else None,scope='Malformed saved log; no hardware proof.',elapsed_seconds=None,completed_rounds=0,slots=[],video_checked=False,issues=[f'Malformed log: {type(error).__name__}: {error}'],latency_ms={},retransmissions=None,retry_breakdown_available=False)

def render(path,report):
 esc=lambda value:html.escape(str(value),quote=True)
 cells=''.join('<tr><th>'+esc(key)+'</th><td>'+esc(report[key])+'</td></tr>'for key in ['status','elapsed_seconds','completed_rounds','slots','video_checked','latency_ms','retransmissions','retry_breakdown_available'])
 issues=''.join('<li>'+esc(x)+'</li>'for x in report['issues'])or'<li>No logged invariant violations found.</li>'
 Path(path).write_text('<!doctype html><meta charset="utf-8"><title>FPGA stress audit</title><style>body{font:16px sans-serif;max-width:1000px;margin:40px auto}td,th{border:1px solid #ccc;padding:10px;text-align:left}table{border-collapse:collapse}</style><h1>Stress log: '+esc(report['status'])+'</h1><p>'+esc(report['scope'])+'</p><table>'+cells+'</table><ul>'+issues+'</ul>',encoding='utf-8')

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('input');ap.add_argument('--out',required=True);ap.add_argument('--html');ap.add_argument('--min-seconds',type=float,default=0);a=ap.parse_args()
 if not math.isfinite(a.min_seconds)or a.min_seconds<0:ap.error('--min-seconds must be finite and nonnegative')
 paths=[Path(a.input).resolve(),Path(a.out).resolve()]+([Path(a.html).resolve()]if a.html else[])
 if len(set(paths))!=len(paths):ap.error('input, JSON output and HTML output must be different paths')
 report=audit(json.loads(Path(a.input).read_text(encoding='utf-8')),a.min_seconds);Path(a.out).write_text(json.dumps(report,indent=2),encoding='utf-8')
 if a.html:render(a.html,report)
 print(json.dumps(report,indent=2));raise SystemExit(1 if report['status']=='FAIL'else 0)
if __name__=='__main__':main()
