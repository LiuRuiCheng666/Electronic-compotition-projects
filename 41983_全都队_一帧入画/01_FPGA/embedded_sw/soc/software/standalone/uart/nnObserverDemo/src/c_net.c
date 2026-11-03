#include "bsp.h"
#include "a_net_service.h"
#include "c_net_time.h"
#include "c_image_backend.h"
static a_net_service service;
static c_image_context image;
static int ready;
static int rd(void *c,uint32_t off,uint32_t *v){(void)c;if((off&3)||off>=0x1000)return -1;__asm__ volatile("fence iorw,iorw":::"memory");*v=*(volatile uint32_t *)(0xf8101000u+off);__asm__ volatile("fence iorw,iorw":::"memory");return 0;}
static int wr(void *c,uint32_t off,uint32_t v){(void)c;if((off&3)||off>=0x1000)return -1;__asm__ volatile("fence iorw,iorw":::"memory");*(volatile uint32_t *)(0xf8101000u+off)=v;__asm__ volatile("fence iorw,iorw":::"memory");return 0;}
static int image_execute(void *unused,uint32_t q[8]){
 volatile uint32_t *r=(volatile uint32_t *)0xf8102000u;uint32_t s,i,n,op=q[0];
 (void)unused;
 __asm__ volatile("fence iorw,iorw":::"memory");
 /* The page ID was checked before registering this private executor. */
 s=r[1];if(!(s&32u)||(s&17u))return A_IMG_BUSY;
 if(s&14u){r[2]=10u;__asm__ volatile("fence iorw,iorw":::"memory");return A_IMG_BUSY;}
 /* Only WRITE_LINE(9) consumes payload words4..7; all other RPCs use words0..3. */
 n=q[0]==9u?8u:4u;for(i=0;i<n;i++)r[16+i]=q[i];
 __asm__ volatile("fence iorw,iorw":::"memory");r[2]=1u;
 for(i=0;i<((op==12u||op==13u)?10000000u:1000000u);i++){s=r[1];if(s&2u)break;}
 if(!(s&2u))return A_IMG_IO; /* Keep the outstanding hardware command intact. */
 __asm__ volatile("fence iorw,iorw":::"memory");
 /* Only line reads consume payload; only STATUS(11) consumes state/fault.
  * All callers consume status+generation. Do not read unused APB words. */
 n=op==11u?4u:2u;for(i=0;i<n;i++)q[i]=r[16+i];
 if(op==8u||op==10u)for(i=4;i<8;i++)q[i]=r[16+i];
 if(op==12u||op==13u)q[4]=r[20];
 r[2]=10u;__asm__ volatile("fence iorw,iorw":::"memory");return 0;
}
void c_net_init(void){
 a_net_mb_io io={0,rd,wr};a_image_backend backend,*selected=0;
 /* A missing image page fails closed. A present page may still be in video
  * root reset; execute returns BUSY until the CPU-domain ready bit rises. */
 if(*(volatile uint32_t *)0xf8102000u==0x4e494d02u){
  c_image_backend_init(&image,image_execute,0,1280,720,&backend);selected=&backend;
 }
 ready=a_net_service_init(&service,&io,selected)==0;
}
void c_net_poll(void){if(ready){uint32_t hi,lo;do{hi=clint_getTimeHigh(BSP_CLINT);lo=clint_getTimeLow(BSP_CLINT);}while(hi!=clint_getTimeHigh(BSP_CLINT));uint32_t ms=c_net_ticks_to_ms(hi,lo,BSP_CLINT_HZ/1000u);if(a_net_service_poll(&service,ms)<0)ready=0;}}
