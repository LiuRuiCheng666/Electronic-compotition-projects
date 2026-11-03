"""Private image lease ownership regression only; no network/NN integration or board claim."""
from pathlib import Path
import hashlib
import json
import os
import subprocess

P = Path(__file__).resolve().parents[1]
D = P / 'tests/lease_run'
D.mkdir(exist_ok=True)
sources = [P / 'rtl/net_image_lease.v', P / 'tests/tb_net_image_lease.sv']
(D / 'run.do').write_text('\n'.join([
    'onerror {quit -code 1}', 'vlib work', 'vmap work work',
    'vlog -sv ' + ' '.join('"' + f.as_posix() + '"' for f in sources),
    'vsim -c work.tb', 'run -all', 'quit -code 0'
]), encoding='ascii')
sim = Path(os.environ.get('MODELSIM_BIN', 'D:/ModelSim/win64'))
r = subprocess.run([str(sim / 'vsim.exe'), '-c', '-l', 'sim.log', '-do', 'run.do'],
                   cwd=D, capture_output=True, text=True, errors='replace')
log = r.stdout + r.stderr
(D / 'output.log').write_text(log, encoding='utf-8')
print('\n'.join(x for x in log.splitlines()
                if 'PASS:' in x or 'Fatal' in x or 'Error:' in x))
assert r.returncode == 0 and 'PASS:' in log and '** Fatal' not in log
(P / 'LEASE_VALIDATION.json').write_text(json.dumps(dict(
    status='RTL_UNIT_PASS_NOT_BOARD_INTEGRATED', image_roundtrip_complete=False,
    sha256={f.relative_to(P).as_posix(): hashlib.sha256(f.read_bytes()).hexdigest()
            for f in sources + [Path(__file__)]},
    scope='Lease controller simulation with capture/core/DMA drain handshakes; '
          'lease coordinator, APB/CDC, model scheduling and board tests still required.'
), indent=2), encoding='utf-8')
