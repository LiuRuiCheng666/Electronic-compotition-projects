from pathlib import Path
import unittest,json,sys,hashlib
P=Path(__file__).resolve().parents[1]
suite=unittest.defaultTestLoader.discover(str(P/'tests'),pattern='test_image_transfer.py')
r=unittest.TextTestRunner(verbosity=2).run(suite)
report=dict(status='PASS' if r.wasSuccessful() else 'FAIL',tests=r.testsRun,failures=len(r.failures),errors=len(r.errors),
 hardware_accessed=False,transport='127.0.0.1 UDP to actual C session executable',backend='host-only identity memory fixture, no NN',
 board_image_roundtrip=False,cases=['image upload/download with CRC','request/ACK loss and packet CRC retransmission',
 'whole-result CRC failure cancellation','bounded unsupported-service timeout','descriptor and verified atomic image save'])
sources=[Path(__file__),P/'tests/test_image_transfer.py',P/'tests/image_session_cli.exe',P/'host/a_image_transfer.py',P/'host/a_net_wire.py']
report['sha256']={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources}
(P/'IMAGE_TRANSFER_VALIDATION.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
sys.exit(0 if r.wasSuccessful() else 1)
