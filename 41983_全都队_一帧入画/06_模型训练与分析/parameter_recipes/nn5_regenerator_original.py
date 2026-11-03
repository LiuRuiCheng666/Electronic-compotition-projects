"""Rebuild final NNW1 weights; optional exact analytic regeneration of 3 styles.

No training is performed. Blueprint/emboss reuse archived exported slots.
Original scripts are preserved. AST selects only parameter functions/statements,
avoiding historical training imports, absolute data paths and write side effects.
"""
from pathlib import Path
import argparse,ast,hashlib,json,struct,zlib
ROOT=Path(__file__).resolve().parents[1]
TOOLS=ROOT/'src/legacy_board/tools'
def sha(b):return hashlib.sha256(b).hexdigest()
def parsed(name):return ast.parse((TOOLS/name).read_text('utf-8-sig'),filename=name)
def function(name,fn,scope):
    node=next(n for n in parsed(name).body if isinstance(n,ast.FunctionDef) and n.name==fn)
    exec(compile(ast.fix_missing_locations(ast.Module(body=[node],type_ignores=[])),name,'exec'),scope)
def fragment(name,start,end,scope):
    main=next(n for n in parsed(name).body if isinstance(n,ast.FunctionDef) and n.name=='main')
    nodes=[];active=False
    for node in main.body:
        names=[x.id for x in node.targets if isinstance(x,ast.Name)] if isinstance(node,ast.Assign) else []
        if start in names:active=True
        if active:nodes.append(node)
        if active and end in names:break
    assert nodes and end in names
    exec(compile(ast.fix_missing_locations(ast.Module(body=nodes,type_ignores=[])),name,'exec'),scope)
    return scope[end]
def regenerate():
    import numpy as np
    s=dict(np=np,struct=struct,CINS=[4,4,4,8,4,4,4,4,4],COUTS=[4,4,8,4,4,4,4,4,3])
    function('train_sunny.py','neutral_slot',s)
    function('build_reference4.py','layer',s)
    function('build_illustration4.py','mixed',s)
    function('build_illustration4.py','build',s)
    refs=json.loads((ROOT/'provenance/retro_REFERENCE_STATS.json').read_text('utf-8'))
    retro,_=s['build']('retro',refs)
    # Execute only buffer construction through its final bytes conversion.
    main=next(n for n in parsed('build_pixel_mosaic.py').body if isinstance(n,ast.FunctionDef) and n.name=='main')
    nodes=[];active=False
    for n in main.body:
        if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='slot' for t in n.targets):
            if not active:active=True
            elif isinstance(n.value,ast.Call) and isinstance(n.value.func,ast.Name) and n.value.func.id=='bytes':
                nodes.append(n);break
        if active:nodes.append(n)
    ps=dict(s)
    exec(compile(ast.fix_missing_locations(ast.Module(body=nodes,type_ignores=[])),'build_pixel_mosaic.py','exec'),ps)
    glitch=fragment('build_glitch.py','b','slot',dict(s,PALETTES=np.array(
        [[4,18,114,235,220,78,242,255],[3,30,200,42,80,232,190,255],[14,104,226,206,58,220,244,255]],np.uint8)))
    return {0:retro,1:ps['slot'],4:glitch}
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--regenerate',action='store_true',help='Requires numpy; regenerate retro/mosaic/glitch from original parameter code')
    args=ap.parse_args()
    assert not args.output.exists(),'Choose a new output folder'
    meta=json.loads((ROOT/'weights/provenance.json').read_text('utf-8'))
    regenerated=regenerate() if args.regenerate else {}
    slots=[];report=[]
    for s in meta['styles']:
        original=(ROOT/'weights'/s['file']).read_bytes()
        b=regenerated.get(s['style'],original)
        assert b==original and len(b)==4096 and sha(b)==s['sha256'],s['name']+' mismatch'
        slots.append(b)
        report.append(dict(style=s['style'],name=s['name'],sha256=sha(b),
            method='regenerated_from_original_parameter_code' if s['style'] in regenerated else 'reused_archived_exported_slot'))
    payload=b''.join(slots)
    original=(ROOT/'weights/a4_dual_models_flash.bin').read_bytes()
    header=bytearray(original[:32]);struct.pack_into('<II',header,8,len(payload),zlib.crc32(payload))
    weights=bytes(header)+payload
    assert weights==original and sha(payload)==meta['payload_sha256']
    args.output.mkdir(parents=True)
    for s,b in zip(meta['styles'],slots):(args.output/s['file']).write_bytes(b)
    (args.output/'a4_dual_models_payload.bin').write_bytes(payload)
    (args.output/'a4_dual_models_flash.bin').write_bytes(weights)
    result=dict(status='PASS',styles=report,payload_sha256=sha(payload),weights_sha256=sha(weights),
                bytes=len(weights),full_boot_flash_image=False,training_performed=False)
    (args.output/'rebuild_report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
