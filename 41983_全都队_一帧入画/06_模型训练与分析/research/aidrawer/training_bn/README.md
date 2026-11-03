# training_bn · 归一化方案三组对照实验

**这个文件夹和 `training/` 并列，完全独立——`training/` 里的代码一行未改。**

目的：用数据回答一个**硬件架构决策问题**——

> InstanceNorm 画质好但硬件要额外做统计电路；BatchNorm 可以折进卷积、硬件几乎零成本。
> 到底该选哪个？

## 目录结构

```
training_bn/
├── model.py        ← 与 training/ 完全相同（归一化已参数化，无需改动）
├── stylize.py      ← 与 training/ 完全相同（含摄像头实时预览）
├── train.py        ← 改进版：修广播告警 / 风格损失科学计数 / 导出 train_log.json
├── evaluate.py     ← 新增：PSNR / SSIM / 风格距离 / 推理延迟 / 确定性
├── run_compare.py  ← 新增：三组对照总调度 + 自动生成报告
├── selfcheck.py    ← 新增：静态自检（语法 + 参数一致性 + 导入检查，不跑模型）
├── test_resize.py  ← 新增：尺寸对齐回归测试（复现 640×426 场景）
├── test_mem.py     ← 新增：内存诊断 + DataLoader 参数构建功能测试
└── README.md
```

### 先跑一次自检（几秒，不占 GPU）

```bash
python selfcheck.py     # 语法 / 参数一致性 / 导入检查
python test_resize.py   # 尺寸对齐逻辑回归测试
python test_mem.py      # 内存诊断 + DataLoader 参数逻辑（需 torch）
```

它会检查：5 个文件语法是否正常、`run_compare.py` 传给 `train.py`/`evaluate.py` 的参数是否都被接受、
跨文件导入是否存在、`model.py` 是否支持三种归一化、以及尺寸对齐是否满足网络要求。
**改动任何文件后建议先跑一次。**

`train.py` 相对原版的三处改动（**算法本身没变**）：
1. 风格损失用 `%.3e` 打印（原版 `%.4f` 会把 1e-5 显示成 0.0000，看不见变化）
2. 风格 Gram 显式 `expand` 到 batch，消除刷屏的广播告警（数学等价）
3. 训练结束导出 `train_log.json`（loss 曲线、耗时、显存峰值、稳定性指标）

## 一、快速验证流程（几十秒）

```bash
cd "D:\Program Files\ClawFiles\deliverables\efinix-realtime-style-transfer\training_bn"

python run_compare.py ^
  --style-image 你的风格图.jpg ^
  --content-dir D:\aidrawer\data\val2017 ^
  --quick --out-root D:\aidrawer\runs_bn_quick
```

`--quick` 每档只跑 20 步、评估 3 张图。**结果无参考价值，只用于确认流程能跑通**（尤其是 `batch` / `none` 两个模式能不能正常训练和加载）。

## 二、正式三组对照

```bash
python run_compare.py ^
  --style-image 你的风格图.jpg ^
  --content-dir D:\aidrawer\data\val2017 ^
  --eval-count 50 --eval-size 640 ^
  --channels 8 --n-res 3 --size 640 --batch-size 4 --epochs 30 ^
  --content-weight 5 --style-weight 1e7 --tv-weight 1e-5 ^
  --style-layers relu1_2,relu2_2,relu3_3,relu4_3 ^
  --out-root D:\aidrawer\runs_bn
```

