# -*- coding: utf-8 -*-
"""
FNS 1/4 通道版 · 风格迁移网络（PyTorch 定义）

对应已确定的架构:
    编码器:  conv3x3(3->C) + conv3x3(C->C)          [替代原 9x9]
             conv3x3s2(C->2C) + conv3x3s2(2C->4C)
    残差块:  N × [ conv3x3(4C->4C) + conv3x3(4C->4C) + skip ]
    解码器:  上采样 + conv3x3(4C->2C) + 上采样 + conv3x3(2C->C)
    输出层:  conv3x3(C->C) + conv3x3(C->3)          [替代原 9x9]

C = 8  -> 官方推荐的"1/4 通道版"，卷积权重 68,400 个
改一个数字即可切换规格（C=9 仍在算力预算内）

关于归一化（重要）:
    norm="instance" : InstanceNorm2d，风格迁移的标准做法、画质最好。
                      但它是"按输入实时统计"的，推理时【不能】折进卷积权重，
                      硬件需要额外实现（有代价）。
    norm="batch"    : BatchNorm2d，推理时【可以】折进前一层卷积权重与偏置，
                      硬件最省，但风格迁移画质可能略降。
    norm="none"     : 不用归一化，硬件最简，训练难度略高。
    训练阶段先用 instance 追求画质；等确认画质后，再评估是否换 batch。
"""
import torch
import torch.nn as nn


def make_norm(kind, ch):
    if kind == "instance":
        return nn.InstanceNorm2d(ch, affine=True, track_running_stats=False)
    if kind == "batch":
        return nn.BatchNorm2d(ch, affine=True, track_running_stats=True)
    if kind == "none":
        return nn.Identity()
    raise ValueError("unknown norm: %s" % kind)


class ConvNormAct(nn.Module):
    """反射填充 + 卷积 + 归一化 + (可选)ReLU"""

    def __init__(self, cin, cout, k=3, stride=1, norm="instance", act=True):
        super().__init__()
        pad = k // 2
        self.pad = nn.ReflectionPad2d(pad)
        self.conv = nn.Conv2d(cin, cout, k, stride=stride, bias=True)
        self.norm = make_norm(norm, cout)
        self.act = nn.ReLU(inplace=True) if act else nn.Identity()

    def forward(self, x):
        return self.act(self.norm(self.conv(self.pad(x))))


class ResidualBlock(nn.Module):
    """两个 3×3 卷积 + 恒等捷径：out = x + F(x)"""

    def __init__(self, ch, norm="instance"):
        super().__init__()
        self.c1 = ConvNormAct(ch, ch, 3, 1, norm, act=True)
        self.c2 = ConvNormAct(ch, ch, 3, 1, norm, act=False)

    def forward(self, x):
        return x + self.c2(self.c1(x))


class FastNeuralStyleNet(nn.Module):
    def __init__(self, channels=8, n_res=3, norm="instance"):
        super().__init__()
        C = channels
        self.channels = C
        self.n_res = n_res
        self.norm_kind = norm

        # 编码器：前两层替代原 9x9
        self.enc = nn.Sequential(
            ConvNormAct(3, C, 3, 1, norm),        # 编码器1a
            ConvNormAct(C, C, 3, 1, norm),        # 编码器1b（替代 9x9）
            ConvNormAct(C, 2 * C, 3, 2, norm),    # 编码器2 下采样
            ConvNormAct(2 * C, 4 * C, 3, 2, norm) # 编码器3 下采样
        )
        # 残差块
        self.res = nn.Sequential(*[ResidualBlock(4 * C, norm) for _ in range(n_res)])
        # 解码器
        self.dec = nn.Sequential(
            nn.Upsample(scale_factor=2, mode="nearest"),
            ConvNormAct(4 * C, 2 * C, 3, 1, norm),   # 解码器1
            nn.Upsample(scale_factor=2, mode="nearest"),
            ConvNormAct(2 * C, C, 3, 1, norm)        # 解码器2
        )
        # 输出层：后两层替代原 9x9，最后一层无归一化无激活
        self.out = nn.Sequential(
            ConvNormAct(C, C, 3, 1, norm),            # 输出层1
            nn.ReflectionPad2d(1),
            nn.Conv2d(C, 3, 3, stride=1, bias=True)   # 输出层2
        )

    def forward(self, x):
        """x: [B,3,H,W] 取值 [0,1] → 输出同尺寸，取值 [0,1]"""
        y = self.out(self.dec(self.res(self.enc(x))))
        return torch.tanh(y) * 0.5 + 0.5

    # ---------- 硬件相关统计 ----------
    def conv_param_count(self):
        """只统计卷积核权重个数（= 要写进 FPGA BRAM 的数量）"""
        n = 0
        for m in self.modules():
            if isinstance(m, nn.Conv2d):
                n += m.weight.numel()
        return n

    def all_param_count(self):
        return sum(p.numel() for p in self.parameters())


if __name__ == "__main__":
    # 自检：验证架构、参数、尺寸
    print("=" * 62)
    print("架构自检")
    print("=" * 62)
    for C, nr in [(8, 3), (9, 3), (8, 5)]:
        net = FastNeuralStyleNet(channels=C, n_res=nr)
        conv_n = net.conv_param_count()
        all_n = net.all_param_count()
        with torch.no_grad():
            y = net(torch.zeros(1, 3, 480, 640))
        print("C=%d, %d 残差块:" % (C, nr))
        print("   卷积权重      : %d 个  (%.1f KB, int8)" % (conv_n, conv_n / 1024))
        print("   全参数量      : %d 个  (含归一化参数，推理时可折掉)" % all_n)
        print("   输入 480x640  →  输出 %dx%d" % (y.shape[2], y.shape[3]))
    print()
    print("参考:C=8,3 残差块 应为 68,400 个卷积权重")
