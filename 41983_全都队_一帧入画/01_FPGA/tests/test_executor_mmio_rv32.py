"""Execute actual linked RV32 image_execute and trace MMIO argument writes, including stale payload words."""
from pathlib import Path
import json,struct,sys,hashlib
P=Path(__file__).resolve().parents[1];sys.path.insert(0,str(P/'tools/_vendor'))
from unicorn import Uc,UC_ARCH_RISCV,UC_MODE_RISCV32,UC_HOOK_MEM_WRITE
from unicorn.riscv_const import *
S=json.loads((P/'integration_tests/c_system_software/symbols.json').read_text());fw=P/'embedded_sw/soc/software/standalone/uart/nnObserverDemo/build/nnObserverDemo.bin';blob=fw.read_bytes();records=[]
for cycle in range(20):
 for op in range(12):
  u=Uc(UC_ARCH_RISCV,UC_MODE_RISCV32);u.mem_map(0xf9000000,65536);u.mem_map(0xf8102000,4096);u.mem_write(0xf9000000,blob);u.reg_write(UC_RISCV_REG_PRIV,3)
  u.reg_write(UC_RISCV_REG_SP,S['_sp']);u.reg_write(UC_RISCV_REG_RA,0xf900fff0);u.reg_write(UC_RISCV_REG_A0,0);u.reg_write(UC_RISCV_REG_A1,0xf9009000)
  q=[op,0x80000000+cycle,cycle*16,65535,0x11223344^cycle,0x778899aa,0xaabbccdd,0xeeff0011]
  u.mem_write(0xf9009000,struct.pack('<8I',*q));u.mem_write(0xf8102040,struct.pack('<8I',*[0xdeadbeef]*8));u.mem_write(0xf8102004,struct.pack('<I',32));writes=[];sent=[]
  response=[0,q[1],6,0,0xfefdfcfb,0x11223344,0x99887766,0x55443322]
  def hook(uc,access,address,size,value,user):
   if 0xf8102040<=address<0xf8102060:writes.append((address,value))
   if address==0xf8102008 and value==1:
    v=list(struct.unpack('<8I',uc.mem_read(0xf8102040,32)));sent.append(v)
    assert v[:4]==q[:4]
    if op==9:assert v[4:]==q[4:]
    else:assert v[4:]==[0xdeadbeef]*4
    uc.mem_write(0xf8102040,struct.pack('<8I',*response));uc.mem_write(0xf8102004,struct.pack('<I',34))
  u.hook_add(UC_HOOK_MEM_WRITE,hook,begin=0xf8102000,end=0xf8102fff)
  u.emu_start(S['image_execute'],0xf900fff0,count=50000)
  assert u.reg_read(UC_RISCV_REG_PC)==0xf900fff0 and u.reg_read(UC_RISCV_REG_A0)==0
  assert len(writes)==(8 if op==9 else 4) and len(sent)==1
  assert list(struct.unpack('<8I',u.mem_read(0xf9009000,32)))==response
  records.append(dict(op=op,argument_word_writes=len(writes)))
report=dict(status='PASS',actual_rv32_linked_function=True,cases=len(records),firmware_sha256=hashlib.sha256(blob).hexdigest(),write_line_words=8,other_rpc_words=4,result_words_read_back=8,stale_payload_ignored_on_non_write=True,scope='CPU executor with MMIO fixture; actual board and model validation separate')
(P/'NETFAST_EXECUTOR_VALIDATION.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
