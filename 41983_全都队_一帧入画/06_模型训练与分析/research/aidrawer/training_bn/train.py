# -*- coding: utf-8 -*-
"""
风格迁移训练脚本 · 对照实验版（training_bn）

与 training/train.py 的区别（3 处改进，算法本身不变）:
    ① 风格损失用科学计数法打印（%.3e）——原版 %.4f 会把 1e-5 显示成 0.0000
    ② 修掉 "target size [1,C,C] != input size [B,C,C]" 的广播告警
       （改用 expand 到 batch，数学等价，但不再刷屏）
    ③ 训练结束导出 train_log.json —— 含 loss 曲线、耗时、显存峰值、稳定性指标
       这份 JSON 是 run_compare.py 生成对照表的输入

训练原理（与原版一致）:
    预训练 VGG16 当"裁判"，判断输出图与内容图/风格图各有多像。
    总损失 = 内容损失(保结构) + 风格损失(保纹理风格) + TV损失(去噪)
    无需人工标注，只需"1 张风格图 + 一批内容图"。

用法:
    python train.py --style-image style/portrait.jpg --content-dir data/val2017 \
        --norm instance --channels 8 --n-res 3 --size 640 --batch-size 4 \
        --epochs 2 --out-dir runs/instance
"""
import argparse
import json
import os
import sys
import time

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader
from torchvision import transforms, models
from torchvision.utils import save_image
from PIL import Image

from model import FastNeuralStyleNet

VGG_MEAN = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
VGG_STD = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)


# ==================== VGG 特征提取（冻结） ====================
class VggFeatures(nn.Module):
    """按层切分 VGG16，输出指定层的特征图。切片索引即"取到该层为止"。"""

    SLICE = {"relu1_2": 4, "relu2_2": 9, "relu3_3": 16, "relu4_3": 23, "relu5_3": 30}

    def __init__(self, layers, require_grad=False):
        super().__init__()
        feats = models.vgg16(weights=models.VGG16_Weights.IMAGENET1K_V1).features
        self.names = list(layers)
        self.slices = nn.ModuleList()
        prev = 0
        for n in self.names:
            cut = self.SLICE[n]
            self.slices.append(nn.Sequential(*list(feats[prev:cut])))
            prev = cut
        for p in self.parameters():
            p.requires_grad = require_grad

    def forward(self, x):
        """x: [0,1] → 各层特征字典"""
        h = (x - VGG_MEAN.to(x)) / VGG_STD.to(x)
        outs = {}
        for n, s in zip(self.names, self.slices):
            h = s(h)
            outs[n] = h
        return outs


def gram_matrix(f):
    """Gram 矩阵 = 通道间相关性（风格统计）。按元素数归一化，避免尺度依赖。"""
    b, c, h, w = f.shape
    f = f.view(b, c, h * w)
    g = torch.bmm(f, f.transpose(1, 2))
    return g / (c * h * w)


def tv_loss(y):
    """总变差损失：抑制噪点，让输出更平滑"""
    return (torch.mean(torch.abs(y[:, :, 1:, :] - y[:, :, :-1, :])) +
            torch.mean(torch.abs(y[:, :, :, 1:] - y[:, :, :, :-1])))


def mem_info():
    """返回 (可用物理内存 MB, 可用提交内存 MB)。仅 Windows 有效，失败返回 None。

    为什么需要这个诊断：Windows 上 DataLoader 的子进程靠“共享文件映射”传数据，
    当系统提交内存（RAM + 页面文件）接近上限时会报 error code 1455 / ArrayMemoryError。
    这类报错看起来像“内存不足”，但常被误判为显存不足。
    """
    try:
        import ctypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong),
                        ("dwMemoryLoad", ctypes.c_ulong),
                        ("ullTotalPhys", ctypes.c_ulonglong),
                        ("ullAvailPhys", ctypes.c_ulonglong),
                        ("ullTotalPageFile", ctypes.c_ulonglong),
                        ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong),
                        ("ullAvailVirtual", ctypes.c_ulonglong),
                        ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

        st = MEMORYSTATUSEX()
        st.dwLength = ctypes.sizeof(st)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            return None
        return st.ullAvailPhys / 1048576.0, st.ullAvailPageFile / 1048576.0
    except Exception:
        return None


