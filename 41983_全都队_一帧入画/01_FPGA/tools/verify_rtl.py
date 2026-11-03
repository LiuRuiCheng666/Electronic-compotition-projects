"""Run the final five-style ABI and screen-metrics testbenches; never access hardware."""
from pathlib import Path
import argparse,os,shutil,subprocess,tempfile,json
P=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--test',choices=['all','five_style_slots','simple_metrics_osd'],default='all')
ap.add_argument('--modelsim-bin',type=Path,default=Path(os.environ['MODELSIM_BIN']) if os.environ.get('MODELSIM_BIN') else None)
ap.add_argument('--plan',action='store_true')
a=ap.parse_args()
sources={
 'five_style_slots':[
  'rtl/c_frame_readback.v','rtl/c_nn_snapshot_apb.v','rtl/c_style_switch_monitor.v',
  'rtl/net_image_dispatch.v','rtl/net_image_lease.v','rtl/net_image_service.v',
  'rtl/video/frame_snapshot_service.v','rtl/nn/rtl/camera_nn_compare_pipeline.v',
  'rtl/nn/rtl/camera_nn_weight_boot_mux.v','rtl/nn/rtl/cat_fisheye_ddr.v',
  'rtl/nn/rtl/net_top.v','rtl/nn/rtl/nn_ddr_picture_display.v','rtl/nn/rtl/nn_ddr_selftest.v'],
 'simple_metrics_osd':['rtl/video/legacy_video_helpers.v','rtl/video/fps_decimal_bank.v']}
cases=list(sources) if a.test=='all' else [a.test]
for case in cases:
 for rel in sources[case]+[f'verification/{case}/test.sv']:
  if not (P/rel).is_file():raise SystemExit('Missing test dependency: '+rel)
if a.plan:
 print(json.dumps({case:sources[case]+[f'verification/{case}/test.sv'] for case in cases},indent=2));raise SystemExit(0)
exe=str(a.modelsim_bin/'vsim.exe') if a.modelsim_bin else shutil.which('vsim')
if not exe:raise SystemExit('Set MODELSIM_BIN or --modelsim-bin to the directory containing vsim.exe')
for case in cases:
 with tempfile.TemporaryDirectory(prefix='yizhen_rtl_') as td:
  work=Path(td);top='tb' if case=='five_style_slots' else 'tb_simple_osd'
  tb=(P/f'verification/{case}/test.sv').read_text(encoding='utf-8')
  (work/'test.sv').write_text(tb,encoding='utf-8')
  files=' '.join('"'+(P/rel).as_posix()+'"' for rel in sources[case])
  cmd=['onerror {quit -code 1}','vlib work','vmap work work',
       f'vlog -sv -timescale 1ns/1ps +incdir+"{P.as_posix()}" {files} test.sv',
       f'vsim -c work.{top}','run -all','quit -code 0']
  (work/'run.do').write_text('\n'.join(cmd),encoding='utf-8')
  r=subprocess.run([exe,'-c','-l','simulation.log','-do','run.do'],cwd=work,capture_output=True,text=True,errors='replace')
  output=r.stdout+r.stderr
  if r.returncode or 'PASS:' not in output or '** Fatal' in output:
   print(output);raise SystemExit('FAIL: '+case)
  print('\n'.join(line for line in output.splitlines() if 'PASS:' in line))
print('PASS: final RTL verification, no hardware access')
