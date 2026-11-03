"""Inference-only, same-style standard-network comparison bound to current final slot2.
No training/optimizers. GPU times are not described as FPGA board latency.
"""
from pathlib import Path
import sys,json,re,hashlib,time,statistics,tempfile,argparse
import numpy as np,torch
from PIL import Image,ImageDraw
P=Path(__file__).resolve().parents[2]
E=P/'07_性能验证'
T=P/'06_模型训练与分析/training'
sys.path[:0]=[str(T),str(T/'teacher'),str(E/'tools')]
from train_students import Student,export
from transformer_net import TransformerNet
from board_exact_infer import load_slots,infer_codes,displayed,tone_table
from quality_metrics import metrics
sha=lambda f:hashlib.sha256(Path(f).read_bytes()).hexdigest()
def camera_image(path):
 rgb=np.asarray(Image.open(path).convert('RGB').resize((1920,1080),Image.Resampling.BICUBIC))
 x=240+(9*np.arange(640))//4;y=(9*np.arange(480))//4
 return torch.from_numpy(rgb[y[:,None],x[None,:]].transpose(2,0,1).copy())

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path);ap.add_argument('--verify-only',action='store_true');args=ap.parse_args()
 out=args.output or E/('replay_'+time.strftime('%Y%m%d_%H%M%S'))
 if not args.verify_only:out.mkdir(exist_ok=False)
 cp=P/'06_模型训练与分析/runs/emboss/model_best.pth'
 provenance=json.loads((cp.parent/'TRAINING_MANIFEST.json').read_text(encoding='utf-8'))
 teacher_cp=T/'teacher/glass.pth'
 assert sha(cp)==provenance['checkpoint_sha256'] and sha(teacher_cp)==provenance['teacher_sha256']
 blob=(P/'01_FPGA/flash_assets/a4_dual_models_flash.bin').read_bytes();part=blob[32+2*4096:32+3*4096]
 assert hashlib.sha256(part).hexdigest()==provenance['slot_sha256']
 torch.set_num_threads(4);torch.backends.cudnn.benchmark=False;torch.backends.cudnn.allow_tf32=False;torch.backends.cuda.matmul.allow_tf32=False
 net=Student().cuda();net.norms=torch.nn.ModuleList([torch.nn.Identity()for _ in range(9)]);net.qat=True
 net.load_state_dict(torch.load(cp,map_location='cuda',weights_only=True)['state_dict']);net.eval()
 with tempfile.TemporaryDirectory() as d:
  export(net,Path(d));assert (Path(d)/'slot.bin').read_bytes()==part,'checkpoint is not deployed slot'
 teacher=TransformerNet().cuda().eval();state=torch.load(teacher_cp,map_location='cuda',weights_only=True)['state_dict']
 assert all(k.startswith('core.') for k in state)
 teacher.load_state_dict({k[5:]:v for k,v in state.items()})
 official=TransformerNet().cuda().eval();ocp=T/'teacher/mosaic.pth';state=torch.load(ocp,map_location='cuda',weights_only=True)
 official.load_state_dict({k:v for k,v in state.items() if not re.search(r'in\d+\.(running_mean|running_var)$',k)})
 for model in (net,teacher,official):
  for v in model.parameters():v.requires_grad_(False)
 case_spec=json.loads((E/'evaluation_inputs.json').read_text('utf-8'))['cases']
 files=[E/c['file'] for c in case_spec]
 assert all(sha(f)==c['sha256'] for f,c in zip(files,case_spec))
 assert len(files)==20
 used={x['sha256'] for x in provenance['training_files']+provenance['validation_files']}
 assert not {sha(f) for f in files}&used
 slots,_=load_slots('cuda',P/'01_FPGA/flash_assets');table=tone_table()
 assert len(table)==256
 if args.verify_only:
  print('PASS: portable matched glass checkpoint, slot byte export, standard teacher, official initialization, twenty reserved cases and board tone identity; no training or board access');return
 rows=[];x=None
 with torch.inference_mode():
  for i,f in enumerate(files):
   rgb=camera_image(f).permute(1,2,0).numpy().astype(np.uint8)
   codes=np.zeros((480,640,4),np.uint8);codes[:,:,:3]=rgb//2
   input_rgb=codes[:,:,:3]*2;x=torch.from_numpy(input_rgb.transpose(2,0,1).copy()).cuda().float()[None]/255
   raw,_,_=infer_codes(codes,slots[2]);integer=displayed(raw,table)
   y=net(x);qy=(y[0].clamp(0,1)*255).round().byte().permute(1,2,0).cpu().numpy();student_display=displayed(qy,table)
   teacher_image=(teacher(x*255).clamp(0,255)[0]).round().byte().permute(1,2,0).cpu().numpy()
   official_image=(official(x*255).clamp(0,255)[0]).round().byte().permute(1,2,0).cpu().numpy()
   row=dict(case=i,input_source=f.relative_to(E).as_posix(),input_sha256=sha(f),integer_vs_matched_teacher=metrics(integer,teacher_image),
    integer_vs_matched_qat_pytorch=metrics(integer,student_display),integer_vs_official_mosaic=metrics(integer,official_image))
   rows.append(row)
   (out/f'metrics_{i:02d}.json').write_text(json.dumps(row,indent=2,allow_nan=False),encoding='utf-8')
   if i<8:
    names=['Input reconstructed RGB8','Deployed integer + board tone','Matched TransformerNet teacher','Official Mosaic initialization']
    panel=Image.new('RGB',(1280,270),'white');draw=ImageDraw.Draw(panel)
    for j,(name,im) in enumerate(zip(names,[input_rgb,integer,teacher_image,official_image])):
     panel.paste(Image.fromarray(im).resize((320,240)),(j*320,30));draw.text((j*320+4,4),name,fill='black')
    panel.save(out/f'comparison_{i}.png')
    for name,im in [('input',input_rgb),('deployed',integer),('teacher',teacher_image),('qat',student_display)]:Image.fromarray(im).save(out/f'case{i}_{name}.png')
   print('GLASS_REFERENCE_CASE',i+1,flush=True)
  timing={}
  for name,model,scale in [('student_qat_pytorch',net,1),('matched_standard_teacher',teacher,255),('official_mosaic',official,255)]:
   for _ in range(5):model(x*scale)
   torch.cuda.synchronize();samples=[]
   for _ in range(30):
    begin=torch.cuda.Event(enable_timing=True);end=torch.cuda.Event(enable_timing=True)
    begin.record();model(x*scale);end.record();end.synchronize();samples.append(begin.elapsed_time(end))
   timing[name]=dict(latency_ms=samples,median_ms=statistics.median(samples),p95_ms=float(np.percentile(samples,95)))
 summary={name:dict(psnr_db_mean=(float(np.mean([r[name]['psnr_db'] for r in rows if r[name]['psnr_db'] is not None])) if any(r[name]['psnr_db'] is not None for r in rows) else None),
   exact_cases=sum(r[name]['psnr_db'] is None for r in rows),
   ssim_mean=float(np.mean([r[name]['ssim_rgb_mean'] for r in rows]))) for name in ['integer_vs_matched_teacher','integer_vs_matched_qat_pytorch','integer_vs_official_mosaic']}
 report=dict(status='MEASURED_OFFLINE_MATCHED_GLASS_ONLY',training_started=False,assessment_scope='Software quality and same-GPU inference comparison for current final slot2; physical board measurements reported separately.',
  same_style_teacher=True,deployed_slot=2,checkpoint_export_equals_slot=True,
  model_parameters=dict(student=sum(v.numel() for v in net.parameters()),standard=sum(v.numel() for v in teacher.parameters())),
  deployed_slot_sha256=hashlib.sha256(part).hexdigest(),checkpoint_sha256=sha(cp),teacher_sha256=sha(teacher_cp),official_mosaic_sha256=sha(ocp),
  preprocessing='Camera center1440x1080 ->640x480 point sampling; identical reconstructed RGB8=2*RGB7 supplied to both models; integer display tone vs teacher raw RGB by original distillation objective',
  timing_scope='Same CUDA device, inference-only, one640x480 image, five warmups, thirty CUDA-event timings. Excludes file IO; student display tone not timed. Not FPGA board latency.',
  device=torch.cuda.get_device_name(0),torch_version=torch.__version__,summary=summary,timings=timing,cases=rows,
  limits=['Matched teacher comparison for current final slot2 (emboss/glass); other four styles are outside this same-style comparison',
   'Original official Mosaic weights are initialization, not the same fine-tuned teacher; scores are not an aesthetic ranking',
   'Physical board throughput/switch/task measurements are in 07_性能验证/原始证据; this script measures software quality and GPU timings',
   'Source training was earlier; this script only infers existing weights; original pretraining exposure is unknown'])
 (out/'REPORT.json').write_text(json.dumps(report,ensure_ascii=False,indent=2,allow_nan=False),encoding='utf-8')
 lines=['# 当前玻璃风格：匹配标准网络对比','',
  '本轮只做推理，没有训练。当前提交slot2与原QAT检查点重新导出的4096B逐字节相同。',
  '20张保留集图片与此学生模型训练/验证列表无SHA交集；大模型早期预训练接触情况未知。','',
  '|比较|平均PSNR dB|平均RGB SSIM|','|---|---|---|']
 for name,v in summary.items():
  psnr='∞（全部逐像素相同）' if v['psnr_db_mean'] is None else f"{v['psnr_db_mean']:.4f}"
  lines.append(f"|{name}|{psnr}|{v['ssim_mean']:.6f}|")
 lines+=['','|GPU网络|参数数|中位延迟ms|P95 ms|','|---|---|---|---|']
 for name,v in timing.items():lines.append(f"|{name}|{report['model_parameters']['student' if name=='student_qat_pytorch' else 'standard']}|{v['median_ms']:.4f}|{v['p95_ms']:.4f}|")
 lines+=['','设备：'+report['device'],report['timing_scope'],'','限制：']+['- '+s for s in report['limits']]
 (out/'REPORT.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
 print(json.dumps(dict(summary=summary,timing=timing),ensure_ascii=False),flush=True)
if __name__=='__main__':main()
