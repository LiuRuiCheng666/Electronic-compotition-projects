# -*- coding: utf-8 -*-
"""
归一化方案三组对照 · 总调度（training_bn）

一次跑完 instance / batch / none 三种归一化方案的训练 + 评估，
并生成对照报告（Markdown + CSV）。

它解决的问题:
    归一化方案【会影响 FPGA 硬件架构】——
      · BatchNorm 推理时可折进卷积权重，硬件几乎零成本
      · InstanceNorm 推理时需实时统计，要多一套电路 + 特征图缓冲 + DDR 往返
    所以这是一个【硬件决策实验】，不能靠猜，必须用数据说话。
    而且这份对照数据本身，就是题目高阶挑战要求的"对比分析"材料。

产出:
    <out-root>/instance/  ← model.pth, train_log.json, eval.json, sample_*.jpg
    <out-root>/batch/     ← 同上
    <out-root>/none/      ← 同上
    <out-root>/compare_report.md   ← 对照报告（可直接放进比赛材料）
    <out-root>/compare_results.csv ← 表格数据

用法:
    # 完整对照（30 轮，推荐）
    python run_compare.py --style-image style/portrait.jpg --content-dir data/val2017 \
        --epochs 30 --size 640 --batch-size 4 \
        --content-weight 5 --style-weight 1e7 --tv-weight 1e-5

    # 快速冒烟测试（每档只跑很少步数，验证流程通不通）
    python run_compare.py ... --quick

    # 只评估、不重训（模型已存在时）
    python run_compare.py ... --skip-train

    # 只跑其中两组
    python run_compare.py ... --modes instance,batch
"""
import argparse
import json
import os
import subprocess
import sys
import time


MODES = ["instance", "batch", "none"]

# 归一化方案的硬件代价对照（分析值，非实测；用于报告）
HW_TABLE = {
    "instance": {
        "硬件电路": "需额外实现",
        "片上缓冲": "需缓存整张特征图（最大 8×480×640 ≈ 2.3MB）",
        "DDR 往返": "需（写1遍+读2遍）",
        "推理可折进卷积": "否",
        "结论": "画质优先，硬件代价最高",
    },
    "batch": {
        "硬件电路": "无需（折进卷积权重）",
        "片上缓冲": "无需",
        "DDR 往返": "无",
        "推理可折进卷积": "是",
        "结论": "硬件最省，画质待实测",
    },
    "none": {
        "硬件电路": "无需",
        "片上缓冲": "无需",
        "DDR 往返": "无",
        "推理可折进卷积": "不适用",
        "结论": "硬件最简，但失去归一化增益",
    },
}

# 各层特征图大小（int8，用于估算 IN 的缓冲需求）
FEATURE_MAPS = [
    ("编码器前两层输出", 8, 480, 640),
    ("编码器第二层输出", 16, 240, 320),
    ("残差块各层（×6）", 32, 120, 160),
    ("解码器第二层输出", 8, 480, 640),
]


def run(cmd, cwd):
    """执行子进程并把输出实时透传"""
    print("  $ " + " ".join('"%s"' % c if " " in c else c for c in cmd))
    p = subprocess.Popen(cmd, cwd=cwd)
    rc = p.wait()
    return rc


def load_json(path):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def fmt(v, nd=4, unit=""):
    if v is None:
        return "—"
    if isinstance(v, float):
        if abs(v) < 1e-3 and v != 0:
            return ("%.3e" % v) + unit
        return ("%%.%df" % nd % v) + unit
    return str(v) + unit


