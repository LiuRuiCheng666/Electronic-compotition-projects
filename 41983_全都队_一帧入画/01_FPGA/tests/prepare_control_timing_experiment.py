"""Prepare an isolated, cycle-equivalent control decode experiment; no board access."""
from pathlib import Path
import hashlib
import json
import re
import shutil

S = Path('D:/FPGA_C/V6_9_ETH_NETFIX_DEV_20261029')
D = Path('D:/FPGA_C/NETFIX_CONTROL_TIMING_EXPERIMENT_20261030')
D.mkdir(exist_ok=True)
(D/'tools').mkdir(exist_ok=True)
(D/'integration_tests').mkdir(exist_ok=True)
shutil.copytree(S/'rtl/nn/rtl', D/'rtl/nn/rtl', dirs_exist_ok=True)
for f in S.glob('*.mem'):
    shutil.copy2(f,D/f.name)
for n in ['test_eth_nn.py','test_v69_accumulator_width.py','run_dual_tests.py']:
    shutil.copy2(S/'tools'/n,D/'tools'/n)
base=Path('integration_tests/v69_nn/queue1/row_overlap/prefetch')
cases=[base/'stress/residual_fast/tail_on/runtime/frames2/pco4'/f'NN_128x72_slot{i}_engine1' for i in range(4)]
cases += [base/'stress/residual_fast/tail_on/runtime/frames2/pco4/NN_32x24_slot0_engine1',
          base/'normal/residual_fast/tail_on/runtime/pco4/NN_1280x720_slot0_engine1']
for case in cases:
    (D/case).mkdir(parents=True,exist_ok=True)
    for f in (S/case).iterdir():
        if f.name=='test.sv' or f.suffix=='.mem':shutil.copy2(f,D/case/f.name)
f=D/'rtl/nn/rtl/net_top.v'
original=f.read_text(encoding='utf-8')
s=original.replace('wire row_tail=TAIL_ENABLE && li==10;', '''// Register decodes alongside the layer index, without an extra cycle.
    reg row_zero_registered,row_tail_registered;
    function decode_row_zero;
        input [4:0] index;
        begin decode_row_zero=ROW_ENABLE && index==5'd0;end
    endfunction
    function decode_row_tail;
        input [4:0] index;
        begin decode_row_tail=TAIL_ENABLE && index==5'd10;end
    endfunction
    wire row_tail=row_tail_registered;''')
assert s!=original
assert len(re.findall(r'\bli\s*<=',s))==4
s=s.replace("li <= 5'd0;", "li <= 5'd0; row_zero_registered<=ROW_ENABLE; row_tail_registered<=1'b0;")
s=s.replace("li<=li+1'b1;", "li<=li+1'b1; row_zero_registered<=decode_row_zero(li+5'd1); row_tail_registered<=decode_row_tail(li+5'd1);")
s=s.replace("li <= row_feed ? 5'd2 : li + 5'd1;", "li <= row_feed ? 5'd2 : li + 5'd1;\n                    row_zero_registered<=decode_row_zero(row_feed?5'd2:li+5'd1);\n                    row_tail_registered<=decode_row_tail(row_feed?5'd2:li+5'd1);")
s=s.replace('assign row_feed=(ROW_ENABLE && li==0) || row_tail;', 'assign row_feed=row_zero_registered || row_tail;')
s=s.replace('(TAIL_ENABLE && st==S_LD && li==10)', '(row_tail && st==S_LD)')
assert s.count('row_zero_registered<=')==4
assert s.count('row_tail_registered<=')==4
f.write_text(s,encoding='utf-8')
# Check every index, including 31->0 wrap. Typed 5-bit function arguments are
# deliberate; an untruncated 32-bit expression would silently change wrap.
for row in [0,1]:
    for tail in [0,1]:
        for index in range(32):
            old_feed=bool(row and index==0 or row and tail and index==10)
            for update in ['reset','start','increment','next']:
                nxt=0 if update in ('reset','start') else ((2 if old_feed else index+1)&31 if update=='next' else (index+1)&31)
                z=bool(row and nxt==0);t=bool(row and tail and nxt==10)
                assert (z or t)==bool(row and nxt==0 or row and tail and nxt==10)
manifest=dict(status='EXPERIMENT_ONLY_PENDING_NN_REFERENCE_AND_PHYSICAL_BUILD',board_verified=False,
    production_changed=False,source=str(S),original_sha256=hashlib.sha256(original.encode()).hexdigest(),
    candidate_sha256=hashlib.sha256(f.read_bytes()).hexdigest(),
    scope='Registered layer decode, same update edges and 5-bit wrap; weights/arithmetic/clock unchanged.')
(D/'EXPERIMENT.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
(D/'README.md').write_text('# 控制译码时序实验（不是可烧录工程）\n\n仅复制NN RTL和6套整数参考夹具。两项译码标志与layer index同周期更新，不增加流水延迟。当前生产目录及正在运行的布局布线没有改动。\n\n仍需完整NN对照、完整工程综合及真实STA；不能凭这项实验声称时序或帧率提升。\n',encoding='utf-8')
print('Prepared isolated experiment:',D)
