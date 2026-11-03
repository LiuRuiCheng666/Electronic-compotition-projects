"""Derive bounded image-mailbox payload paths from mapped connectivity.

Conservative LUT/ADD fanout includes all D/CE sinks up to the first FF.
Only proven three-stage event synchronizer first D pins are false paths.
This is structural evidence; routed timing and board testing remain required.
"""
from pathlib import Path
from collections import defaultdict
import hashlib,json,re
P=Path(__file__).resolve().parents[1]
mapped=P/'outflow/ti60f225_oob.map.v';t=mapped.read_text()
def net(s):return re.sub(r'\s+','',s).lstrip('\\')
cells={};graph=defaultdict(set);sinks=defaultdict(list)
for typ,name,ports,attrs in re.findall(r'EFX_(FF|LUT4|COMB4|ADD)\s+(\\\S+|\w+)\s*\((.*?)\)\s*/\*(.*?)\*/\s*;',t,re.S):
 n=name.lstrip('\\');c={k:net(v)for k,v in re.findall(r'\.(\w+)\(([^()]*)\)',ports)}
 if typ=='FF':
  cells[n]=c
  for pin in ('D','CE'):sinks[c[pin]].append((n,pin))
 else:
  outputs=[v for k,v in c.items()if k in ('O','CO','P') and not re.fullmatch(r"\d+'[bhd][0-9a-fxz]+",v,re.I)]
  if typ in ('LUT4','COMB4'):
   match=re.search(r"LUTMASK=16'h([0-9a-fA-F]+)",attrs);assert match,(typ,n,attrs)
   mask=int(match[1],16)
   constants={i:int(c['I'+str(i)][-1])for i in range(4)if c.get('I'+str(i))in ("1'b0","1'b1")}
   for k,v in c.items():
    if k not in ('I0','I1','I2','I3'):continue
    i=int(k[1])
    for out in ('O','P'):
     if out not in c or c[out]not in outputs:continue
     if out=='P':
      if i>1:continue
      values=[8+x for x in range(4)if all(((x>>j)&1)==b for j,b in constants.items()if j<2)]
     else:values=[x for x in range(16)if all(((x>>j)&1)==b for j,b in constants.items())]
     if any(((mask>>x)^(mask>>(x^(1<<i))))&1 for x in values):graph[v].add(c[out])
  else:
   for k,v in c.items():
    if k.startswith('I') or k=='CI':graph[v].update(outputs)
# Scalar aliases are uncommon for these groups, but keep their connectivity.
for lhs,rhs in re.findall(r'\bassign\s+([^=;]+)=\s*([^;]+);',t):
 rhs=re.sub(r'/\*.*?\*/','',rhs,flags=re.S).strip();lhs=lhs.strip()
 if not re.search(r'[{}&|?:~+*/]',lhs+rhs):graph[net(rhs)].add(net(lhs))
assert len(cells)>20000,len(cells)
chains=[]
def follow(first,count):
 names=[first];assert first in cells,first
 for _ in range(count-1):
  prior=cells[names[-1]]
  matches=[n for n,c in cells.items()if c['D']==prior['Q'] and c['CLK']==prior['CLK']]
  assert len(matches)==1,(first,matches)
  names+=matches
 return names
for prefix,source in [
 ('u_image_service/mailbox/request_sync','mipi_tx_feedback100'),
 ('u_image_service/mailbox/done_sync','core_clk'),
 ('u_image_service/mailbox/ack_sync','mipi_tx_feedback100'),
 ('u_image_service/mailbox/orphan_sync','mipi_tx_feedback100'),
 ('g_rgbx_ddr.u_capture/hold_pixel_sync','core_clk'),
 ('g_rgbx_ddr.u_capture/hold_ack_sync','hdmi_tx_slow_clk')]:
 names=follow(prefix+'[0]~FF',3)
 a,b,c=[cells[n]for n in names]
 assert a['CLK']==b['CLK']==c['CLK'] and source!=a['CLK']
 assert a['SR']==b['SR']==c['SR'] and all(x['CE']=="1'b1"for x in (a,b,c))
 assert b['D']==a['Q']and c['D']==b['Q']
 chains.append(dict(first=names[0],source_clock=source,target_clock=a['CLK'],stages=names))

groups=[]
# These are aliases of the immutable CPU mailbox words, not core registers.
# Synthesis can choose the downstream DMA signal as the register name.
# Check the exact RTL wiring before deriving their bounded first-FF fanout.
dispatch=(P/'rtl/net_image_dispatch.v').read_text()
mailbox=(P/'rtl/net_image_mailbox.v').read_text()
compact=re.sub(r'\s+','',dispatch)
for statement in ['assigndma_generation=request[63:32];',
                  "assigndma_offset=scan_mode?{10'd0,scan_offset}:request[95:64];",
                  'assigndma_mask=request[111:96];']:
 assert statement in compact,('Mailbox alias wiring changed',statement)
