# Core1 independent luminance texture experiment

Immutable accepted core1: D:\aidrawer\output\VanGogh_SelfPortrait\20261009_StyleContextDetail_CorePruning\runs\core1\model_final.pth, SHA256 85a36743568c0ca872f09b6e207b29a9e0a41ee8a9189592b6779eba21d1c5e3.
Original IN teacher: original_in_teacher/identity.json. Never use style image as target.
Freeze ALL core1 weights. Reuse its quarter-resolution 8-channel detail features,
then DW3x3(8)+LeakyReLU+PW1x1(8->16), PixelShuffle4 -> one full-resolution luminance
residual. Only224 parameters train;22,818 total. No higher-resolution feature branch.
Final head zero initialization reproduces core1 exactly in FP32. Same delta added
to RGB, with joint gamut limiting, preserving R-G and G-B; brightness can change.
Residual bounded to +/-0.08 at strength1. Phase mean removed within each4x4 block
before gamut limiting; this does NOT mean exact zero mean after gamut limiting.
This intentionally restricts residual to fine texture; broad strokes may remain
unrecovered, and phase patterns/checkerboards are a possible visual failure mode.

Train ONLY original IN teacher luminance highpass5/9, local high-frequency energy
and luminance gradients, weights1/.5/.25. No color learning, VGG, Gram, quota loss.
Teacher/student edges may differ: compare for ghosts and synthetic edges.
Every250 steps creates external26 four-column comparisons plus texture_metrics.json.
Original IN, frozen core1 and combined model are separately labeled. Numeric
highpass improvement does not establish artistic texture fidelity.
Default1000 optimizer steps,1280x720,accum4,LR1e-4. Source weights unchanged.

Analytical extra convolution11.52M MAC,172800 issue cycles (~1.728ms at100MHz).
Previous core1 budget + these convolutions ~13.066ms; extra phase arithmetic,
gamut bounds and memory/control are not included. New engine required; this is
not a30FPS guarantee. Exact DSP/XLR/memory usage requires RTL implementation.
No FPGA modifications or Efinity compilation in this experiment.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_Core1_LumaTexture\train_texture.py"
```
Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261009_Core1_LumaTexture\runs\luma_v1 . Resume by adding --resume.
For inference, load LumaTextureStudent state_dict; strength0 disables added texture,
strength0.5/1 controls its contribution (0..1 recommended). Existing FPGA engine
cannot consume this checkpoint directly; matching RTL/export is still required.
