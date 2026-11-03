"""Compile actual production image callbacks; native register/DDR test fixture only."""
from pathlib import Path
import hashlib,json,os,subprocess
P=Path(__file__).resolve().parents[1]
S=P/'embedded_sw/soc/software/standalone/uart/nnObserverDemo/src'
D=P/'tests/real_backend_run';D.mkdir(exist_ok=True)
cc=Path(os.environ.get('HOST_CC','D:/Quartus18.0/quartus/bin64/cygwin/bin/gcc.exe'))
env=os.environ.copy();env['PATH']=str(cc.parent)+';'+env['PATH']
sources=[P/'tests/test_real_image_backend.c',S/'c_image_backend.c',S/'a_net_service.c',S/'a_image_session.c']
for profile,flags in [('cached',[]),('direct_mmio',['-DA_NET_DIRECT_RX_BASE=0xf8101800u'])]:
 r=subprocess.run([str(cc),'-std=c99','-O2','-Wall','-Wextra','-Werror',*flags,'-I'+str(S),*map(str,sources),'-o',str(D/(profile+'.exe'))],env=env,cwd=P,capture_output=True,text=True,errors='replace')
 (D/(profile+'_compile.log')).write_text(r.stdout+r.stderr,encoding='utf-8')
 assert r.returncode==0,r.stdout+r.stderr
 r=subprocess.run([str(D/(profile+'.exe'))],env=env,cwd=P,capture_output=True,text=True,errors='replace')
 log=r.stdout+r.stderr;(D/(profile+'_output.log')).write_text(log,encoding='utf-8');print(profile+'\n'+log,flush=True)
 assert r.returncode==0 and 'NOT board or NN proof'in log
sources +=[S/'c_image_backend.h',S/'a_net_service.h',S/'a_image_session.h',Path(__file__)]
(P/'C_IMAGE_BACKEND_VALIDATION.json').write_text(json.dumps(dict(
 status='NATIVE_C_BACKEND_PASS_REGISTER_DDR_FIXTURE_NOT_BOARD',board_verified=False,image_roundtrip_complete=False,
 profiles=['cached','direct_mmio'],scope='Actual backend callbacks and shared CRC; 10 dimensions/format cases through 720p per profile; direct RX fixed-address memory fixture, output pattern, no NN arithmetic.',
 sha256={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources}
),indent=2),encoding='utf-8')
