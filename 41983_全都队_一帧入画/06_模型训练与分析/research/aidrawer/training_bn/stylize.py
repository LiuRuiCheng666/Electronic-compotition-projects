# -*- coding: utf-8 -*-
"""
风格化推理脚本：单图 / 视频 / 摄像头实时预览

用法:
    # 单张图片
    python stylize.py --model runs/model.pth --input photo.jpg --output out.jpg

    # 视频（逐帧风格化）
    python stylize.py --model runs/model.pth --input in.mp4 --output out.mp4

    # 摄像头实时预览（原画 | 风格画 左右对比，窗口内显示 FPS）
    python stylize.py --model runs/model.pth --camera 0

    # 摄像头预览 + 同时保存风格化视频
    python stylize.py --model runs/model.pth --camera 0 --save out.mp4

窗口热键:
    q 或 ESC : 退出
    s        : 保存当前这一帧的对比图

视频模式会打印处理速度（fps），这个数字有两个用途:
    ① 证明算法可行；② 作为 FPGA 加速的对照组（GPU fps vs FPGA fps）
"""
import argparse
import os
import time

import torch
from PIL import Image
from torchvision import transforms

from model import FastNeuralStyleNet


def load_model(path, channels=8, n_res=3, norm="instance", dev="cuda"):
    net = FastNeuralStyleNet(channels, n_res, norm).to(dev).eval()
    sd = torch.load(path, map_location=dev)
    net.load_state_dict(sd)
    return net


def style_image(net, img_tensor, dev):
    """输入 [1,3,H,W]，输出 [3,H,W]（CPU，取值 0~1）"""
    with torch.no_grad():
        return net(img_tensor.to(dev))[0].clamp(0, 1).cpu()


