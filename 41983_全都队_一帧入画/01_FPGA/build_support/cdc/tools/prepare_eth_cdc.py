from pathlib import Path
import re,json,hashlib,runpy
from collections import defaultdict
P=Path(__file__).resolve().parents[1];f=P/'outflow/ti60f225_oob.map.v';text=f.read_text();cells={}
for name,ports in re.findall(r'EFX_FF\s+(\\\S+|\w+)\s*\((.*?)\)\s*/\*.*?\*/\s*;',text,re.S):cells[name.lstrip('\\')]={k:v.strip().lstrip('\\')for k,v in re.findall(r'\.(\w+)\(([^()]*)\)',ports)}
byq={c.get('Q'):n for n,c in cells.items()};sync=[];groups={('rxc','mipi_tx_feedback100'):[],('mipi_tx_feedback100','rxc'):[]}
direct='.DIRECT_RX_METADATA(1)'in(P/'rtl/ethernet/a_net_service_endpoint.v').read_text()
for n,c in cells.items():
 if not n.startswith('u_net_endpoint/'):continue
 source=byq.get(c.get('D'))
 if not source or cells[source]['CLK']==c['CLK']:continue
 pair=(cells[source]['CLK'],c['CLK']);assert pair in groups,(source,n,pair)
 if any(x+'[0]~FF' in n for x in ['rx_req_sync','rx_ack_sync','tx_req_sync','tx_complete_sync']):sync.append(dict(source=source,target=n,clock=pair[0]));continue
 if not(direct and pair==('rxc','mipi_tx_feedback100')):
  assert ('/n_' in source and '/c_' in n)or('/c_tx_' in source and '/mb_' in n),(source,n)
 groups[pair].append(n+'|D')
descriptor_sources=[]
ram_sampling_pins=[]
if direct:
 # Use the same truth-table-aware first-sequential-boundary graph as the
 # image mailbox. Direct descriptors terminate in CPU APB/compare logic,
 # not in the removed c_* copy bank. Every crossing remains time bounded.
 graph_ns=runpy.run_path(str(P/'tools/prepare_image_cdc.py'))
 fc,graph,sinks=graph_ns['cells'],graph_ns['graph'],graph_ns['sinks']
 # Synthesis may implement ordinary synchronous data control on SR instead
 # of D/CE. Include only SR_SYNC=1 ports; asynchronous reset remains excluded.
 synchronous_sr={n.lstrip('\\')for n in re.findall(r'defparam\s+(\\\S+|\w+)\s*\.SR_SYNC\s*=\s*1\x27b1',text)}
 for n,c in fc.items():
  if c['CLK']=='mipi_tx_feedback100'and n in synchronous_sr:
   sinks[c['SR']].append((n,'SR'))
 # RAM write/read controls and addresses are sequential capture endpoints too.
 widths={n.lstrip('\\'):(int(a)-int(b)+1)if a else 1 for a,b,n in re.findall(r'\bwire\s*(?:\[(\d+):(\d+)\])?\s*(\\\S+|\w+)\s*;',text)}
 def bits(expr):
  expr=re.sub(r'\s+','',expr).lstrip('\\')
  if expr.startswith('{')and expr.endswith('}'):
   return [b for item in expr[1:-1].split(',')for b in bits(item)]
  k=re.fullmatch(r"(\d+)'[bhd][0-9a-fxz]+",expr,re.I)
  if k:return [None]*int(k[1])
  k=re.fullmatch(r'(.+)\[(\d+)(?::(\d+))?\]',expr)
  if k:
   hi=int(k[2]);lo=int(k[3])if k[3]is not None else hi
   return [k[1]+'['+str(i)+']'for i in range(hi,lo-1,-1)]
  w=widths.get(expr,1)
  return [expr]if w==1 else [expr+'['+str(i)+']'for i in range(w-1,-1,-1)]
 ram_sinks=defaultdict(list)
 for rn,ports in re.findall(r'EFX_RAM10\s+(\\\S+|\w+)\s*\((.*?)\)\s*/\*',text,re.S):
  rn=rn.lstrip('\\');rc={k:v for k,v in re.findall(r'\.(\w+)\(([^()]*)\)',ports)}
  for port,clock_port in [('WE','WCLK'),('WDATA','WCLK'),('WADDR','WCLK'),('WCLKE','WCLK'),('WADDREN','WCLK'),('RE','RCLK'),('RADDR','RCLK'),('RADDREN','RCLK')]:
   if port not in rc:continue
   values=bits(rc[port]);clk=graph_ns['net'](rc[clock_port])
   for index,signal in enumerate(reversed(values)):
    if signal is None:continue
    pin=port+('['+str(index)+']'if port in ['WE','WDATA','WADDR','RADDR']else'')
    ram_sinks[signal].append((rn,pin,clk))
 descriptor_sources=[n for n,c in fc.items()if c['CLK']=='rxc'and
  re.match(r'^u_net_endpoint/u_mailbox/(?:n_|c_)(?:mac|ip|sid|seq|off|total|token|port|len|op)\[',n)]
 assert len(descriptor_sources)==280,('Immutable descriptor mapping changed',len(descriptor_sources))
 todo=[fc[n]['Q']for n in descriptor_sources];seen=set();ends=set()
 while todo:
  signal=todo.pop()
  if signal in seen:continue
  seen.add(signal)
  for n,pin in sinks.get(signal,[]):
   if fc[n]['CLK']!='rxc':
    assert fc[n]['CLK']=='mipi_tx_feedback100',('Unexpected descriptor clock',n,fc[n]['CLK'])
    ends.add(n+'|'+pin)
  for n,pin,clock in ram_sinks.get(signal,[]):
   if clock!='rxc':
    assert clock=='mipi_tx_feedback100',('Unexpected RAM capture clock',n,pin,clock)
    ends.add(n+'|'+pin);ram_sampling_pins.append(dict(pin=n+'|'+pin,clock=clock))
  todo.extend(graph.get(signal,()))
 assert len(ends)>=32,('Direct descriptor has no CPU sampling boundary',len(ends))
 groups[('rxc','mipi_tx_feedback100')]=sorted(ends)
