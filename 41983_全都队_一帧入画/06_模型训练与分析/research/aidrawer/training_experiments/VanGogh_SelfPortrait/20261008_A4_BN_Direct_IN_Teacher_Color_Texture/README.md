# A4 direct IN teacher color and texture distillation

Teacher: D:\aidrawer\output\VanGogh_SelfPortrait\Legacy_Teacher_IN_runs3_ins\ckpt_step012500.pth, checkpoint step 12500. Original remains unchanged.
Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261008_A4_BN_Direct_IN_Teacher_Color_Texture
Architecture: legacy A4, 1584 convolution weights, 1629 total parameters.
640x480, 3000 optimizer steps, microbatch 1, accumulation 4. BN warmup 250 steps;
then sequential population calibration on 64 training images and fixed BN statistics.
Teacher RGB, perceptual features, shallow Gram, palette distribution, luminance/chroma
and multiscale RGB gradients. No style image supervision and no recoloring of targets.
26 external evaluation images excluded from training; comparison panels every 250 steps.
Color coverage and quality are optimization targets, not guaranteed outcomes.
No quantization, FPGA edits, training execution, or board FPS claim.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261008_A4_BN_Direct_IN_Teacher_Color_Texture\train_a4.py"
```
Resume: add --resume. Extend: add --resume --steps 4000.
Use model_final.pth/eval_stepXXXXXX/inference_model.pth for fixed-stat inference.
Warmup previews use running BN statistics and are not final quality evidence.
