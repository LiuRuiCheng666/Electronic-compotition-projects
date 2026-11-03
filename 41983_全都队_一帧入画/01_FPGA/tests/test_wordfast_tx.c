#include "a_net_service.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
static uint8_t out[1408];static unsigned used,total,busy;
static int rd(void*c,uint32_t a,uint32_t*v){(void)c;*v=a==0?0x414e4d01u:a==4?busy?2u:0u:a==0x5c||a==0x60?1:0;return 0;}
static int wr(void*c,uint32_t a,uint32_t v){unsigned j;(void)c;if(a==0x50)total=v;if(a==0x54)for(j=0;j<4;j++)out[used++]=(uint8_t)(v>>(8*j));return 0;}
static uint32_t crc(uint32_t c,const uint8_t*b,unsigned n){unsigned i,j;for(i=0;i<n;i++){c^=b[i];for(j=0;j<8;j++)c=(c>>1)^(0xedb88320u&(0u-(c&1)));}return c;}
int main(void){a_net_mb_io io={0,rd,wr};a_net_mb_request peer;a_image_reply r;unsigned n,i;uint32_t c,wire;
memset(&peer,0,sizeof peer);memset(&r,0,sizeof r);peer.peer_ip=0xc0a80003;peer.peer_port=40000;r.op=0x26;r.session=17;r.sequence=29;r.offset=42;r.total=2764800;
for(n=0;n<=1368;n++){memset(out,0xcc,sizeof out);used=total=0;r.length=n;for(i=0;i<n;i++)r.payload[i]=(uint8_t)(i*37+n);
assert(a_net_mb_send(&io,&peer,&r)==A_MB_READY);assert(total==n+32&&used==((n+35)&~3u));assert(!memcmp(out,"ANET",4)&&!memcmp(out+32,r.payload,n));
c=~crc(crc(0xffffffff,out,28),r.payload,n);wire=(uint32_t)out[28]<<24|(uint32_t)out[29]<<16|(uint32_t)out[30]<<8|out[31];assert(c==wire);for(i=n+32;i<used;i++)assert(out[i]==0);assert(out[used]==0xcc);}
busy=1;used=0;assert(a_net_mb_send(&io,&peer,&r)==A_MB_BUSY&&used==0);puts("PASS: actual TX packing, lengths0..1368, exact CRC/padding and BUSY no writes");return 0;}