def resize_keep_ratio(w, h, max_size):
    """长边限制到 max_size，保持长宽比；并把宽高对齐到 4 的倍数。

    为什么是 4：网络含两次 stride-2 下采样 + 两次 ×2 上采样。
    下采样为 floor((n-1)/2)+1（会丢掉半个像素），上采样精确 ×2 补不回来，
    所以 H/W 必须能被 4 整除，否则输入输出尺寸不一致。

    注意：即使不需要缩放，也必须做对齐——否则长边正好等于上限、
    另一维不是 4 的倍数时（如 640×426）会出错。
    """
    if max_size and max(w, h) > max_size:
        s = max_size / max(w, h)
        w, h = int(w * s), int(h * s)
    return max(w // 4 * 4, 4), max(h // 4 * 4, 4)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--input", default=None, help="图片或视频路径（不用摄像头时必填）")
    ap.add_argument("--output", default=None, help="输出路径（不用摄像头时必填）")
    ap.add_argument("--camera", type=int, default=-1,
                    help="摄像头索引，例如 0 表示默认摄像头；给了就用实时预览模式")
    ap.add_argument("--save", default=None,
                    help="摄像头模式下额外保存风格化视频的路径（可选）")
    ap.add_argument("--channels", type=int, default=8)
    ap.add_argument("--n-res", type=int, default=3)
    ap.add_argument("--norm", default="instance")
    ap.add_argument("--max-size", type=int, default=0,
                    help="限制处理分辨率的长边。视频默认 0(不限制)；摄像头默认 640")
    ap.add_argument("--mirror", action="store_true",
                    help="摄像头画面水平镜像（自拍视角更自然）")
    args = ap.parse_args()

    dev = "cuda" if torch.cuda.is_available() else "cpu"
    net = load_model(args.model, args.channels, args.n_res, args.norm, dev)
    print("模型已加载 | 设备:", dev)
    if dev == "cuda":
        torch.backends.cudnn.benchmark = True   # 固定尺寸下可加速卷积

    # ================== 摄像头实时预览 ==================
    if args.camera >= 0:
        try:
            import cv2
            import numpy as np
        except ImportError:
            raise SystemExit("摄像头模式需要 opencv: pip install opencv-python")

        cap = cv2.VideoCapture(args.camera)
        if not cap.isOpened():
            raise SystemExit("打不开摄像头 index=%d（换个索引试试，如 --camera 1）" % args.camera)

        max_size = args.max_size or 640        # 摄像头默认限到 640
        fps_cam = cap.get(cv2.CAP_PROP_FPS) or 30
        W0 = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        H0 = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        w, h = resize_keep_ratio(W0, H0, max_size)
        print("摄像头 %d: %dx%d → 处理尺寸 %dx%d" % (args.camera, W0, H0, w, h))
        print("热键: q/ESC 退出, s 保存当前帧对比图")

        writer = None
        if args.save:
            writer = cv2.VideoWriter(args.save, cv2.VideoWriter_fourcc(*"mp4v"), fps_cam, (w, h))
            print("将同时保存风格化视频到:", args.save)

        win = "Stylizer  [q]=quit  [s]=save"
        cv2.namedWindow(win, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(win, w * 2, h + 34)   # 并排窗口

        tf = transforms.ToTensor()
        n_frames = 0
        t0 = time.time()
        fps_shown = 0.0
        times = []                              # 最近若干帧耗时，用于平滑 FPS

        while True:
            ok, frame = cap.read()
            if not ok:
                print("摄像头读取失败，退出")
                break
            if args.mirror:
                frame = cv2.flip(frame, 1)
            if (frame.shape[1], frame.shape[0]) != (w, h):
                frame = cv2.resize(frame, (w, h))

            # --- 风格化 ---
            t1 = time.time()
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            x = tf(Image.fromarray(rgb)).unsqueeze(0)
            y = style_image(net, x, dev)
            out = (y.permute(1, 2, 0).numpy() * 255).astype("uint8")
            styled = cv2.cvtColor(out, cv2.COLOR_RGB2BGR)
            times.append(time.time() - t1)
            if len(times) > 30:
                times.pop(0)

            n_frames += 1
            el = time.time() - t0
            fps_shown = n_frames / max(el, 1e-6)
            infer_ms = sum(times) / len(times) * 1000

            # --- 拼成"原画 | 风格画" ---
            pair = np.hstack([frame, styled])
            cv2.line(pair, (w, 0), (w, h), (0, 220, 255), 2)     # 中间分隔线
            # 顶部信息条
            bar = np.zeros((34, w * 2, 3), dtype="uint8")
            bar[:] = (32, 32, 32)
            cv2.putText(bar, "INPUT", (12, 23),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (200, 200, 200), 2)
            cv2.putText(bar, "STYLIZED", (w + 12, 23),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 220, 255), 2)
            cv2.putText(bar, "FPS %.1f  |  infer %.1f ms  |  %dx%d" %
                        (fps_shown, infer_ms, w, h),
                        (w * 2 - 430, 23),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.55, (160, 255, 160), 1)
            view = np.vstack([bar, pair])

            cv2.imshow(win, view)
            if writer is not None:
                writer.write(styled)

            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if key == ord("s"):
                fn = "snapshot_%06d.jpg" % n_frames
                cv2.imwrite(fn, view)
                print("已保存对比图:", fn)

        cap.release()
        if writer is not None:
            writer.release()
            print("已保存风格化视频:", args.save)
        cv2.destroyAllWindows()
        print("共 %d 帧，耗时 %.1fs，平均 %.2f fps" % (n_frames, time.time() - t0, fps_shown))
        return

    # ================== 文件模式（单图 / 视频） ==================
    if not args.input or not args.output:
        raise SystemExit("文件模式需要 --input 和 --output（或用 --camera 0 开摄像头）")

    ext = os.path.splitext(args.input)[1].lower()

    # ---------------- 单图 ----------------
    if ext in (".jpg", ".jpeg", ".png", ".bmp", ".webp"):
        tf = transforms.ToTensor()
        x = tf(Image.open(args.input).convert("RGB")).unsqueeze(0)
        t = time.time()
        y = style_image(net, x, dev)
        Image.fromarray((y.permute(1, 2, 0).numpy() * 255).astype("uint8")).save(args.output)
        print("完成: %s  (%.0f ms)" % (args.output, (time.time() - t) * 1000))
        return

    # ---------------- 视频 ----------------
    try:
        import cv2
    except ImportError:
        raise SystemExit("视频模式需要 opencv: pip install opencv-python")

    cap = cv2.VideoCapture(args.input)
    if not cap.isOpened():
        raise SystemExit("打不开视频: %s" % args.input)
    fps_in = cap.get(cv2.CAP_PROP_FPS) or 30
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print("输入视频: %dx%d, %.1f fps, %d 帧" % (w, h, fps_in, n))

    w, h = resize_keep_ratio(w, h, args.max_size)
    if (w, h) != (int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))):
        print("已缩放到 %dx%d" % (w, h))

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    vw = cv2.VideoWriter(args.output, fourcc, fps_in, (w, h))

    tf = transforms.ToTensor()
    i = 0
    t0 = time.time()
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        if (rgb.shape[1], rgb.shape[0]) != (w, h):
            rgb = cv2.resize(rgb, (w, h))
        x = tf(Image.fromarray(rgb)).unsqueeze(0)
        y = style_image(net, x, dev)
        out = (y.permute(1, 2, 0).numpy() * 255).astype("uint8")
        vw.write(cv2.cvtColor(out, cv2.COLOR_RGB2BGR))

        i += 1
        if i % 30 == 0:
            el = time.time() - t0
            print("  %d/%d 帧  %.1f fps" % (i, n, i / max(el, 1e-6)))

    cap.release()
    vw.release()
    el = time.time() - t0
    print("完成: %s" % args.output)
    print("共 %d 帧，耗时 %.1fs，平均 %.2f fps" % (i, el, i / max(el, 1e-6)))


if __name__ == "__main__":
    main()
