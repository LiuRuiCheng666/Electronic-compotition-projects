# Texture trunk refinement: unchanged resolution and inference cost

Start from original accepted-color step3000 model, SHA256 62d944de4b8c62173a86687d2e253b3e0ee608455546597f62e81fd8d82ef421.
Do NOT start from the unsuccessful texture-head-only step1000 experiment.
Same frozen original IN teacher, no teacher modification or style-image target.

Unfreeze e8/e16 texture encoders, four context residual blocks, context_reduce,
texture_spatial/mix, and detail_reduce/spatial/output. Keep stem, condition-network
weights and local_color-head weights frozen; exact frozen parameter equality is
checked against the original at every checkpoint.
Because color heads consume shared features, freezing their weights does not
freeze color outputs. Low-frequency output anchor to frozen previous student
protects color; report actual drift rather than claiming exact preservation.
Its initial relative output-gradient target is .8, increased from .5.
Other loss targets retained: pixel .08, shallow feature1, localGram .6, highpass .4,
patch high-frequency amplitude .6, gradients .3, teacher palette .1.
5% coverage is REPORT ONLY. No forced brightness/saturation or minimum-area loss.
Texture energy can also reflect noise: inspect strokes, halos and periodic artifacts.

1000 additional optimizer steps, real1280x720, same1/4,1/8,1/16 feature levels,
microbatch1/accumulation4, LR3e-5, checkpoint/comparisons every250.
All inference operations, parameter count and theoretical cost are unchanged.
Extra baseline network is a training/evaluation reference, not a deployment path.
New optimizer; --resume continues only this independent refinement experiment.
No full formal training, quantization, RTL change or Efinity compile by preparation.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_StyleContextDetail_TextureTrunk_Refinement\train_texture_trunk.py"
```
Add --resume after interruption. Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261009_StyleContextDetail_TextureTrunk_Refinement\runs\texture_trunk_v1
Comparison columns: Input / IN teacher / Previous step3000 / Texture refinement.
