"""Independent standard-library Ethernet/IPv4/UDP test-frame construction."""
import struct,zlib
LOCAL_MAC=bytes.fromhex('02000060f225');PEER_MAC=bytes.fromhex('001122334455')
LOCAL_IP=bytes([192,168,0,2]);PEER_IP=bytes([192,168,0,3])
def checksum(raw):
 if len(raw)%2:raw+=b'\0'
 s=sum(struct.unpack('!'+str(len(raw)//2)+'H',raw))
 while s>>16:s=(s&65535)+(s>>16)
 return (~s)&65535
def ethernet(body):
 body=body.ljust(60,b'\0')
 return b'\x55'*7+b'\xd5'+body+struct.pack('<I',zlib.crc32(body))
def udp(payload,port=40000,destination=LOCAL_IP,fragment=0x4000,zero_checksum=False,bad_ip=False,bad_udp=False):
 ulen=8+len(payload)
 udp=struct.pack('!HHHH',40001,port,ulen,0)+payload
 c=0 if zero_checksum else checksum(PEER_IP+destination+struct.pack('!BBH',0,17,ulen)+udp) or 65535
 udp=udp[:6]+struct.pack('!H',c)+udp[8:]
 if bad_udp:udp=udp[:-1]+bytes([udp[-1]^1])
 ip=struct.pack('!BBHHHBBH4s4s',0x45,0,20+ulen,1,fragment,64,17,0,PEER_IP,destination)
 ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
 if bad_ip:ip=ip[:8]+bytes([ip[8]^1])+ip[9:]
 return ethernet(LOCAL_MAC+PEER_MAC+b'\x08\x00'+ip+udp)
def arp(destination=LOCAL_IP):
 return ethernet(b'\xff'*6+PEER_MAC+b'\x08\x06'+struct.pack('!HHBBH',1,0x800,6,4,1)+PEER_MAC+PEER_IP+b'\0'*6+destination)
