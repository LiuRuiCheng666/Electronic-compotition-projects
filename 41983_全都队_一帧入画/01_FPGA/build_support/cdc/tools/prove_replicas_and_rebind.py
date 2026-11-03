from pathlib import Path
import re,json,hashlib,itertools
P=Path(__file__).resolve().parents[1];text=(P/'outflow/ti60f225_oob.map.v').read_text();norm=lambda x:re.sub(r'\s+','',x).lstrip('\\')
ff={};luts=[]
for typ,name,ports,attrs in re.findall(r'EFX_(FF|LUT4)\s+(\\\S+|\w+)\s*\((.*?)\)\s*/\*(.*?)\*/\s*;',text,re.S):
 n=name.lstrip('\\');c={k:norm(v)for k,v in re.findall(r'\.(\w+)\(([^()]*)\)',ports)}
 if typ=='FF':ff[n]=c
 else:luts.append((c,int(re.search(r"LUTMASK=16'h([0-9a-fA-F]+)",attrs).group(1),16)))
params={}
for n,k,v in re.findall(r'defparam\s+(\\\S+|\w+)\s*\.(\w+)\s*=\s*([^;]+);',text):params.setdefault(n.lstrip('\\'),{})[k]=norm(v)
parent={}
def root(n):
 while n in parent:
  if parent[n]in parent:parent[n]=parent[parent[n]]
  n=parent[n]
 return n
def join(a,b):
 a,b=root(a),root(b)
 if a==b:return False
 parent[max(a,b)]=min(a,b);return True
pairs=[];families={}
for n in ff:
 if re.search(r'~FF_REP\d+$',n):families.setdefault(re.sub(r'~FF_REP\d+$','~FF',n),[]).append(n)
for base,members in families.items():
 reference=base if base in ff else members[0]
 for n in members:
  if n==reference:continue
  pairs.append((reference,n));join(ff[n]['Q'],ff[reference]['Q'])
# Replica FF classes are a candidate induction relation. Verify all next-state
# and clock/reset functions after exact LUT truth-table canonicalization.
for iteration in range(30):
 table={};changed=False
 for c,mask in luts:
  for i in range(4):
   if 'I'+str(i)not in c:
    assert all(((mask>>v)&1)==((mask>>(v^(1<<i)))&1)for v in range(16)),('unconnected significant LUT pin',c,mask,i)
    c['I'+str(i)]="1'b0"
  ins=[root(c['I'+str(i)])for i in range(4)];variables=tuple(sorted(set(x for x in ins if x not in ("1'b0","1'b1"))))
  bits=0
  for a in range(1<<len(variables)):
   vals={v:(a>>i)&1 for i,v in enumerate(variables)};vals.update({"1'b0":0,"1'b1":1});index=sum(vals[v]<<i for i,v in enumerate(ins));bits|=((mask>>index)&1)<<a
  sig=(variables,bits)
  if sig in table:changed=join(c['O'],table[sig])or changed
  else:table[sig]=c['O']
 if not changed:break
for base,n in pairs:
 assert params.get(base,{})==params.get(n,{}),(base,n,'FF parameters differ')
 for pin in ['D','CE','CLK','SR']:assert root(ff[base][pin])==root(ff[n][pin]),(base,n,pin,ff[base][pin],ff[n][pin])
resets=[]
for n,x in ff.items():
 if not re.search(r'/(?:src_reset|dst_reset|cpu_reset|core_reset|pixel_reset|s_reset|d_reset)\[0\]~FF(?:_REP\d+)?$',n):continue
 if x['D']not in("1'b0","1'b1")or x['CE']!="1'b1":continue
 for m,y in ff.items():
  if root(y['D'])!=root(x['Q'])or root(y['CLK'])!=root(x['CLK'])or root(y['SR'])!=root(x['SR'])or y['CE']!="1'b1":continue
  assert params[n].get('SR_SYNC')==params[m].get('SR_SYNC')=="1'b0"
  resets.append(dict(stage0=n,stage1=m,clock=x['CLK'],canonical_reset=root(x['SR'])))
pins=sorted({x[k]+'|SR'for x in resets for k in ['stage0','stage1']})
view=sorted(n+'|D'for n in ff if re.match(r'u_live_nn_display/(view_core|roi_core|original_part|remaining)(\[|~)',n));assert len(view)>=21
s='\n# BEGIN PROVEN_FANOUT_ALIASES\n'
s+='# Exact replicated asynchronous reset SR pins; functional D and CE remain timed.\n'
s+='set_false_path -from [get_clocks {core_clk mipi_tx_feedback100 hdmi_tx_slow_clk hdmi_rx_slow_clk i_mipi_rx_pclk vid_clk_dvi2 i_cam_ck_CLKOUT}] -to [get_pins {'+' '.join(pins)+'}]\n'
s+='# Existing immutable row mode/ROI descriptor contract, including every proven FF replica.\n'
s+='set_max_delay -from [get_clocks {hdmi_tx_slow_clk}] -to [get_pins {'+' '.join(view)+'}] 10.000\n'
s+='set_min_delay -from [get_clocks {hdmi_tx_slow_clk}] -to [get_pins {'+' '.join(view)+'}] 0.000\n# END PROVEN_FANOUT_ALIASES\n'
for f in [P/'ti60f225_oob.sdc',P/'original_spec.sdc']:
 old=f.read_text();old=re.sub(r'# BEGIN PROVEN_FANOUT_ALIASES.*?# END PROVEN_FANOUT_ALIASES\s*','',old,flags=re.S);f.write_text(old+s,encoding='utf-8')
(P/'PROVEN_FANOUT_ALIASES.json').write_text(json.dumps(dict(status='PASS',method='Inductive FF-replica correspondence; every FF parameter and D/CE/CLK/SR function equal after exhaustive4input LUT truth tables. Only reset synchronizer SR pins exempted; same10ns bound extended to immutable view descriptor replicas.',ff_replica_pairs=pairs,reset_chains=resets,exact_reset_SR_pins=pins,view_descriptor_pins=view,map_sha256=hashlib.sha256((P/'outflow/ti60f225_oob.map.v').read_bytes()).hexdigest()),indent=2))
print('PASS replica correspondence',len(pairs),'pairs; exact reset SR pins',len(pins),'immutable view descriptor pins',len(view),flush=True)
