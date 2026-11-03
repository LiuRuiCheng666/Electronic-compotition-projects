"""A-owned UDP application wire format. No FPGA backend is implied by this file.

All integer fields are network byte order. CRC covers header[0:28] and payload.
This CRC is application integrity, not Ethernet FCS and not authentication.
"""
from dataclasses import dataclass
import struct,zlib

MAGIC=b'ANET';VERSION=1
HEADER=struct.Struct('!4sBBHIIIIHHI')
MAX_DATAGRAM=1400
CHUNK_BYTES=MAX_DATAGRAM-HEADER.size
HELLO=1;STATUS=2;BEGIN=0x10;DATA=0x11;ACK=0x12;COMMIT=0x13;ABORT=0x14;RESULT=0x20
OPS={HELLO,STATUS,BEGIN,DATA,ACK,COMMIT,ABORT,RESULT}

@dataclass(frozen=True)
class Packet:
    op:int
    session:int
    sequence:int=0
    offset:int=0
    total:int=0
    payload:bytes=b''

def encode(p):
    if p.op not in OPS:raise ValueError('unsupported opcode')
    for n in (p.session,p.sequence,p.offset,p.total):
        if type(n) is not int or not 0<=n<=0xffffffff:raise ValueError('uint32 field out of range')
    if not isinstance(p.payload,bytes) or len(p.payload)>CHUNK_BYTES:raise ValueError('oversized payload')
    h=HEADER.pack(MAGIC,VERSION,p.op,0,p.session,p.sequence,p.offset,p.total,len(p.payload),0,0)
    crc=zlib.crc32(h[:28]+p.payload)
    return h[:28]+struct.pack('!I',crc)+p.payload

def decode(raw):
    if not HEADER.size<=len(raw)<=MAX_DATAGRAM:raise ValueError('datagram length')
    magic,version,op,flags,sid,seq,offset,total,n,reserved,crc=HEADER.unpack(raw[:HEADER.size])
    if magic!=MAGIC or version!=VERSION or op not in OPS or flags or reserved:raise ValueError('header/ABI')
    if len(raw)!=HEADER.size+n:raise ValueError('payload length')
    payload=raw[HEADER.size:]
    if zlib.crc32(raw[:28]+payload)!=crc:raise ValueError('CRC mismatch')
    return Packet(op,sid,seq,offset,total,payload)

def chunks(raw,session,op=DATA):
    if not isinstance(raw,bytes) or not raw:raise ValueError('nonempty bytes required')
    if op not in (DATA,RESULT):raise ValueError('data opcode required')
    for seq,off in enumerate(range(0,len(raw),CHUNK_BYTES)):
        yield Packet(op,session,seq,off,len(raw),raw[off:off+CHUNK_BYTES])

class Collector:
    """PC-side bounded, out-of-order frame receiver. C must implement ownership
    and commit validation independently; this is not an FPGA frame buffer."""
    def __init__(self,session,total,op=RESULT,max_bytes=4*1024*1024):
        if not 0<total<=max_bytes or op not in (DATA,RESULT):raise ValueError('frame declaration')
        self.session,self.total,self.op=session,total,op
        self.parts=[None]*((total+CHUNK_BYTES-1)//CHUNK_BYTES)
    def accept(self,p):
        if p.session!=self.session or p.total!=self.total or p.op!=self.op:raise ValueError('wrong transfer')
        if p.offset%CHUNK_BYTES or p.sequence!=p.offset//CHUNK_BYTES:raise ValueError('chunk identity')
        if not 0<=p.offset<self.total:raise ValueError('chunk offset')
        n=min(CHUNK_BYTES,self.total-p.offset)
        if len(p.payload)!=n:raise ValueError('chunk length')
        previous=self.parts[p.sequence]
        if previous is not None and previous!=p.payload:raise ValueError('conflicting duplicate')
        self.parts[p.sequence]=p.payload
    def missing(self):return [i for i,p in enumerate(self.parts) if p is None]
    def finish(self,expected_crc32):
        if self.missing():raise ValueError('incomplete frame')
        raw=b''.join(self.parts)
        if zlib.crc32(raw)!=expected_crc32:raise ValueError('frame CRC mismatch')
        return raw

