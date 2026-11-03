"""Derive exact two-stage reset SR exceptions from real mapped connectivity."""
from pathlib import Path
import re,hashlib,json
P=Path(__file__).resolve().parents[1];mapped=P/'outflow/ti60f225_oob.map.v';t=mapped.read_text(encoding='utf-8')
cells={}
for name,ports in re.findall(r'EFX_FF\s+(\\\S+|\w+)\s*\((.*?)\)\s*/\*.*?\*/\s*;',t,re.S):
 cells[name.lstrip('\\')]={p:v.strip().lstrip('\\') for p,v in re.findall(r'\.(\w+)\(([^()]*)\)',ports)}
chains=[]
for name,x in cells.items():
 standard='/release_sync[0]~FF' in name
 mailbox=name in ['u_frame_snapshot/u_apb/s_reset[0]~FF','u_frame_snapshot/u_apb/d_reset[0]~FF']
 if not standard and not mailbox:continue
 assert x['D']==("1'b0" if mailbox else "1'b1") and x['CE']=="1'b1",name
 children=[(n,y) for n,y in cells.items() if y.get('D')==x['Q']]
 assert children,(name,children)
 for end,y in children:
  assert y['CLK']==x['CLK'] and y['SR']==x['SR'] and y['CE']=="1'b1",name
  for n in [name,end]:
   assert re.search(r'defparam\s+\\?'+re.escape(n)+r'\s*\.SR_SYNC\s*=\s*1\x27b0',t),n
  chains.append(dict(stage0=name,stage1=end,clock=x['CLK'],reset=x['SR']))
assert 25<=len({c['stage0']for c in chains})<=45,len(chains)
pins=[c[k]+'|SR' for c in chains for k in ['stage0','stage1']]
sdc=P/'ti60f225_oob.sdc';s=re.sub(r'# BEGIN V69_MAPPED_RESET_SR.*?# END V69_MAPPED_RESET_SR\s*','',sdc.read_text(encoding='utf-8'),flags=re.S)
# The camera CPU bridge can merge its same-clock reset chain with its peer.
# Drop only stale exact SR lines; retain real mapped chain constraints.
lines=[]
for line in s.splitlines():
 if 'u_c_camera_bridge/' in line and '~FF|SR' in line:
  names=re.findall(r'(u_c_camera_bridge/[^\s{}]+)\|SR',line)
  if names and not any(name in cells for name in names):continue
 lines.append(line)
s='\n'.join(lines)+'\n'
s+='\n# BEGIN V69_MAPPED_RESET_SR\n# Exact SR pins only. All stage-to-stage and functional D/CE paths stay timed.\n'
for pin in pins:s+='set_false_path -from [get_clocks {core_clk mipi_tx_feedback100 hdmi_tx_slow_clk hdmi_rx_slow_clk i_mipi_rx_pclk vid_clk_dvi2 i_cam_ck_CLKOUT}] -to [get_pins {'+pin+'}]\n'
s+='# END V69_MAPPED_RESET_SR\n';sdc.write_text(s,encoding='utf-8')
out=dict(status='PASS',method='constant-D stage0 -> every original/replicated same-clock stage1 D, all matching CE/asynchronous SR, matching asynchronous reset; only SR exceptions',map_sha256=hashlib.sha256(mapped.read_bytes()).hexdigest(),chains=chains,reset_pins=pins)
(P/'V69_RESET_AUDIT.json').write_text(json.dumps(out,indent=2),encoding='utf-8')
print('PASS exact mapped reset chains=',len(chains),'SR pins=',len(pins),flush=True)
