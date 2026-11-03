/* Real portable session + production C callbacks. Every DDR/lease command
 * blocks on the actual ModelSim APB/CDC/DMA/NN RTL through a local pipe.
 * The only input/output files are tiny deterministic test images. */
#include "c_image_backend.h"
#include "a_net_service.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned rpc_count;
static int execute(void *unused,uint32_t q[8]){
 char line[256];unsigned i,v[8];(void)unused;rpc_count++;
 printf("RPC");for(i=0;i<8;i++)printf(" %08x",q[i]);putchar('\n');fflush(stdout);
 if(!fgets(line,sizeof(line),stdin))return A_IMG_IO;
 if(sscanf(line,"RSP %x %x %x %x %x %x %x %x",v,v+1,v+2,v+3,v+4,v+5,v+6,v+7)!=8)return A_IMG_IO;
 for(i=0;i<8;i++)q[i]=v[i];return 0;
}
static uint32_t crc(const uint8_t *p,unsigned n){
 uint32_t c=0xffffffffu;while(n--)c=a_net_crc32_byte(c,*p++);return ~c;
}
static void read_file(const char *path,uint8_t *p,unsigned n){
 FILE *f=fopen(path,"rb");assert(f);assert(fread(p,1,n,f)==n);assert(fgetc(f)==EOF);fclose(f);
}
static unsigned now_ms;
static a_image_session session;
static a_image_reply reply;
static void packet(unsigned op,unsigned seq,unsigned off,unsigned total,const uint8_t *p,unsigned n){
 a_image_packet q={(uint8_t)op,0x01020304u,seq,off,total,p,(uint16_t)n};
 assert(a_image_session_process(&session,0xc0a800039c41ull,&q,now_ms++,&reply));
}
static void control(unsigned op,unsigned seq,unsigned total,const uint8_t *p,unsigned n){
 unsigned i;
 for(i=0;i<2000;i++){
  packet(op,seq,0,total,p,n);assert(reply.op==A_IMG_ACK&&reply.length>=16);
  if(reply.payload[5]!=A_IMG_BUSY){assert(reply.payload[5]==A_IMG_OK);return;}
 }
 assert(!"control timeout");
}
int main(int argc,char **argv){
 uint8_t input[2304],gold[2304],output[2304],desc[32],commit[4],query[5];
 a_image_backend backend;c_image_context context;a_image_desc d,r;
 unsigned i,n,seq=1;uint32_t value;assert(argc==3);
 read_file(argv[1],input,sizeof(input));read_file(argv[2],gold,sizeof(gold));
 c_image_backend_init(&context,execute,0,32,24,&backend);a_image_session_init(&session,&backend);
 d.width=32;d.height=24;d.format=1;d.style=0;d.stride=96;d.total=sizeof(input);d.crc32=crc(input,sizeof(input));
 a_image_desc_encode(&d,desc);control(A_IMG_BEGIN,seq++,d.total,desc,32);
 for(i=0;i<d.total;i+=A_IMG_CHUNK){
  n=d.total-i;if(n>A_IMG_CHUNK)n=A_IMG_CHUNK;
  packet(A_IMG_DATA,i/A_IMG_CHUNK,i,d.total,input+i,n);assert(reply.payload[5]==0);
  packet(A_IMG_DATA,i/A_IMG_CHUNK,i,d.total,input+i,n);assert(reply.payload[5]==0);
 }
 commit[0]=(uint8_t)(d.crc32>>24);commit[1]=(uint8_t)(d.crc32>>16);commit[2]=(uint8_t)(d.crc32>>8);commit[3]=(uint8_t)d.crc32;
 control(A_IMG_COMMIT,seq++,d.total,commit,4);query[0]=0;
 for(i=0;i<2000;i++){
  control(A_IMG_STATUS,seq++,0,query,1);
  if(session.phase==A_IMG_READY)break;
  assert(session.phase==A_IMG_RUNNING);
 }
 assert(i<2000&&reply.length==48&&a_image_desc_decode(reply.payload+16,32,&r));
 assert(r.width==32&&r.height==24&&r.total==2304&&r.format==1&&r.crc32==crc(gold,sizeof(gold)));
 for(i=0;i<r.total;i+=A_IMG_CHUNK){
  value=i/A_IMG_CHUNK;query[0]=1;query[1]=(uint8_t)(value>>24);query[2]=(uint8_t)(value>>16);query[3]=(uint8_t)(value>>8);query[4]=(uint8_t)value;
  packet(A_IMG_STATUS,seq++,0,0,query,5);assert(reply.op==A_IMG_RESULT&&reply.offset==i);
  n=r.total-i;if(n>A_IMG_CHUNK)n=A_IMG_CHUNK;assert(reply.length==n);memcpy(output+i,reply.payload,n);
 }
 assert(!memcmp(output,gold,sizeof(gold)));query[0]=2;control(A_IMG_STATUS,seq++,0,query,1);
 assert(session.phase==A_IMG_IDLE);
 printf("PASS actual_C_RTL_NN_roundtrip bytes=2304 crc=%08x rpc=%u\n",crc(output,sizeof(output)),rpc_count);fflush(stdout);
 return 0;
}
