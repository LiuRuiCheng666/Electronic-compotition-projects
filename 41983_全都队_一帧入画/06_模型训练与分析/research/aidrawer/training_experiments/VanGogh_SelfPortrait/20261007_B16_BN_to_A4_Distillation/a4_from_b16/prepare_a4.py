"""Freeze the chosen calibrated B16 and generate dependent A4 initialization."""
import argparse,json,shutil
from pathlib import Path
import torch
from support import digest
from structure import B16,main as prune
ROOT=Path('D:/aidrawer/output/VanGogh_SelfPortrait/20261007_B16_BN_to_A4_Distillation/a4_from_b16')

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--source',type=Path,default=ROOT.parent/'runs/portrait_b16_bn/model_final.pth')
    ap.add_argument('--check-only',action='store_true')
    a=ap.parse_args()
    source=a.source.resolve()
    source_hash=digest(source)
    net=B16().eval()
    state=torch.load(source,map_location='cpu',weights_only=True)
    net.load_state_dict(state,strict=True)
    cfg=json.loads((source.parent/'config.json').read_text(encoding='utf-8'))
    if cfg['norm']!='batch':raise RuntimeError('Expected B16 BN')
    complete=[]
    for p in source.parent.glob('eval_step*'):
        if not (p/'metrics.json').exists() or not (p/'inference_model.pth').exists():continue
        snap=torch.load(p/'inference_model.pth',map_location='cpu',weights_only=True)
        if state.keys()==snap.keys() and all(torch.equal(state[k],snap[k]) for k in state):complete.append(p)
    if not complete:raise RuntimeError('Source must match a completed calibrated evaluation snapshot')
    selected=max(complete,key=lambda p:int(p.name.split('_')[1][4:]))
    step=int(selected.name.split('_')[1][4:])
    print(f'Selected B16: {source}; calibrated step={step}; SHA256={digest(source)}')
    if step<=cfg['vga_start']:print('NOTE: B16 has not completed its VGA training stage; extending to 12000 is recommended.')
    if a.check_only:return
    frozen=ROOT/'frozen_b16'
    if frozen.exists() or (ROOT/'a4_init.pth').exists() or (ROOT/'pruning_report.json').exists():raise RuntimeError('Initialization already exists; preserve it and use a separate experiment for another teacher.')
    frozen.mkdir()
    if digest(source)!=source_hash:raise RuntimeError('Source changed during inspection; finish training before freezing')
    shutil.copy2(source,frozen/'model_final.pth')
    if digest(frozen/'model_final.pth')!=source_hash:raise RuntimeError('Source changed during copy; use a fresh experiment directory')
    identity={'source':str(source),'sha256':source_hash,'style_sha256':cfg['style_sha256'],'step':step,'evaluation':str(selected),'architecture':'B16 BN, one residual block'}
    (frozen/'identity.json').write_text(json.dumps(identity,indent=2),encoding='utf-8')
    shutil.copy2(source.parent/'config.json',frozen/'source_config.json')
    torch.set_num_threads(4)
    prune()
if __name__=='__main__':main()
