#include "image_backend_fixture.h"
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static a_image_session s;static a_image_reply r;
static uint8_t image[6144],desc_bytes[32],crc_bytes[4];
static uint32_t now=100,sid=123;
static void sendp(uint64_t peer,uint8_t op,uint32_t seq,uint32_t off,uint32_t total,const uint8_t *p,uint16_t n){
 a_image_packet q={op,sid,seq,off,total,p,n};CHECK(a_image_session_process(&s,peer,&q,now++,&r));
}
static unsigned status(void){CHECK(r.op==A_IMG_ACK&&r.length>=16&&!memcmp(r.payload,"ACK1",4));return r.payload[5];}
static void begin(uint32_t crc){
 a_image_desc d={64,32,1,2,192,6144,crc};a_image_desc_encode(&d,desc_bytes);
 crc_bytes[0]=(uint8_t)(crc>>24);crc_bytes[1]=(uint8_t)(crc>>16);crc_bytes[2]=(uint8_t)(crc>>8);crc_bytes[3]=(uint8_t)crc;
 sendp(7,A_IMG_BEGIN,0xffffff00u,0,sizeof(image),desc_bytes,32);
}
static void chunk(unsigned i){
 uint32_t off=i*A_IMG_CHUNK;uint16_t n=(uint16_t)(sizeof(image)-off>A_IMG_CHUNK?A_IMG_CHUNK:sizeof(image)-off);
 sendp(7,A_IMG_DATA,i,off,sizeof(image),image+off,n);
}
static void commit(void){sendp(7,A_IMG_COMMIT,0xffffff01u,0,sizeof(image),crc_bytes,4);}
int main(void){
 a_image_backend b=fixture_backend();a_image_desc d;uint8_t selector[5]={0};unsigned i;uint32_t good_crc,g;
 for(i=0;i<sizeof(image);i++)image[i]=(uint8_t)(i*19u);good_crc=fixture_crc(image,sizeof(image));
 a_image_session_init(&s,&b);begin(good_crc);CHECK(status()==A_IMG_OK&&reserve_count==1);g=s.generation;
 begin(good_crc);CHECK(status()==A_IMG_OK&&reserve_count==1);
 desc_bytes[9]=3;sendp(7,A_IMG_BEGIN,9,0,sizeof(image),desc_bytes,32);CHECK(status()==A_IMG_CONFLICT);desc_bytes[9]=2;
 sendp(8,A_IMG_DATA,0,0,sizeof(image),image,A_IMG_CHUNK);CHECK(status()==A_IMG_OWNER&&write_count==0);
 chunk(1);CHECK(status()==A_IMG_OK&&s.received==1);commit();CHECK(status()==A_IMG_INCOMPLETE&&submit_count==0);
 chunk(1);CHECK(status()==A_IMG_OK&&write_count==1);
 image[A_IMG_CHUNK]^=1;chunk(1);CHECK(status()==A_IMG_CONFLICT&&write_count==1);image[A_IMG_CHUNK]^=1;
 write_error=1;chunk(0);CHECK(status()==A_IMG_IO&&s.received==1);write_error=0;
 for(i=0;i<5;i++){chunk(i);CHECK(status()==A_IMG_OK);}CHECK(s.received==5&&write_count==5);
 sendp(7,A_IMG_DATA,5,6144,6144,image,1);CHECK(status()==A_IMG_RANGE);
 commit();CHECK(status()==A_IMG_OK&&submit_count==1&&s.phase==A_IMG_RUNNING);
 commit();CHECK(status()==A_IMG_OK&&submit_count==1);
 poll_busy=1;sendp(7,A_IMG_STATUS,10,0,0,selector,1);CHECK(status()==A_IMG_OK&&s.phase==A_IMG_RUNNING);
 sendp(7,A_IMG_STATUS,11,0,0,selector,1);CHECK(status()==A_IMG_OK&&s.phase==A_IMG_READY&&r.length==48);
 CHECK(a_image_desc_decode(r.payload+16,32,&d)&&d.crc32==good_crc);
 /* A READY status must really poll the backend, not just return cached metadata. */
 poll_busy=1;sendp(7,A_IMG_STATUS,12,0,0,selector,1);CHECK(status()==A_IMG_OK&&poll_busy==0);
 CHECK(s.result_timeout_ms==8000);

 for(i=0;i<5;i++){
  selector[0]=1;selector[1]=(uint8_t)(i>>24);selector[2]=(uint8_t)(i>>16);selector[3]=(uint8_t)(i>>8);selector[4]=(uint8_t)i;
  sendp(7,A_IMG_STATUS,20+i,0,0,selector,5);CHECK(r.op==A_IMG_RESULT&&r.sequence==i&&r.offset==i*A_IMG_CHUNK&&!memcmp(r.payload,image+r.offset,r.length));
 }
 selector[0]=2;release_busy=2;sendp(7,A_IMG_STATUS,40,0,0,selector,1);CHECK(status()==A_IMG_BUSY&&s.generation==g&&s.phase==A_IMG_RELEASING);
 a_image_session_tick(&s,now++);CHECK(s.phase==A_IMG_RELEASING);
 sendp(7,A_IMG_STATUS,40,0,0,selector,1);CHECK(status()==A_IMG_OK&&s.phase==A_IMG_IDLE&&release_count==1);
 sendp(7,A_IMG_STATUS,40,0,0,selector,1);CHECK(status()==A_IMG_OK&&release_count==1);
 begin(good_crc);CHECK(status()==A_IMG_CONFLICT);
 sid++;begin(good_crc^1u);CHECK(status()==A_IMG_OK);for(i=0;i<5;i++)chunk(i);commit();CHECK(status()==A_IMG_CRC&&submit_count==1);
 sendp(7,A_IMG_ABORT,50,0,0,0,0);CHECK(status()==A_IMG_OK&&s.phase==A_IMG_IDLE);
 sendp(7,A_IMG_ABORT,50,0,0,0,0);CHECK(status()==A_IMG_OK);
 sid++;now=0xfffffff0u;begin(good_crc);CHECK(status()==A_IMG_OK);s.receive_timeout_ms=20;
 a_image_session_tick(&s,0x20u);CHECK(s.phase==A_IMG_IDLE&&s.terminal_status==A_IMG_TIMEOUT);
 sid++;now=100;begin(good_crc);CHECK(status()==A_IMG_OK);for(i=0;i<5;i++)chunk(i);commit();CHECK(submit_count==2);
 release_busy=1;sendp(7,A_IMG_ABORT,70,0,0,0,0);CHECK(status()==A_IMG_BUSY&&s.phase==A_IMG_RELEASING);
 a_image_session_tick(&s,now++);CHECK(s.phase==A_IMG_IDLE);
 sid++;begin(good_crc);CHECK(status()==A_IMG_OK);for(i=0;i<5;i++)chunk(i);commit();
 selector[0]=0;sendp(7,A_IMG_STATUS,80,0,0,selector,1);CHECK(s.phase==A_IMG_READY);
 a_image_session_tick(&s,s.last_activity+8000);CHECK(s.phase==A_IMG_IDLE&&s.terminal_status==A_IMG_TIMEOUT);
 /* Control replays do not extend a receive lease without DATA progress. */
 s.receive_timeout_ms=3000;sid++;now=10000;begin(good_crc);CHECK(s.phase==A_IMG_RECEIVING);g=s.last_activity;
 now=g+1000;begin(good_crc);CHECK(status()==A_IMG_OK&&s.last_activity==g);
 selector[0]=0;sendp(7,A_IMG_STATUS,90,0,0,selector,1);CHECK(status()==A_IMG_OK&&s.last_activity==g);
 a_image_session_tick(&s,g+3000);CHECK(s.phase==A_IMG_IDLE&&s.terminal_status==A_IMG_TIMEOUT);
 /* Duplicate COMMIT acknowledges the same task without extending its deadline. */
 sid++;now=20000;begin(good_crc);for(i=0;i<5;i++)chunk(i);commit();CHECK(s.phase==A_IMG_RUNNING);g=s.last_activity;
 now=g+1000;commit();CHECK(status()==A_IMG_OK&&s.last_activity==g);
 a_image_session_tick(&s,g+10000);CHECK(s.phase==A_IMG_IDLE&&s.terminal_status==A_IMG_TIMEOUT);
 {a_image_session unbound;a_image_packet cap={A_IMG_STATUS,999,1,0,0,(const uint8_t *)"CAP1",4};
  a_image_session_init(&unbound,0);CHECK(a_image_session_process(&unbound,7,&cap,now,&r));
  CHECK(status()==A_IMG_OK&&r.payload[6]==0x80&&r.payload[8]==0&&r.payload[9]==0&&r.payload[10]==0&&r.payload[11]==0);}
 desc_bytes[10]=1;CHECK(!a_image_desc_decode(desc_bytes,32,&d));desc_bytes[10]=0;
 desc_bytes[12]=255;CHECK(!a_image_desc_decode(desc_bytes,32,&d));
 printf("PASS: image session ownership, out-of-order chunks, idempotent BEGIN/DATA/COMMIT/release, conflicting duplicates, IO/CRC/missing/bounds rejection, result lock, busy drain, cancel and wrapping timeout; context_bytes=%u\n",(unsigned)sizeof(s));
 return 0;
}