def build_report(args, out_root, train_logs, eval_logs):
    lines = []
    A = lines.append

    A("# 归一化方案对照实验报告")
    A("")
    A("> 自动生成于 %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    A("")
    A("## 一、实验设置")
    A("")
    A("| 项 | 值 |")
    A("|---|---|")
    A("| 风格图 | `%s` |" % os.path.basename(args.style_image))
    A("| 内容图目录 | `%s` |" % args.content_dir)
    A("| 网络结构 | C=%d, %d 残差块, 3×3 卷积 |" % (args.channels, args.n_res))
    A("| 训练裁切尺寸 | %d |" % args.size)
    A("| batch size | %d |" % args.batch_size)
    A("| 训练步数 | %s |" % (train_logs.get(MODES[0], {}).get("config", {}).get("steps", "—")
                          if train_logs.get(MODES[0]) else "—"))
    A("| 损失权重 | 内容=%g / 风格=%g / tv=%g |" % (args.content_weight, args.style_weight, args.tv_weight))
    A("| 风格层 | %s |" % args.style_layers)
    A("| 评估图数 × 尺寸 | %d 张 × 长边 %d |" % (args.eval_count, args.eval_size))
    A("| 随机种子 | %d（三组一致，保证可比） |" % args.seed)
    A("")

    # ---------- 指标对照 ----------
    A("## 二、指标对照")
    A("")
    A("**指标解读**：PSNR/SSIM 衡量「内容保留」；风格距离衡量「纹理有多接近风格图」。")
    A("风格迁移没有标准答案，所以这三个数**不能单独判定\"好看与否\"**，必须配合样图看。")
    A("")
    A("| 归一化 | PSNR (dB)↑ | SSIM ↑ | 风格距离 ↓ | 延迟 (ms) ↓ | fps ↑ | 训练末段 loss 波动 ↓ | 显存峰值 (GB) |")
    A("|---|---|---|---|---|---|---|---|")
    best_style = None
    for m in MODES:
        ev = eval_logs.get(m)
        tl = train_logs.get(m)
        if not ev:
            A("| %s | 未完成 | — | — | — | — | — | — |" % m)
            continue
        e = ev["eval"]
        r = (tl or {}).get("result", {})
        A("| **%s** | %.2f (σ%.2f) | %.4f | %s | %.1f | %.1f | %s | %s |" % (
            m,
            e["psnr"]["mean"], e["psnr"]["std"],
            e["ssim"]["mean"],
            fmt(e["style_distance"]["mean"]),
            e["latency_ms_stable"], e["fps_stable"],
            fmt(r.get("loss_cv_tail"), 4),
            fmt(r.get("peak_mem_gb"), 2),
        ))
        if best_style is None or e["style_distance"]["mean"] < best_style[1]:
            best_style = (m, e["style_distance"]["mean"])
    A("")
    if best_style:
        A("- 风格匹配最好的：**%s**（Gram 距离 %s）" % (best_style[0], fmt(best_style[1])))
    A("")

    # ---------- 硬件代价 ----------
    A("## 三、硬件代价对照（关键决策依据）")
    A("")
    A("这一节是「为什么要做这个实验」的核心——归一化方案直接决定 FPGA 架构。")
    A("")
    A("| 归一化 | 额外电路 | 片上缓冲 | DDR 往返 | 可折进卷积 | 定位 |")
    A("|---|---|---|---|---|---|")
    for m in MODES:
        h = HW_TABLE[m]
        A("| **%s** | %s | %s | %s | %s | %s |" % (
            m, h["硬件电路"], h["片上缓冲"], h["DDR 往返"], h["推理可折进卷积"], h["结论"]))
    A("")
    A("### 各层特征图大小（int8）—— 决定 IN 的缓冲压力")
    A("")
    A("| 位置 | 形状 (C×H×W) | 大小 |")
    A("|---|---|---|")
    total = 0
    for name, c, h, w in FEATURE_MAPS:
        kb = c * h * w / 1024
        total += kb
        A("| %s | %d×%d×%d | %.0f KB |" % (name, c, h, w, kb))
    A("| **最高分辨率单层** | 8×480×640 | **%.0f KB** |" % (8 * 480 * 640 / 1024))
    A("")
    A("> 可用片上 BRAM 约 190 KB。可见 **InstanceNorm 所需的特征图缓冲远超片上容量**，")
    A("> 必须走 DDR，并带来「写一遍 + 读两遍」的额外往返与流水线打断。")
    A("> BatchNorm / none 则完全没有这项开销。")
    A("")

    # ---------- 结论 ----------
    A("## 四、结论与建议")
    A("")
    A("请结合 `runs/<mode>/sample_*.jpg` 的样图（左=原图，右=风格化）一起判断：")
    A("")
    A("1. **画质**：肉眼看三组样图，哪组笔触/纹理最自然？")
    A("2. **指标**：PSNR/SSIM 高 = 原图结构保留好；风格距离低 = 风格纹理更贴近目标。")
    A("3. **硬件**：`batch` / `none` 可省掉整套归一化电路与 DDR 往返，对 Ti60 的资源紧张局面很关键。")
    A("4. **决策句式**（可直接用于答辩）：")
    A("   > 我们对比了三种归一化方案：InstanceNorm 画质最佳但硬件需额外统计电路与特征图缓冲；")
    A("   > BatchNorm 画质略有变化，但推理时可完全折进卷积权重，硬件零额外开销。")
    A("   > 综合画质与资源占用，我们选择 ______。")
    A("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--style-image", required=True)
    ap.add_argument("--content-dir", required=True, help="训练用内容图目录")
    ap.add_argument("--eval-dir", default=None, help="评估用图片目录（默认同 content-dir）")
    ap.add_argument("--eval-count", type=int, default=50)
    ap.add_argument("--eval-size", type=int, default=640)
    ap.add_argument("--modes", default="instance,batch,none", help="要跑哪几组")
    ap.add_argument("--out-root", default="runs_bn")
    # 训练参数（三组共用，保证可比）
    ap.add_argument("--channels", type=int, default=8)
    ap.add_argument("--n-res", type=int, default=3)
    ap.add_argument("--size", type=int, default=640)
    ap.add_argument("--batch-size", type=int, default=4)
    ap.add_argument("--epochs", type=float, default=30)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--content-weight", type=float, default=5)
    ap.add_argument("--style-weight", type=float, default=1e7)
    ap.add_argument("--tv-weight", type=float, default=1e-5)
    ap.add_argument("--style-layers", default="relu1_2,relu2_2,relu3_3,relu4_3")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--sample-every", type=int, default=500)
    ap.add_argument("--workers", type=int, default=0,
                    help="DataLoader 子进程数。Windows 上建议 0（子进程各自加载一份 torch，"
                         "容易触发系统提交内存上限）；若训练失败，本脚本会自动用 0 重试一次")
    ap.add_argument("--quick", action="store_true", help="冒烟测试：每档只跑 20 步、评估 3 张")
    ap.add_argument("--skip-train", action="store_true")
    ap.add_argument("--skip-eval", action="store_true")
    args = ap.parse_args()

    if args.quick:
        args.epochs = 0.02
        args.size = min(args.size, 256)
        args.eval_count = 3
        args.sample_every = 10
        print("[quick 模式] 步数很少，仅用于验证流程是否跑通，结果无参考价值")

    if args.eval_dir is None:
        args.eval_dir = args.content_dir

    here = os.path.dirname(os.path.abspath(__file__))
    out_root = os.path.abspath(args.out_root)
    os.makedirs(out_root, exist_ok=True)
    modes = [m.strip() for m in args.modes.split(",") if m.strip()]
    for m in modes:
        if m not in MODES:
            raise SystemExit("未知归一化方案: %s（可选 %s）" % (m, MODES))

    train_logs, eval_logs = {}, {}
    t_all = time.time()

    for m in modes:
        mdir = os.path.join(out_root, m)
        os.makedirs(mdir, exist_ok=True)
        print()
        print("#" * 70)
        print("# [%s] 归一化方案 = %s" % (m, m))
        print("#" * 70)

        # ---------- 训练 ----------
        if not args.skip_train:
            def train_cmd(w):
                return [sys.executable, "train.py",
                        "--style-image", os.path.abspath(args.style_image),
                        "--content-dir", os.path.abspath(args.content_dir),
                        "--channels", str(args.channels),
                        "--n-res", str(args.n_res),
                        "--norm", m,
                        "--size", str(args.size),
                        "--batch-size", str(args.batch_size),
                        "--epochs", str(args.epochs),
                        "--lr", str(args.lr),
                        "--content-weight", str(args.content_weight),
                        "--style-weight", str(args.style_weight),
                        "--tv-weight", str(args.tv_weight),
                        "--style-layers", args.style_layers,
                        "--seed", str(args.seed),
                        "--sample-every", str(args.sample_every),
                        "--workers", str(w),
                        "--out-dir", mdir]

            rc = run(train_cmd(args.workers), here)
            # 自动降级重试：多进程 DataLoader 在 Windows 上易撞"提交内存上限"(1455)，
            # 改用单进程（workers=0）通常能直接跑完。返码 2 是本脚本训练的"内存类错误"约定值。
            if rc != 0 and args.workers > 0:
                print("!! [%s] 训练失败（返回码 %d）。自动重试：改用 --workers 0" % (m, rc))
                rc = run(train_cmd(0), here)
            if rc != 0:
                print("!! [%s] 训练返回码 %d，跳过评估" % (m, rc))
                train_logs[m] = load_json(os.path.join(mdir, "train_log.json"))
                continue
            train_logs[m] = load_json(os.path.join(mdir, "train_log.json"))
        else:
            train_logs[m] = load_json(os.path.join(mdir, "train_log.json"))

        # ---------- 评估 ----------
        if not args.skip_eval:
            model = os.path.join(mdir, "model.pth")
            if not os.path.exists(model):
                print("!! [%s] 找不到 %s，跳过评估" % (m, model))
                continue
            cmd = [sys.executable, "evaluate.py",
                   "--model", model,
                   "--norm", m,
                   "--channels", str(args.channels),
                   "--n-res", str(args.n_res),
                   "--style-image", os.path.abspath(args.style_image),
                   "--eval-dir", os.path.abspath(args.eval_dir),
                   "--count", str(args.eval_count),
                   "--eval-size", str(args.eval_size),
                   "--style-layers", args.style_layers,
                   "--out", os.path.join(mdir, "eval.json")]
            rc = run(cmd, here)
            if rc != 0:
                print("!! [%s] 评估返回码 %d" % (m, rc))
        eval_logs[m] = load_json(os.path.join(mdir, "eval.json"))

    # ---------- 生成报告 ----------
    print()
    print("#" * 70)
    print("# 生成对照报告")
    print("#" * 70)
    report = build_report(args, out_root, train_logs, eval_logs)
    rp = os.path.join(out_root, "compare_report.md")
    with open(rp, "w", encoding="utf-8") as f:
        f.write(report)
    print("已保存:", rp)

    # CSV
    csv = os.path.join(out_root, "compare_results.csv")
    with open(csv, "w", encoding="utf-8-sig") as f:
        f.write("norm,psnr_mean,psnr_std,ssim_mean,style_distance,latency_ms,fps,loss_cv_tail,peak_mem_gb\n")
        for m in modes:
            ev = eval_logs.get(m)
            tl = train_logs.get(m) or {}
            r = tl.get("result", {})
            if ev:
                e = ev["eval"]
                f.write("%s,%.4f,%.4f,%.6f,%.6e,%.3f,%.3f,%s,%s\n" % (
                    m, e["psnr"]["mean"], e["psnr"]["std"], e["ssim"]["mean"],
                    e["style_distance"]["mean"], e["latency_ms_stable"], e["fps_stable"],
                    r.get("loss_cv_tail", ""), r.get("peak_mem_gb", "")))
            else:
                f.write("%s,,,,,,,%s,%s\n" % (m, r.get("loss_cv_tail", ""), r.get("peak_mem_gb", "")))
    print("已保存:", csv)

    print()
    print("总耗时: %.1f 分钟" % ((time.time() - t_all) / 60))
    print("请打开 compare_report.md 查看对照结果，并对比各组的 sample_*.jpg 样图。")


if __name__ == "__main__":
    main()
