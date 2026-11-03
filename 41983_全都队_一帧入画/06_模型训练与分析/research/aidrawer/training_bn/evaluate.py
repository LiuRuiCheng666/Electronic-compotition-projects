# -*- coding: utf-8 -*-
"""
归一化方案对照 · 评估脚本（training_bn）

对单个模型计算四类指标，结果写入 eval.json:

    ① 内容保持度   PSNR / SSIM（输出 vs 输入）—— 越高说明原图结构保留得越好
    ② 风格匹配度   Gram 距离（输出 vs 风格图）—— 越低说明风格纹理越接近目标
    ③ 推理速度     单帧耗时 (ms) 与 fps —— 与 FPGA 对照的关键数据
    ④ 确定性       同图跑两次是否完全一致 —— 排除模型内部随机性

关于指标的解读（重要）:
    · PSNR/SSIM 衡量的是「内容保留」，不是「画质好坏」。
      风格迁移没有标准答案，所以不能用它直接给"好看程度"打分。
    · 风格距离衡量「纹理统计有多接近风格图」，同样不等于"好看"。
    · 三个指标要合起来看：
        内容高 + 风格距离低 = 两张都顾到了（理想）
        内容高 + 风格距离高 = 只保住了原图，风格没上去
        内容低 + 风格距离低 = 风格压过了内容（可能就是"糊满星点"那种）

用法:
    python evaluate.py --model runs/instance/model.pth --norm instance \
        --style-image style/portrait.jpg --eval-dir data/val2017 \
        --count 50 --eval-size 640 --out runs/instance/eval.json
"""
import argparse
import json
import math
import os
import time

import torch
import torch.nn.functional as F
from PIL import Image
from torchvision import transforms

from model import FastNeuralStyleNet
from train import VggFeatures, gram_matrix


# ==================== 指标实现 ====================
def _gaussian_window(size, sigma, channels, device):
    coords = torch.arange(size, dtype=torch.float32, device=device) - (size - 1) / 2.0
    g = torch.exp(-(coords ** 2) / (2 * sigma ** 2))
    g = g / g.sum()
    w = g[:, None] * g[None, :]
    return w.expand(channels, 1, size, size).contiguous()


def compute_ssim(x, y, data_range=1.0):
    """结构相似度 SSIM（高斯窗 11×11, sigma=1.5），逐通道后取均值。x,y: [B,C,H,W]"""
    c = x.shape[1]
    win = _gaussian_window(11, 1.5, c, x.device)
    pad = 5
    mu_x = F.conv2d(x, win, padding=pad, groups=c)
    mu_y = F.conv2d(y, win, padding=pad, groups=c)
    mu_x2, mu_y2 = mu_x ** 2, mu_y ** 2
    mu_xy = mu_x * mu_y
    sx2 = F.conv2d(x * x, win, padding=pad, groups=c) - mu_x2
    sy2 = F.conv2d(y * y, win, padding=pad, groups=c) - mu_y2
    sxy = F.conv2d(x * y, win, padding=pad, groups=c) - mu_xy
    c1 = (0.01 * data_range) ** 2
    c2 = (0.03 * data_range) ** 2
    s = ((2 * mu_xy + c1) * (2 * sxy + c2)) / ((mu_x2 + mu_y2 + c1) * (sx2 + sy2 + c2))
    return s.mean().item()


def compute_psnr(x, y, data_range=1.0):
    """峰值信噪比 PSNR（dB）。x,y: [B,C,H,W]，范围 [0,1]"""
    mse = F.mse_loss(x, y).item()
    if mse <= 1e-12:
        return 99.0
    return 10.0 * math.log10((data_range ** 2) / mse)


def style_distance(vgg, out, style_grams, layers):
    """输出与风格图的 Gram 距离（MSE 平均），越低表示风格越接近"""
    with torch.no_grad():
        of = vgg(out)
        d = 0.0
        for k in layers:
            d = d + F.mse_loss(gram_matrix(of[k]), style_grams[k])
    return (d / len(layers)).item()


