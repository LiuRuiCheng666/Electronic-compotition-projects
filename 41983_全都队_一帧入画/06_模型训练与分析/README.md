# 最终五风格：参数源码、训练与部署

本目录按本次提交工程的实际槽位组织，和FPGA、固件、网页及完整Flash一致：

|槽位|风格|参数来源及复现入口|
|---|---|---|
|0|复古建筑版画（诺贝尔）|参数构造代码、已归档色板统计，重新生成4096字节|
|1|工程线稿|本地`midnight_blueprint`训练检查点，导出4096字节|
|2|浮雕|本地`glass`教师蒸馏训练检查点，导出4096字节|
|3|首版细像素（马赛克）|均值卷积及模型LUT参数构造，重新生成4096字节|
|4|故障艺术|卷积及分通道LUT参数构造，重新生成4096字节|

五槽的逐字节匹配以`../01_FPGA/flash_assets/a4_dual_models_flash.bin`为准。NN5补充包使用另一种槽位排序，本提交已按上述顺序衔接；不能将补充包的原始权重直接覆盖当前Flash。

## 从源码和检查点恢复最终权重

安装本目录`requirements.txt`依赖后，在项目根目录运行：

```powershell
python 06_模型训练与分析/tools/rebuild_weights.py --regenerate --export-trained --output E:/nn5_rebuilt
```

该命令从参数源码重生成槽0、3、4，并从最终训练检查点导出槽1、2。每槽先与当前工程核对，再按本项目顺序合成20512字节NNW1文件。它不启动训练、不生成新的FPGA配置，也不访问开发板。输出只包含模型，完整启动烧录仍使用`04_烧录文件/OSD_SIMPLE_SELECTED5_FULL_FLASH.hex`。

仅复制并合并已归档槽位可去掉两个可选开关，届时只需要Python标准库。`SOURCE_INDEX.json`记录收录文件的来源、长度与SHA-256。

## 本地训练工程

`training/train_students.py`包含A4学生网络、BN折叠、QAT及硬件格式导出；`train_batch10_styles.py`和`batch10_styles.py`保留工程线稿的配对目标训练；`train_portable_candidates.py`、`art_models.py`及`teacher/`保留浮雕对应的教师蒸馏链路。`runs/blueprint`与`runs/emboss`包含最终检查点、导出槽位、系数和训练记录。这两套检查点重新导出的槽位均与最终提交权重相同。

完整训练照片数据集不随代码提交；训练脚本、检查点与部署参数已收录。重新训练时自行准备包含`train/`与`val/`的JPEG数据根目录；原配方使用200张训练图、12张验证图，线稿另保留8张独立样本。具体数据文件的原始路径与哈希保留在浮雕训练记录及源工程记录中。训练依赖可用CUDA的PyTorch，运行环境安装包不随项目复制。

先生成独立工作副本，避免覆盖提交结果：

```powershell
python 06_模型训练与分析/tools/prepare_training.py --data E:/datasets/selected --output E:/nn5_training
cd E:/nn5_training
python train_local.py --style blueprint --warm 1200 --qat 24000
python train_local.py --style emboss --warm 800 --qat 1600
```

准备工具只复制代码并迁移路径，数据仍从外部目录读取。它不自动开始训练。随机训练与GPU库版本可能影响新训练结果；精确恢复既有最终字节应使用已归档检查点和上面的权重重建入口。

## 结构、统计及对比分析

网络结构和参数量见`network.svg`、`network_layers.csv`和`网络与参数统计.md`。`tools/evaluate.py`可用最终槽位执行软件参考推理，输出逐图PSNR、SSIM及CPU参考耗时；标准网络结果通过`--baseline-dir`提供，评估图像尺寸必须相同。报告明确区分软件参考时间和FPGA硬件延迟，结果不混用。

```powershell
python 06_模型训练与分析/tools/evaluate.py --input-dir E:/evaluation/input --baseline-dir E:/evaluation/standard_model --baseline-name standard_model --slot 1 --width 320 --height 240 --output E:/evaluation/result
```

FPGA帧率和刷新率由屏幕PROC FPS、DISP FPS分别计量；硬件资源与时序文件在`05_技术资料/`。本次补充不改动最终NN RTL或烧录镜像。

## 历史研究源代码

`research/aidrawer/`收录NN5补充包中的训练、教师蒸馏、结构化剪枝和量化导出源代码，并精选最终检查点，保留研究来源；重复中间检查点、优化器快照及完整数据集未重复收录。这些历史实验与上表中最终五槽的实际参数来源分开标识，不能将历史Nobel实验检查点误认为最终槽0的直接导出来源。原始研究脚本保持来源字节，可能含原机器路径，当前交付的便携入口在本目录`tools/`。
