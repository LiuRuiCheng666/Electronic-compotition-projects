"""Build the merged C system and foreground lighting service.
Install the 32 KiB ROM lanes only with explicit --install. Uses RV32IM/ILP32;
preserves the baseline NN PLIC ISR and control protocol.
"""
from pathlib import Path
import os,subprocess,shutil,argparse,hashlib,json
P=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--install',action='store_true');a=parser.parse_args()
prefix=os.environ.get('RISCV_PREFIX','D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-')
S=P/'embedded_sw/soc/software/standalone';B=P/'embedded_sw/soc/bsp/efinix/EfxSapphireSoc'
A=S/'uart/nnObserverDemo';O=A/'build';O.mkdir(exist_ok=True)
flags=['-Os','-msave-restore','-flto','-g','-specs=nano.specs','-march=rv32im_zicsr_zifencei','-mabi=ilp32','-DUSE_GP','-DDUAL_INPUT_PROFILE','-fcommon','-ffunction-sections','-fdata-sections',
 '-DSYSTEM_UART_A_APB=SYSTEM_UART_0_IO_APB','-DSYSTEM_GPIO_A_APB=SYSTEM_GPIO_0_IO_APB','-DSYSTEM_I2C_A_APB=SYSTEM_I2C_0_IO_APB',
 '-DA_NET_DIRECT_RX_BASE=0xf8101800u','-DA_NET_HW_CRC','-DA_NET_DIRECT_TX_FIFO=0xf8101054u']
flags += ['-I'+str(x) for x in [B/'include',B/'app',S/'include',S/'driver',A/'src']]
sources=[*sorted((A/'src').glob('*.c')),S/'common/start.S',S/'common/trap.S',S/'common/syscalls.c']
objects=[]
def run(args):
 r=subprocess.run([str(x) for x in args],cwd=O,capture_output=True,text=True,errors='replace')
 if r.stdout:print(r.stdout)
 if r.stderr:print(r.stderr)
 if r.returncode:raise SystemExit(r.returncode)
for src in sources:
 extra=['-Oz','-fno-inline-small-functions']if src.name in ['a_net_service.c','a_image_session.c','c_net.c','c_image_backend.c']else[]
 obj=O/(src.stem+'.o');run([prefix+'gcc.exe','-c',*flags,*extra,'-o',obj,src]);objects.append(obj)
elf=O/'nnObserverDemo.elf'
run([prefix+'gcc.exe',*flags,'-o',elf,*objects,'-nostartfiles','-ffreestanding','-specs=nosys.specs',
 '-Wl,-T,'+str(B/'linker/default.ld')+',-Map,'+str(O/'nnObserverDemo.map')+',--print-memory-usage,--no-warn-rwx-segment,--gc-sections',
 '-Wl,-u,trap,-u,trap_entry','-Wl,--start-group','-lc','-lgcc','-lm','-Wl,--end-group'])
for form,suffix in [('binary','bin'),('ihex','hex')]:run([prefix+'objcopy.exe','-O',form,elf,O/('nnObserverDemo.'+suffix)])
nm=subprocess.check_output([prefix+'nm.exe','-n',str(elf)],text=True)
symbols={v[2]:int(v[0],16) for line in nm.splitlines() if len(v:=line.split())==3}
symbol_dir=P/'integration_tests/c_system_software';symbol_dir.mkdir(exist_ok=True)
(symbol_dir/'symbols.json').write_text(json.dumps(symbols,indent=2))
data=(O/'nnObserverDemo.bin').read_bytes()
if len(data)>30720:raise SystemExit('ROM leaves less than 2KiB stack space')
if a.install:
 backup=P/'merge_baseline/firmware';backup.mkdir(parents=True,exist_ok=True)
 targets=[P/'firmware/nnObserverDemo.hex']+[P/f'ip/soc/EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin' for i in range(4)]
 for path in targets:
  dest=backup/path.name
  if not dest.exists():shutil.copy2(path,dest)
 shutil.copy2(O/'nnObserverDemo.hex',P/'firmware/nnObserverDemo.hex')
 padded=data+bytes(32768-len(data))
 for i in range(4):
  (P/f'ip/soc/EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin').write_text(''.join(f'{b:08b}\n' for b in padded[i::4]),encoding='ascii')
 (P/'MERGED_LIGHT_FIRMWARE.json').write_text(json.dumps({'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'isa':'RV32IM','installed':True,'nn_protocol_preserved':True,'lto':True},indent=2))
print('firmware bytes:',len(data),'installed:',a.install)