def resize_keep_ratio(w, h, max_size):
    """长边限制到 max_size，保持长宽比；并把宽高对齐到 4 的倍数。

    为什么是 4：网络含两次 stride-2 下采样 + 两次 ×2 上采样。
    下采样为 floor((n-1)/2)+1（会丢掉半个像素），上采样精确 ×2 补不回来，
    所以 H/W 必须能被 4 整除，否则输入输出尺寸不一致（例如 426 → 428）。

    注意：即使不需要缩放，也必须做对齐——否则 640×426 这类图会直接出错。
    """
    if max_size and max(w, h) > max_size:
        s = max_size / max(w, h)
        w, h = int(w * s), int(h * s)
    return max(w // 4 * 4, 4), max(h // 4 * 4, 4)


def _stats(vals):
    if not vals:
        return {"mean": None, "std": None, "min": None, "max": None}
    n = len(vals)
    m = sum(vals) / n
    var = sum((v - m) ** 2 for v in vals) / n
    return {"mean": m, "std": var ** 0.5, "min": min(vals), "max": max(vals)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="model.pth 路径")
    ap.add_argument("--norm", default="instance", choices=["instance", "batch", "none"])
    ap.add_argument("--channels", type=int, default=8)
    ap.add_argument("--n-res", type=int, default=3)
    ap.add_argument("--style-image", required=True)
    ap.add_argument("--eval-dir", required=True, help="评估用图片目录")
    ap.add_argument("--count", type=int, default=50, help="评估多少张（0=全部）")
    ap.add_argument("--eval-size", type=int, default=640, help="评估分辨率长边（640 = 部署尺度）")
    ap.add_argument("--style-layers", default="relu1_2,relu2_2,relu3_3,relu4_3")
    ap.add_argument("--latency-runs", type=int, default=20, help="测速重复次数")
    ap.add_argument("--out", default=None, help="eval.json 输出路径")
    args = ap.parse_args()

    dev = "cuda" if torch.cuda.is_available() else "cpu"
    layers = args.style_layers.split(",")

    # ---- 模型 ----
    net = FastNeuralStyleNet(args.channels, int(args.n_res), args.norm).to(dev).eval()
    net.load_state_dict(torch.load(args.model, map_location=dev))

    # ---- VGG 与风格 Gram ----
    vgg = VggFeatures(layers, require_grad=False).to(dev).eval()
    tf_style = transforms.Compose([transforms.Resize(args.eval_size), transforms.ToTensor()])
    style_img = tf_style(Image.open(args.style_image).convert("RGB")).unsqueeze(0).to(dev)
    with torch.no_grad():
        style_grams = {k: gram_matrix(v) for k, v in vgg(style_img).items()}

    # ---- 评估图列表 ----
    exts = (".jpg", ".jpeg", ".png", ".bmp", ".webp")
    paths = []
    for d, _, fs in os.walk(args.eval_dir):
        for f in sorted(fs):
            if f.lower().endswith(exts):
                paths.append(os.path.join(d, f))
    if not paths:
        raise SystemExit("评估目录下没找到图片: %s" % args.eval_dir)
    if args.count and args.count > 0:
        paths = paths[:args.count]

    print("=" * 68)
    print("评估配置")
    print("=" * 68)
    print("设备      :", dev, "|", torch.cuda.get_device_name(0) if dev == "cuda" else "-")
    print("归一化    :", args.norm, "| 模型:", args.model)
    print("评估图数  :", len(paths), "| 评估尺寸: 长边", args.eval_size)
    print("=" * 68)

    tf = transforms.ToTensor()
    psnrs, ssims, sds, lats = [], [], [], []
    sizes = []
    deterministic = True

    for i, p in enumerate(paths):
        img = Image.open(p).convert("RGB")
        w, h = resize_keep_ratio(img.width, img.height, args.eval_size)
        img = img.resize((w, h), Image.BILINEAR)
        x = tf(img).unsqueeze(0).to(dev)
        sizes.append((w, h))

        t0 = time.time()
        with torch.no_grad():
            y = net(x)
        if dev == "cuda":
            torch.cuda.synchronize()
        lats.append((time.time() - t0) * 1000.0)

        yc = y.clamp(0, 1)
        psnrs.append(compute_psnr(x, yc))
        ssims.append(compute_ssim(x, yc))
        sds.append(style_distance(vgg, yc, style_grams, layers))

        # 确定性检查（只测第一张，避免浪费）
        if i == 0:
            with torch.no_grad():
                y2 = net(x)
            if not torch.allclose(y, y2, atol=1e-6):
                deterministic = False

        if (i + 1) % 10 == 0:
            print("  已处理 %d/%d" % (i + 1, len(paths)))

    # ---- 测速（固定尺寸重复多次，取稳定值） ----
    w, h = sizes[0]
    xb = torch.rand(1, 3, h, w, device=dev)
    with torch.no_grad():
        for _ in range(3):          # 预热
            net(xb)
    if dev == "cuda":
        torch.cuda.synchronize()
    t0 = time.time()
    with torch.no_grad():
        for _ in range(args.latency_runs):
            net(xb)
    if dev == "cuda":
        torch.cuda.synchronize()
    lat_stable = (time.time() - t0) / args.latency_runs * 1000.0

    result = {
        "norm": args.norm,
        "model": args.model,
        "eval": {
            "n_images": len(paths),
            "eval_size_long_side": args.eval_size,
            "sample_resolution": [sizes[0][1], sizes[0][0]],   # [H, W]
            "psnr": _stats(psnrs),
            "ssim": _stats(ssims),
            "style_distance": _stats(sds),
            "latency_ms_per_image": _stats(lats),
            "latency_ms_stable": lat_stable,
            "fps_stable": 1000.0 / lat_stable if lat_stable > 0 else None,
            "deterministic": deterministic,
        },
    }

    print("-" * 68)
    print("内容保持  PSNR : %.2f dB  (σ=%.2f)" % (result["eval"]["psnr"]["mean"], result["eval"]["psnr"]["std"]))
    print("内容保持  SSIM : %.4f     (σ=%.4f)" % (result["eval"]["ssim"]["mean"], result["eval"]["ssim"]["std"]))
    print("风格距离  Gram : %.3e  (越低越接近风格图)" % result["eval"]["style_distance"]["mean"])
    print("推理延迟       : %.1f ms/帧  →  %.1f fps" % (lat_stable, result["eval"]["fps_stable"]))
    print("确定性         :", "完全确定" if deterministic else "两次结果不一致(!)")

    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=1)
        print("已保存:", args.out)


if __name__ == "__main__":
    main()