assert len(sync)==4 and len(groups[('mipi_tx_feedback100','rxc')])==112,(len(sync),{k:len(v)for k,v in groups.items()})
if not direct:assert len(groups[('rxc','mipi_tx_feedback100')])==280
chains=[]
for n,c in cells.items():
 if not n.startswith(('u_net_endpoint/','u_net_physical/'))or not re.search(r'(net_release|cpu_release|nr|cr|osc_release|run_pipe)\[0\]~FF$',n):continue
 assert c['D']=="1'b1" and c['CE']=="1'b1",(n,c)
 chain=[n]
 for _ in range(2):
  child=[(m,d)for m,d in cells.items()if d.get('D')==cells[chain[-1]]['Q']];assert len(child)==1,child
  m,d=child[0];assert d['CLK']==c['CLK']and d['SR']==c['SR']and d['CE']=="1'b1";chain.append(m)
 chains.append(chain)
expected_heads={'u_net_endpoint/net_release[0]~FF','u_net_endpoint/cpu_release[0]~FF','u_net_endpoint/u_mailbox/cr[0]~FF','u_net_endpoint/u_mailbox/nr[0]~FF','u_net_physical/run_pipe[0]~FF','u_net_physical/osc_release[0]~FF'}
assert {c[0]for c in chains}==expected_heads,chains
sdc=P/'ti60f225_oob.sdc';s=re.sub(r'# BEGIN ETH_CDC.*?# END ETH_CDC\s*','',sdc.read_text(),flags=re.S);s+='\n# BEGIN ETH_CDC\n'
for x in sync:s+='set_false_path -from [get_clocks {'+x['clock']+'}] -to [get_pins {'+x['target']+'|D}]\n'
for (source,target),pins in groups.items():
 bound=10 if target=='mipi_tx_feedback100'else 8
 s+='set_max_delay -from [get_clocks {'+source+'}] -to [get_pins {'+' '.join(pins)+'}] '+str(bound)+'.000\n'
 s+='set_min_delay -from [get_clocks {'+source+'}] -to [get_pins {'+' '.join(pins)+'}] 0.000\n'
for chain in chains:
 for n in chain:s+='set_false_path -from [get_clocks {rxc osc_inst1_CLKOUT core_clk mipi_tx_feedback100 hdmi_tx_slow_clk hdmi_rx_slow_clk i_mipi_rx_pclk vid_clk_dvi2 i_cam_ck_CLKOUT}] -to [get_pins {'+n+'|SR}]\n'
s+='# END ETH_CDC\n';sdc.write_text(s,encoding='utf-8')
(P/'ETHERNET_CDC_AUDIT.json').write_text(json.dumps(dict(status='MAPPED_STRUCTURE_PASS_ROUTED_TIMING_PENDING',map_sha256=hashlib.sha256(f.read_bytes()).hexdigest(),direct_rx_metadata=direct,descriptor_source_registers=descriptor_sources,ram_sampling_pins=ram_sampling_pins,synchronizer_first_stages=sync,held_payload=[dict(source=a,target=b,pins=c,bound_ns=10 if b=='mipi_tx_feedback100'else 8)for(a,b),c in groups.items()],reset_chains=chains,scope='Only proven synchronizer D and constant-D reset SR exceptions. Held payload D/CE/synchronous-SR and RAM input endpoints remain bounded. Physical routed STA still required.'),indent=2))
print('PASS Ethernet CDC:4 sync first stages, held payload sinks',[len(v)for v in groups.values()],len(chains),'reset chains')
