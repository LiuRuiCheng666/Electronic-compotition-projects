"""Bounded ANET HELLO probe. Sends only when explicitly invoked."""
import argparse,socket,secrets
from a_net_wire import Packet,HELLO,ACK,encode,decode
p=argparse.ArgumentParser();p.add_argument('--ip',required=True);p.add_argument('--port',type=int,default=40000);p.add_argument('--count',type=int,default=4);p.add_argument('--timeout',type=float,default=1);a=p.parse_args()
if not 1<=a.count<=100 or not 1<=a.port<=65535 or not 0<a.timeout<=30:p.error('invalid bounds')
sid=secrets.randbits(32);good=0
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
 s.settimeout(a.timeout);s.connect((a.ip,a.port))
 for i in range(a.count):
  payload=b'HELLO'+i.to_bytes(4,'big');s.send(encode(Packet(HELLO,sid,i,payload=payload)))
  try:
   r=decode(s.recv(2048))
   if r.op in (HELLO,ACK) and r.session==sid and r.sequence==i and r.payload==payload:good+=1
  except (OSError,ValueError):pass
print(f'replies={good}/{a.count}')
raise SystemExit(0 if good==a.count else 1)
