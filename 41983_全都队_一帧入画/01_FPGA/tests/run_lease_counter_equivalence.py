"""Cycle-by-cycle old/new lease output comparison under existing corner cases."""
from pathlib import Path
import hashlib,json,re,subprocess
P=Path(__file__).resolve().parents[1];D=P/'tests/lease_counter_equivalence';D.mkdir(exist_ok=True)
reference=P/'integration_tests/recovery_fix_20261101/before_shared_timer/net_image_lease.v'
old=reference.read_text();assert 'prepare_count' in old and 'inactive_count'in old
(D/'old_lease.v').write_text(old.replace('module net_image_lease','module old_lease',1))
s=(P/'tests/tb_net_image_lease.sv').read_text()
instance=re.search(r' net_image_lease #\(.*?\) dut\(.*?\);',s,re.S)[0]
widths=dict(command_ack=1,command_status=8,capture_hold=1,pause_video_jobs=1,use_upload_axi=1,
 lease_active=1,memory_allowed=1,memory_write_allowed=1,owns_nn=1,job_valid=1,
 generation=32,last_released_generation=32,style=2,phase=4,terminal_status=8)
bindings=dict(re.findall(r'\.(\w+)\((\w+)\)',instance));decl=[];checks=[]
other=instance.replace('net_image_lease','old_lease',1).replace(' dut(',' reference_dut(',1)
for port,w in widths.items():
 signal=bindings[port];copy='old_'+signal
 decl.append(f'wire [{w-1}:0] {copy};')
 other=other.replace('.'+port+'('+signal+')','.'+port+'('+copy+')')
 checks.append(f'if({signal}!=={copy})$fatal(1,"cycle mismatch: {port}");')
s=s.replace(instance,instance+'\n'+'\n'.join(decl)+'\n'+other+'\ninteger compared=0;\nalways @(negedge clk)begin #0.1;if(reset)begin compared=compared+1;'+''.join(checks)+'end end\n')
s=s.replace('integer starts=0;','integer starts=0;integer random_cycle;reg[31:0]random_bits=32\'h71a239ef;')
s=s.replace('  $display("PASS:', '''
  for(random_cycle=0;random_cycle<50000;random_cycle=random_cycle+1)begin
   @(negedge clk);
   random_bits={random_bits[30:0],random_bits[31]^random_bits[21]^random_bits[1]^random_bits[0]};
   reset=(random_cycle%997)!=0;cv=random_bits[0]&random_bits[1];cmd=random_bits[4:2];
   cg=random_bits[5]?gen:gen+1;cs=random_bits[7:6];
   hold_ack=random_bits[8];cap_idle=random_bits[9];vid_idle=random_bits[10];
   core_idle=random_bits[11];mquiet=random_bits[12];activity=random_bits[13];
   jr=random_bits[14];jdone=random_bits[15];jdrain=random_bits[16];jerror=random_bits[17];
  end
  $display("PASS:''')
s=s.replace('$display("PASS:', '$display("METRIC exact_counter_cycles=%0d",compared);\n  $display("PASS:')
(D/'test.sv').write_text(s)
sources=[P/'rtl/net_image_lease.v',D/'old_lease.v',D/'test.sv']
(D/'run.do').write_text('\n'.join(['onerror {quit -code 1}','vlib work','vmap work work','vlog -sv '+' '.join('"'+f.as_posix()+'"'for f in sources),'vsim -c work.tb','run -all','quit -code 0']))
r=subprocess.run(['D:/ModelSim/win64/vsim.exe','-c','-l','sim.log','-do','run.do'],cwd=D,capture_output=True,text=True,errors='replace')
log=r.stdout+r.stderr;(D/'output.log').write_text(log)
print('\n'.join(x for x in log.splitlines()if any(y in x for y in ['PASS:','METRIC','Fatal','Error:'])))
assert r.returncode==0 and 'PASS:'in log and '** Fatal'not in log
(P/'LEASE_COUNTER_EQUIVALENCE.json').write_text(json.dumps(dict(status='CYCLE_COMPARISON_PASS_DIRECTED_CORNER_CASES',
 scope='Exact cycle comparison of every lease output with original two-counter RTL during directed corner cases plus 50000 deterministic pseudorandom input cycles including resets; not formal exhaustive proof.',
 cycles=int(re.search(r'exact_counter_cycles=(\d+)',log)[1]),reference_original_sha256=hashlib.sha256(reference.read_bytes()).hexdigest(),
 sha256={f.relative_to(P).as_posix():hashlib.sha256(f.read_bytes()).hexdigest()for f in sources+[Path(__file__)]}),indent=2))
