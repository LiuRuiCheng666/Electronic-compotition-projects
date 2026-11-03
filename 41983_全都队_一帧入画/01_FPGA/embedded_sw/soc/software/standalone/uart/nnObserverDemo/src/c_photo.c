#include "c_photo.h"
#include "bsp.h"

static unsigned supported(const nn_control_io *io) {
 return nn_control_probe(io)&&(io->read(0x104)&16u)&&io->read(0x800)==0x46524d01u;
}
void c_photo_release(const nn_control_io *io) {
 if(!supported(io)){bsp_printf("ERR photo unavailable\r\n");return;}
 if(io->read(0x804)&2u){bsp_printf("ERR photo AXI still draining; state preserved\r\n");return;}
 io->write(0x804,0);bsp_printf("photo_release=OK; use mode auto if desired\r\n");
}
static unsigned word(const nn_control_io *io,unsigned offset,unsigned *value) {
 unsigned began=io->ticks(),s;
 io->write(0x808,offset);
 for(;;){
  s=io->read(0x804);
  if(s&4u)return 1;
  if(!(s&2u))break;
  if((unsigned)(io->ticks()-began)>10000000u)return 2;
 }
 if(!(s&8u))return 3;
 *value=io->read(0x810);return 0;
}
static void capture(const nn_control_io *io,unsigned preview) {
 nn_control_record record;unsigned rc,start,s,w,h,frame,meta,source,offset,value,k,byte,bit;
 unsigned crc=0xffffffffu,was_auto,bytes,total,sw,sh,at;
 if(!supported(io)){bsp_printf("ERR photo unavailable\r\n");return;}
 if(io->read(0x804)&3u){bsp_printf("ERR photo already locked/busy; inspect before release\r\n");return;}
 nn_control_status(io,&record);
 if(record.flags&14u){bsp_printf("ERR photo requires no queued task or pending ACK\r\n");return;}
 was_auto=!(record.flags&1u);rc=nn_control_command(io,NN_MODE_CPU);
 if(rc){bsp_printf("ERR photo CPU mode=%d\r\n",(int)rc);return;}
 start=io->ticks();
 while(!(io->read(0x804)&16u)){
  if((unsigned)(io->ticks()-start)>200000000u){bsp_printf("ERR photo drain timeout; CPU mode retained\r\n");return;}
  io->pause();
 }
 io->write(0x804,1);s=io->read(0x804);
 if(!(s&1u)||s&4u){bsp_printf("ERR photo lock failed; state preserved\r\n");return;}
 frame=io->read(0x820);meta=io->read(0x824);w=io->read(0x828);h=io->read(0x82c);
 if(!w||!h||w>2048||h>2048||((w*h)&3u)){bsp_printf("ERR photo dimensions; lock retained\r\n");return;}
 sw=w<64?w:64;sh=h<36?h:36;total=preview?sw*sh*4u:w*h*7u;
 if(preview)bsp_printf("SAMPLE_BEGIN width=%d height=%d source_width=%d source_height=%d bytes=%d frame=%d style=%d roi=%d fish=%d format=RGB7X video_paused=1\r\n",(int)sw,(int)sh,(int)w,(int)h,(int)total,(int)frame,(int)((meta&3u)|((meta>>3)&4u)),(int)((meta>>2)&3u),(int)((meta>>4)&1u));
 else
 bsp_printf("PHOTO_BEGIN width=%d height=%d bytes=%d frame=%d style=%d roi=%d fish=%d tone=AWB4 video_paused=1\r\n",
  (int)w,(int)h,(int)total,(int)frame,(int)((meta&3u)|((meta>>3)&4u)),(int)((meta>>2)&3u),(int)((meta>>4)&1u));
 for(source=0;source<(preview?1u:2u);source++){
  io->write(0x80c,source);bytes=preview?total:w*h*(source?3u:4u);
  for(offset=0;offset<bytes;offset+=4){
   at=preview?((((offset/4u)/sw)*h/sh)*w+((offset/4u)%sw)*w/sw)*4u:offset;
   rc=word(io,at,&value);
   if(rc){bsp_printf("\r\nPHOTO_ERROR code=%d source=%d offset=%d; lock retained\r\n",(int)rc,(int)source,(int)offset);return;}
   for(k=0;k<4;k++){
    byte=value&255u;value>>=8;uart_write(BSP_UART_TERMINAL,byte);
    crc^=byte;for(bit=0;bit<8;bit++)crc=(crc>>1)^((0u-(crc&1u))&0xedb88320u);
   }
  }
 }
 if(io->read(0x820)!=frame || io->read(0x804)&4u){bsp_printf("\r\nPHOTO_ERROR frame ownership lost; lock retained\r\n");return;}
 io->write(0x804,0);
 bsp_printf("\r\n%s_END crc=0x%x frame=%d\r\n",preview?"SAMPLE":"PHOTO",(int)(crc^0xffffffffu),(int)frame);
 if(was_auto){rc=nn_control_command(io,NN_MODE_AUTO);bsp_printf("photo_restore_auto=%s\r\n",nn_control_error(rc));}
 else bsp_printf("photo_CPU_mode_retained=1\r\n");
}

void c_photo_capture(const nn_control_io *io){capture(io,0);}
void c_photo_preview(const nn_control_io *io){capture(io,1);}
