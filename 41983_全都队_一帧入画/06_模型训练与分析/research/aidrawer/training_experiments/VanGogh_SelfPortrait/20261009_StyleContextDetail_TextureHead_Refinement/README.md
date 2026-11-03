# Texture head refinement, unchanged StyleContextDetail network

Initialize from previous accepted-color student step3000, SHA256 62d944de4b8c62173a86687d2e253b3e0ee608455546597f62e81fd8d82ef421.
Only detail_reduce, detail_spatial and detail_output train (712 parameters).
Freeze stem, encoders, condition network, context blocks, texture trunk and local
color head. Their weights are checked unchanged at each checkpoint. The full
output can still change color through the detail head, so a low-frequency anchor
to frozen previous student output protects color; no absolute preservation promise.
Teacher texture targets: RGB, shallow features, six-region shallow Gram, multiscale
highpass residuals, patch high-frequency energy, multiscale RGB gradients.
Reduce pixel gradient target from .5 to .08. New initial output-gradient ratios:
pixel .08, feature1, localGram .6, highpass .4, energy .6, gradient .3, color .5,
palette .1. Color L1 calibration uses analytic unit-sign gradient at zero drift.
No TV, no strong brightness/saturation target, no 5% coverage term in losses.
5% palette report retained. Edge/highpass energy may also rise with artifacts,
so metrics do not replace checking fine strokes, halos, noise and4-pixel patterns.
1000 ADDITIONAL steps, real1280x720, accumulation4, LR5e-5, checkpoints every250.
Four columns: input / IN teacher / previous step3000 / texture refinement.
New optimizer; --resume restores this texture experiment, not the original run.
Inference structure and operation budget unchanged; baseline network is training
and evaluation reference only and is not deployed. No quantization or RTL action.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_StyleContextDetail_TextureHead_Refinement\train_texture.py"
```
Add --resume after interruption. Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261009_StyleContextDetail_TextureHead_Refinement\runs\texture_v1