> PowerShell 的换行符是反引号 `` ` ``，上面用的是 cmd 的 `^`。写成一行最省事。

**三组共用相同的参数与随机种子**（`--seed 0`），保证结果可比。

### 预计耗时

单档耗时主要看 `--size` 和 `--epochs`。按你之前的实测（size 640、约 2 步/秒、2500 步约 20 分钟）估算：

| 内容 | 单档 | 三档合计 |
|---|---|---|
| 训练 | 约 20~30 分钟 | 约 1~1.5 小时 |
| 评估 | 约 1~2 分钟 | 约 5 分钟 |

**耗时是估算，以实测为准。** 建议先用 `--epochs 2` 跑一轮看效果，再决定要不要加长。

### 显存提醒

`--size 640 --batch-size 4` 在你 8GB 显存上应该可行（训练时 VGG 特征图是主要开销）。若报 OOM：

```bash
--batch-size 2      # 或
--size 480 --batch-size 4
```

**注意**：三组必须用相同设置，否则不可比。

## 三、产出

```
<out-root>/
├── instance/
│   ├── model.pth          ← 模型
│   ├── train_log.json     ← 训练日志（含 loss 曲线）
│   ├── eval.json          ← 评估指标
│   └── sample_*.jpg       ← 对比样图（左=原图，右=风格化）★ 最重要
├── batch/                 ← 同上
├── none/                  ← 同上
├── compare_report.md      ← 对照报告 ★
└── compare_results.csv    ← 表格数据
```

## 四、已知问题与修复记录

### 修复 #1（2026-09-16）：尺寸非 4 倍数导致评估崩溃

**现象**：`evaluate.py` 报 `RuntimeError: The size of tensor a (426) must match the size of tensor b (428)`。

**根因**：网络含两次 stride-2 下采样 + 两次 ×2 上采样。
下采样用卷积实现，公式为 `floor((n-1)/2)+1`（会向下取整丢掉半个像素），而上采样精确 ×2 补不回来。
所以 H/W **必须能被 4 整除**，否则输入输出尺寸不一致：

```
输入 426 → 下采样 213 → 107 → 上采样 428   ✗ 与输入不符
输入 428 → 下采样 214 → 107 → 上采样 428   ✓
```

**触发原因**：`resize_keep_ratio()` 在“不需要缩放”的分支里直接原样返回，未做对齐。
COCO val2017 里有大量 **640×426** 这类图（长边正好 640），于是走了该分支。

**修复**：`evaluate.py` 与 `stylize.py` 中的 `resize_keep_ratio()` 统一改为——

1. 无论如何都对齐到 **4 的倍数**（不再提前返回）
2. 需要缩放时先按长边缩，再对齐

**影响**：向下取整最多损失 3 个像素，肉眼无感。
**注意**：这个约束在 FPGA 上同样真实存在（硬件流水线通常也要求宽度为某个数的倍数），
修复的只是脚本遗忘对齐的问题，不是绕过约束。

**回归测试**：`python test_resize.py`（覆盖 640×426、1920×1080、小于 4 的极小尺寸等 10+ 案例）

### 修复 #2（2026-09-16）：DataLoader 多进程撞系统提交内存上限

**现象**：训练中途崩溃，两类报错——

```
RuntimeError: Couldn't open shared file mapping: <torch_...>, error code: <1455>
RuntimeError: Caught MemoryError in DataLoader worker process 1
  → numpy._core._exceptions._ArrayMemoryError: Unable to allocate 1.17 MiB
