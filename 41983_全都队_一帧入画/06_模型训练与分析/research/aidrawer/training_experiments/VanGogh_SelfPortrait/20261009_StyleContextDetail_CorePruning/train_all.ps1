$ErrorActionPreference = 'Stop'
foreach ($candidate in @('core3', 'core2', 'core1')) {
    python "D:\aidrawer\training_experiments\VanGogh_SelfPortrait\20261009_StyleContextDetail_CorePruning\train_compact.py" --candidate $candidate --steps 1000
    if ($LASTEXITCODE -ne 0) { throw "Training failed for $candidate; sequence stopped." }
}
