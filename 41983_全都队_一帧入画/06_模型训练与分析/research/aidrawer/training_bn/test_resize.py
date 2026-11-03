# -*- coding: utf-8 -*-
"""数值测试：验证 resize_keep_ratio 修复是否正确（含 426 复现场景）"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# 直接从源码提取函数，避免 import 触发 torch
import ast


def load_func(path, name):
    src = open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            ns = {}
            exec(compile(ast.Module(body=[n], type_ignores=[]), "<f>", "exec"), ns)
            return ns[name]
    raise RuntimeError("找不到函数 %s" % name)


def net_out(H, W, sys_mod):
    """按网络结构推算输出尺寸"""
    def down(n):   # stride-2 卷积
        return (n - 1) // 2 + 1
    def up(n):
        return n * 2
    h = up(up(down(down(H))))
    w = up(up(down(down(W))))
    return h, w


f_eval = load_func(os.path.join(HERE, "evaluate.py"), "resize_keep_ratio")
f_styl = load_func(os.path.join(HERE, "stylize.py"), "resize_keep_ratio")

print("=" * 78)
print("① 复现你的报错场景（COCO val2017 里的 640×426）")
print("=" * 78)
cases = [
    (640, 426, 640),   # ← 你报错的那张
    (640, 427, 640),
    (426, 640, 640),
    (640, 480, 640),
    (1920, 1080, 640),
    (1280, 720, 640),
    (333, 500, 640),
    (100, 60, 640),
    (640, 426, 256),
    (1920, 1080, 256),
]
print("%-18s %-10s %-14s %-12s %s" % ("输入 (w,h)", "max_size", "对齐后", "网络输出", "判定"))
print("-" * 78)
allok = True
for w, h, mx in cases:
    # 注意: resize_keep_ratio 的参数顺序是 (w, h, max_size)
    nw, nh = f_eval(w, h, mx)
    oh, ow = net_out(nh, nw, None)
    ok = (ow == nw and oh == nh)
    ok4 = (nw % 4 == 0 and nh % 4 == 0)
    status = "OK" if (ok and ok4) else "FAIL"
    if not (ok and ok4):
        allok = False
    print("%-18s %-10d %-14s %-12s %s" % ("(%d,%d)" % (w, h), mx,
                                          "(%d,%d)" % (nw, nh), "(%d,%d)" % (ow, oh), status))

print()
print("=" * 78)
print("② 两个文件的函数行为是否一致")
print("=" * 78)
for w, h, mx in cases:
    a = f_eval(w, h, mx)
    b = f_styl(w, h, mx)
    if a != b:
        print("  !! 不一致 (%d,%d,%d): eval=%s stylize=%s" % (w, h, mx, a, b))
        allok = False
print("  OK 两处实现完全一致" if allok else "  存在不一致")

print()
print("=" * 78)
print("③ 边界情况")
print("=" * 78)
edge = [
    (3, 3, 640, "极小图"),
    (5, 7, 640, "小于 4 的尺寸"),
    (640, 640, 640, "正方形且正好等于上限"),
    (641, 641, 640, "略超上限"),
    (0, 0, 640, "零尺寸(不应崩)"),
]
for w, h, mx, desc in edge:
    try:
        nw, nh = f_eval(w, h, mx)
        print("  %-24s (%d,%d) max=%d → (%d,%d) %s" % (desc, w, h, mx, nw, nh,
              "OK" if nw >= 4 and nh >= 4 and nw % 4 == 0 and nh % 4 == 0 else "!!"))
    except Exception as e:
        print("  %-24s 抛异常: %s" % (desc, e)); allok = False

print()
print("=" * 78)
print("结论:", "修复正确 ✅" if allok else "仍有问题 ❌")
print("=" * 78)
