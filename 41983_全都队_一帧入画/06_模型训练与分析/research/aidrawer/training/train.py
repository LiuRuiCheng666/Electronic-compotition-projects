# -*- coding: utf-8 -*-
"""
风格迁移训练脚本（Fast Neural Style · 感知损失）

训练原理:
    用预训练 VGG16 当"裁判"，判断"输出图"和"内容图/风格图"分别有多像。
    总损失 = 内容损失(保结构) + 风格损失(保纹理风格) + TV损失(去噪)
    不需要任何人工标注，只需要"1 张风格图 + 一批内容图"。

用法示例:
    python train.py --style-image standard.jpg --content-dir D:\aidrawer\data\val2017 --channels 8 --n-res 3 --size 640 --batch-size 4 --epochs 2 --out-dir D:\aidrawer\output\standard\runs6.2 --content-weight 5 --style-weight 1e7 --tv-weight 0
"""
import argparse
import os
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
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    dev = "cuda" if torch.cuda.is_available() else "cpu"
    print("设备:", dev, "|", torch.cuda.get_device_name(0) if dev == "cuda" else "（无 GPU，会很慢）")
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
    dl = DataLoader(ds, batch_size=args.batch_size, shuffle=True,
                    num_workers=args.workers, drop_last=True)
    steps_per_epoch = len(dl)
    total_steps = max(1, int(steps_per_epoch * args.epochs))
    print("内容图 %d 张 | 每轮 %d 步 | 计划 %d 步" % (len(ds), steps_per_epoch, total_steps))

    opt = torch.optim.Adam(net.parameters(), lr=args.lr)

    step = 0
    t0 = time.time()
    while step < total_steps:
        for content in dl:
            if step >= total_steps:
                break
            content = content.to(dev)

            out = net(content)
            of = vgg(out)
            with torch.no_grad():
                cf = vgg(content)

            # 内容损失（保结构）
            l_content = F.mse_loss(of[args.content_layer], cf[args.content_layer])
            # 风格损失（保纹理风格）
            '''l_style = sum(F.mse_loss(gram_matrix(of[k]), style_grams[k])
                          for k in style_layers) / len(style_layers)'''
            SW = {"relu1_2": 1.5, "relu2_2": 1.0,
                  "relu3_3": 0.5,  "relu4_3": 0.25}
            wsum = sum(SW[k] for k in style_layers)
            l_style = sum(SW[k] * F.mse_loss(gram_matrix(of[k]), style_grams[k])
                          for k in style_layers) / wsum
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
                print("[%5d/%d] loss=%.4f  内容=%.4f  风格=%.4f  %.1fs  (%.2f 步/秒)"
                      % (step, total_steps, loss.item(), l_content.item(),
                         l_style.item(), el, step / max(el, 1e-6)))

            if step % args.sample_every == 0:
                with torch.no_grad():
                    sample = net(content[:1])
                save_image(torch.cat([content[:1], sample], dim=0),
                           os.path.join(args.out_dir, "sample_%06d.jpg" % step),
                           nrow=2)
                print("   → 已存样图 %s/sample_%06d.jpg" % (args.out_dir, step))

            if step % args.ckpt_every == 0:
                torch.save(net.state_dict(),
                           os.path.join(args.out_dir, "ckpt_%06d.pth" % step))

    final = os.path.join(args.out_dir, "model.pth")
    torch.save(net.state_dict(), final)
    print("训练结束，模型已保存:", final)


if __name__ == "__main__":
    main()
