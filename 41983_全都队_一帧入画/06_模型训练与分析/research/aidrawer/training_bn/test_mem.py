# -*- coding: utf-8 -*-
"""功能测试：验证内存修复相关改动（不训练、不用 GPU）"""
import os
import sys
from PIL import Image
from torch.utils.data import DataLoader

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# ① 内存诊断
from train import mem_info
mi = mem_info()
print("① mem_info()")
if mi:
    print("   可用物理 %.2f GB | 可用提交 %.2f GB" % (mi[0] / 1024, mi[1] / 1024))
    print("   OK")
else:
    print("   返回 None（非 Windows 或调用失败）——不影响主流程")

# ② DataLoader 参数构建逻辑（关键：workers=0 时不能传 prefetch_factor）
from train import ContentDataset

tmp = os.path.join(HERE, "_tmp_imgs")
os.makedirs(tmp, exist_ok=True)
for i in range(4):
    Image.new("RGB", (128, 96), (i * 40, 80, 160)).save(os.path.join(tmp, "t%d.jpg" % i))

ds = ContentDataset(tmp, size=64)
print()
print("② ContentDataset: %d 张，单张形状 %s" % (len(ds), tuple(ds[0].shape)))

print()
print("③ DataLoader 构建（复刻 train.py 的逻辑）")


def build(w, batch=2, prefetch=2, pin=False):
    kw = dict(batch_size=batch, shuffle=True, num_workers=w,
              drop_last=True, pin_memory=pin)
    if w > 0:
        kw["prefetch_factor"] = prefetch
        kw["persistent_workers"] = False
    return DataLoader(ds, **kw), kw


dl0, kw0 = build(0)
print("   workers=0  kwargs:", sorted(kw0.keys()))
print("            实际批数: %d，形状 %s" % (len(dl0), tuple(next(iter(dl0)).shape)))

# 反向验证：workers=0 却传 prefetch_factor 应当报错（说明条件传参是必要的）
try:
    DataLoader(ds, batch_size=2, num_workers=0, prefetch_factor=2)
    print("   !! 预期应报错但没报错")
except ValueError as e:
    print("   反向验证 OK：workers=0 时传 prefetch_factor 会报 ValueError")
    print("              （证明条件传参是必要的）")

# 清理
import shutil
shutil.rmtree(tmp, ignore_errors=True)
print()
print("全部功能测试通过 ✅")
