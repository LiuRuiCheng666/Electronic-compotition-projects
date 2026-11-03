# -*- coding: utf-8 -*-
"""
training_plus 自检 + 功能测试（不需要 GPU、不需要 VGG、不训练）

覆盖：
  ① 语法解析
  ② 与 training 的一致性（model.py / stylize.py 必须逐字节相同）
  ③ 训练算法未被改动（关键代码片段比对）
  ④ 新增 CLI 参数齐全
  ⑤ 运行目录解析逻辑（时间戳子文件夹 / 续训沿用原目录）
  ⑥ 检查点保存与读取往返（CPU 上的极小模型）
  ⑦ 损失曲线绘制（matplotlib）
"""
import ast
import filecmp
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TRAINING = os.path.join(ROOT, "training")
ok = True


def section(t):
    print()
    print("=" * 72)
    print(t)
    print("=" * 72)


# ---------- ① 语法 ----------
section("① 语法解析")
trees = {}
for f in ["model.py", "stylize.py", "train.py", "plot_log.py"]:
    p = os.path.join(HERE, f)
    if not os.path.exists(p):
        print("  缺失:", f); ok = False; continue
    src = open(p, encoding="utf-8").read()
    try:
        trees[f] = ast.parse(src)
        print("  OK   %-14s %d 行" % (f, len(src.splitlines())))
    except SyntaxError as e:
        print("  FAIL %-14s 第 %s 行: %s" % (f, e.lineno, e.msg)); ok = False

# ---------- ② 与 training 一致性 ----------
section("② model.py / stylize.py 是否与 training 逐字节相同")
for f in ["model.py", "stylize.py"]:
    a = os.path.join(TRAINING, f)
    b = os.path.join(HERE, f)
    same = filecmp.cmp(a, b, shallow=False)
    print("  %-14s %s" % (f, "相同 OK" if same else "不同 !!"))
    if not same:
        ok = False

# ---------- ③ 训练算法未改动 ----------
section("③ 核心训练算法片段比对（应与 training 一致）")
snippets = [
    "loss = (args.content_weight * l_content +",
    "l_content = F.mse_loss(of[args.content_layer], cf[args.content_layer])",
    "opt.zero_grad()",
    "loss.backward()",
    "opt.step()",
    "torch.bmm(f, f.transpose(1, 2))",
    "g / (c * h * w)",
    "transforms.RandomResizedCrop(size, scale=(0.5, 1.0))",
    "SLICE = {\"relu1_2\": 4, \"relu2_2\": 9, \"relu3_3\": 16, \"relu4_3\": 23}",
]
t_src = open(os.path.join(TRAINING, "train.py"), encoding="utf-8").read()
p_src = open(os.path.join(HERE, "train.py"), encoding="utf-8").read()
for s in snippets:
    int_, inp = s in t_src, s in p_src
    mark = "OK" if (int_ and inp) else ("新增加" if inp and not int_ else "!! 丢失")
    if not inp:
        ok = False
    print("  %-8s %s" % (mark, s[:58]))
# 确认没有把 resize_keep_ratio 的修复带进来
print()
print("  确认未引入 training_bn 的尺寸修复（stylize.py 应保持原样）：")
sj = open(os.path.join(HERE, "stylize.py"), encoding="utf-8").read()
print("    含 '// 2 * 2'（原版写法）:", "// 2 * 2" in sj)
print("    含 '// 4 * 4'（修复写法）:", "// 4 * 4" in sj)
if "// 4 * 4" in sj:
    print("    !! 不应包含修复版写法"); ok = False

# ---------- ④ CLI 参数 ----------
section("④ 新增 CLI 参数")
if "train.py" in trees:
    names = set()
    for n in ast.walk(trees["train.py"]):
        if isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "add_argument":
            if n.args and isinstance(n.args[0], ast.Constant):
                names.add(n.args[0].value)
    for want in ["--out-dir", "--tag", "--save-every", "--resume",
                 "--log-every", "--sample-every", "--plot-every",
                 "--workers", "--norm", "--seed"]:
        has = want in names
        print("  %-16s %s" % (want, "OK" if has else "!! 缺失"))
        if not has:
            ok = False

# ---------- ⑤ 运行目录解析 ----------
section("⑤ 运行目录解析逻辑")


