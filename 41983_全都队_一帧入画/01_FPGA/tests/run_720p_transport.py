"""Full-size localhost UDP/C-session stress, identity fixture (NOT NN/board)."""
from pathlib import Path
import hashlib,json,sys,time,zlib
P=Path(__file__).resolve().parents[1];sys.path.insert(0,str(P/'tests'));sys.path.insert(0,str(P/'host'))
from test_image_transfer import CBridge
from a_image_transfer import ImageClient,ImageDesc
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
cases=[]
for fmt,style,faults in [(1,0,False),(1,3,True),(2,1,False),(2,2,True)]:
 bpp={1:3,2:4}[fmt];raw=bytes(range(256))*(1280*720*bpp//256)
 assert len(raw)==1280*720*bpp
 d=ImageDesc(1280,720,fmt,style,1280*bpp,len(raw),zlib.crc32(raw))
 bridge=CBridge(faults=faults);client=ImageClient('127.0.0.1',bridge.port,bind_ip='127.0.0.1',timeout=.5,attempts=5,job_timeout=10)
 start=time.perf_counter()
 try:
  out,result=client.transfer(raw,d)
  assert out==raw and result==d,'Full-size byte/descriptor mismatch'
  if faults:
   assert client.stats['retransmissions']>=5 and client.stats['bad_datagrams']>=1
   assert bridge.seen=={'request0','begin_ack','commit_ack','release_ack','result_crc'}
 finally:client.close();bridge.close()
 chunks=(len(raw)+1367)//1368
 assert bridge.stats==(1,chunks,1,1),('Extra reserve/write/submit/release',bridge.stats,chunks)
 case=dict(format=fmt,style=style,bytes=len(raw),chunks=chunks,last_chunk_bytes=len(raw)-(chunks-1)*1368,faults=faults,
  input_sha256=hashlib.sha256(raw).hexdigest(),output_sha256=hashlib.sha256(out).hexdigest(),fixture_calls=list(bridge.stats),stats=client.stats,
  localhost_elapsed_ms=round((time.perf_counter()-start)*1000,3))
 cases.append(case);print('PASS',fmt,style,'chunks',chunks,'faults',faults,flush=True)
files=[Path(__file__),P/'tests/test_image_transfer.py',P/'tests/image_session_cli.exe',P/'tests/image_session_cli.c',P/'tests/image_backend_fixture.h',P/'software/a_image_session.c',P/'software/a_image_session.h',P/'host/a_image_transfer.py',P/'host/a_net_wire.py']
(P/'IMAGE_720P_TRANSPORT_VALIDATION.json').write_text(json.dumps(dict(status='FULL_720P_LOCALHOST_C_SESSION_TRANSPORT_PASS_IDENTITY_FIXTURE',
 width=1280,height=720,cases=cases,hardware_accessed=False,production_720p_jointly_tested=False,
 scope='Full-size UDP loopback through actual portable C image session. Identity host memory fixture; no actual DMA/NN, physical Ethernet, RV32 execution or board throughput claim.',
 sources={f.relative_to(P).as_posix():sha(f)for f in files}),indent=2))
print('PASS: four full 720p protocol sessions; not full 720p NN or board proof',flush=True)
