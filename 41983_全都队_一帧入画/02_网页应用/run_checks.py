"""Run offline application tests only; never discover or connect a physical board."""
from pathlib import Path
import hashlib
import json
import sys
import time
import unittest

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT))
import adapters
validation=ROOT/'validation';validation.mkdir(exist_ok=True)
start=time.monotonic()
suite=unittest.defaultTestLoader.discover(str(ROOT/'tests'))
with (validation/'offline_tests.txt').open('w',encoding='utf-8')as log:
    result=unittest.TextTestRunner(stream=log,verbosity=2).run(suite)
report=dict(status='PASS_OFFLINE_NOT_BOARD'if result.wasSuccessful()else'FAIL',tests_run=result.testsRun,
            failures=[str(test)for test,_ in result.failures],errors=[str(test)for test,_ in result.errors],
            elapsed_seconds=round(time.monotonic()-start,3),board_connected=False,
            scope='Loopback UDP identity fixture, UART reply fixture, HTTP/API, persistence. No style model or physical board.',
            sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in [ROOT/'server.py',ROOT/'adapters.py',ROOT/'compare_results.py',ROOT/'web/app.js',ROOT/'tests/test_app.py']})
(validation/'OFFLINE_TESTS.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=False,indent=2))
raise SystemExit(0 if result.wasSuccessful()else 1)
