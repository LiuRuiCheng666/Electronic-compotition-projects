# training_plus · 训练增强版（周期性保存模型 + 续训 + 损失曲线）

**定位**：以 `training/` 为基线的**功能增强版**——核心训练算法一字未改，只增加"训练过程可观察、可中断、可续训"的能力。

> `training/` 与本目录并列、**原封不动**。

## 一、与 training 的差异（只有"增加"，没有"修改"）

| 项 | training/train.py | training_plus/train.py |
|---|---|---|
| 损失定义（内容 + Gram + TV） | 原样 | **完全一致**（逐条片段比对通过） |
| 网络结构 / 数据集 / VGG 裁判 | 原样 | **完全一致** |
| `model.py` / `stylize.py` | — | **逐字节复制，未改一个字符** |
| 输出目录 | `--out-dir` 直接就是目录 | **`--out-dir` 作为父目录，自动建时间戳子文件夹** |
| 模型保存 | 只有 `ckpt_every`（默认 2000）存 `ckpt_*.pth`；结束存 `model.pth` | **每 `--save-every` 步同时存 `model_step*.pth` + `ckpt_step*.pth`** |
| 续训 | 无 | **`--resume` 可从任意检查点接着训** |
| 训练记录 | 无 | **`history.json`（中途持续写）+ `loss_curve.png`（损失曲线）** |
| 评估 | 无 | 无（按需求不引入） |

## 二、文件清单

| 文件 | 作用 |
|---|---|
| `model.py` | 网络定义（与 training 逐字节相同） |
| `stylize.py` | 推理/摄像头预览（与 training 逐字节相同） |
| `train.py` | **训练主脚本（增强版）** |
| `plot_log.py` | 损失曲线绘制（matplotlib；失败自动降级为纯 PIL） |
| `selfcheck.py` | 自检：语法 / 一致性 / 参数 / 检查点往返 / 绘图 |
| `README.md` | 本文件 |

## 三、用法

### 3.1 首次训练

```bash
python train.py --style-image standard3.jpg --content-dir D:\aidrawer\data\val2017 ^
  --channels 8 --n-res 3 --norm instance --size 640 --batch-size 4 ^
  --epochs 10 --content-weight 5 --style-weight 1e7 --tv-weight 1e-5 ^
  --save-every 1000 ^
  --out-dir D:\aidrawer\output
```

运行后会自动创建：

```
D:\aidrawer\output\20260916_190233\
├── model_step001000.pth   ← 仅权重，可直接给 stylize.py 用
├── ckpt_step001000.pth    ← 完整状态（含优化器），用于 --resume
├── model_step002000.pth
├── ckpt_step002000.pth
├── ...
├── sample_000500.jpg      ← 对比样图（左=原图，右=风格化）
├── history.json           ← 训练记录（中途持续写入）
├── loss_curve.png         ← 损失曲线
├── model_final.pth        ← 最终权重
└── ckpt_step012500.pth    ← 最终完整检查点
```

要加标签便于区分实验，用 `--tag`：

```bash
--out-dir D:\aidrawer\output --tag inst640
# → D:\aidrawer\output\20260916_190233_inst640\
```

### 3.2 续训

```bash
python train.py --resume D:\aidrawer\output\20260916_190233\ckpt_step010000.pth ^
  --style-image standard3.jpg --content-dir D:\aidrawer\data\val2017 ^
  --epochs 20
```

**续训行为说明**：

- 接续 **步数、优化器状态、随机数状态**，等价于"没停过"
- **未指定 `--out-dir` 时自动写回原目录**，历史记录与曲线继续累计
- `--epochs` 指的是**总目标轮数**（不是新增轮数）。例：原来 `--epochs 10` 跑到第 10000 步，想再训 10 轮就填 `--epochs 20`
- 若当前步数已达目标，脚本会提示"无需继续"并退出
- 数据顺序会重新洗牌（新起了一个 DataLoader），对微调无影响

### 3.3 晚上训练 batch 版

同一条命令换 `--norm batch` 即可，建议换 `--tag` 以免混淆：

```bash
python train.py --style-image standard3.jpg --content-dir D:\aidrawer\data\val2017 ^
  --channels 8 --n-res 3 --norm batch --size 640 --batch-size 4 ^
  --epochs 10 --content-weight 5 --style-weight 1e7 --tv-weight 1e-5 ^
  --save-every 1000 --out-dir D:\aidrawer\output --tag bn640
```

### 3.4 用中间模型看效果 / 跑摄像头

```bash
python stylize.py --model D:\aidrawer\output\20260916_190233\model_step005000.pth ^
  --norm instance --camera 0 --max-size 640
```

> `--norm` 必须与训练时一致，否则加载权重会报形状不匹配。

## 四、关键参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--save-every` | **1000** | 每多少步保存一次模型（同时产出 `model_step*` 与 `ckpt_step*`） |
| `--out-dir` | 无 | 父目录；自动建时间戳子文件夹。续训且不指定时写回原目录 |
| `--tag` | 空 | 子文件夹名后缀，便于区分实验 |
| `--resume` | 无 | 从 `ckpt_stepXXXXXX.pth` 续训 |
| `--plot-every` | 1000 | 每多少步刷新一次 `loss_curve.png`（0 = 只在结束时画） |
| `--log-every` | 50 | 打印间隔 |
| `--sample-every` | 500 | 对比样图间隔 |
| `--norm` | instance | `instance` / `batch` / `none` |
| `--workers` | **0** | 见下方说明 |

## 五、关于 `--workers` 默认值（重要，请留意）

**本目录默认 `--workers 0`（training 里是 4）。这是一个稳定性改动，不是算法改动。**

原因：Windows 下 DataLoader 的每个子进程都会**重新加载一份 torch**。在 `size 640 + batch 4` 下用 `workers=4` 时，你的机器出现过：

```
RuntimeError: Couldn't open shared file mapping, error code: <1455>   ← 系统提交内存耗尽
RuntimeError: Caught MemoryError in DataLoader worker process 1
```

**性能影响很小**：`size 640` 下实测 2.1 步/秒（每步约 470 ms），而加载 4 张图只需几十毫秒——GPU 是瓶颈，单进程完全够用。

如果你希望恢复 training 的行为，显式传 `--workers 4` 即可。

## 六、自检

```bash
python selfcheck.py
```

覆盖：语法解析 · `model.py`/`stylize.py` 与 training 逐字节一致 · **核心训练算法片段比对** · 新增 CLI 参数齐全 · 运行目录解析逻辑 · 检查点保存/读取往返 · 损失曲线绘制。**改动代码后建议先跑一次。**

## 七、建议的保存间隔

按实测 2.1 步/秒（size 640）估算：

| `--save-every` | 间隔时间 | 10 轮产出 | 评价 |
|---|---|---|---|
| 500 | 约 4 分钟 | 25 个 | 最细，最早看出趋势，文件偏多 |
| **1000** | **约 8 分钟** | **12 个** | **默认值，推荐** |
| 1250（=1 轮） | 约 10 分钟 | 10 个 | 每轮一个，整齐 |

单个 `model_step*.pth` 约 287 KB，`ckpt_step*.pth` 约 1.2 MB。10 轮合计约 15 MB，不占地方。

**判断建议**：目的是看"多训几轮有没有变好"，建议间隔**不要超过 1250 步**，否则曲线点太少看不出走势。训练中随时可以打开 `loss_curve.png` 和 `sample_*.jpg` 观察。
