# -*- coding: utf-8 -*-
"""
多风格批量训练调度器（training_plus）

一条命令，晚上挂机，依次训练多种风格。

设计要点
--------
1. **不修改 train.py**：本脚本只是调度器，按顺序调用 `train.py`，训练算法完全不变。
2. **串行执行**：GPU 只有一块，串行才不会互相抢显存。
3. **每个风格独立目录**：`<out-root>/<风格名>/<时间戳>/`，互不干扰。
4. **失败隔离**：某个风格崩溃不影响后续风格，全部跑完后给出汇总表。
5. **自动续训（--auto-resume，默认开启）**：若某风格已有检查点但未跑完，
   自动从最近的 `ckpt_step*.pth` 续训，而不是从头开始。
6. **失败自动重试（--retry N，默认 1）**：某个风格失败后自动重跑一次
   （配合 auto-resume，等价于"从断点续"）。

用法
----
    python train_multi.py \
      --styles "D:\\style\\jojo.jpg,D:\\style\\ink.jpg,D:\\style\\picture.jpg" \
      --content-dir D:\\aidrawer\\data\\val2017 \
      --epochs 10 --size 640 --batch-size 4 --save-every 1000 \
      --out-root D:\\aidrawer\\output\\multi

    # 只跑某几个风格（用 --only 按名字筛选）
    python train_multi.py ... --only jojo,ink

    # 查看计划但不动手
    python train_multi.py ... --dry-run
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

CKPT_RE = re.compile(r"^ckpt_step(\d+)\.pth$")


# ==================== 工具函数 ====================
def style_key(path, used):
    """从风格图路径派生一个安全的目录名"""
    base = os.path.splitext(os.path.basename(path))[0]
    key = re.sub(r"[^0-9A-Za-z_\-]", "_", base).strip("_") or "style"
    k, i = key, 2
    while k in used:
        k = "%s_%d" % (key, i)
        i += 1
    used.add(k)
    return k


def list_runs(style_dir):
    """列出某风格目录下的所有运行目录（含 ckpt）"""
    runs = []
    if not os.path.isdir(style_dir):
        return runs
    for d in os.listdir(style_dir):
        p = os.path.join(style_dir, d)
        if not os.path.isdir(p):
            continue
        cks = []
        for f in os.listdir(p):
            m = CKPT_RE.match(f)
            if m:
                cks.append((int(m.group(1)), os.path.join(p, f)))
        if cks:
            cks.sort()
            runs.append({"dir": p, "last_step": cks[-1][0], "ckpt": cks[-1][1],
                         "mtime": os.path.getmtime(p)})
    runs.sort(key=lambda r: r["mtime"], reverse=True)
    return runs


def read_progress(run_dir):
    """读 history.json，返回 (last_step, total_steps, finished)"""
    h = os.path.join(run_dir, "history.json")
    if not os.path.exists(h):
        return None, None, False
    try:
        d = json.load(open(h, encoding="utf-8"))
    except Exception:
        return None, None, False
    cfg = d.get("config", {})
    res = d.get("result", {})
    total = cfg.get("total_steps")
    last = res.get("last_step")
    fin = os.path.exists(os.path.join(run_dir, "model_final.pth"))
    return last, total, fin


def fmt_dur(sec):
    sec = int(max(sec, 0))
    h, m = divmod(sec // 60, 60)
    return ("%d 小时 %d 分" % (h, m)) if h else ("%d 分 %d 秒" % (m, sec % 60))


# ==================== 主流程 ====================
def main():
    ap = argparse.ArgumentParser(description="多风格批量训练调度器")
    ap.add_argument("--styles", required=True,
                    help="风格图路径列表，用逗号分隔（支持完整路径）")
    ap.add_argument("--content-dir", required=True, help="内容图目录（所有风格共用）")
    ap.add_argument("--out-root", required=True,
                    help="总输出目录；每个风格会在其下建一个同名子目录")
    ap.add_argument("--only", default="",
                    help="只跑这些风格（按派生出的目录名筛选，逗号分隔）")
    ap.add_argument("--only-first", type=int, default=0,
                    help="只跑前 N 个风格（0 = 全部）")

    # 训练参数（全部透传给 train.py）
    ap.add_argument("--epochs", type=float, default=10)
    ap.add_argument("--channels", type=int, default=8)
    ap.add_argument("--n-res", type=int, default=3)
    ap.add_argument("--norm", default="instance", choices=["instance", "batch", "none"])
    ap.add_argument("--size", type=int, default=640)
    ap.add_argument("--batch-size", type=int, default=4)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--content-weight", type=float, default=5)
    ap.add_argument("--style-weight", type=float, default=1e7)
    ap.add_argument("--tv-weight", type=float, default=1e-5)
    ap.add_argument("--content-layer", default="relu3_3")
    ap.add_argument("--style-layers", default="relu1_2,relu2_2,relu3_3,relu4_3")
    ap.add_argument("--save-every", type=int, default=1000)
    ap.add_argument("--sample-every", type=int, default=500)
    ap.add_argument("--plot-every", type=int, default=1000)
    ap.add_argument("--log-every", type=int, default=50)
    ap.add_argument("--workers", type=int, default=0)
    ap.add_argument("--seed", type=int, default=0)

    # 调度行为
    ap.add_argument("--auto-resume", dest="auto_resume", action="store_true", default=True,
                    help="已有未完成的检查点时自动续训（默认开启）")
    ap.add_argument("--no-auto-resume", dest="auto_resume", action="store_false",
                    help="关闭自动续训，每次都从头训")
    ap.add_argument("--retry", type=int, default=1,
                    help="某个风格失败后自动重试次数（默认 1 次，配合续训等价于断点续）")
    ap.add_argument("--skip-finished", dest="skip_finished", action="store_true", default=True,
                    help="已跑完的风格直接跳过（默认开启）")
    ap.add_argument("--no-skip-finished", dest="skip_finished", action="store_false")
    ap.add_argument("--dry-run", action="store_true", help="只打印计划，不实际训练")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    train_py = os.path.join(here, "train.py")
    if not os.path.exists(train_py):
        raise SystemExit("找不到 train.py（应与本脚本同目录）: %s" % train_py)

    # ---- 解析风格列表 ----
    raw = [s.strip() for s in args.styles.split(",") if s.strip()]
    if not raw:
        raise SystemExit("--styles 为空")
    used = set()
    items = []
    for p in raw:
        full = os.path.abspath(p)
        items.append({"path": full, "key": style_key(full, used)})

    if args.only:
        want = {s.strip() for s in args.only.split(",") if s.strip()}
        items = [it for it in items if it["key"] in want]
    if args.only_first > 0:
        items = items[:args.only_first]
    if not items:
        raise SystemExit("筛选后没有要训练的风格")

    if not args.dry_run:
        os.makedirs(args.out_root, exist_ok=True)

    # ---- 打印计划 ----
    print("=" * 96)
    print("多风格批量训练计划")
    print("=" * 96)
    print("内容图目录 :", args.content_dir, "(存在)" if os.path.isdir(args.content_dir) else "!! 不存在")
    print("总输出目录 :", args.out_root)
    print("归一化     :", args.norm, "| 通道 C:", args.channels, "| 残差块:", args.n_res)
    print("裁切/batch :", args.size, "/", args.batch_size, "| 轮数:", args.epochs)
    print("自动续训   :", "开" if args.auto_resume else "关",
          "| 失败重试:", args.retry, "次 | 跳过已完成:", "开" if args.skip_finished else "关")
    print("-" * 96)
    print("%-14s %-46s %s" % ("风格名", "风格图", "状态"))
    print("-" * 96)

    for it in items:
        sp = it["path"]
        it["exist"] = os.path.exists(sp)
        it["style_dir"] = os.path.join(args.out_root, it["key"])
        runs = list_runs(it["style_dir"])
        it["runs"] = runs
        note = []
        if not it["exist"]:
            note.append("!! 图片不存在")
        if runs:
            last, total, fin = read_progress(runs[0]["dir"])
            if fin:
                note.append("已完成(step=%s)" % last)
            else:
                note.append("有检查点 step=%s/%s → 将续训" % (last, total))
        elif it["exist"]:
            note.append("全新训练")
        it["note"] = " | ".join(note)
        print("%-14s %-46s %s" % (it["key"], sp, it["note"]))

    print("-" * 96)
    if args.dry_run:
        print("[dry-run] 以上为计划，未执行。")
        return

    # ---- 逐个训练 ----
    summary = []
    t_all = time.time()
    for idx, it in enumerate(items, 1):
        print()
        print("#" * 96)
        print("# [%d/%d] 风格: %s" % (idx, len(items), it["key"]))
        print("#" * 96)

        rec = {"key": it["key"], "style": it["path"], "status": "未开始",
               "steps": None, "seconds": None, "run_dir": None, "note": ""}

        if not it["exist"]:
            rec["status"] = "跳过"
            rec["note"] = "风格图不存在"
            print("!! 风格图不存在，跳过:", it["path"])
            summary.append(rec)
            continue

        os.makedirs(it["style_dir"], exist_ok=True)
        log_path = os.path.join(it["style_dir"], "train.log")

        # 检查是否已完成
        runs = list_runs(it["style_dir"])
        if args.skip_finished and runs:
            last, total, fin = read_progress(runs[0]["dir"])
            if fin:
                rec.update(status="已完成(跳过)", steps=last, run_dir=runs[0]["dir"],
                           note="上次已跑完")
                print("该风格上次已跑完（step=%s），跳过。" % last)
                summary.append(rec)
                continue

        # 组装命令（每次都重新探测，因为重试后会新增检查点）
        attempt = 0
        while attempt <= args.retry:
            runs = list_runs(it["style_dir"])
            resume_ckpt = None
            if args.auto_resume and runs:
                last, total, fin = read_progress(runs[0]["dir"])
                if not fin:
                    resume_ckpt = runs[0]["ckpt"]
                    print("检测到未完成检查点，将续训：", resume_ckpt)
                    print("   （上次记录：step=%s / 目标 %s）" % (last, total))

            cmd = [sys.executable, "train.py",
                   "--style-image", it["path"],
                   "--content-dir", os.path.abspath(args.content_dir),
                   "--channels", str(args.channels),
                   "--n-res", str(args.n_res),
                   "--norm", args.norm,
                   "--size", str(args.size),
                   "--batch-size", str(args.batch_size),
                   "--epochs", str(args.epochs),
                   "--lr", str(args.lr),
                   "--content-weight", str(args.content_weight),
                   "--style-weight", str(args.style_weight),
                   "--tv-weight", str(args.tv_weight),
                   "--content-layer", args.content_layer,
                   "--style-layers", args.style_layers,
                   "--save-every", str(args.save_every),
                   "--sample-every", str(args.sample_every),
                   "--plot-every", str(args.plot_every),
                   "--log-every", str(args.log_every),
                   "--workers", str(args.workers),
                   "--seed", str(args.seed)]
            if resume_ckpt:
                # 续训：不传 --out-dir，train.py 会写回原目录（历史与曲线继续累计）
                cmd += ["--resume", resume_ckpt]
            else:
                cmd += ["--out-dir", it["style_dir"], "--tag", it["key"]]

            tag = "首次" if attempt == 0 else "重试#%d" % attempt
            print("-" * 96)
            print("[%s] 执行：" % tag)
            print("  " + " ".join(('"%s"' % c if " " in c else c) for c in cmd))
            print("  日志：" + log_path)
            print("-" * 96)

            t0 = time.time()
            rc = None
            try:
                with open(log_path, "a", encoding="utf-8") as lf:
                    lf.write("\n\n===== [%s] %s =====\n" % (tag, time.strftime("%Y-%m-%d %H:%M:%S")))
                    lf.write("CMD: " + " ".join(cmd) + "\n\n")
                    lf.flush()
                    proc = subprocess.Popen(cmd, cwd=here, stdout=subprocess.PIPE,
                                            stderr=subprocess.STDOUT, text=True,
                                            encoding="utf-8", errors="replace", bufsize=1)
                    for line in proc.stdout:
                        sys.stdout.write(line)
                        sys.stdout.flush()
                        lf.write(line)
                        lf.flush()
                    rc = proc.wait()
            except KeyboardInterrupt:
                print("\n!! 收到中断信号，停止批量训练")
                rec.update(status="已中断", note="用户 Ctrl+C")
                summary.append(rec)
                raise
            except Exception as e:
                print("!! 启动训练失败:", e)
                rc = -1

            dur = time.time() - t0
            # 探测本次结果
            runs = list_runs(it["style_dir"])
            if runs:
                last, total, fin = read_progress(runs[0]["dir"])
                rec.update(steps=last, seconds=dur, run_dir=runs[0]["dir"])
                if fin:
                    rec.update(status="完成", note="%s 步" % last)
                    break
            if rc == 0:
                rec.update(status="完成(无final)", note="退出码 0")
                break

            # 失败
            if attempt < args.retry:
                print("!! 该风格训练失败（退出码 %s），将重试（第 %d 次）" % (rc, attempt + 1))
                if rc == 2:
                    print("   退出码 2 = 内存类错误。重试时建议先关掉其他程序；")
                attempt += 1
                continue
            rec.update(status="失败", note="退出码 %s，已重试 %d 次" % (rc, args.retry))
            break

        summary.append(rec)
        print()
        print(">>> [%s] 本风格结果：%s（%s）" % (it["key"], rec["status"], rec["note"]))

    # ---- 汇总 ----
    total_dur = time.time() - t_all
    print()
    print("=" * 96)
    print("批量训练汇总")
    print("=" * 96)
    print("%-14s %-18s %10s %14s %s" % ("风格名", "状态", "步数", "耗时", "输出目录"))
    print("-" * 96)
    n_ok = n_fail = n_skip = 0
    for r in summary:
        if r["status"].startswith("完成"):
            n_ok += 1
        elif r["status"] in ("失败", "已中断"):
            n_fail += 1
        else:
            n_skip += 1
        print("%-14s %-18s %10s %14s %s" % (
            r["key"], r["status"], r["steps"] or "-",
            fmt_dur(r["seconds"]) if r["seconds"] else "-",
            r["run_dir"] or "-"))
    print("-" * 96)
    print("完成 %d 个 | 失败 %d 个 | 跳过 %d 个 | 总耗时 %s" % (n_ok, n_fail, n_skip, fmt_dur(total_dur)))

    out = {"generated": time.strftime("%Y-%m-%d %H:%M:%S"),
           "config": {"content_dir": args.content_dir, "epochs": args.epochs,
                      "size": args.size, "batch_size": args.batch_size,
                      "norm": args.norm, "out_root": args.out_root},
           "results": summary,
           "total_seconds": total_dur}
    jp = os.path.join(args.out_root, "_multi_summary.json")
    with open(jp, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("汇总已保存:", jp)
    if n_fail:
        print()
        print("!! 有 %d 个风格未完成。重新执行同一条命令即可自动续训（未加 --no-auto-resume 时）。" % n_fail)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n已中断。")
        sys.exit(130)
