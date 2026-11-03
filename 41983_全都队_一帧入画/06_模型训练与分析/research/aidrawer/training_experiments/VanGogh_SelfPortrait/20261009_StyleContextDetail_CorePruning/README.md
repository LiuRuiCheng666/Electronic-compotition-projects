# Color-preserving context pruning

Reference: accepted phase_fold step 1000, SHA256 25ee5898c9676fbfcde5bb6d463bc0ec6d7f1ca6c8604df822ad0c61cdebf2fd.
All candidates start independently from this immutable accepted reference, not from
one another's unreviewed results. Original IN remains a separate evaluation column.
Retain 3, 2 or 1 original context blocks; preserve their dilations and slice matching
FiLM controls. Keep all input/encoder/color/detail reconstruction resolutions and
branches. No added texture loss, forced palette quota or automatic training.

| Candidate | Retained original blocks | Parameters | Ideal compute ms at100MHz | Illustrative frame ms |
| --- | --- | --- | --- | --- |
| core3 | [0, 2, 3] | 42194 | 13.545 | 24.839 |
| core2 | [0, 2] | 32394 | 12.442 | 23.141 |
| core1 | [0] | 22594 | 11.338 | 21.443 |

Timing assumes a NEW efficient DW8/PW8x8 shared engine, plus modeled auxiliary
multiplications. Frame scenario uses unverified 65% utilization +4ms other costs.
These values do NOT measure current RTL and do NOT prove 720p30. Some interpolation,
memory, reduction, nonlinear/clamp scheduling costs require cycle-accurate validation.
Target real per-frame completion <=33.333ms; camera/HDMI refresh does not count.
Fewer layers reduce cycles and weight memory, not automatically DSP lane count.
Current v6_4 cannot run these models just by replacing weights. No FPGA files changed.

Probe ranks all 14 block subsets on eight training images by low-frequency color
drift. External 26 images are reserved for evaluations during training. Initial
numeric ranking does not establish visual acceptance, especially for core1.
Each recovery run:1000 optimizer steps,1280x720,accum4,LR5e-5,eval every250.
Select the smallest visually acceptable checkpoint, using intermediate250/500/750
comparisons too; do not blindly prefer the final step. No verified model overwritten.

```powershell
conda activate fns
& "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_StyleContextDetail_CorePruning\train_all.ps1"
```
Or run just one candidate:
```powershell
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_StyleContextDetail_CorePruning\train_compact.py" --candidate core2
```
Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261009_StyleContextDetail_CorePruning\runs . Resume a single run by adding --resume.
The sequence stops on an existing run or failure; do not rerun the whole sequence
to resume. Run the interrupted candidate with --resume, then the remaining ones.
