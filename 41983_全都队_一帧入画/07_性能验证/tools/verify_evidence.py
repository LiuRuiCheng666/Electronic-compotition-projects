"""Verify recorded measurements, evaluation inputs and current model binding."""
from pathlib import Path
import collections, csv, hashlib, json, math, statistics

E=Path(__file__).resolve().parents[1]
P=E.parent
read=lambda p:json.loads(p.read_text('utf-8-sig'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
j=read(E/'原始证据/result.json')
s=read(E/'实测统计.json')
assert j['status']=='COLLECTION_COMPLETE'
switches=j['switches']; tasks=j['task_samples']; steady=j['steady_samples']
assert len(switches)==60 and len(tasks)==150 and len(steady)==58
counts=collections.Counter((x['from_style'],x['to_style']) for x in switches)
assert counts==collections.Counter({(a,b):3 for a in range(5) for b in range(5) if a!=b})
raw=(E/'原始证据/serial_log.txt').read_text('utf-8')
for x in switches:
    assert x['core_hz']==160000000 and x['switch_us_exact']==x['cycles']/160
    assert 0<x['switch_us_exact']<100000
    assert all(x[k]==v for k,v in [('valid',1),('pending',0),('superseded',0),('timeout',0),('fault',0),('below_100ms',1)])
    assert f"cycles={x['cycles']} core_hz={x['core_hz']}" in raw
    assert all(x['delta'][k]==0 for k in ['abort','skipped','stale','underflows','blank_frames','partial_frames','errors_before','errors_after'])
first=switches[0]['before'];last=switches[-1]['after']
assert all(last[k]-first[k]==3064 for k in ['capture','nn','new'])
assert last['uptime_ms']-first['uptime_ms']==102124
assert all(x['CAP']==30 and x['NEW']==30 and x['HDMI']==60 for x in steady)
assert all(x[k]==0 for x in steady for k in ['errors','underflows','blank_frames','partial_frames'])
assert collections.Counter(x['style'] for x in tasks)==collections.Counter({i:30 for i in range(5)})
assert all(x['accepted_frame']==x['done_frame'] for x in tasks)
assert math.isclose(statistics.mean(x['elapsed_ms'] for x in tasks),s['task_overall_mean_ms'])
assert math.isclose(max(x['switch_us_exact']/1000 for x in switches),s['switch']['max_ms'])
for e in s['evidence']:
    p=E/e['file'];assert p.stat().st_size==e['bytes'] and sha(p)==e['sha256'],e['file']
with (E/'原始证据/switches.csv').open(encoding='utf-8-sig',newline='') as f:
    rows=list(csv.DictReader(f));assert len(rows)==len(switches)
    assert all(int(a['cycles'])==b['cycles'] for a,b in zip(rows,switches))
with (E/'原始证据/tasks.csv').open(encoding='utf-8-sig',newline='') as f:
    rows=list(csv.DictReader(f));assert len(rows)==len(tasks)
    assert all(int(a['done_frame'])==b['done_frame'] and int(a['elapsed_ms'])==b['elapsed_ms'] for a,b in zip(rows,tasks))
r=read(E/'浮雕标准网络对比/REPORT.json')
slot=(P/'01_FPGA/flash_assets/a4_dual_models_flash.bin').read_bytes()[32+2*4096:32+3*4096]
assert hashlib.sha256(slot).hexdigest()==r['deployed_slot_sha256']
assert sha(P/'06_模型训练与分析/runs/emboss/model_best.pth')==r['checkpoint_sha256']
assert sha(P/'06_模型训练与分析/training/teacher/glass.pth')==r['teacher_sha256']
assert sha(P/'06_模型训练与分析/training/teacher/mosaic.pth')==r['official_mosaic_sha256']
inputs=read(E/'evaluation_inputs.json')['cases']
assert len(inputs)==len(r['cases'])==20
for a,b in zip(inputs,r['cases']):
    assert sha(E/a['file'])==a['sha256']==b['input_sha256']
provenance=read(P/'06_模型训练与分析/runs/emboss/TRAINING_MANIFEST.json')
used={x['sha256'] for x in provenance['training_files']+provenance['validation_files']}
assert not used & {c['sha256'] for c in inputs}
assert r['model_parameters']=={'student':1551,'standard':1679235}
assert r['summary']['integer_vs_matched_qat_pytorch']['exact_cases']==20
for key,metric in [('psnr_db_mean','psnr_db'),('ssim_mean','ssim_rgb_mean')]:
    assert math.isclose(statistics.mean(c['integer_vs_matched_teacher'][metric] for c in r['cases']),r['summary']['integer_vs_matched_teacher'][key],abs_tol=1e-12)
print('PASS: 60 switches / 20 directed pairs, 150 tasks, continuity counters, raw CSV/log/media hashes, 20 held-out cases and current slot/checkpoint/teacher binding')
