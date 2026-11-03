param([int]$Steps=3000,[switch]$Resume)
$ErrorActionPreference='Stop'
Set-Location -LiteralPath $PSScriptRoot
$trainArgs=@('train_round2.py','--norm','batch','--run','portrait_b16_bn','--steps',"$Steps",'--vga-start','8000')
if($Resume){$trainArgs+='--resume'}
& 'C:\Program Files\Python311\python.exe' @trainArgs
if($LASTEXITCODE -ne 0){throw "Training stopped with exit code $LASTEXITCODE"}
