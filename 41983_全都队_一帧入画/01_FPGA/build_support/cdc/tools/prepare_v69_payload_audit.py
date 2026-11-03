"""Resolve actual alias-renamed payload capture FFs from current mapped nets."""
from pathlib import Path
import re,hashlib,json,collections
P=Path(__file__).resolve().parents[1];path=P/'outflow/ti60f225_oob.map.v';t=path.read_text(encoding='utf-8')
cells={}
for name,ports in re.findall(r'EFX_FF\s+(\\\S+|\w+)\s*\((.*?)\)\s*/\*.*?\*/\s*;',t,re.S):
 cells[name.lstrip('\\')]={p:v.strip().lstrip('\\') for p,v in re.findall(r'\.(\w+)\(([^()]*)\)',ports)}
groups=[]
for prefix,src,dst,bound,minimum in [
 ('u_frame_snapshot/u_apb/s_command[','mipi_tx_feedback100','core_clk',6.25,45),
 ('u_frame_snapshot/u_apb/d_response[','core_clk','mipi_tx_feedback100',10.,30),
 ('u_camera_frontend/u_gains/held[','mipi_tx_feedback100','vid_clk_dvi2',13.468,10),
 ('u_camera_frontend/u_statistics/held[','hdmi_tx_slow_clk','mipi_tx_feedback100',10.,30),
 ('u_source_snapshot/held[','hdmi_tx_slow_clk','mipi_tx_feedback100',10.,25),
 ('u_c_camera_bridge/payload[','mipi_tx_feedback100','mipi_tx_feedback100',10.,10)]:
 out=[];edges=[]
 for name,c in cells.items():
  if not name.startswith(prefix):continue
  assert c['CLK']==src,(name,c)
  matches=[(n,d) for n,d in cells.items() if d.get('D')==c['Q'] and d['CLK']==dst]
  assert matches,(name,'no direct local payload capture')
  for n,d in matches:out.append(n+'|D');edges.append(dict(source=name+'|Q',target=n+'|D'))
 assert len(set(out))>=minimum,(prefix,len(set(out)))
 groups.append(dict(name=prefix,source_clock=src,destination_clock=dst,bound_ns=bound,pins=sorted(set(out)),direct_edges=edges))
apb=[n+'|D' for n,c in cells.items() if n.startswith('u_c_soc/u_EfxSapphireSoc/io_apbSlave_0_logic_io_input_rsp_payload_fragment_data[') and c['CLK']=='mipi_tx_feedback100']
assert len(apb)==32,len(apb)
groups.append(dict(name='held observer/video APB reports',source_clock='core_clk hdmi_tx_slow_clk',destination_clock='mipi_tx_feedback100',bound_ns=10.,pins=sorted(apb),contract='Single-master APB: read trigger blocks until source ACK synchronizes; source payload stays frozen until next trigger. Only APB data response FFs are bounded; command/IRQ/control paths remain timed.'))
sdc=P/'ti60f225_oob.sdc';s=sdc.read_text(encoding='utf-8');s=re.sub(r'# BEGIN V69_PAYLOAD_CAPTURE.*?# END V69_PAYLOAD_CAPTURE\s*','',s,flags=re.S)
lines=[]
for line in s.splitlines():
 if any(prefix+'meta*~FF|D' in line and not any(n.startswith(prefix+'meta') for n in cells) for prefix in ['u_hdmi_frontend/u_hdmi_frames_cdc/','u_hdmi_frontend/u_hdmi_skipped_cdc/']):continue
 if line.startswith('set_') and any(v in line for v in ['u_video_diag/core_held*~FF|Q','u_video_diag/pixel_held*~FF|Q','u_c_nn_bridge/held*~FF|Q']):continue
 if 'g_rgbx_ddr.u_capture/overflow_sync[0]' in line:line=line.replace('hdmi_rx_slow_clk','hdmi_tx_slow_clk')
 lines.append(line)
s='\n'.join(lines)+'\n# BEGIN V69_PAYLOAD_CAPTURE\n'
for g in groups:
 pins=' '.join(g['pins']);s+=f'# {g["name"]}: mapped capture FFs={len(g["pins"])}\n'
 if g['source_clock']==g['destination_clock']:
  s+='# Same100MHz clock: use ordinary synchronous timing, no payload exception.\n'
  continue
 s+=f'set_max_delay -from [get_clocks {{{g["source_clock"]}}}] -to [get_pins {{{pins}}}] {g["bound_ns"]:.3f}\n'
 s+=f'set_min_delay -from [get_clocks {{{g["source_clock"]}}}] -to [get_pins {{{pins}}}] 0.000\n'
s+='# END V69_PAYLOAD_CAPTURE\n';sdc.write_text(s,encoding='utf-8')
(P/'V69_PAYLOAD_AUDIT.json').write_text(json.dumps(dict(status='PASS',map_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),groups=groups),indent=2),encoding='utf-8')
print('PASS mapped payload capture endpoints',[(g['name'],len(g['pins'])) for g in groups],flush=True)
