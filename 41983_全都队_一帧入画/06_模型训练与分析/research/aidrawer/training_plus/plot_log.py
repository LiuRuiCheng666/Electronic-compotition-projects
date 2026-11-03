# -*- coding: utf-8 -*-
"""
训练曲线绘制（training_plus）

优先用 matplotlib 画（矢量感好、支持对数轴）；若导入失败，自动降级为纯 PIL 绘制。
输出：loss_curve.png —— 两栏子图
    上：总损失 + 内容损失（线性轴）
    下：风格损失 + TV 损失（对数轴，因为它们量级很小）
坐标轴标签用英文，避免 matplotlib 默认字体缺少中文字形而显示成方块。
"""
import os


def _series(history, key):
    xs, ys = [], []
    for r in history:
        v = r.get(key)
        if v is None:
            continue
        xs.append(r["step"])
        ys.append(v)
    return xs, ys


def plot_history(history, out_path, title="", tps=None):
    """history: [{'step':int,'loss':f,'content':f,'style':f,'tv':f}, ...]
    tps: 可选，速度文本（步/秒）"""
    if not history:
        print("  (history 为空，跳过绘图)")
        return False
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    try:
        return _plot_matplotlib(history, out_path, title, tps)
    except Exception as e:
        print("  matplotlib 绘图失败(%s)，改用 PIL 降级绘制" % e)
        try:
            return _plot_pil(history, out_path, title, tps)
        except Exception as e2:
            print("  PIL 绘图也失败: %s" % e2)
            return False


# ---------------- matplotlib 版 ----------------
def _plot_matplotlib(history, out_path, title, tps):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    # 配置中文字体：若标题含中文，避免显示成方块（Windows 自带雅黑/黑体）
    matplotlib.rcParams["font.sans-serif"] = [
        "Microsoft YaHei", "SimHei", "DejaVu Sans"]
    matplotlib.rcParams["axes.unicode_minus"] = False

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 7.5), sharex=True)

    s, y = _series(history, "loss")
    ax1.plot(s, y, color="#2563eb", lw=2.0, label="total loss")
    s, y = _series(history, "content")
    ax1.plot(s, y, color="#0d9488", lw=1.6, alpha=0.9, label="content loss")
    ax1.set_ylabel("loss (linear)")
    ax1.grid(alpha=0.25, ls="--")
    ax1.legend(loc="upper right", fontsize=9)

    s, y = _series(history, "style")
    if y:
        ax2.plot(s, y, color="#7c3aed", lw=1.6, label="style loss (x1e-5)")
        ax2.set_yscale("log")
    s, y = _series(history, "tv")
    if y:
        ax2.plot(s, y, color="#d97706", lw=1.6, alpha=0.85, label="tv loss")
        ax2.set_yscale("log")
    ax2.set_xlabel("training step")
    ax2.set_ylabel("loss (log)")
    ax2.grid(alpha=0.25, ls="--", which="both")
    ax2.legend(loc="upper right", fontsize=9)

    head = title or "training curves"
    if tps:
        head += "   (%.2f steps/s)" % tps
    fig.suptitle(head, fontsize=12)
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    fig.savefig(out_path, dpi=110)
    plt.close(fig)
    return True


# ---------------- PIL 降级版 ----------------
def _plot_pil(history, out_path, title, tps):
    from PIL import Image, ImageDraw, ImageFont

    W, H = 1100, 760
    img = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(img)
    try:
        f_big = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 20)
        f_s = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 14)
    except Exception:
        f_big = ImageFont.load_default()
        f_s = ImageFont.load_default()

    head = title or "training curves"
    if tps:
        head += "   (%.2f steps/s)" % tps
    d.text((30, 16), head, font=f_big, fill=(30, 41, 59))

    def panel(y0, h, keys, colors, logy, name):
        L, R = 110, W - 40
        d.rectangle([L, y0, R, y0 + h], outline=(210, 217, 226), width=1)
        allx, ally = [], []
        for k in keys:
            xs, ys = _series(history, k)
            allx += xs
            if logy:
                ys = [max(v, 1e-12) for v in ys]
            ally += ys
        if not allx:
            return
        import math
        xmin, xmax = min(allx), max(allx)
        ymin, ymax = min(ally), max(ally)
        if logy:
            ymin, ymax = math.log10(ymin), math.log10(ymax)
        if ymax - ymin < 1e-12:
            ymax = ymin + 1e-12

        def px(x):
            return L + (x - xmin) / max(xmax - xmin, 1e-9) * (R - L)

        def py(v):
            vv = math.log10(max(v, 1e-12)) if logy else v
            return y0 + h - (vv - ymin) / (ymax - ymin) * h

        for k, col in zip(keys, colors):
            xs, ys = _series(history, k)
            pts = [(px(a), py(b)) for a, b in zip(xs, ys)]
            if len(pts) > 1:
                d.line(pts, fill=col, width=2, joint="curve")
        d.text((L, y0 - 20), name, font=f_s, fill=(100, 116, 139))
        d.text((L - 100, y0), "%.3g" % (max(ally) if not logy else 10 ** ymax), font=f_s, fill=(100, 116, 139))
        d.text((L - 100, y0 + h - 16), "%.3g" % (min(ally) if not logy else 10 ** ymin), font=f_s, fill=(100, 116, 139))

    panel(80, 260, ["loss", "content"], [(37, 99, 235), (13, 148, 136)], False, "total / content loss (linear)")
    panel(420, 260, ["style", "tv"], [(124, 58, 237), (217, 119, 6)], True, "style / tv loss (log)")
    d.text((110, 706), "x-axis: training step", font=f_s, fill=(100, 116, 139))
    img.save(out_path)
    return True


if __name__ == "__main__":
    import json
    import sys
    if len(sys.argv) > 1:
        with open(sys.argv[1], encoding="utf-8") as f:
            data = json.load(f)
        hist = data.get("history", data)
        out = sys.argv[2] if len(sys.argv) > 2 else "loss_curve.png"
        print("生成:", out, plot_history(hist, out, "test"))
