"""Check a prepared training copy without starting an optimizer or changing weights."""
from pathlib import Path
import argparse,hashlib,json,sys
import numpy as np
import torch


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--prepared',type=Path,required=True)
    ap.add_argument('--output',type=Path)
    a=ap.parse_args();root=a.prepared.resolve()
    setup=json.loads((root/'PATH_REMAP_REPORT.json').read_text('utf-8'))
    data=Path(setup['data'])
    assert (data/'train').is_dir() and (data/'val').is_dir()
    sys.path[:0]=[str(root),str(root/'board_reference/tools')]
    import train_students as students
    import train_batch10_styles as blueprint
    import train_portable_candidates as emboss
    from art_models import ArtTransformer
    from board_exact_infer import tone_table
    assert students.P==root
    assert students.BASE==root/'board_reference'
    table=tone_table()
    assert table.shape==(256,) and np.isfinite(table).all()
    source_root=Path(__file__).resolve().parents[2]
    tone=root/'board_reference/rtl/nn/rtl/camera_tone_mapper.v'
    assert tone.read_bytes()==(source_root/'01_FPGA/rtl/nn/rtl/camera_tone_mapper.v').read_bytes()
    teacher_file=root/'architecture_experiments/glass_mosaic_rgb_v1/model_best.pth'
    teacher=ArtTransformer().eval()
    teacher.load_state_dict(torch.load(teacher_file,map_location='cpu',weights_only=True)['state_dict'],strict=True)
    torch.set_num_threads(2)
    torch.manual_seed(41983)
    x=torch.rand(1,3,32,32)
    net=students.Student()
    target=blueprint.target(x,'midnight_blueprint')
    y=net(x)
    assert y.shape==target.shape==x.shape
    loss=blueprint.objective(y,target)
    loss.backward()
    assert all(v.grad is None or torch.isfinite(v.grad).all() for v in net.parameters())
    net.fold_qat();net.project()
    with torch.inference_mode():
        q=net(x);t=teacher(x)
    assert q.shape==t.shape==x.shape and torch.isfinite(q).all() and torch.isfinite(t).all()
    result={'status':'PASS','prepared_modules_import':True,'current_final_tone_reference':True,
            'matched_teacher_state_loaded_strict':True,'student_forward_backward':True,
            'qat_forward':True,'optimizer_steps':0,'original_weights_changed':False,
            'external_train_jpegs':len(list((data/'train').glob('*.jpg'))),
            'external_val_jpegs':len(list((data/'val').glob('*.jpg'))),
            'tone_source_sha256':hashlib.sha256(tone.read_bytes()).hexdigest()}
    if a.output:a.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
