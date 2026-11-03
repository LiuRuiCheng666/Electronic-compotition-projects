# C6 Res3 BN: approximately half the teacher parameters

Original selected VanGogh IN teacher checkpoint step12500, C8 Res3, frozen FP32.
Random C6 Res3 BN student; channel widths 6/12/24, all three residual blocks and
14 convolutions retained. Half refers to parameter count, not half the channels.
Training does not change P_CI/P_CO or any FPGA code. Hardware PCI2/PCO4 values
are only used for cost reporting; this architecture needs later RTL adaptation.
640x480 from start, 3000 optimizer steps, microbatch1/accumulation4, LR .0002.
BN warmup250, sequential population calibration, then fixed statistics with
trainable affine parameters. Actual inference uses the same fixed statistics.
Original teacher supervision, no vivid target/brightness/saturation boost.
Retain agreed teacher palette of up to8 representatives with >=5% area targets,
color-distance rejection and per-image coverage reports; not a hard guarantee.
External26 images only evaluate; training duplicates excluded by hashes.
Every250 steps: original/teacher/student panels and per-color coverage PASS/FAIL.
No training, quantization, Efinity compilation or board programming performed.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_C6_Res3_BN_HalfParameters_IN_Distillation\train_c6_bn.py"
```
Resume after interruption: add --resume.
Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261009_C6_Res3_BN_HalfParameters_IN_Distillation\runs\c6_bn
