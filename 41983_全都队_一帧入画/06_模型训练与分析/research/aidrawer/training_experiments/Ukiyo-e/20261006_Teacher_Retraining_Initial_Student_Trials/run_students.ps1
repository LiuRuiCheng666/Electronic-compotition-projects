Set-Location -LiteralPath $PSScriptRoot

$python = 'C:\Program Files\Python311\python.exe'
$teacher = 'D:\\aidrawer\\output\\Ukiyo-e\\20261006_Teacher_Retraining_Initial_Student_Trials\\runs\\ukiyo_teacher_pilot\\model_final.pth'

echo "Running A_IN..."
& $python experiment.py --stage a_in --run ukiyo_a_in_pilot --steps 3000 --teacher $teacher

echo "Running A_BN..."
& $python experiment.py --stage a_bn --run ukiyo_a_bn_pilot --steps 3000 --teacher $teacher

echo "Running B_BN..."
& $python experiment.py --stage b_bn --run ukiyo_b_bn_pilot --steps 3000 --teacher $teacher

echo "All done."
