from pathlib import Path
import os,sys,subprocess,json,struct
from ethernet_vectors import *
P=Path(__file__).resolve().parents[1];sys.path.insert(0,str(P/'host'))
from a_net_wire import Packet,encode,HELLO,STATUS,DATA,ACK
w=P/'tests/run_service_endpoint';w.mkdir(exist_ok=True)
frames={'arp':arp()};replies={}
for n,op,seq in [(0,STATUS,1),(5,STATUS,2),(1368,DATA,3)]:
 data=bytes((i*17+3)&255 for i in range(n))
 frames['req'+str(n)]=udp(encode(Packet(op,0x10203040,seq,total=n if op==DATA else 0,payload=data)))
 # APB test CPU supplies raw transport replies, not an inference backend.
 replies[n]=encode(Packet(ACK,0x10203040,seq,payload=data))
 raw=replies[n];padded=raw+b'\0'*((-len(raw))%4)
 (w/('reply'+str(n)+'.mem')).write_text(''.join(f'{x:08x}\n' for x in struct.unpack('<'+'I'*(len(padded)//4),padded)))
hello_replies=[]
for n in [0,5,1368]:
 data=bytes((i*29+11)&255 for i in range(n));packet=encode(Packet(HELLO,0x11223344,100+n,payload=data))
 frames['hello'+str(n)]=udp(packet);hello_replies.append(encode(Packet(ACK,0x11223344,100+n,payload=data)))
raw=encode(Packet(HELLO,0x11223344,105,payload=bytes((i*29+11)&255 for i in range(5))))
frames['bad_hello']=udp(raw[:-1]+bytes([raw[-1]^1]))
raw=encode(Packet(STATUS,0x10203040,2,payload=bytes((i*17+3)&255 for i in range(5))))
frames['bad_app']=udp(raw[:-1]+bytes([raw[-1]^1]))
frames['bad_fcs']=frames['req5'][:-1]+bytes([frames['req5'][-1]^1])
for name,raw in frames.items():(w/(name+'.mem')).write_text(''.join(f'{b:02x}\n' for b in raw))
files=['rtl/net_physical_link.v','rtl/a_rgmii_fabric_adapter.v','rtl/a_phy_link_poll.v','rtl/a_mdio_clause22.v','rtl/a_gmii_udp_rx.v','rtl/a_net_packet_rx.v','rtl/a_net_mailbox_apb.v','rtl/a_gmii_udp_tx.v','rtl/a_gmii_reply_tx.v','rtl/a_net_service_endpoint.v','tests/tb_service_endpoint.sv']
(w/'run.do').write_text('\n'.join(['onerror {quit -code 1}','vlib work','vmap work work','vlog -sv '+' '.join('"'+(P/n).as_posix()+'"' for n in files),'vsim -c work.tb','run -all','quit -code 0']))
sim=Path(os.environ.get('MODELSIM_BIN','D:/ModelSim/win64'))
r=subprocess.run([str(sim/'vsim.exe'),'-c','-l','test.log','-do','run.do'],cwd=w,capture_output=True,text=True,errors='replace')
t=r.stdout+r.stderr;(w/'output.log').write_text(t,encoding='utf-8')
print('\n'.join(x for x in t.splitlines() if 'PASS:' in x or 'Fatal' in x or 'Error:' in x))
assert r.returncode==0 and 'PASS:' in t and '** Fatal' not in t
actual=[bytes.fromhex(p) for p in (w/'tx_frames.txt').read_text().split('END') if p.strip()]
def response(raw):
 n=8+len(raw);ip=struct.pack('!BBHHHBBH4s4s',0x45,0,20+n,0,0x4000,64,17,0,LOCAL_IP,PEER_IP)
 ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
 return ethernet(PEER_MAC+LOCAL_MAC+b'\x08\x00'+ip+struct.pack('!HHHH',40000,40001,n,0)+raw)
arp_reply=ethernet(PEER_MAC+LOCAL_MAC+b'\x08\x06'+struct.pack('!HHBBH',1,0x800,6,4,2)+LOCAL_MAC+LOCAL_IP+PEER_MAC+PEER_IP)
expected=[response(replies[n]) for n in [0,5,1368,1368]]+[arp_reply,response(replies[0])]+[arp_reply]+[response(r) for r in hello_replies]+[response(replies[1368]),response(hello_replies[0])]
assert len(actual)==len(expected),(len(actual),len(expected))
for i,(got,want)in enumerate(zip(actual,expected)):
 assert got==want,('frame mismatch',i,len(got),len(want),next((j for j in range(min(len(got),len(want))) if got[j]!=want[j]),None))
print('PASS: 12 Ethernet output frames byte-exact vs independent Python reference')
(P/'SERVICE_ENDPOINT_VALIDATION.json').write_text(json.dumps(dict(status='PASS',ethernet_frames=12,byte_exact=True,network_clock_hz=125000000,cpu_clock_hz=100000000,hardware_accessed=False,cpu='APB testbench, not the C driver',image_inference_roundtrip=False),indent=2))
