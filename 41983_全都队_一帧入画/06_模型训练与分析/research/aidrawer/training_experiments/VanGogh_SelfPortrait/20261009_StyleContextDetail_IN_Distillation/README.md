# Style Context Detail: original IN teacher distillation

Teacher: D:\aidrawer\output\VanGogh_SelfPortrait\Legacy_Teacher_IN_runs3_ins\ckpt_step012500.pth, step12500, original frozen IN C8/Res3, FP32.
Student: independent new StyleContextDetail_v1; 52399 parameters; no BN; one
low-resolution per-image statistics site; no old student initialization.
640x480 and 1280x720 supported. Default training starts at real1280x720.
3000 optimizer steps, microbatch1, accumulation4, BF16 student/VGG, FP32 teacher.
Small residual RGB head initialization for stability, unchanged architecture.
Original teacher RGB/features/shallow Gram/local palette/gradient supervision only.
No raw-input content supervision, no style-image target, no forced brightening,
no saturation enhancement, no minimum-area quota or 5% term in training losses.
Relative initial output-gradient targets pixel .5, feature1, Gram .2, global
palette .3, regional palette .3, multiscale teacher gradient .1.
Initial output gradients calibrated on4 training crops, not persistent guarantees.

Every250 steps: 26 external images, full1280x720 PNGs and uniform comparison
panels. metrics.json reports teacher error and distance-qualified palette areas;
5% PASS/FAIL is REPORT ONLY and is not the visual quality acceptance criterion.
Original/checkpoint weights preserved. Training and evaluation duplicates excluded
by hashes. New runs fail rather than overwrite; checkpoints include optimizer/RNG.
Resume continues from a complete periodic checkpoint, not bitwise replay of the
previous DataLoader order. Ctrl+C discards a partial optimization step.
Formal training must be started by the user. No quantization/RTL/Efinity action.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_StyleContextDetail_IN_Distillation\train_student.py"
```
Resume: same command + --resume. Extend the total optimizer steps, for example:
```powershell
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_StyleContextDetail_IN_Distillation\train_student.py" --resume --steps 4000
```
Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261009_StyleContextDetail_IN_Distillation\runs\scd_v1
No board30FPS or teacher-quality equivalence proven by this experiment.
