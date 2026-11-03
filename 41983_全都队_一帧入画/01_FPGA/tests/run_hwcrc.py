from pathlib import Path
import subprocess,json,hashlib
P=Path(__file__).resolve().parents[1];D=P/'tests/hwcrc_run';D.mkdir(exist_ok=True)
files=[P/'rtl/net_image_dispatch.v',P/'tests/tb_image_hwcrc.sv']
(D/'run.do').write_text('onerror {quit -code 1}\nvlib work\nvmap work work\nvlog -sv '+ ' '.join('"'+f.as_posix()+'"'for f in files)+'\nvsim -c work.tb\nrun -all\nquit -code 0\n')
r=subprocess.run(['D:/ModelSim/win64/vsim.exe','-c','-l','sim.log','-do','run.do'],cwd=D,capture_output=True,text=True,errors='replace');text=r.stdout+r.stderr;(D/'output.log').write_text(text,encoding='utf-8');print('\n'.join(s for s in text.splitlines()if 'PASS:'in s or 'Error:'in s or 'Fatal'in s),flush=True);assert r.returncode==0 and 'PASS:'in text and '** Fatal'not in text
(P/'HWCRC_UNIT_VALIDATION.json').write_text(json.dumps({'status':'RTL_UNIT_PASS_NOT_BOARD','files':{str(f.relative_to(P)):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}},indent=2))
