# 修复全黑塌缩：仅修改脚本，未运行训练

已从上一轮日志确认：外部验证目标平均黑色覆盖64.2%，500步起预测全黑。此前黑线像素7倍加权和额外黑线损失叠加，偏向黑色常量解；训练用BF16也可能让饱和tanh端点梯度更难恢复，但此项未独立验证。

修正：提高弱边缘噪声门限，缩短连通传播，弱线局部覆盖超过42%时只保留原强轮廓；保留5×5线宽。损失按黑/非黑区域各自面积归一化且等权，不再额外叠加黑线损失。改用FP32。评估若半数以上图片几乎全黑而目标并非全黑，立即停止，不生成完成记录供导出。

金色阴影计算和规则原样保留，A4结构未改，仍跳过额外BN校准。仅完成AST语法及静态一致性检查，没有启动训练或运行前向/反向。修正后效果与收敛需新训练确认。

```powershell
& "D:/Anaconda_envs/envs/fns/python.exe" "D:/aidrawer/training_experiments/Nobel/20261017_A4_AdaptiveInk_Balanced/train_a4.py" --steps 3000
```

从此新目录重新训练，不续接已塌缩模型。输出D:/aidrawer/output/Nobel/20261017_A4_AdaptiveInk_Balanced/runs/a4/model_final.pth。旧权重、现有PS1和板端均未修改。
