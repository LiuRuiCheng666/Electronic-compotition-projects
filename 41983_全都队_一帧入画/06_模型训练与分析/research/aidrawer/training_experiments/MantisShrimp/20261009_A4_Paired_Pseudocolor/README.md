# 螳螂虾启发伪彩色：保持 A4 的配对训练

准备日期：2026-10-09。当前仅准备代码并检查，不启动正式训练。

## 目标与边界

按照用户左右对照图的右侧确定视觉方向：青色背景、蓝紫红色暗部、
原黄色条纹转青蓝、石头细节出现青绿红色差异。属于艺术伪彩色，
不是紫外/偏振重建或真实动物视觉。参考截图只用于比较，不参与训练。
当前规则是根据视觉目标设计的近似，不宣称恢复原视频公式。

rules.json 固定颜色、亮度节点、色度混合和有限局部增强；target.py 在线生成
原图对应的目标图。采用连续 smoothstep 色带及 RGB 对手色权重，不使用整帧
自适应直方图或硬阈值切色。局部增强半径为2像素；仍可能增强摄像头噪声，
真实视频稳定性需后续单独验收。

## 结构与训练

9个3×3卷积，一个4通道残差块，两次最近邻上采样，反射填充、BN、tanh；
完整沿用旧A4模块名与张量形状。实测核权重1512个，总可训练参数1623个。
旧实验 models.py 的 cost() 硬编码1584/1629与实际模型不符，本实验直接计数。
verify.py 已验证严格 state_dict 兼容，以及相同参数下前向逐值相等。

- 随机初始化，不加载浮世绘或梵高权重，不需要画作教师或VGG下载。
- 默认640×480，3000优化步，微批次1、累计4，Adam学习率2e-4；这是筛选实验。
- 前250步BN热身；随后用64张训练图逐层校准、冻结统计量，继续训练affine参数。
- 完成时再次用训练集校准BN；model_final.pth与最终评估使用同一份统计量。
- 损失：像素L1 1.0、多尺度L1 0.35、目标梯度L1 0.20、色度L1 0.15。
  都匹配规则目标，不要求保留原图颜色，也不添加画作Gram纹理。
- 随机裁剪/翻转/轻曝光和噪声扰动在生成目标之前执行，保持配对一致。
- 默认使用data/val2017中的5000张图片和student_eval_external中的26张外部图；
  训练开始前哈希排除外部图重复内容，外部图不参与训练和BN校准。
- 每250步保存模型、优化器、随机状态、BN冻结标记，以及26张三栏比较和指标。
- Ctrl+C丢弃未保存步骤；--resume从最近完整检查点继续，保存随机状态以恢复采样。
  配置、源码、规则、数据哈希变化时拒绝续训；改规则必须选择新的--output。
- MAE/PSNR只度量对规则教师的拟合，曝光扰动指标也不等于视频验收。

代码：D:\aidrawer\training_experiments\MantisShrimp\20261009_A4_Paired_Pseudocolor

输出：D:\aidrawer\output\MantisShrimp\20261009_A4_Paired_Pseudocolor

## 启动

首次正式训练（尚未执行）：

```powershell
& 'D:\aidrawer\training_experiments\MantisShrimp\20261009_A4_Paired_Pseudocolor\start_training.ps1'
```

断点恢复：

```powershell
& 'D:\aidrawer\training_experiments\MantisShrimp\20261009_A4_Paired_Pseudocolor\start_training.ps1' -Resume
```

只有检查，不创建训练目录、不更新权重：

```powershell
& 'D:\Anaconda_envs\envs\fns\python.exe' 'D:\aidrawer\training_experiments\MantisShrimp\20261009_A4_Paired_Pseudocolor\train_a4.py' --check-only
```

规则预览：target_preview_v2/contact_sheet.jpg和reference_comparison.jpg。
这些是规则变换结果，不是A4训练结果。第一次预览v1留存，v2修正了蓝青色
被错误分入绿色权重的问题，当前rules/target代码对应v2。

模型满意后才另做BN折叠、INT8校准、RTL数值验证、部署与真实视频检查。
本实验不导出板端ROM，不运行Efinity，不修改现有模型或硬件。
