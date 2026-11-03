from pathlib import Path
import subprocess,os,json,hashlib
P=Path(__file__).resolve().parents[1]
cc=os.environ.get('HOST_CC','D:/Quartus18.0/quartus/bin64/cygwin/bin/gcc.exe');os.environ['PATH']=str(Path(cc).parent)+';'+os.environ['PATH']
for source,name in [('test_image_session.c','image_session_test.exe'),('image_session_cli.c','image_session_cli.exe')]:
 subprocess.run([cc,'-std=c99','-O2','-Wall','-Wextra','-Werror','-I'+str(P/'software'),str(P/'tests'/source),str(P/'software/a_image_session.c'),'-o',str(P/'tests'/name)],check=True)
r=subprocess.run([str(P/'tests/image_session_test.exe')],capture_output=True,text=True,check=True);print(r.stdout)
sources=[Path(__file__)]+list((P/'software').glob('a_image_session.*'))+[P/'tests'/n for n in ['test_image_session.c','image_session_cli.c','image_backend_fixture.h','image_session_cli.exe']]
(P/'IMAGE_SESSION_C_VALIDATION.json').write_text(json.dumps(dict(status='PASS',hardware_accessed=False,scope='Portable C session on host memory fixture, not DDR DMA or a model',sha256={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources}),indent=2))
