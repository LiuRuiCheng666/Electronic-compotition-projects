# Color-focused SCD structural compression

Two initialized candidates, no formal training executed:
phase_fold: keep4 context blocks; replace quarter-resolution48 phase outputs with
3 RGB outputs via exact16-phase weight/bias averaging and nearest4x expansion.
core3: additionally remove original context block1 and its80 FiLM output controls.
Both keep true full-resolution RGB color reconstruction and original resolution
levels; reduced learned texture is intentional. Nearest4x residual may show block
boundaries. All-color visual acceptance and quantization are still pending.

Reference is the latest larger SCD texture-trunk-refinement result, SHA256
256862107b46c0135a7b9e99d244bbe63e92e070b2d2eb224b2ba1c65532d99a. This is compression recovery to preserve its color,
NOT a new claim to distill directly from the original IN teacher. Original IN
remains immutable and is shown separately in all comparisons and palette reports.
Training matches reference RGB, low-frequency RGB, shallow features and global/
regional color distribution. No texture/highpass/Gram objectives or5% quota.
Default1000 recovery steps, true1280x720, accumulation4, LR5e-5, every250 evaluation.

Analytical savings assume the NEW reusable72-lane DW/64-lane PW engine, not old RTL:
phase_fold approximately16.4% fewer issue cycles; core3 approximately22.7% fewer.
Fewer cycles does not mean proportional fewer DSPs. Packing/DDR/reconstruction
resources and actual FPS require RTL work and synthesis after model acceptance.
Direct deletion of the whole detail branch was rejected because it changes colors.
8 deterministic TRAIN images selected structure; external26 are evaluation only.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_StyleContextDetail_ColorCompression\train_compact.py" --candidate phase_fold
```
Optional more aggressive experiment, after inspecting phase_fold:
```powershell
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_StyleContextDetail_ColorCompression\train_compact.py" --candidate core3
```
Resume the chosen candidate: add --resume. Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261009_StyleContextDetail_ColorCompression\runs
Pretraining comparison panels will be placed in initial_comparisons.
Source weights and FPGA files are unchanged; no Efinity compilation.
