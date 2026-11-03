# 训练工具包 · FNS 1/4 通道版

把"真模型"训出来并看到画质。三个文件：

| 文件 | 作用 |
|---|---|
| `model.py` | 网络定义（C 可配置，默认 8 = 1/4 通道版） |
| `train.py` | 训练脚本（VGG 感知损失） |
| `stylize.py` | 推理脚本（单图 / 视频） |

---

## 一、环境准备（你自己操作）

```bash
conda create -n fns python=3.11 -y
conda activate fns
```

**⚠️ RTX 5070 Laptop 的关键点**：RTX 50 系列是 Blackwell 架构（sm_120），
**必须用 CUDA 12.8 及以上的 PyTorch 构建**。旧版 PyTorch 会报
"no kernel image is available"。

去 <https://pytorch.org/get-started/locally/> 选 **CUDA 12.8** 拿到安装命令，
大致形如：

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
pip install pillow numpy opencv-python
```

装完自检：

```bash
python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0))"
```

能打印出显卡名就说明配对成功。

---

## 二、准备数据

### 风格图（1 张）
自己挑一张，放进 `style/` 目录。建议选**高对比、几何感强**的风格
（浮世绘、版画、高对比海报风），小网络对这类风格表现更好。

### 内容图（一批照片）
用 COCO 数据集。**推荐 val2017（5000 张，约 1GB）**，而不是 train2017（13GB）：

<http://images.cocodataset.org/zips/val2017.zip>

解压后把图片放进 `data/coco512/`（脚本会递归扫描子目录，怎么放都行）。
如果嫌大，从里面挑 2000~5000 张就够。

---

## 三、先自检架构

```bash
python model.py
```

期望输出（C=8，3 残差块）：
- 卷积权重 **68,400** 个
- 输入 480×640 → 输出 **480×640**（尺寸必须一致）

这两条对了，说明架构和之前算的一致。

---

## 四、训练

```bash
python train.py \
  --style-image style/ukiyoe.jpg \
  --content-dir data/coco512 \
  --channels 8 --n-res 3 \
  --size 256 --batch-size 8 --epochs 2 \
  --out-dir runs
```

训练过程中：
- 每 50 步打印 loss（内容/风格分开看）
- 每 500 步存一张对比样图到 `runs/sample_XXXXXX.jpg`（**左=原图，右=风格化**）
- 每 2000 步存一次中间权重

**想看画质够不够，训练早期就能判断**——先跑几百步看
`sample_*.jpg`，风格有没有上上去。不够再调权重。

### 参数量不够时怎么调

| 手段 | 命令改动 | 效果 |
|---|---|---|
| 加宽通道 | `--channels 9` | 质量↑，算力↑（仍在预算内） |
| 加残差块 | `--n-res 4` | 质量↑，算力↑ |
| 风格更强 | `--style-weight 3e5` | 风格更重，可能压内容 |
| 内容更清晰 | `--content-weight 3` | 结构保留更好 |
| 换归一化 | `--norm batch` | 硬件更省，质量可能略降 |

> 损失权重的默认值（style 1e5 / content 1 / tv 1e-6）是**起始值**，不是调好的最优值，需要按实际效果调。

---

## 五、看效果：单图 → 视频

### 单图
```bash
python stylize.py --model runs/model.pth --input photo.jpg --output styled.jpg
```

### 视频（电脑版"实时风格化系统"）
```bash
python stylize.py --model runs/model.pth --input in.mp4 --output out.mp4 --max-size 640
```

视频模式会打印 **平均 fps**。这个数字有两个用途：
1. 证明算法可行；
2. **作为 FPGA 的对照组**——"GPU 跑 X fps / 高功耗" vs "FPGA 跑 15+ fps / 低功耗"，
   这是答辩里很有说服力的素材。

---

## 六、常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `no kernel image is available` | PyTorch 不支持 sm_120，换 cu128 版本 |
| 显存不足 | 减小 `--batch-size`（4 或 2）或 `--size`（192） |
| 输出全灰 / 无风格 | 风格权重太小，`--style-weight` 调大 |
| 输出结构丢失 | 内容权重太小，`--content-weight` 调大 |
| 训练很慢 | 确认 `torch.cuda.is_available()` 为 True；换 SSD 存放数据 |
| 下载 VGG 失败 | VGG16 权重需联网下载（约 500MB），首次会缓存 |

---

## 七、训完之后接什么

训练产出的 `model.pth` 是整条链路的"内容"。接下来：

1. **量化**：把 `.pth` 的浮点权重转成 INT8，算出每层缩放参数（复用 starter-kit 的思路）
2. **导出**：把量化权重 + 参数写成硬件能读的格式
3. **对比分析**：把"1/8 / 1/4 / 全尺寸"三个规格的 PSNR/SSIM 与推理延迟列成表
   —— 这正是题目高阶挑战要求的交付物

> 说明：权重里含 InstanceNorm 参数。如果最终硬件选 `--norm instance`，
> 需要单独实现归一化；选 `--norm batch` 则可以折进卷积权重。这个决定
> 等看到画质之后再定不迟。