# ==================== 数据集 ====================
class ContentDataset(Dataset):
    """内容图数据集：随机裁切 + 水平翻转。不需要标签。"""

    EXTS = (".jpg", ".jpeg", ".png", ".bmp", ".webp")

    def __init__(self, root, size=256):
        self.paths = []
        for d, _, files in os.walk(root):
            for f in files:
                if f.lower().endswith(self.EXTS):
                    self.paths.append(os.path.join(d, f))
        if not self.paths:
            raise RuntimeError("在 %s 下没找到图片" % root)
        self.tf = transforms.Compose([
            transforms.RandomResizedCrop(size, scale=(0.5, 1.0)),
            transforms.RandomHorizontalFlip(),
            transforms.ToTensor(),          # → [0,1]
        ])

    def __len__(self):
        return len(self.paths)

    def __getitem__(self, i):
        img = Image.open(self.paths[i]).convert("RGB")
        return self.tf(img)


# ==================== 训练主流程 ====================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--style-image", required=True, help="风格图路径（1 张）")
    ap.add_argument("--content-dir", required=True, help="内容图目录（一批照片）")
    ap.add_argument("--channels", type=int, default=8, help="基准通道数 C（默认 8 = 1/4 版本）")
    ap.add_argument("--n-res", type=int, default=3, help="残差块个数")
    ap.add_argument("--norm", default="instance", choices=["instance", "batch", "none"])
    ap.add_argument("--size", type=int, default=256, help="训练裁切尺寸")
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--epochs", type=float, default=2.0)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--content-weight", type=float, default=1.0)
    ap.add_argument("--style-weight", type=float, default=1e5)
    ap.add_argument("--tv-weight", type=float, default=1e-6)
    ap.add_argument("--content-layer", default="relu3_3")
    ap.add_argument("--style-layers", default="relu1_2,relu2_2,relu3_3,relu4_3")
    ap.add_argument("--out-dir", default=None)
    ap.add_argument("--sample-every", type=int, default=500, help="每多少步存一张样图")
    ap.add_argument("--ckpt-every", type=int, default=2000, help="每多少步存一次权重")
    ap.add_argument("--workers", type=int, default=0,
                    help="DataLoader 子进程数。Windows 上强烈建议 0：每个子进程都会重新加载一份"
                         "torch，4 个 worker 容易撞上系统提交内存上限，"
                         "报 'error code 1455' 或 'ArrayMemoryError'（注意：这不是显存不足）")
    ap.add_argument("--prefetch-factor", type=int, default=2,
                    help="每个 worker 预取批数（仅 workers>0 时生效；调小可降内存）")
    ap.add_argument("--seed", type=int, default=0, help="随机种子（保证三组对照可比）")
    args = ap.parse_args()

    # 固定种子：三组对照必须从相同初始条件出发
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)

    dev = "cuda" if torch.cuda.is_available() else "cpu"
    print("=" * 66)
    print("训练配置")
    print("=" * 66)
    print("设备      :", dev, "|", torch.cuda.get_device_name(0) if dev == "cuda" else "（无 GPU）")
    print("归一化    :", args.norm)
    print("通道数 C  :", args.channels, "| 残差块:", int(args.n_res))
    print("裁切尺寸  :", args.size, "| batch:", args.batch_size)
    print("损失权重  : 内容=%g  风格=%g  tv=%g" % (args.content_weight, args.style_weight, args.tv_weight))
    print("风格层    :", args.style_layers)
    print("=" * 66)
    if args.out_dir is None:
        style_key = "".join(c if c.isascii() and (c.isalnum() or c in "_-") else "_" for c in os.path.splitext(os.path.basename(args.style_image))[0]).strip("_") or "style"
        norm_label = {"instance":"IN","batch":"BN","none":"NoNorm"}[args.norm]
        method = time.strftime("%Y%m%d_%H%M%S") + "_Teacher_%s_C%d_Res%d" % (norm_label,args.channels,args.n_res)
        args.out_dir = os.path.join("D:/aidrawer/output", style_key, method)
    os.makedirs(args.out_dir, exist_ok=True)

    # ---- 网络 ----
    net = FastNeuralStyleNet(args.channels, int(args.n_res), args.norm).to(dev)
    print("卷积权重: %d 个 (%.1f KB int8)" % (net.conv_param_count(), net.conv_param_count() / 1024))

    # ---- 裁判 VGG（冻结） ----
    style_layers = args.style_layers.split(",")
    vgg = VggFeatures(style_layers, require_grad=False).to(dev).eval()

    # ---- 风格图 → 目标 Gram ----
    st = transforms.Compose([transforms.Resize(args.size), transforms.ToTensor()])
    style_img = st(Image.open(args.style_image).convert("RGB")).unsqueeze(0).to(dev)
    with torch.no_grad():
        sf = vgg(style_img)
        style_grams = {k: gram_matrix(v) for k, v in sf.items()}

    # ---- 数据 ----
    ds = ContentDataset(args.content_dir, args.size)
    # 关键：prefetch_factor / persistent_workers 只在 workers>0 时才能传，
    # 否则 PyTorch 会直接报错。pin_memory 显式关掉（CPU 側不需要）。
    dl_kwargs = dict(batch_size=args.batch_size, shuffle=True,
                     num_workers=args.workers, drop_last=True, pin_memory=False)
    if args.workers > 0:
        dl_kwargs["prefetch_factor"] = args.prefetch_factor
        dl_kwargs["persistent_workers"] = False
    dl = DataLoader(ds, **dl_kwargs)
    steps_per_epoch = len(dl)
    total_steps = max(1, int(steps_per_epoch * args.epochs))
    print("内容图 %d 张 | 每轮 %d 步 | 计划 %d 步" % (len(ds), steps_per_epoch, total_steps))
    mi = mem_info()
    if mi:
        print("内存      : 可用物理 %.1f GB | 可用提交 %.1f GB" % (mi[0] / 1024, mi[1] / 1024))
        if mi[1] < 2048:
            print("!! 可用提交内存不足 2 GB，请把 --workers 设为 0 并降低 --batch-size")
    if args.workers > 0:
        print("提示      : workers=%d 会派生 %d 个子进程（每个都要加载一份 torch）。"
              % (args.workers, args.workers))
        print("            Windows 上若报 error code 1455 / ArrayMemoryError，请改用 --workers 0")

    opt = torch.optim.Adam(net.parameters(), lr=args.lr)

    history = []          # 每 50 步记录一次
    step = 0
    t0 = time.time()
    while step < total_steps:
        for content in dl:
            if step >= total_steps:
                break
            content = content.to(dev)
            B = content.shape[0]

            out = net(content)
            of = vgg(out)
            with torch.no_grad():
                cf = vgg(content)

            # 内容损失（保结构）
            l_content = F.mse_loss(of[args.content_layer], cf[args.content_layer])
            # 风格损失（保纹理风格）
            # 改进②: 风格 Gram 只有 1 份(风格图只有一张)，显式 expand 到 batch，
            #        避免广播告警。数学上与隐式广播等价。
            l_style = 0.0
            for k in style_layers:
                sg = style_grams[k].expand(B, -1, -1)
                l_style = l_style + F.mse_loss(gram_matrix(of[k]), sg)
            l_style = l_style / len(style_layers)
            # TV 损失（去噪）
            l_tv = tv_loss(out)

            loss = (args.content_weight * l_content +
                    args.style_weight * l_style +
                    args.tv_weight * l_tv)

            opt.zero_grad()
            loss.backward()
            opt.step()

            step += 1
            if step % 50 == 0:
                el = time.time() - t0
                rec = {
                    "step": step,
                    "loss": loss.item(),
                    "content": l_content.item(),
                    "style": l_style.item(),
                    "tv": l_tv.item(),
                    "elapsed_s": el,
                }
                history.append(rec)
                # 改进①: 风格损失用科学计数法，否则 1e-5 恒显示 0.0000
                print("[%5d/%d] loss=%.4f  内容=%.4f  风格=%.3e  tv=%.3e  %.1fs  (%.2f 步/秒)"
                      % (step, total_steps, rec["loss"], rec["content"],
                         rec["style"], rec["tv"], el, step / max(el, 1e-6)))

            if step % args.sample_every == 0:
                with torch.no_grad():
                    sample = net(content[:1])
                save_image(torch.cat([content[:1], sample], dim=0),
                           os.path.join(args.out_dir, "sample_%06d.jpg" % step),
                           nrow=2)
                print("   → 已存样图 %s/sample_%06d.jpg" % (args.out_dir, step))

            if args.ckpt_every > 0 and step % args.ckpt_every == 0:
                torch.save(net.state_dict(),
                           os.path.join(args.out_dir, "ckpt_%06d.pth" % step))

    total_time = time.time() - t0
    final = os.path.join(args.out_dir, "model.pth")
    torch.save(net.state_dict(), final)
    print("训练结束，模型已保存:", final)

    # ---- 改进③: 导出训练日志，供 run_compare.py 做对照分析 ----
    # 稳定性指标：取最后 20% 步数的 loss 变异系数（越小越稳）
    tail = history[max(1, int(len(history) * 0.8)):]
    def _cv(vals):
        if len(vals) < 2:
            return 0.0
        m = sum(vals) / len(vals)
        if abs(m) < 1e-12:
            return 0.0
        var = sum((v - m) ** 2 for v in vals) / len(vals)
        return (var ** 0.5) / abs(m)

    peak_mem = 0
    if dev == "cuda":
        peak_mem = torch.cuda.max_memory_allocated() / (1024 ** 3)

    log = {
        "config": {
            "norm": args.norm,
            "channels": args.channels,
            "n_res": int(args.n_res),
            "size": args.size,
            "batch_size": args.batch_size,
            "epochs": args.epochs,
            "steps": total_steps,
            "lr": args.lr,
            "content_weight": args.content_weight,
            "style_weight": args.style_weight,
            "tv_weight": args.tv_weight,
            "content_layer": args.content_layer,
            "style_layers": style_layers,
            "style_image": os.path.basename(args.style_image),
            "seed": args.seed,
        },
        "result": {
            "final_loss": history[-1]["loss"] if history else None,
            "final_content": history[-1]["content"] if history else None,
            "final_style": history[-1]["style"] if history else None,
            "total_time_s": total_time,
            "peak_mem_gb": peak_mem,
            "steps_per_sec": total_steps / max(total_time, 1e-6),
            "loss_cv_tail": _cv([r["loss"] for r in tail]),
            "content_cv_tail": _cv([r["content"] for r in tail]),
            "conv_param_count": net.conv_param_count(),
        },
        "history": history,
    }
    with open(os.path.join(args.out_dir, "train_log.json"), "w", encoding="utf-8") as f:
        json.dump(log, f, ensure_ascii=False, indent=1)

    print("-" * 66)
    print("耗时        : %.1f s  (%.2f 步/秒)" % (total_time, total_steps / max(total_time, 1e-6)))
    if dev == "cuda":
        print("显存峰值    : %.2f GB" % peak_mem)
    print("末段 loss 变异系数: %.4f" % log["result"]["loss_cv_tail"])
    print("训练日志已保存:", os.path.join(args.out_dir, "train_log.json"))


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        msg = str(e)
        # 这两类报错看起来像“内存不足”，但根因是 Windows 系统提交内存
        # （RAM + 页面文件）耗尽，不是显存。最常见的触发源是 DataLoader 多进程。
        keywords = ("shared file mapping", "DataLoader worker", "ArrayMemoryError",
                    "MemoryError", "paging file", "error code: <1455>", "1455")
        if any(k in msg for k in keywords):
            print()
            print("!" * 68)
            print("训练中断：系统内存（RAM + 页面文件）不足，不是显存问题")
            print("!" * 68)
            print("典型报错特征：")
            print("  · Couldn't open shared file mapping: <torch_...>, error code: <1455>")
            print("  · Unable to allocate 1.17 MiB for an array with shape (640,640,3)")
            print()
            print("原因：Windows 下 DataLoader 的每个子进程都会重新加载一份 torch，")
            print("      workers=4 很容易撞上提交内存上限（错误码 1455 = 页面文件太小）。")
            print()
            print("解决办法（按推荐顺序）：")
            print("  1) 加 --workers 0        ← 最有效，本脚本已默认 0")
            print("  2) 降 --batch-size 4 -> 2")
            print("  3) 关闭其他占内存的程序（浏览器/IDE/其他训练进程）")
            print("  4) 调大 Windows 虚拟内存：系统属性 → 高级 → 性能设置 →")
            print("     高级 → 虚拟内存 → 自定义，设为物理内存的 1.5~2 倍")
            print("!" * 68)
            print("原始错误首行：", msg.splitlines()[0] if msg else "(空)")
            sys.exit(2)
        raise
