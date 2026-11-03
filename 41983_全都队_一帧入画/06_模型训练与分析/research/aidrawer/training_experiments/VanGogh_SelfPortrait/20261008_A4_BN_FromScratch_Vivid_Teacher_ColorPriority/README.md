# Fresh A4: vivid teacher colors first

Random A4 initialization, no previous student weights. Same original selected IN
checkpoint step12500; original teacher model is frozen, FP32 and unchanged.
Color target deliberately raises HSV value to at least .80 and saturation to at
least .60 in teacher regions with RGB chroma > .06, preserving hue. Original
teacher still supplies content/texture supervision. Neutral regions are unchanged.
Student color floor penalties: value .80 and RGB chroma .48 on those regions.
This is an explicit brightened color target, not exact original-teacher imitation.
No hard palette restriction or inference postprocessing. Soft penalties do not
guarantee thresholds; evaluation reports the fraction of pixels violating them.
Initial relative RGB-output gradient targets: pixel .03, feature .5, Gram .3,
content .05, palette 2, luminance/chroma 2, texture .02, coverage 4, regional 3,
vivid floor 3. Calibration uses 8 training batches, repeated after BN freeze.
These ratios are initialization measurements, not a persistent guarantee.
Same A4: 1584 convolution weights, 1629 parameters; no RTL/FPS changes.
640x480, 3000 steps, accumulation4, BN warmup250 then fixed statistics.
Every250: input/original teacher/vivid target/fresh A4 comparison and color metrics.
No external evaluation images used in training or loss calibration.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261008_A4_BN_FromScratch_Vivid_Teacher_ColorPriority\train_a4_vivid.py"
```
Add --resume after interruption. Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261008_A4_BN_FromScratch_Vivid_Teacher_ColorPriority\runs\a4