assert 'wirescan_mode=crc_op;'in compact and 'wire[21:0]scan_end=request[85:64];'in compact
assert 'if(!busy_cpu&&!completed&&!orphan)window[rel[4:2]]<=command_word' in re.sub(r'\s+','',mailbox)
# The CRC offset mux is entirely core-local. CPU W2 reaches its first core
# FF through the same bounded immutable request graph, not a new clock bypass.
crc_registers=[n for n in cells if n.startswith(('u_image_service/dispatcher/scan_crc[','u_image_service/dispatcher/scan_nibble[','u_image_service/dispatcher/scan_offset['))]
assert crc_registers and all(cells[n]['CLK']=='core_clk'for n in crc_registers)
request_aliases=('u_image_service/dma_generation[','u_image_service/dma_mask[','u_image_service/dispatcher/scan_end[')
for prefix,source,target,bound,minimum,minimum_sinks in [
 ('u_image_service/request[','mipi_tx_feedback100','core_clk',6.25,128,128),
 ('u_image_service/response[','core_clk','mipi_tx_feedback100',10.0,128,32)]:
 starts=[(n,c)for n,c in cells.items()if n.startswith(prefix) or
  (prefix=='u_image_service/request[' and n.startswith(request_aliases)) or
  (prefix=='u_image_service/response[' and (c['Q'].startswith('image_generation[') or
   n.startswith(('u_image_service/dispatcher/response_header[',
                 'u_image_service/dispatcher/response_has_data',
                 'u_image_service/dispatcher/response_has_crc',
                 'u_image_service/dispatcher/scan_crc[',
                 'u_image_service/dma/resp_data[', 'image_wdata['))))]
 assert len(starts)>=minimum,(prefix,len(starts))
 assert all(c['CLK']==source for n,c in starts)
 todo=[c['Q']for n,c in starts];seen=set();ends=set();parents={x:None for x in todo}
 while todo:
  signal=todo.pop()
  if signal in seen:continue
  seen.add(signal)
  for n,pin in sinks.get(signal,[]):
   if cells[n]['CLK']!=source:
    if cells[n]['CLK']!=target:
     path=[signal]
     while parents[path[-1]] is not None:path.append(parents[path[-1]])
     raise AssertionError((prefix,n,cells[n]['CLK'],path))
    ends.add(n+'|'+pin)
  for child in graph.get(signal,()):
   if child not in parents:parents[child]=signal
   todo.append(child)
 assert len(ends)>=minimum_sinks,(prefix,len(ends))
 groups.append(dict(source_registers=[n for n,c in starts],source_clock=source,
  destination_clock=target,bound_ns=bound,pins=sorted(ends),visited_comb_signals=len(seen)))

reset_names=follow('u_image_service/mailbox/cpu_reset_sync[0]~FF',3)
a,b,c=[cells[n]for n in reset_names]
assert a['D']=="1'b0" and b['D']==a['Q'] and c['D']==b['Q']
assert all(x['CE']=="1'b1"and x['CLK']=='core_clk'and x['SR']==a['SR']for x in (a,b,c))
for n in reset_names:
 assert re.search(r'defparam\s+\\?'+re.escape(n)+r'\s*\.SR_SYNC\s*=\s*1\x27b0',t),n

sdc=P/'ti60f225_oob.sdc'
s=re.sub(r'# BEGIN IMAGE_CDC.*?# END IMAGE_CDC\s*','',sdc.read_text(),flags=re.S)
s+='\n# BEGIN IMAGE_CDC\n# Bundled data stays bounded; no broad image clock exceptions.\n'
for x in chains:
 s+='set_false_path -from [get_clocks {'+x['source_clock']+'}] -to [get_pins {'+x['first']+'|D}]\n'
for g in groups:
 pins=' '.join(g['pins']);src=g['source_clock']
 s+=f'set_max_delay -from [get_clocks {{{src}}}] -to [get_pins {{{pins}}}] {g["bound_ns"]:.3f}\n'
 s+=f'set_min_delay -from [get_clocks {{{src}}}] -to [get_pins {{{pins}}}] 0.000\n'
for n in reset_names:
 s+='set_false_path -from [get_clocks {core_clk mipi_tx_feedback100}] -to [get_pins {'+n+'|SR}]\n'
s+='# END IMAGE_CDC\n';sdc.write_text(s,encoding='utf-8')
(P/'IMAGE_CDC_AUDIT.json').write_text(json.dumps(dict(
 status='MAPPED_STRUCTURE_PASS_ROUTED_TIMING_PENDING',map_sha256=hashlib.sha256(mapped.read_bytes()).hexdigest(),
 synchronizers=chains,held_payload=groups,cpu_reset_release=reset_names,
 immutable_command_aliases=[n for n in groups[0]['source_registers']if n.startswith(request_aliases)],
 method='First-sequential-boundary fanout with exhaustive LUT/COMB4 truth-table dependencies and conservative ADD edges; all crossing D/CE sinks bounded. Includes stable lease generation aliases. Event chains structurally proven.',
 scope='Offline structure only. No routed timing or board proof.'),indent=2))
print('PASS image CDC:',len(chains),'event chains, payload sinks',[len(g['pins'])for g in groups],flush=True)
