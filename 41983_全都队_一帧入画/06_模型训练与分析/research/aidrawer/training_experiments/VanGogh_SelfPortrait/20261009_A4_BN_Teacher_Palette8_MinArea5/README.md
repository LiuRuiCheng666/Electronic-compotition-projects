# Teacher palette coverage: A4, 8 colors, minimum area 5%

Teacher: selected original IN checkpoint step12500, immutable frozen copy.
Fresh A4 initialization, no old student weights or forced brightness/saturation.
Same A4 architecture, BN warmup250 then fixed statistics; 640x480, 3000 optimizer
steps, accumulation4. Existing models/RTL remain unchanged.

Teacher RGB palette: deterministic farthest-first + 12-iteration k-means on up to
4096 sampled teacher pixels. Maximum 8 representatives. Merge colors closer than
.08 Euclidean normalized RGB; use fewer for genuinely indistinct/neutral colors.
Training: nearest-color restoring gradients for missing 5% areas, soft nearest
assignments gated by color distance, under-5% penalty, teacher proportions adjusted
by water filling with a 5% floor, regional palette + perceptual/Gram preservation.
Rare colors may intentionally occupy more area than in the teacher.
No quota is enforced by recoloring inference outputs; soft losses cannot guarantee
5% on every image. Evaluation uses ALL pixels, closest representative plus RGB
Euclidean distance <= .15. Far-away colors are excluded and reported as uncovered.
RGB distance is an engineering tolerance, not perceptual Delta-E.

Every250 steps: Input/IN teacher/student, representative swatches with qualified
area percentages and PASS/FAIL. metrics.json records RGB, teacher/target/student
areas and distances. coverage_summary.json reports all-color pass image count.
External images never used for training/calibration. No training launched here.

```powershell
conda activate fns
python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_A4_BN_Teacher_Palette8_MinArea5\train_a4_palette.py"
```
Resume: add --resume. Results: D:\aidrawer\output\VanGogh_SelfPortrait\20261009_A4_BN_Teacher_Palette8_MinArea5\runs\a4
