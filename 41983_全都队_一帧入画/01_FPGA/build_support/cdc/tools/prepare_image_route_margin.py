"""Tighten the existing synchronous diagnostic CE budget; no false paths."""
from pathlib import Path
import re,json,hashlib
P=Path(__file__).resolve().parents[1]
mapped=P/'outflow/ti60f225_oob.map.v'
t=mapped.read_text()
pins=sorted(set(re.findall(r'EFX_FF\s+\\(u_live_nn/error_count\[\d+\]~FF)\s*\(',t)))
assert len(pins)==32,('Diagnostic register mapping changed',pins)
line_pins=sorted(set(re.findall(r'EFX_FF\s+\\(u_live_nn/g_inference\.u_net_top/G_LB\[0\]\.u_lb/sr_[tmb]2\[\d+\]~FF)\s*\(',t)))
assert len(line_pins)>=24,('First line-buffer register mapping changed',line_pins)
lease_ce_pins=sorted(set(re.findall(r'EFX_FF\s+\\((?:u_image_service/lease/(?:inactive_count|shared_count|prepare_count)|image_generation)\[\d+\]~FF)\s*\(',t)))
lease_state_pins=sorted(set(re.findall(r'EFX_FF\s+\\(image_phase\[\d+\]~FF)\s*\(',t)))
assert len(lease_ce_pins)>=48 and len(lease_state_pins)>=3,('Lease timing endpoints changed',lease_ce_pins,lease_state_pins)
sdc=P/'ti60f225_oob.sdc';s=sdc.read_text()
s=re.sub(r'# BEGIN IMAGE_ROUTE_MARGIN.*?# END IMAGE_ROUTE_MARGIN\s*','',s,flags=re.S)
s+='\n# BEGIN IMAGE_ROUTE_MARGIN\n# 5.8ns is stricter than the original 6.25ns core period.\n'
s+='set_max_delay -from [get_clocks {core_clk}] -to [get_pins {'+' '.join(n+'|CE'for n in pins)+'}] 5.800\n'
s+='set_max_delay -from [get_clocks {core_clk}] -to [get_pins {'+' '.join(n+'|D'for n in line_pins)+'}] 5.800\n'
s+='# Keep acquisition/quiescence controls local; stricter than core 6.25ns, not an exception.\n'
s+='set_max_delay -from [get_clocks {core_clk}] -to [get_pins {'+' '.join(n+'|CE'for n in lease_ce_pins)+'}] 5.800\n'
s+='set_max_delay -from [get_clocks {core_clk}] -to [get_pins {'+' '.join(n+'|D'for n in lease_state_pins)+'}] 5.800\n'
s+='# END IMAGE_ROUTE_MARGIN\n';sdc.write_text(s,encoding='utf-8')
(P/'IMAGE_ROUTE_MARGIN.json').write_text(json.dumps(dict(status='STRICTER_SYNCHRONOUS_BUDGET',period_ns=6.25,max_delay_ns=5.8,pins=pins,line_buffer_pins=line_pins,lease_max_delay_ns=5.8,lease_ce_pins=lease_ce_pins,lease_state_pins=lease_state_pins,map_sha256=hashlib.sha256(mapped.read_bytes()).hexdigest()),indent=2))
print('PASS stricter 5.8ns synchronous budget:',len(pins),'diagnostic CE and',len(line_pins),'line-buffer D pins')