```

**关键澄清：这不是显存不足。** 错误码 **1455 = ERROR_COMMITMENT_LIMIT**，
指的是 Windows 的**系统提交内存（物理内存 + 页面文件）**耗尽。
报错位置在 DataLoader worker 里（分配 1.17 MiB 都失败了），说明是 CPU 侧内存而非 GPU。

**根因**：`--workers 4` 在 Windows 上会派生 4 个子进程，
**每个子进程都要重新加载一份 torch 运行时**（几百 MB）。
再叠加主进程的 CUDA 上下文，很容易撞上提交上限。

**旁证**：文件时间戳显示内存是**逐步累积**的——第一组（instance）跑到约 1150 步才崩，
第二组（batch）只跑到约 200 步就崩了，符合“共享映射未及时释放”的特征。

**修复**：

1. `train.py`：`--workers` 默认从 **4 改为 0**（单进程加载数据，根本不产生共享文件映射）；
   新增 `--prefetch-factor`；`prefetch_factor` / `persistent_workers` 只在 `workers>0` 时传入
   （否则 PyTorch 会直接报 ValueError）。
2. `train.py`：启动时打印**可用物理/提交内存**，不足 2 GB 时提前警告。
3. `train.py`：捕获此类错误并打印**可操作的排查指引**（退出码 2）。
4. `run_compare.py`：`--workers` 默认 0；训练失败时**自动用 `--workers 0` 重试一次**。

**性能影响**：几乎为零。size 640 下 GPU 是瓶颈（2.1 步/秒），
而 DataLoader 加载 4 张图只需几十毫秒，单进程完全吃得消。

**若仍然报错**，按顺序尝试：

| 措施 | 说明 |
|---|---|
| 降 `--batch-size`（4 → 2） | 直接减半内存占用 |
| 关闭其他占内存程序 | 浏览器 / IDE / 残留的训练进程 |
| 调大 Windows 虚拟内存 | 系统属性 → 高级 → 性能设置 → 高级 → 虚拟内存，设为物理内存的 1.5~2 倍 |

**回归测试**：`python test_mem.py`

## 五、怎么看结果

**先看样图，再看数字。**

| 步骤 | 看什么 | 判断 |
|---|---|---|
| 1 | `runs_bn/<mode>/sample_002500.jpg` 等样图 | 肉眼比笔触/纹理是否自然 |
| 2 | `compare_report.md` 的指标表 | PSNR/SSIM 高=结构保留好；风格距离低=风格更接近目标 |
| 3 | 报告第三节「硬件代价对照」 | BatchNorm / none 可省整套归一化电路 + DDR 往返 |

### 指标的边界（务必知道）

- **PSNR / SSIM 衡量"内容保留"，不是"画质好坏"。** 风格迁移没有标准答案图，所以这两个数**不能单独判定好看与否**。
- **风格距离**衡量纹理统计与风格图的接近程度，同样不等于"好看"。
- 三个数要合起来看：

| 组合 | 含义 |
|---|---|
| PSNR 高 + 风格距离低 | 两全（理想） |
| PSNR 高 + 风格距离高 | 只保住原图，风格没上去 |
| PSNR 低 + 风格距离低 | 风格压过内容（可能就是"糊满星点"） |

**最终还是要靠肉眼。** 数字只用来排除明显更差的选项。

## 六、只跑部分流程

```bash
# 只跑两组
python run_compare.py ... --modes instance,batch

# 内存紧张时：显式用单进程 + 小 batch
python run_compare.py ... --workers 0 --batch-size 2

# 模型已训好，只重新评估
python run_compare.py ... --skip-train

# 只训不评
python run_compare.py ... --skip-eval

# 单独调某一档（比如就想看看 batch 的画质）
python train.py --norm batch --out-dir D:\aidrawer\runs_bn\batch \
    --style-image 风格图.jpg --content-dir D:\aidrawer\data\val2017 ^
    --size 640 --batch-size 4 --epochs 30 ^
    --content-weight 5 --style-weight 1e7 --tv-weight 1e-5

# 用训好的模型做单图/视频/摄像头预览
python stylize.py --model D:\aidrawer\runs_bn\batch\model.pth --norm batch --camera 0
```

> **注意**：`stylize.py` 的 `--norm` 必须和训练时一致，否则加载权重会报错（形状不匹配）。

## 七、这个实验的额外价值

这份对照数据可以直接用作题目高阶挑战要求的材料：

> "提交网络结构图、参数量统计表，并与标准网络进行**画质（PSNR/SSIM）与推理延迟的对比分析**"

我们不仅做了不同网络规格的对比，还做了**归一化方案的硬件代价对比**——后者与 FPGA 实现直接相关，是更有说服力的加分项。

## 八、答辩可用的一句话

> 我们对比了三种归一化方案：InstanceNorm 画质最佳，但推理时需实时统计，
> 硬件上要额外一套统计电路、特征图缓冲与 DDR 往返（单层特征图最高约 2.3 MB，
> 远超片上 190 KB 可用 BRAM）；BatchNorm 推理时可完全折进卷积权重，
> 硬件零额外开销。综合画质与资源占用，我们选择 ______。

（空白处等你跑完实验填。）
