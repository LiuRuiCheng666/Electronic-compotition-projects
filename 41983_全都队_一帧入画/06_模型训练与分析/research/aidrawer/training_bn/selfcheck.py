# -*- coding: utf-8 -*-
"""静态自检：语法解析 + 跨文件参数一致性（只读，不执行任何模型代码）"""
import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["model.py", "train.py", "evaluate.py", "run_compare.py", "stylize.py"]

ok = True

# ---------- 1. 语法解析 ----------
print("=" * 70)
print("① 语法解析")
print("=" * 70)
trees = {}
for f in FILES:
    p = os.path.join(HERE, f)
    if not os.path.exists(p):
        print("  缺失: %s" % f); ok = False; continue
    src = open(p, encoding="utf-8").read()
    try:
        trees[f] = ast.parse(src)
        print("  OK   %-16s %d 行" % (f, len(src.splitlines())))
    except SyntaxError as e:
        print("  FAIL %-16s 第 %s 行: %s" % (f, e.lineno, e.msg)); ok = False


def cli_args(tree):
    """提取 argparse add_argument 的参数名"""
    out = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "add_argument":
            if n.args and isinstance(n.args[0], ast.Constant):
                out.add(n.args[0].value)
    return out


# ---------- 2. run_compare 传的参数 vs train/evaluate 接收的参数 ----------
print()
print("=" * 70)
print("② 参数传递一致性（run_compare → train / evaluate）")
print("=" * 70)
if "run_compare.py" in trees:
    rc_src = open(os.path.join(HERE, "run_compare.py"), encoding="utf-8").read()
    train_args = cli_args(trees["train.py"]) if "train.py" in trees else set()
    eval_args = cli_args(trees["evaluate.py"]) if "evaluate.py" in trees else set()

    # 从源码里找出传给 train.py 和 evaluate.py 的 --xxx（简单文本扫描）
    import re
    def passed(cmd_name, argset):
        m = re.search(cmd_name + r'"\](.*?)\]\s*$', rc_src, re.S | re.M)
        return m
    seg_train = rc_src.split('sys.executable, "train.py"')[1].split(']')[0]
    seg_eval = rc_src.split('sys.executable, "evaluate.py"')[1].split(']')[0]
    p_train = set(re.findall(r'"(--[a-z\-]+)"', seg_train))
    p_eval = set(re.findall(r'"(--[a-z\-]+)"', seg_eval))
    # 这两段里可能有变量拼接，取字面量即可
    missing_t = p_train - train_args
    missing_e = p_eval - eval_args
    print("  传给 train.py  :", len(p_train), "个参数")
    if missing_t:
        print("    !! train.py 不认识:", sorted(missing_t)); ok = False
    else:
        print("    OK 全部被 train.py 接受")
    print("  传给 evaluate.py:", len(p_eval), "个参数")
    if missing_e:
        print("    !! evaluate.py 不认识:", sorted(missing_e)); ok = False
    else:
        print("    OK 全部被 evaluate.py 接受")

# ---------- 3. evaluate.py 从 train.py 导入的名字是否存在 ----------
print()
print("=" * 70)
print("③ 跨文件导入检查（evaluate.py ← train.py）")
print("=" * 70)
if "evaluate.py" in trees and "train.py" in trees:
    want = []
    for n in ast.walk(trees["evaluate.py"]):
        if isinstance(n, ast.ImportFrom) and n.module == "train":
            want = [a.name for a in n.names]
    defined = set()
    for n in ast.walk(trees["train.py"]):
        if isinstance(n, (ast.FunctionDef, ast.ClassDef)):
            defined.add(n.name)
        if isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Name):
                    defined.add(t.id)
    print("  evaluate.py 需要:", want)
    miss = [w for w in want if w not in defined]
    if miss:
        print("  !! train.py 中不存在:", miss); ok = False
    else:
        print("  OK 全部存在")

# ---------- 4. model.py 归一化分支 ----------
print()
print("=" * 70)
print("④ model.py 归一化分支")
print("=" * 70)
if "model.py" in trees:
    src = open(os.path.join(HERE, "model.py"), encoding="utf-8").read()
    for kind in ["instance", "batch", "none"]:
        has = ('"%s"' % kind) in src
        print("  %-9s %s" % (kind, "OK 已支持" if has else "!! 缺失"))
        if not has:
            ok = False

# ---------- 5. 三档骨架一致性 ----------
print()
print("=" * 70)
print("⑤ 目录内容")
print("=" * 70)
for f in sorted(os.listdir(HERE)):
    p = os.path.join(HERE, f)
    if os.path.isfile(p):
        print("  %-18s %7d B" % (f, os.path.getsize(p)))

print()
print("=" * 70)
print("结论:", "全部通过 ✅" if ok else "存在问题 ❌")
print("=" * 70)
sys.exit(0 if ok else 1)