def resolve_run_dir(resume, out_dir, tag=""):
    """复刻 train.py 中的逻辑"""
    import time as _t
    if resume and out_dir is None:
        return os.path.dirname(os.path.abspath(resume))
    base = out_dir or "runs"
    name = _t.strftime("%Y%m%d_%H%M%S")
    if tag:
        name += "_" + tag
    return os.path.join(base, name)


a = resolve_run_dir(None, r"D:\out", "exp1")
b = resolve_run_dir(None, r"D:\out")
c = resolve_run_dir(r"D:\out\20260916_190000\ckpt_step001000.pth", None)
print("  新训练+tag  :", a, "（含时间戳与 tag）", "OK" if ("exp1" in a and a.startswith(r"D:\out")) else "!!")
print("  新训练      :", b, "（含时间戳）", "OK" if b.startswith(r"D:\out") else "!!")
print("  续训(无out) :", c, "（沿用原目录）", "OK" if c == r"D:\out\20260916_190000" else "!!")
if not (c == r"D:\out\20260916_190000" and "exp1" in a and b.startswith(r"D:\out")):
    ok = False

# ---------- ⑥ 检查点往返 ----------
section("⑥ 检查点保存/读取往返（CPU、极小模型）")
try:
    import torch
    sys.path.insert(0, HERE)
    import train as T

    tmpd = tempfile.mkdtemp(prefix="tp_ckpt_")
    tiny = torch.nn.Sequential(torch.nn.Conv2d(3, 4, 3, padding=1))
    opt = torch.optim.Adam(tiny.parameters(), lr=1e-3)
    (tiny(torch.rand(1, 3, 8, 8)).sum()).backward()
    opt.step()
    cfg = {"norm": "instance", "size": 640}

    ck = T.save_checkpoint(tmpd, 1000, tiny, opt, cfg)
    m_p = os.path.join(tmpd, "model_step001000.pth")
    print("  model_step001000.pth 存在:", os.path.exists(m_p),
          "%.1f KB" % (os.path.getsize(m_p) / 1024))
    print("  ckpt_step001000.pth  存在:", os.path.exists(ck),
          "%.1f KB" % (os.path.getsize(ck) / 1024))

    loaded = torch.load(ck, map_location="cpu")
    keys = sorted(loaded.keys())
    print("  检查点包含字段:", keys)
    need = {"model", "optim", "step", "torch_rng", "config"}
    miss = need - set(keys)
    print("  必需字段齐全:", "OK" if not miss else "!! 缺 %s" % miss)
    if miss:
        ok = False
    print("  step 还原:", loaded["step"], "OK" if loaded["step"] == 1000 else "!!")
    # 权重可被直接加载（stylize.py 用法）
    tiny2 = torch.nn.Sequential(torch.nn.Conv2d(3, 4, 3, padding=1))
    tiny2.load_state_dict(torch.load(m_p, map_location="cpu"))
    print("  model_*.pth 可被 load_state_dict 直接加载: OK")
    shutil.rmtree(tmpd, ignore_errors=True)
except Exception as e:
    print("  !! 测试失败:", e)
    ok = False

# ---------- ⑦ 绘图 ----------
section("⑦ 损失曲线绘制")
try:
    from plot_log import plot_history
    hist = []
    for i in range(1, 21):
        hist.append({"step": i * 500,
                     "loss": 120.0 / (1 + i * 0.3) + 5,
                     "content": 10.0 / (1 + i * 0.25) + 1,
                     "style": 1.5e-5 / (1 + i * 0.4) + 1e-6,
                     "tv": 0.1 / (1 + i * 0.2) + 0.01})
    out = os.path.join(HERE, "_test_curve.png")
    r = plot_history(hist, out, "selfcheck 曲线")
    print("  生成成功:", r, "| 文件存在:", os.path.exists(out),
          "| %.1f KB" % (os.path.getsize(out) / 1024 if os.path.exists(out) else 0))
    if os.path.exists(out):
        os.remove(out)
    if not r:
        ok = False
except Exception as e:
    print("  !! 绘图测试失败:", e)
    ok = False

section("结论")
print("  全部通过 ✅" if ok else "  存在问题 ❌")
sys.exit(0 if ok else 1)
