/* Actual C backend against a bounded register/DDR fixture. The tiny output
 * pattern below is NOT an NN model; actual NN RTL has separate integer tests. */
#include "c_image_backend.h"
#include "a_net_service.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#ifdef A_NET_DIRECT_RX_BASE
#include <windows.h>
#endif
static uint8_t raw[0x400000],result[2764816],original[0x400000];
static uint32_t gen=0x80000000u,phase,last_gen,pixels,input_bytes,format;
static unsigned reads,writes,submits,releases,commands,fail_read,fail_write,busy_submit,polls,hold_release;
static const uint8_t *wire_payload(const uint8_t *src,uint32_t n,unsigned skip){
#ifdef A_NET_DIRECT_RX_BASE
 uint8_t *p=(uint8_t *)(uintptr_t)A_NET_DIRECT_RX_BASE;
 assert(n+skip<=A_IMG_CHUNK);memcpy(p+skip,src,n);return p+skip;
#else
 (void)n;(void)skip;return src;
#endif
}
static uint32_t reference_crc(const uint8_t *b,uint32_t n){
 uint32_t c=0xffffffffu,i,j;for(i=0;i<n;i++){c^=b[i];for(j=0;j<8;j++)c=(c>>1)^(0xedb88320u&(0u-(c&1u)));}return ~c;
}
static int execute(void *unused,uint32_t q[8]){
 uint32_t op=q[0],g=q[1],off=q[2],mask=q[3],i;uint8_t *b=(uint8_t *)(q+4);int rc=0;
 (void)unused;commands++;
 if(op==0){if(!phase){phase=2;rc=A_IMG_BUSY;}else if(phase!=2)rc=A_IMG_BUSY;}
 else if(op==1){if(phase!=2)rc=A_IMG_BUSY;else{phase=3;++gen;}}
 else if(g!=gen)rc=A_IMG_OWNER;
 else if(op==8||op==10){
  if((off&15u)||off+16u>(op==8?sizeof(raw):((pixels*3u+15u)&~15u)))rc=A_IMG_RANGE;
  else if(op==10&&phase!=6)rc=A_IMG_BUSY;
  else if(op==8&&phase!=3&&phase!=6)rc=A_IMG_BUSY;
  else if(++reads==fail_read)rc=A_IMG_IO;
  else memcpy(b,(op==8?raw:result)+off,16);
 }else if(op==9){
  if(phase!=3)rc=A_IMG_BUSY;
  else if((off&15u)||off+16u>sizeof(raw))rc=A_IMG_RANGE;
  else{
   ++writes;for(i=0;i<16;i++)if(mask&(1u<<i))raw[off+i]=b[i];
   if(writes==fail_write)rc=A_IMG_IO; /* Error may arrive after bytes committed. */
  }
 }else if(op==12||op==13){
  if(!off || (off&15u) || off>(op==13?pixels*3u:input_bytes))rc=A_IMG_RANGE;
  else if(op==13&&phase!=6)rc=A_IMG_BUSY;
  else if(++reads==fail_read)rc=A_IMG_IO;
  else{
   if(op==12&&mask)for(i=0;i<off;i++)if(raw[i]&((i&3u)==3u?255u:128u)){rc=A_IMG_FORMAT;break;}
   q[4]=reference_crc(op==13?result:raw,off);
  }
 }else if(op==2){
  if(phase==3){
   if(busy_submit){--busy_submit;rc=A_IMG_BUSY;}
   else{
    for(i=0;i<pixels;i++){
     unsigned k,bpp=format==1?3u:4u;
     for(k=0;k<3;k++)assert(raw[i*4+k]==(format==3?original[i*bpp+k]:(original[i*bpp+k]>>1)));
     assert(raw[i*4+3]==0);
     /* Deterministic fixture output only; exercises result bytes and CRC. */
     result[i*3]=(uint8_t)(255u-(raw[i*4]<<1));
     result[i*3+1]=(uint8_t)((raw[i*4+1]<<1)^0x55u);
     result[i*3+2]=(uint8_t)((raw[i*4+2]<<1)^0xaau);
    }
    phase=5;submits++;
   }
  }else if(phase!=5&&phase!=6)rc=A_IMG_STATE;
 }else if(op==11){if(phase==5&&++polls>=2)phase=6;}
 else if(op==3||op==4){
  if(phase==0&&last_gen==g)rc=0;
  else if(phase!=7){phase=7;rc=A_IMG_BUSY;}
  else if(hold_release)rc=A_IMG_BUSY;
  else{phase=0;last_gen=g;releases++;}
 }else rc=A_IMG_STATE;
 q[0]=(uint32_t)rc;q[1]=gen;q[2]=phase;q[3]=0;return 0;
}
static void init(c_image_context *ctx,a_image_backend *b,unsigned w,unsigned h,unsigned fmt,int bad_crc){
 uint32_t i,g=0;int rc; a_image_desc d;
 phase=last_gen=0;reads=writes=submits=releases=commands=fail_read=fail_write=busy_submit=polls=hold_release=0;
 pixels=w*h;format=fmt;input_bytes=pixels*(fmt==1?3u:4u);
 memset(raw,0xcd,sizeof(raw));memset(result,0xac,sizeof(result));
 for(i=0;i<input_bytes;i++)original[i]=(uint8_t)(i*37u+(i/3u)*11u+19u);
 if(fmt==3)for(i=0;i<input_bytes;i++)original[i]=(i&3u)==3u?0u:original[i]&127u;
 d.width=(uint16_t)w;d.height=(uint16_t)h;d.format=(uint8_t)fmt;d.style=2;
 d.stride=w*(fmt==1?3u:4u);d.total=input_bytes;d.crc32=reference_crc(original,input_bytes)+(bad_crc?1u:0u);
 c_image_backend_init(ctx,execute,0,(uint16_t)w,(uint16_t)h,b);
 assert(b->write(ctx,0,0,original,1)==A_IMG_STATE);
 assert(b->reserve(ctx,&d,&g)==A_IMG_BUSY);rc=b->reserve(ctx,&d,&g);
 assert(rc==0&&g==gen&&ctx->generation==gen);
}
static void upload(a_image_backend *b,c_image_context *ctx){
 uint32_t off,n;
 for(off=0;off<input_bytes;off+=1368u){
  n=input_bytes-off;if(n>1368u)n=1368u;
  assert(b->write(ctx,gen,off,wire_payload(original+off,n,0),(uint16_t)n)==0);
 }
 assert(!memcmp(raw,original,input_bytes));
 assert(b->compare(ctx,gen,0,wire_payload(original,input_bytes<31?input_bytes:31,3),(uint16_t)(input_bytes<31?input_bytes:31))==1);
 original[0]^=1;assert(b->compare(ctx,gen,0,wire_payload(original,1,1),1)==0);original[0]^=1;
 assert(b->write(ctx,gen+1,0,original,1)==A_IMG_OWNER);
 assert(b->write(ctx,gen,0xffffffffu,original,1)==A_IMG_RANGE);
}
static void release_all(a_image_backend *b,c_image_context *ctx){
 assert(b->release(ctx,gen,1)==1);hold_release=1;
 assert(b->release(ctx,gen,1)==1&&phase==7);hold_release=0;
 assert(b->release(ctx,gen,1)==0&&phase==0);
 assert(b->release(ctx,gen,1)==0&&releases==1);
 assert(b->write(ctx,gen,0,original,1)==A_IMG_STATE);
}
static void roundtrip(unsigned w,unsigned h,unsigned fmt){
 c_image_context ctx;a_image_backend b;a_image_desc d;uint8_t returned[1368];uint32_t off,n;unsigned before;
 init(&ctx,&b,w,h,fmt,0);upload(&b,&ctx);
 assert(b.read(&ctx,gen,0,returned,1)==A_IMG_NOT_READY);
 busy_submit=1;assert(b.submit(&ctx,gen,ctx.input.crc32)==A_IMG_BUSY);
 before=writes;assert(ctx.converted==1&&submits==0);
 assert(b.submit(&ctx,gen,ctx.input.crc32)==0&&writes==before&&submits==1);
 assert(b.submit(&ctx,gen,ctx.input.crc32)==0&&writes==before&&submits==1);
 assert(b.submit(&ctx,gen,ctx.input.crc32^1u)==A_IMG_CRC);
 assert(b.poll(&ctx,gen,&d)==0);assert(b.poll(&ctx,gen,&d)==1);
 assert(d.width==w&&d.height==h&&d.format==1&&d.style==2&&d.stride==w*3u&&d.total==pixels*3u);
 assert(d.crc32==reference_crc(result,d.total));before=reads;
 assert(b.poll(&ctx,gen,&d)==1&&reads==before);
 for(off=0;off<d.total;off+=1368u){
  n=d.total-off;if(n>1368u)n=1368u;
  assert(b.read(&ctx,gen,off,returned,(uint16_t)n)==0&&!memcmp(returned,result+off,n));
 }
 assert(b.read(&ctx,gen,d.total,returned,1)==A_IMG_RANGE);
 assert(raw[pixels*4u]==0xcd); /* No writes beyond the expanded RGBX image. */
 release_all(&b,&ctx);
 printf("PASS: C backend %ux%u fmt%u original CRC, reverse RGBX7, exactly-once submit, raw RGB8 result CRC/readback, release\n",w,h,fmt);
}
int main(void){
 c_image_context ctx;a_image_backend b;unsigned before;uint32_t c=0xffffffffu;const uint8_t *known=(const uint8_t *)"123456789";
#ifdef A_NET_DIRECT_RX_BASE
 assert(VirtualAlloc((void *)(uintptr_t)0xf8100000u,65536,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE)==(void *)(uintptr_t)0xf8100000u);
#endif
 for(before=0;before<9;before++)c=a_net_crc32_byte(c,known[before]);assert(~c==0xcbf43926u);
 for(before=1;before<=3;before++){
#ifndef A_NET_HW_CRC
  roundtrip(1,1,before);roundtrip(5,3,before);roundtrip(17,3,before);
#endif
  roundtrip(32,24,before);roundtrip(1280,720,before);
 }
 init(&ctx,&b,16,3,1,1);upload(&b,&ctx);before=writes;
 assert(b.submit(&ctx,gen,ctx.input.crc32)==A_IMG_CRC&&writes==before&&!memcmp(raw,original,input_bytes)&&submits==0);
 release_all(&b,&ctx);
 init(&ctx,&b,16,3,1,0);upload(&b,&ctx);fail_read=reads+1;
 assert(b.submit(&ctx,gen,ctx.input.crc32)==A_IMG_IO&&ctx.poisoned&&submits==0);before=commands;
 assert(b.submit(&ctx,gen,ctx.input.crc32)==A_IMG_IO&&commands==before);release_all(&b,&ctx);
 init(&ctx,&b,16,3,1,0);upload(&b,&ctx);fail_write=writes+2;
 assert(b.submit(&ctx,gen,ctx.input.crc32)==A_IMG_IO&&ctx.poisoned&&submits==0);before=commands;
 assert(b.submit(&ctx,gen,ctx.input.crc32)==A_IMG_IO&&commands==before);release_all(&b,&ctx);
 /* CRC-valid packed input with invalid lane bits must fail before submit. */
 for(before=0;before<2;before++){
  init(&ctx,&b,16,3,3,0);original[before?3:0]|=before?1u:128u;
  ctx.input.crc32=reference_crc(original,input_bytes);upload(&b,&ctx);
  assert(b.submit(&ctx,gen,ctx.input.crc32)==A_IMG_FORMAT&&submits==0);
  release_all(&b,&ctx);
 }
 puts("PASS: CRC-before-mutation, read/write fault poisoning, no retry conversion/replay, actual C callbacks with register/DDR fixture; NOT board or NN proof");
 return 0;
}
