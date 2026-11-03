#include "a_net_service.h"
#include <string.h>
static int rd(const a_net_mb_io *io,uint32_t a,uint32_t *v){return !io||!io->read||io->read(io->context,a,v)?A_MB_IO:0;}
static int wr(const a_net_mb_io *io,uint32_t a,uint32_t v){return !io||!io->write||io->write(io->context,a,v)?A_MB_IO:0;}
static int abi(const a_net_mb_io *io){uint32_t v;if(rd(io,0,&v))return A_MB_IO;return v==0x414e4d01u?0:A_MB_ABI;}
static void put16(uint8_t *p,uint16_t n){p[0]=(uint8_t)(n>>8);p[1]=(uint8_t)n;}
static void put32(uint8_t *p,uint32_t n){p[0]=(uint8_t)(n>>24);p[1]=(uint8_t)(n>>16);p[2]=(uint8_t)(n>>8);p[3]=(uint8_t)n;}
uint32_t a_net_crc32_byte(uint32_t c,uint8_t b){
 static const uint32_t table[16]={0,0x1db71064u,0x3b6e20c8u,0x26d930acu,0x76dc4190u,0x6b6b51f4u,0x4db26158u,0x5005713cu,
  0xedb88320u,0xf00f9344u,0xd6d6a3e8u,0xcb61b38cu,0x9b64c2b0u,0x86d3d2d4u,0xa00ae278u,0xbdbdf21cu};
 c^=b;c=(c>>4)^table[c&15];return (c>>4)^table[c&15];
}
static int read_payload(const a_net_mb_io *io,uint8_t *out,uint32_t n){
 uint32_t i,j,word;
 for(i=0;i<n;i+=4){
  if(rd(io,0x800+i,&word))return A_MB_IO;
  for(j=0;j<4&&i+j<n;j++)out[i+j]=(uint8_t)(word>>(j*8));
 }
 return 0;
}
int a_net_mb_receive(const a_net_mb_io *io,a_net_mb_request *r){
 uint32_t v,token,stat,lo,hi;int rc=abi(io);
 if(rc)return rc;
 if(!r)return A_MB_RANGE;
 if(rd(io,4,&stat))return A_MB_IO;
 if(!(stat&1))return A_MB_NONE;
 if(rd(io,8,&token)||!token)return A_MB_IO;
 if(rd(io,0x10,&r->peer_ip)||rd(io,0x14,&v))return A_MB_IO;
 r->peer_port=(uint16_t)v;
 if(rd(io,0x18,&v))return A_MB_IO;
 r->packet.op=(uint8_t)v;r->packet.length=(uint16_t)(v>>16);
 if(r->packet.length>A_IMG_CHUNK)return A_MB_RANGE;
 if(rd(io,0x1c,&r->packet.session)||rd(io,0x20,&r->packet.sequence)||rd(io,0x24,&r->packet.offset)||rd(io,0x28,&r->packet.total)||rd(io,0x2c,&lo)||rd(io,0x30,&hi))return A_MB_IO;
 r->peer_mac=((uint64_t)(hi&0xffffu)<<32)|lo;
#ifdef A_NET_DIRECT_RX_BASE
 if(r->packet.op!=A_IMG_DATA)
#endif
 if(read_payload(io,r->payload,r->packet.length<sizeof(r->payload)?r->packet.length:sizeof(r->payload)))return A_MB_IO;
 if(rd(io,4,&stat)||rd(io,8,&v))return A_MB_IO;
 if(!(stat&1)||v!=token)return A_MB_STALE;
 r->token=token;r->packet.payload=r->payload;
#ifdef A_NET_DIRECT_RX_BASE
 if(r->packet.op==A_IMG_DATA)r->packet.payload=(const uint8_t *)(uintptr_t)A_NET_DIRECT_RX_BASE;
#endif
 return A_MB_READY;
}
int a_net_mb_release(const a_net_mb_io *io,uint32_t token){
 uint32_t stat,current,last;int rc=abi(io);if(rc)return rc;if(!token)return A_MB_RANGE;
 if(rd(io,0x34,&last))return A_MB_IO;
 if(last==token)return A_MB_READY;
 if(rd(io,4,&stat)||rd(io,8,&current))return A_MB_IO;
 if(!(stat&1)||current!=token)return A_MB_STALE;
 if(wr(io,0x0c,token))return A_MB_IO;
 if(rd(io,0x34,&last))return A_MB_IO;
 return last==token?A_MB_READY:A_MB_BUSY;
}
int a_net_mb_take_events(const a_net_mb_io *io,uint32_t *errors,uint32_t *done_token){
 uint32_t stat;int rc=abi(io);
 if(rc)return rc;
 if(!errors||!done_token)return A_MB_RANGE;
 *errors=0;*done_token=0;
 if(rd(io,4,&stat))return A_MB_IO;
 if(stat&8){if(rd(io,0x60,done_token)||wr(io,0x68,1))return A_MB_IO;}
 if(stat&16){if(rd(io,0x64,errors)||wr(io,0x64,*errors))return A_MB_IO;}
 return stat&24?A_MB_READY:A_MB_NONE;
}
int a_net_mb_send(const a_net_mb_io *io,const a_net_mb_request *peer,const a_image_reply *r){
 uint8_t header[32];uint32_t stat,token,done_token,c=0xffffffffu,i,j,word,n;int rc=abi(io);
 if(rc)return rc;
 if(!peer||!r||r->length>A_IMG_CHUNK)return A_MB_RANGE;
 if(rd(io,4,&stat))return A_MB_IO;
 if(stat&2)return A_MB_BUSY;
 memset(header,0,sizeof(header));memcpy(header,"ANET",4);header[4]=1;header[5]=r->op;
 put32(header+8,r->session);put32(header+12,r->sequence);put32(header+16,r->offset);put32(header+20,r->total);put16(header+24,r->length);
 for(i=0;i<28;i++)c=a_net_crc32_byte(c,header[i]);
 for(i=0;i<r->length;i++)c=a_net_crc32_byte(c,r->payload[i]);
 put32(header+28,c^0xffffffffu);
 n=32u+r->length;
 if(wr(io,0x40,peer->peer_ip)||wr(io,0x44,peer->peer_port)||wr(io,0x48,(uint32_t)peer->peer_mac)||wr(io,0x4c,(uint32_t)(peer->peer_mac>>32))||wr(io,0x50,n)||rd(io,0x5c,&token)||!token)return A_MB_IO;
 #ifdef A_NET_DIRECT_TX_FIFO
 __asm__ volatile("fence iorw,iorw":::"memory");
 #endif
 for(i=0;i<n;i+=4){
  if(i+4<=n){
   /* memcpy permits unaligned byte buffers; RV32 compiler selects safe
    * loads. Header/payload boundary32 is also word aligned. */
   memcpy(&word,i<32?header+i:r->payload+i-32,4);
  }else{
   word=0;for(j=0;j<4&&i+j<n;j++)word|=(uint32_t)r->payload[i+j-32]<<(j*8);
  }
 #ifdef A_NET_DIRECT_TX_FIFO
  *(volatile uint32_t *)A_NET_DIRECT_TX_FIFO=word;
 #else
  if(wr(io,0x54,word))return A_MB_IO;
 #endif
 }
 #ifdef A_NET_DIRECT_TX_FIFO
 __asm__ volatile("fence iorw,iorw":::"memory");
 #endif
 if(wr(io,0x58,token)||rd(io,4,&stat)||rd(io,0x60,&done_token))return A_MB_IO;
 /* Queued in immutable TX RAM is distinct from delivery or NN completion. */
 return (stat&2)||done_token==token?A_MB_READY:A_MB_IO;
}
int a_net_service_init(a_net_service *s,const a_net_mb_io *io,const a_image_backend *backend){
 int rc;if(!s||!io)return A_MB_RANGE;rc=abi(io);if(rc)return rc;
 memset(s,0,sizeof(*s));s->io=*io;a_image_session_init(&s->session,backend);return 0;
}
int a_net_service_poll(a_net_service *s,uint32_t now){
 int rc;uint64_t owner;uint32_t error_bits,done_token;
 if(!s)return A_MB_RANGE;
 a_image_session_tick(&s->session,now);
 rc=a_net_mb_take_events(&s->io,&error_bits,&done_token);
 if(rc<0)return rc;
 if(done_token)s->last_done_token=done_token;
 s->last_errors|=error_bits;
 if(error_bits)return A_MB_IO;
 if(!s->pending){
  rc=a_net_mb_receive(&s->io,&s->request);if(rc!=A_MB_READY)return rc;
  owner=((uint64_t)s->request.peer_ip<<16)|s->request.peer_port;
  if(!a_image_session_process(&s->session,owner,&s->request.packet,now,&s->reply))return A_MB_RANGE;
#ifdef A_NET_DIRECT_RX_BASE
  /* Echo large diagnostics through the existing reply buffer. Keep the RX
   * token until TX commit; every RX access remains aligned and 32-bit. */
  if(s->request.packet.op==A_IMG_HELLO && !s->request.packet.offset && !s->request.packet.total && s->request.packet.length>sizeof(s->request.payload)){
   if(read_payload(&s->io,s->reply.payload,s->request.packet.length))return A_MB_IO;
   s->reply.length=s->request.packet.length;
  }
#endif
  s->pending=1;
 }
 if(s->pending==1){rc=a_net_mb_send(&s->io,&s->request,&s->reply);if(rc!=A_MB_READY)return rc;s->pending=2;}
 rc=a_net_mb_release(&s->io,s->request.token);if(rc==A_MB_READY)s->pending=0;return rc;
}
