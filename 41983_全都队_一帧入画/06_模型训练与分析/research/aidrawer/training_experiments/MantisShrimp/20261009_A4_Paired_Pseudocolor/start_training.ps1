param([switch]$Resume)
$ErrorActionPreference = 'Stop'
$trainingPython = 'D:\Anaconda_envs\envs\fns\python.exe'
if (-not (Test-Path -LiteralPath $trainingPython)) { throw 'fns Python environment not found' }
$trainingArgs = @((Join-Path $PSScriptRoot 'train_a4.py'))
if ($Resume) { $trainingArgs += '--resume' }
& $trainingPython @trainingArgs
if ($LASTEXITCODE -ne 0) { throw "Training exited with code $LASTEXITCODE" }
