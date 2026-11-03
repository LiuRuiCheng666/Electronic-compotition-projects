# -*- coding: utf-8 -*-
"""
风格迁移训练脚本 · 增强版（training_plus）

【基线】本文件以 training/train.py 为基础，只做"功能增加"，核心训练算法一字未改：
    · 损失定义（内容 + 风格 Gram + TV）与 training 完全一致
    · 网络结构、数据集、VGG 裁判，均直接沿用 training 的实现
    · model.py / stylize.py 与 training 逐字节相同

【新增功能】
    ① --out-dir 作为"父目录"，每次运行自动创建带时间戳的子文件夹
       例：--out-dir D:\\aidrawer\\output  →  output\\20260916_190233\\
    ② --save-every  每 N 步同时产出两类文件：
         model_step001000.pth   仅权重（可直接交给 stylize.py 用）
         ckpt_step001000.pth    完整状态（含优化器、步数、随机数状态，用于续训）
    ③ --resume  从任意 ckpt_stepXXXXXX.pth 继续训练（接续步数、优化器、随机数）
    ④ history.json  训练中途持续写入，崩溃也不丢数据
    ⑤ loss_curve.png  损失曲线（matplotlib 绘制；失败自动降级为 PIL）
    ⑥ 启动时打印可用内存；遇到内存类错误给出可操作提示

【用法】
    # 首次训练：10 轮，每 1000 步存一次
    python train.py --style-image style/portrait.jpg --content-dir data/val2017 \
        --channels 8 --n-res 3 --norm instance --size 640 --batch-size 4 \
        --epochs 10 --content-weight 5 --style-weight 1e7 --tv-weight 1e-5 \
        --save-every 1000 --out-dir D:\\aidrawer\\output

    # 续训：从上次的完整检查点接着跑
    python train.py --resume <上面的目录>\ckpt_step010000.pth \
        --style-image ... --content-dir ... --epochs 20
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
from plot_log import plot_history

VGG_MEAN = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
VGG_STD = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)


# ==================== VGG 特征提取（冻结） ====================
class VggFeatures(nn.Module):
    """按层切分 VGG16，输出指定层的特征图。切片索引即"取到该层为止"。"""

    SLICE = {"relu1_2": 4, "relu2_2": 9, "relu3_3": 16, "relu4_3": 23}

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
    """返回 (可用物理内存 MB, 可用提交内存 MB)。仅 Windows 有效，失败返回 None。"""
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


# ==================== 检查点读写 ====================
def save_checkpoint(run_dir, step, net, opt, cfg, also_model=True):
    """保存两类文件：
       model_stepXXXXXX.pth  仅权重（体积小，可直接被 stylize.py 加载）
       ckpt_stepXXXXXX.pth   完整状态（含优化器与随机数，用于 --resume 续训）
    """
    sd = net.state_dict()
    if also_model:
        torch.save(sd, os.path.join(run_dir, "model_step%06d.pth" % step))
    full = {
        "model": sd,
        "optim": opt.state_dict(),
        "step": step,
        "torch_rng": torch.get_rng_state(),
        "cuda_rng": torch.cuda.get_rng_state_all() if torch.cuda.is_available() else None,
        "config": cfg,
    }
    torch.save(full, os.path.join(run_dir, "ckpt_step%06d.pth" % step))
    return os.path.join(run_dir, "ckpt_step%06d.pth" % step)


def dump_json(path, obj):
    """原子式写 JSON：先写临时文件再替换，避免中途崩溃留下半截文件"""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


# ==================== 训练主流程 ====================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--style-image", required=True, help="风格图路径（1 张）")
    ap.add_argument("--content-dir", required=True, help="内容图目录（一批照片）")
    ap.add_argument("--channels", type=int, default=8, help="基准通道数 C（默认 8 = 1/4 版本）")
    ap.add_argument("--n-res", type=int, default=3, help="残差块个数")
    ap.add_argument("--norm", default="instance", choices=["instance", "batch", "none"],
                    help="归一化方案（instance 画质优先 / batch 硬件友好 / none 最简）")
    ap.add_argument("--size", type=int, default=256, help="训练裁切尺寸")
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--epochs", type=float, default=2.0)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--content-weight", type=float, default=1.0)
    ap.add_argument("--style-weight", type=float, default=1e5)
    ap.add_argument("--tv-weight", type=float, default=1e-6)
    ap.add_argument("--content-layer", default="relu3_3")
    ap.add_argument("--style-layers", default="relu1_2,relu2_2,relu3_3,relu4_3")

    # ---- 输出与保存 ----
    ap.add_argument("--out-dir", default=None,
                    help="父目录。每次运行会在其下自动创建「时间戳」子文件夹；"
                         "若指定了 --resume 且未指定本参数，则写入原检查点所在目录")
    ap.add_argument("--tag", default="", help="可选标签，拼在子文件夹名后，便于区分实验")
    ap.add_argument("--save-every", type=int, default=1000,
                    help="每多少步保存一次模型（同时产出 model_/ckpt_ 两个文件）")
    ap.add_argument("--resume", default=None,
                    help="从 ckpt_stepXXXXXX.pth 继续训练（接续步数/优化器/随机数）")
    ap.add_argument("--log-every", type=int, default=50, help="每多少步打印一次日志")
    ap.add_argument("--sample-every", type=int, default=500, help="每多少步存一张对比样图")
    ap.add_argument("--plot-every", type=int, default=1000,
                    help="每多少步刷新一次 loss_curve.png（0 = 只在结束时画）")
    ap.add_argument("--workers", type=int, default=0,
                    help="DataLoader 子进程数。Windows 建议 0：子进程各自加载一份 torch，"
                         "多进程容易撞上系统提交内存上限（错误码 1455）")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    # ---------- 运行目录 ----------
    created_new = False
    if args.resume and args.out_dir is None:
        run_dir = os.path.dirname(os.path.abspath(args.resume))
    else:
        style_key = "".join(c if c.isascii() and (c.isalnum() or c in "_-") else "_" for c in os.path.splitext(os.path.basename(args.style_image))[0]).strip("_") or "style"
        base = args.out_dir or os.path.join("D:/aidrawer/output", style_key)
        norm_label = {"instance":"IN","batch":"BN","none":"NoNorm"}[args.norm]
        name = time.strftime("%Y%m%d_%H%M%S") + "_Teacher_%s_C%d_Res%d" % (norm_label,args.channels,args.n_res)
        if args.tag:
            name += "_" + "".join(c if c.isascii() and (c.isalnum() or c in "_-") else "_" for c in args.tag)
        run_dir = os.path.join(base, name)
        created_new = True
    os.makedirs(run_dir, exist_ok=True)

    dev = "cuda" if torch.cuda.is_available() else "cpu"
    print("=" * 70)
    print("训练配置")
    print("=" * 70)
    print("运行目录  :", run_dir, ("（新建）" if created_new else "（续训，沿用原目录）"))
    print("设备      :", dev, "|", torch.cuda.get_device_name(0) if dev == "cuda" else "（无 GPU）")
    print("归一化    :", args.norm, "| 通道数 C:", args.channels, "| 残差块:", int(args.n_res))
    print("裁切尺寸  :", args.size, "| batch:", args.batch_size, "| 目标轮数:", args.epochs)
    print("损失权重  : 内容=%g  风格=%g  tv=%g" % (args.content_weight, args.style_weight, args.tv_weight))
    print("风格层    :", args.style_layers)
    print("保存间隔  : 每 %d 步（model_step*.pth + ckpt_step*.pth）" % args.save_every)
    if args.resume:
        print("续训自    :", args.resume)
    print("=" * 70)

    mi = mem_info()
    if mi:
        print("内存      : 可用物理 %.1f GB | 可用提交 %.1f GB" % (mi[0] / 1024, mi[1] / 1024))
        if mi[1] < 2048:
            print("!! 可用提交内存不足 2 GB，建议降 --batch-size 或关闭其他程序")

    # 固定种子（首次训练时生效；续训时会被检查点里的随机数状态覆盖）
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)

    # ---- 网络 ----
    net = FastNeuralStyleNet(args.channels, int(args.n_res), args.norm).to(dev)
    print("卷积权重  : %d 个 (%.1f KB int8)" % (net.conv_param_count(), net.conv_param_count() / 1024))

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
    dl_kwargs = dict(batch_size=args.batch_size, shuffle=True,
                     num_workers=args.workers, drop_last=True, pin_memory=False)
    if args.workers > 0:
        dl_kwargs["prefetch_factor"] = 2
    dl = DataLoader(ds, **dl_kwargs)
    steps_per_epoch = len(dl)
    total_steps = max(1, int(steps_per_epoch * args.epochs))

    opt = torch.optim.Adam(net.parameters(), lr=args.lr)

    cfg = {
        "norm": args.norm, "channels": args.channels, "n_res": int(args.n_res),
        "size": args.size, "batch_size": args.batch_size, "epochs": args.epochs,
        "lr": args.lr, "content_weight": args.content_weight,
        "style_weight": args.style_weight, "tv_weight": args.tv_weight,
        "content_layer": args.content_layer, "style_layers": style_layers,
        "style_image": os.path.basename(args.style_image), "seed": args.seed,
        "steps_per_epoch": steps_per_epoch, "total_steps": total_steps,
    }

    # ---------- 续训 ----------
    step = 0
    history = []
    hist_path = os.path.join(run_dir, "history.json")
    if args.resume:
        ck = torch.load(args.resume, map_location=dev)
        net.load_state_dict(ck["model"])
        if "optim" in ck:
            opt.load_state_dict(ck["optim"])
        step = int(ck.get("step", 0))
        if ck.get("torch_rng") is not None:
            try:
                torch.set_rng_state(ck["torch_rng"].cpu())
            except Exception:
                pass
        if ck.get("cuda_rng") is not None and torch.cuda.is_available():
            try:
                torch.cuda.set_rng_state_all([s.cpu() for s in ck["cuda_rng"]])
            except Exception:
                pass
        if os.path.exists(hist_path):
            try:
                with open(hist_path, encoding="utf-8") as f:
                    history = json.load(f).get("history", [])
            except Exception:
                history = []
        print("已从检查点恢复：step=%d，历史记录 %d 条" % (step, len(history)))
        if step >= total_steps:
            print("!! 当前步数(%d) 已达目标(%d)，无需继续。请把 --epochs 调大。" % (step, total_steps))
            return

    print("内容图 %d 张 | 每轮 %d 步 | 目标 %d 步 | 从第 %d 步开始"
          % (len(ds), steps_per_epoch, total_steps, step))

    t0 = time.time()
    steps_done_this_run = 0

    def flush_history(final=False):
        obj = {"config": cfg, "history": history,
               "result": {"last_step": step,
                          "last_loss": history[-1]["loss"] if history else None,
                          "elapsed_s": time.time() - t0,
                          "steps_this_run": steps_done_this_run}}
        dump_json(hist_path, obj)

    def make_plot():
        plot_history(history, os.path.join(run_dir, "loss_curve.png"),
                     "%s  size=%d  C=%d  nres=%d" % (args.norm, args.size, args.channels, int(args.n_res)))

    while step < total_steps:
        for content in dl:
            if step >= total_steps:
                break
            content = content.to(dev)

            out = net(content)
            of = vgg(out)
            with torch.no_grad():
                cf = vgg(content)

            l_content = F.mse_loss(of[args.content_layer], cf[args.content_layer])
            l_style = sum(F.mse_loss(gram_matrix(of[k]), style_grams[k])
                          for k in style_layers) / len(style_layers)
            l_tv = tv_loss(out)

            loss = (args.content_weight * l_content +
                    args.style_weight * l_style +
                    args.tv_weight * l_tv)

            opt.zero_grad()
            loss.backward()
            opt.step()

            step += 1
            steps_done_this_run += 1

            if step % args.log_every == 0:
                el = time.time() - t0
                rec = {"step": step, "loss": loss.item(), "content": l_content.item(),
                       "style": l_style.item(), "tv": l_tv.item(), "elapsed_s": el}
                history.append(rec)
                tps = steps_done_this_run / max(el, 1e-6)
                print("[%5d/%d] loss=%.4f  内容=%.4f  风格=%.3e  tv=%.3e  %.1fs  (%.2f 步/秒)"
                      % (step, total_steps, rec["loss"], rec["content"],
                         rec["style"], rec["tv"], el, tps))
                flush_history()

            if step % args.sample_every == 0:
                with torch.no_grad():
                    sample = net(content[:1])
                save_image(torch.cat([content[:1], sample], dim=0),
                           os.path.join(run_dir, "sample_%06d.jpg" % step), nrow=2)
                print("   → 已存样图 sample_%06d.jpg" % step)

            # ---- 周期性保存模型（核心新增功能）----
            if step % args.save_every == 0:
                ck = save_checkpoint(run_dir, step, net, opt, cfg)
                flush_history()
                print("   → 已存模型 model_step%06d.pth / 完整检查点 %s"
                      % (step, os.path.basename(ck)))
                if args.plot_every and step % args.plot_every == 0:
                    make_plot()
                    print("   → 已刷新 loss_curve.png")

    # ---- 收尾保存 ----
    elapsed = time.time() - t0
    final = os.path.join(run_dir, "model_final.pth")
    torch.save(net.state_dict(), final)
    ck_final = save_checkpoint(run_dir, step, net, opt, cfg, also_model=False)
    flush_history()
    make_plot()

    print("-" * 70)
    print("训练结束。本次新增 %d 步，耗时 %.1f s (%.2f 步/秒)"
          % (steps_done_this_run, elapsed, steps_done_this_run / max(elapsed, 1e-6)))
    print("最终模型  :", final)
    print("完整检查点:", ck_final, "（可用于 --resume）")
    print("损失曲线  :", os.path.join(run_dir, "loss_curve.png"))
    print("输出目录  :", run_dir)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        msg = str(e)
        keywords = ("shared file mapping", "DataLoader worker", "ArrayMemoryError",
                    "MemoryError", "paging file", "1455")
        if any(k in msg for k in keywords):
            print()
            print("!" * 68)
            print("训练中断：系统内存（RAM + 页面文件）不足，不是显存问题")
            print("!" * 68)
            print("特征：'shared file mapping ... error code: <1455>' 或")
            print("      'Unable to allocate ... for an array with shape (...)'")
            print()
            print("处理：")
            print("  1) 加 --workers 0     ← 本脚本已默认 0")
            print("  2) 降 --batch-size，例如 4 -> 2")
            print("  3) 关闭其他占内存程序（浏览器/IDE/残留训练进程）")
            print("  4) 调大 Windows 虚拟内存（设为物理内存的 1.5~2 倍）")
            print("!" * 68)
            sys.exit(2)
        raise
