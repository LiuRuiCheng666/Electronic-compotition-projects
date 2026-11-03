#include "c_image_backend.h"
#include <string.h>
static void payload_copy(uint8_t *dst,const uint8_t *src,uint32_t n){
#ifdef A_NET_DIRECT_RX_BASE
 uintptr_t address=(uintptr_t)src,last=~(uintptr_t)0;uint32_t word=0,i;
 if(address>=(uintptr_t)A_NET_DIRECT_RX_BASE&&address<(uintptr_t)A_NET_DIRECT_RX_BASE+A_IMG_CHUNK){
  /* Aligned full words are the normal DATA path. Alias-qualified stores
   * are valid for byte buffers; guard both pointers and the entire length.
   * The byte-lane fallback below retains partial/unaligned semantics. */
  if(!((address|(uintptr_t)dst|n)&3u)){
   typedef uint32_t alias_u32 __attribute__((may_alias));
   alias_u32 *d=(alias_u32 *)(void *)dst;
   const volatile uint32_t *s=(const volatile uint32_t *)address;
   for(i=0;i<n/4;i++)d[i]=s[i];
   return;
  }
  /* APB rejects unaligned byte accesses. Read each aligned word once and
   * select its byte lane; the RX token remains owned until reply/release. */
  for(i=0;i<n;i++){
   uintptr_t a=(address+i)&~(uintptr_t)3;
   if(a!=last){word=*(volatile uint32_t *)a;last=a;}
   dst[i]=(uint8_t)(word>>(((address+i)&3u)*8u));
  }
  return;
 }
#endif
 memcpy(dst,src,n);
}
static int call(c_image_context *c,uint32_t q[8]){
 int rc=c->execute(c->io,q);return rc?rc:(int)q[0];
}
static int control(c_image_context *c,uint32_t op,uint32_t generation,uint32_t arg,uint32_t q[8]){
 memset(q,0,32);q[0]=op;q[1]=generation;q[2]=arg;return call(c,q);
}
static int line(c_image_context *c,int result,int write,uint32_t off,uint8_t bytes[16],uint16_t mask){
 uint32_t q[8];q[0]=write?9u:result?10u:8u;q[1]=c->generation;q[2]=off;q[3]=mask;
 if(write)memcpy(q+4,bytes,16);
 if(call(c,q)){c->poisoned=1;return A_IMG_IO;}
 if(q[1]!=c->generation){c->poisoned=1;return A_IMG_IO;}
 if(!write)memcpy(bytes,q+4,16);
 return 0;
}
#ifdef A_NET_HW_CRC
static int crc(c_image_context *c,int result,uint32_t bytes,uint32_t *answer){
 uint32_t q[8]={0};int rc;
 q[0]=result?13u:12u;q[1]=c->generation;q[2]=bytes;q[3]=!result&&c->input.format==3;
 rc=call(c,q);
 if(rc==A_IMG_FORMAT)return rc;
 if(rc||q[1]!=c->generation){c->poisoned=1;return A_IMG_IO;}
 *answer=q[4];return 0;
}
#else
static int crc(c_image_context *c,int result,uint32_t bytes,uint32_t *answer){
 uint32_t off,n,i,v=0xffffffffu;uint8_t b[16];
 for(off=0;off<bytes;off+=16){
  if(line(c,result,0,off,b,0))return A_IMG_IO;
  n=bytes-off;if(n>16)n=16;
  /* Packed RGBX7 is an explicit negotiated transport format. Validate all
   * lanes before the NN may consume the image; do not trust host packing. */
  if(!result&&c->input.format==3){
   for(i=0;i<n;i++)if(b[i]&((i&3u)==3u?255u:128u))return A_IMG_FORMAT;
  }
  for(i=0;i<n;i++)v=a_net_crc32_byte(v,b[i]);
 }
 *answer=~v;return 0;
}
#endif
static int reserve(void *user,const a_image_desc *d,uint32_t *generation){
 c_image_context *c=user;uint32_t q[8],bpp=d->format==1?3u:(d->format==2||d->format==3)?4u:0u;int rc;
 if(!bpp||!c->width||c->width>1280||!c->height||c->height>720||d->width!=c->width||d->height!=c->height||d->style>=5||
    d->stride!=(uint32_t)d->width*bpp||d->total!=d->stride*d->height||d->total>0x400000u)return A_IMG_FORMAT;
 rc=control(c,0,0,0,q);if(rc)return rc;
 rc=control(c,1,0,d->style,q);if(rc)return rc;
 if(!q[1])return A_IMG_IO;
 c->input=*d;c->generation=q[1];c->converted=0;c->submitted=0;c->result_ready=0;c->poisoned=0;
 *generation=q[1];return 0;
}
/* One bounded byte mover avoids three duplicate alignment/RPC loops.
 * mode:0=compare upload,1=write upload,2=read completed result. */
