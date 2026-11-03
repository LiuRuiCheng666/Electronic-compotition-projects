param([switch]$Resume,[switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$trainingPython = 'D:\Anaconda_envs\envs\fns\python.exe'
$trainingArgs = @((Join-Path $PSScriptRoot 'train_a4.py'))
if ($Resume) { $trainingArgs += '--resume' }
if ($CheckOnly) { $trainingArgs += '--check-only' }
& $trainingPython @trainingArgs
if ($LASTEXITCODE -ne 0) { throw "Training exited with code $LASTEXITCODE" }
