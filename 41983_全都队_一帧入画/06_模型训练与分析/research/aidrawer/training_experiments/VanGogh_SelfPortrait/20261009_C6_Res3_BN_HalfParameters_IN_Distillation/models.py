import sys,math
from pathlib import Path
import torch
from torch import nn
sys.path.insert(0,'D:/aidrawer/training_plus')
from model import FastNeuralStyleNet
ROOT=Path('D:\\aidrawer\\output\\VanGogh_SelfPortrait\\20261009_C6_Res3_BN_HalfParameters_IN_Distillation')
class Student(FastNeuralStyleNet):
    def __init__(self,variant='c6_bn'):
        if variant!='c6_bn':raise ValueError(variant)
        super().__init__(channels=6,n_res=3,norm='batch')
def cost(variant,width,height):
    specs=[(3,6,1),(6,6,1),(6,12,2),(12,24,4)]+[(24,24,4)]*6+[(24,12,2),(12,6,1),(6,6,1),(6,3,1)]
    net=Student(variant)
    cycles=sum(width*height//d**2*math.ceil(ci/2)*math.ceil(co/4) for ci,co,d in specs)
    return {'parameters':net.all_param_count(),'conv_weights':net.conv_param_count(),'teacher_parameters':69267,
            'parameter_fraction':net.all_param_count()/69267,'channels':[6,12,24],'residual_blocks':3,'conv_layers':14,
            'mac_cycles_pci2_pco4':cycles,'mac_ms_100MHz':cycles/1e5,'limitations':'MAC only; no board latency or FPS claim; no RTL adaptation performed'}
