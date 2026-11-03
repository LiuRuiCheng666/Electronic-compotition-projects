# A4 color coverage and regional repair

Initialize from the previous A4 step 3000 model, SHA256 041c12700d1086fb4f7cbfad744f158f53fc176211468fa7890cdaeae3f22b25.
Same selected IN teacher, unchanged architecture, preserved fixed BN statistics.
Train 1000 additional optimizer steps at 640x480, LR 5e-5, accumulation 4.
Rare-weighted teacher-to-student nearest colors plus differentiable RGB histogram
area matching; 3x4 regional palette distributions; retained perceptual and shallow
Gram texture targets. RGB gradient relative weight reduced from .3 to .05.
Relative output gradients are calibrated at initialization; this does not guarantee
their balance throughout training or recovery of every teacher color.
Only training data drives losses/calibration; 26 external images for evaluation.
Each 250 steps: Input / IN teacher / Previous A4 / Color repair A4 panels and color metrics.
Repair step numbers 250..1000 are additional steps, not original cumulative steps.
New optimizer; --resume restores only this repair experiment.
No formal training or FPGA/quantization action performed by preparation.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261008_A4_BN_Color_Coverage_Regional_Repair\train_a4_repair.py"
```
Add --resume to continue after interruption.
Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261008_A4_BN_Color_Coverage_Regional_Repair\runs\a4