static int __attribute__((noinline,noclone)) transfer(c_image_context *c,uint32_t generation,uint32_t off,uint8_t *data,uint16_t length,unsigned mode){
 uint8_t b[16],p[16];uint32_t n,low,total=mode==2?(uint32_t)c->width*c->height*3u:c->input.total;
 if(generation!=c->generation)return A_IMG_OWNER;
 if(c->poisoned)return A_IMG_IO;
 if(mode!=2&&c->converted)return A_IMG_STATE;
 if(mode==2&&!c->result_ready)return A_IMG_NOT_READY;
 if(length>A_IMG_CHUNK||off>total||length>total-off)return A_IMG_RANGE;
 while(length){
  low=off&15u;n=16u-low;if(n>length)n=length;
  if(mode==1){if(low||n!=16)memset(b,0,16);payload_copy(b+low,data,n);}
  if(line(c,mode==2,mode==1,off&~15u,b,mode==1?(uint16_t)(((1u<<n)-1u)<<low):0))return A_IMG_IO;
  if(mode==0){payload_copy(p,data,n);if(memcmp(b+low,p,n))return A_IMG_CONFLICT;}
  else if(mode==2)memcpy(data,b+low,n);
  off+=n;data+=n;length=(uint16_t)(length-n);
 }
 return 0;
}
static int write_bytes(void *user,uint32_t generation,uint32_t off,const uint8_t *data,uint16_t length){
 return transfer(user,generation,off,(uint8_t *)(uintptr_t)data,length,1);
}
static int compare(void *user,uint32_t generation,uint32_t off,const uint8_t *data,uint16_t length){
 int rc=transfer(user,generation,off,(uint8_t *)(uintptr_t)data,length,0);
 return rc==0?1:rc==A_IMG_CONFLICT?0:-1;
}
static int submit(void *user,uint32_t generation,uint32_t expected_crc){
 c_image_context *c=user;uint32_t q[8],actual,end,first,n,i,j,bpp;
 uint8_t block[64];int rc;
 if(generation!=c->generation)return A_IMG_OWNER;
 if(c->poisoned)return A_IMG_IO;
 if(c->converted==2)return A_IMG_STATE;
 if(expected_crc!=c->input.crc32)return A_IMG_CRC;
 if(c->submitted)return 0;
 if(!c->converted){
  rc=crc(c,0,c->input.total,&actual);if(rc)return rc;
  if(actual!=expected_crc)return A_IMG_CRC; /* No mutation before full CRC. */
  if(c->input.format!=3){
  bpp=c->input.format==1?3u:4u;end=(uint32_t)c->width*c->height;
  while(end){
   /* Aligned groups, walked backwards before RGB888 expands into RGBX7. */
   first=(end-1u)&~15u;n=end-first;memset(block,0,sizeof(block));
   for(i=0;i<n*bpp;i+=16)
    if(line(c,0,0,first*bpp+i,block+i,0))return A_IMG_IO;
   for(i=n;i!=0;){
    --i;for(j=3;j!=0;){--j;block[i*4+j]=(uint8_t)(block[i*bpp+j]>>1);}
    block[i*4+3]=0;
   }
   for(i=0;i<n*4;i+=16){
    j=n*4-i;if(j>16)j=16;
    if(line(c,0,1,first*4+i,block+i,(uint16_t)((1u<<j)-1u)))return A_IMG_IO;
   }
   end=first;
  }
  }
  c->converted=1;
 }
 rc=control(c,2,generation,0,q);
 if(!rc&&q[1]!=generation)rc=A_IMG_IO;
 if(!rc)c->submitted=1;
 else if(rc!=A_IMG_BUSY)c->poisoned=1;
 return rc;
}
static int poll(void *user,uint32_t generation,a_image_desc *result){
 c_image_context *c=user;uint32_t q[8];int rc;
 if(generation!=c->generation||c->poisoned||!c->submitted)return -1;
 rc=control(c,11,generation,0,q);if(rc||q[1]!=generation)return -1;
 if((q[2]&15u)==4||(q[2]&15u)==5)return 0;
 if((q[2]&15u)!=6||q[3]){c->poisoned=1;return -1;}
 if(!c->result_ready){
  rc=crc(c,1,(uint32_t)c->width*c->height*3u,&c->result_crc);if(rc)return -1;
  c->result_ready=1;
 }
 *result=c->input;result->format=1;result->stride=(uint32_t)c->width*3u;
 result->total=result->stride*c->height;result->crc32=c->result_crc;return 1;
}
static int read_bytes(void *user,uint32_t generation,uint32_t off,uint8_t *data,uint16_t length){
 return transfer(user,generation,off,data,length,2);
}
static int release(void *user,uint32_t generation,int cancel){
 c_image_context *c=user;uint32_t q[8];int rc;
 if(generation!=c->generation)return -1;
 rc=control(c,cancel?4u:3u,generation,0,q);
 if(!rc){c->converted=2;c->submitted=0;c->result_ready=0;c->poisoned=0;return 0;}
 return rc==A_IMG_BUSY?1:-1;
}
void c_image_backend_init(c_image_context *c,c_image_execute execute,void *io,uint16_t width,uint16_t height,a_image_backend *backend){
 memset(c,0,sizeof(*c));c->execute=execute;c->io=io;c->width=width;c->height=height;c->converted=2;
 backend->user=c;backend->reserve=reserve;backend->write=write_bytes;backend->compare=compare;
 backend->submit=submit;backend->poll=poll;backend->read=read_bytes;backend->release=release;
}
