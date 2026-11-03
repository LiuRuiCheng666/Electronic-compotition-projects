#include "a_image_session.h"
#include <string.h>
static uint16_t be16(const uint8_t *p){return (uint16_t)(((uint16_t)p[0]<<8)|p[1]);}
static uint32_t be32(const uint8_t *p){return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];}
static void put16(uint8_t *p,uint16_t n){p[0]=(uint8_t)(n>>8);p[1]=(uint8_t)n;}
static void put32(uint8_t *p,uint32_t n){p[0]=(uint8_t)(n>>24);p[1]=(uint8_t)(n>>16);p[2]=(uint8_t)(n>>8);p[3]=(uint8_t)n;}
static int valid_desc(const a_image_desc *d){
 uint32_t bpp=d->format==1?3u:(d->format==2||d->format==3)?4u:0u;
 return bpp && d->width && d->width<=1280 && d->height && d->height<=720 && d->style<5 &&
  d->stride>=(uint32_t)d->width*bpp && d->stride<=A_IMG_MAX_BYTES/d->height &&
  d->total==d->stride*d->height && d->total && d->total<=A_IMG_MAX_BYTES;
}
int a_image_desc_decode(const uint8_t *p,uint16_t n,a_image_desc *d){
 if(!p||!d||n!=32||memcmp(p,"IMG1",4)||be16(p+10)||be16(p+24)!=A_IMG_CHUNK||be16(p+26)||be32(p+28))return 0;
 d->width=be16(p+4);d->height=be16(p+6);d->format=p[8];d->style=p[9];
 d->stride=be32(p+12);d->total=be32(p+16);d->crc32=be32(p+20);return valid_desc(d);
}
void a_image_desc_encode(const a_image_desc *d,uint8_t p[32]){
 memset(p,0,32);memcpy(p,"IMG1",4);put16(p+4,d->width);put16(p+6,d->height);p[8]=d->format;p[9]=d->style;
 put32(p+12,d->stride);put32(p+16,d->total);put32(p+20,d->crc32);put16(p+24,A_IMG_CHUNK);
}
static int equal_desc(const a_image_desc *a,const a_image_desc *b){
 return a->width==b->width&&a->height==b->height&&a->format==b->format&&a->style==b->style&&
  a->stride==b->stride&&a->total==b->total&&a->crc32==b->crc32;
}
static void ack(const a_image_packet *p,a_image_reply *r,unsigned status,uint32_t detail,uint32_t generation){
 r->op=A_IMG_ACK;r->session=p->session;r->sequence=p->sequence;r->offset=p->offset;r->total=p->total;r->length=16;
 memcpy(r->payload,"ACK1",4);r->payload[4]=p->op;r->payload[5]=(uint8_t)status;
 put16(r->payload+6,0);put32(r->payload+8,detail);put32(r->payload+12,generation);
}
void a_image_session_init(a_image_session *s,const a_image_backend *b){
 memset(s,0,sizeof(*s));if(b)s->io=*b;
 s->receive_timeout_ms=3000;s->run_timeout_ms=10000;s->result_timeout_ms=8000;
}
static void drain(a_image_session *s){
 if(s->phase==A_IMG_RELEASING && s->io.release && s->io.release(s->io.user,s->generation,s->release_cancel)==0){
  s->last_session=s->session;s->last_peer=s->peer;s->last_generation=s->generation;s->have_last=1;
  s->phase=A_IMG_IDLE;s->generation=0;s->received=0;
 }
}
void a_image_session_tick(a_image_session *s,uint32_t now){
 uint32_t limit=0;if(!s)return;
 if(s->phase==A_IMG_RECEIVING)limit=s->receive_timeout_ms;
 else if(s->phase==A_IMG_RUNNING)limit=s->run_timeout_ms;
 else if(s->phase==A_IMG_READY||s->phase==A_IMG_FAULT)limit=s->result_timeout_ms;
 if(limit && (uint32_t)(now-s->last_activity)>=limit){s->terminal_status=A_IMG_TIMEOUT;s->phase=A_IMG_RELEASING;s->release_cancel=1;}
 drain(s);
}
int a_image_session_process(a_image_session *s,uint64_t peer,const a_image_packet *p,uint32_t now,a_image_reply *r){
 a_image_desc d;uint32_t i,off,remaining;uint16_t n;int rc;
 if(!s||!p||!r||p->length>A_IMG_CHUNK||(p->length&&!p->payload))return 0;
 a_image_session_tick(s,now);ack(p,r,A_IMG_OK,s->phase,s->generation);
 /* HELLO is compatible with the existing diagnostic endpoint, not typed ACK1. */
 if(p->op==A_IMG_HELLO){
#ifdef A_NET_DIRECT_RX_BASE
  /* Physical endpoint handles full-size HELLO in hardware. The CPU keeps
   * only a 32-byte control cache; never echo past that cache if misrouted. */
  if(p->length>32u){ack(p,r,A_IMG_UNSUPPORTED,0,0);return 1;}
#endif
  if(p->offset||p->total){ack(p,r,A_IMG_FORMAT,0,0);return 1;}
  r->length=p->length;if(p->length)memcpy(r->payload,p->payload,p->length);return 1;
 }
 if(p->op==A_IMG_STATUS && p->length==4 && !memcmp(p->payload,"CAP1",4)){
  if(p->offset||p->total){ack(p,r,A_IMG_FORMAT,0,0);return 1;}
  /* Capability query is not a keepalive and never grants buffer access. */
  i=s->io.reserve&&s->io.write&&s->io.compare&&s->io.submit&&s->io.poll&&s->io.read&&s->io.release?15u:0u;
  ack(p,r,A_IMG_OK,i,0);put16(r->payload+6,0x8000);return 1;
 }
 if(p->op==A_IMG_BEGIN){
  if(!p->session||p->offset||!a_image_desc_decode(p->payload,p->length,&d)||p->total!=d.total){ack(p,r,A_IMG_FORMAT,0,0);return 1;}
  if(s->phase!=A_IMG_IDLE){
   if(peer==s->peer&&p->session==s->session&&equal_desc(&d,&s->input)&&s->phase!=A_IMG_RELEASING){return 1;}
   ack(p,r,(peer==s->peer&&p->session==s->session)?A_IMG_CONFLICT:A_IMG_BUSY,s->phase,0);return 1;
  }
  if(s->have_last&&p->session==s->last_session){ack(p,r,A_IMG_CONFLICT,0,0);return 1;}
  if(!s->io.reserve||!s->io.write||!s->io.compare||!s->io.submit||!s->io.poll||!s->io.read||!s->io.release){ack(p,r,A_IMG_UNSUPPORTED,0,0);return 1;}
  i=0;rc=s->io.reserve(s->io.user,&d,&i);
  if(rc||!i){ack(p,r,rc>0?(unsigned)rc:A_IMG_IO,0,0);return 1;}
  s->input=d;s->generation=i;s->session=p->session;s->peer=peer;s->received=0;s->last_activity=now;
  s->total_chunks=(d.total+A_IMG_CHUNK-1u)/A_IMG_CHUNK;memset(s->bitmap,0,sizeof(s->bitmap));
  s->phase=A_IMG_RECEIVING;s->terminal_status=A_IMG_OK;ack(p,r,A_IMG_OK,s->phase,s->generation);return 1;
 }
 if(s->phase==A_IMG_IDLE){
  if(s->have_last&&peer==s->last_peer&&p->session==s->last_session&&!p->offset&&!p->total&&
    ((p->op==A_IMG_ABORT&&!p->length)||(p->op==A_IMG_STATUS&&p->length==1&&p->payload[0]==2))){
   ack(p,r,A_IMG_OK,A_IMG_IDLE,s->last_generation);return 1;
  }
  ack(p,r,A_IMG_STATE,A_IMG_IDLE,0);return 1;
 }
 if(peer!=s->peer||p->session!=s->session){ack(p,r,A_IMG_OWNER,0,0);return 1;}
 if(p->op==A_IMG_ABORT){
  if(p->length||p->offset||p->total){ack(p,r,A_IMG_FORMAT,0,s->generation);return 1;}
  s->release_cancel=1;s->phase=A_IMG_RELEASING;drain(s);
  ack(p,r,s->phase==A_IMG_IDLE?A_IMG_OK:A_IMG_BUSY,s->phase,s->phase==A_IMG_IDLE?s->last_generation:s->generation);return 1;
 }
 if(s->phase==A_IMG_RELEASING){ack(p,r,A_IMG_BUSY,s->phase,s->generation);return 1;}
 if(p->op==A_IMG_DATA){
  if(s->phase!=A_IMG_RECEIVING){ack(p,r,A_IMG_STATE,s->phase,s->generation);return 1;}
  off=p->offset;
  if(p->total!=s->input.total||off>=p->total||off%A_IMG_CHUNK||p->sequence!=off/A_IMG_CHUNK){ack(p,r,A_IMG_RANGE,0,s->generation);return 1;}
  remaining=p->total-off;n=(uint16_t)(remaining<A_IMG_CHUNK?remaining:A_IMG_CHUNK);i=off/A_IMG_CHUNK;
  if(p->length!=n){ack(p,r,A_IMG_RANGE,0,s->generation);return 1;}
  if(s->bitmap[i/8]&(1u<<(i%8))){
   rc=s->io.compare(s->io.user,s->generation,off,p->payload,n);
   if(rc!=1){ack(p,r,rc<0?A_IMG_IO:A_IMG_CONFLICT,s->received,s->generation);return 1;}
  }else{
   rc=s->io.write(s->io.user,s->generation,off,p->payload,n);
   if(rc){ack(p,r,rc>0?(unsigned)rc:A_IMG_IO,s->received,s->generation);return 1;}
   s->bitmap[i/8]|=(uint8_t)(1u<<(i%8));s->received++;
  }
  s->last_activity=now;ack(p,r,A_IMG_OK,s->received,s->generation);return 1;
 }
 if(p->op==A_IMG_COMMIT){
  if(p->offset||p->total!=s->input.total||p->length!=4||be32(p->payload)!=s->input.crc32){ack(p,r,A_IMG_FORMAT,0,s->generation);return 1;}
  if(s->phase==A_IMG_RUNNING||s->phase==A_IMG_READY){return 1;}
  if(s->phase!=A_IMG_RECEIVING){ack(p,r,A_IMG_STATE,s->phase,s->generation);return 1;}
  if(s->received!=s->total_chunks){ack(p,r,A_IMG_INCOMPLETE,s->total_chunks-s->received,s->generation);return 1;}
  rc=s->io.submit(s->io.user,s->generation,s->input.crc32);
  if(rc){ack(p,r,rc>0?(unsigned)rc:A_IMG_IO,0,s->generation);return 1;}
  s->phase=A_IMG_RUNNING;s->last_activity=now;ack(p,r,A_IMG_OK,s->phase,s->generation);return 1;
 }
 if(p->op==A_IMG_STATUS){
  if(p->offset||p->total||p->length<1){ack(p,r,A_IMG_FORMAT,0,s->generation);return 1;}
  if(p->payload[0]==0&&p->length==1){
   /* READY status must renew and validate the actual hardware result lease. */
   if(s->phase==A_IMG_RUNNING||s->phase==A_IMG_READY){
    rc=s->io.poll(s->io.user,s->generation,&d);
    if(rc<0){s->phase=A_IMG_FAULT;ack(p,r,A_IMG_IO,s->phase,s->generation);return 1;}
    if(rc==1){if(!valid_desc(&d)){s->phase=A_IMG_FAULT;ack(p,r,A_IMG_FORMAT,s->phase,s->generation);return 1;}s->result=d;s->phase=A_IMG_READY;}
    s->last_activity=now;
   }
   /* Receiving status/BEGIN replays are not upload progress or keepalive. */
   ack(p,r,A_IMG_OK,s->phase,s->generation);
   if(s->phase==A_IMG_READY){put16(r->payload+6,1);a_image_desc_encode(&s->result,r->payload+16);r->length=48;}
   return 1;
  }
  if(p->payload[0]==1&&p->length==5){
   if(s->phase!=A_IMG_READY){ack(p,r,A_IMG_NOT_READY,s->phase,s->generation);return 1;}
   i=be32(p->payload+1);
   if(i>=(s->result.total+A_IMG_CHUNK-1u)/A_IMG_CHUNK){ack(p,r,A_IMG_RANGE,0,s->generation);return 1;}
   off=i*A_IMG_CHUNK;remaining=s->result.total-off;n=(uint16_t)(remaining<A_IMG_CHUNK?remaining:A_IMG_CHUNK);
   rc=s->io.read(s->io.user,s->generation,off,r->payload,n);
   if(rc){ack(p,r,rc>0?(unsigned)rc:A_IMG_IO,0,s->generation);return 1;}
   r->op=A_IMG_RESULT;r->sequence=i;r->offset=off;r->total=s->result.total;r->length=n;s->last_activity=now;return 1;
  }
  if(p->payload[0]==2&&p->length==1){
   if(s->phase!=A_IMG_READY){ack(p,r,A_IMG_STATE,s->phase,s->generation);return 1;}
   s->release_cancel=0;s->phase=A_IMG_RELEASING;drain(s);
   ack(p,r,s->phase==A_IMG_IDLE?A_IMG_OK:A_IMG_BUSY,s->phase,s->phase==A_IMG_IDLE?s->last_generation:s->generation);return 1;
  }
  ack(p,r,A_IMG_FORMAT,0,s->generation);return 1;
 }
 ack(p,r,A_IMG_UNSUPPORTED,0,s->generation);return 1;
}
