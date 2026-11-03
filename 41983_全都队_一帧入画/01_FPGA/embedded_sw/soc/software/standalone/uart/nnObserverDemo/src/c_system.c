#include "c_system.h"
#include "camera_table.h"
unsigned c_camera_ready,c_camera_error,c_camera_index,c_system_config=64;
static unsigned apply(const nn_control_io *io,unsigned cfg) {
 unsigned rc=nn_control_command(io,7u|(cfg<<8));if(!rc)c_system_config=cfg;return rc;
}
unsigned c_system_ui(const nn_control_io *io,unsigned tag,unsigned enable) {
 return apply(io,(c_system_config&~(15u<<6))|((enable&1u)<<6)|((tag&7u)<<7));
}
unsigned c_system_style(const nn_control_io *io,unsigned model,unsigned buttons) {
 if(!buttons && model>=5)return NN_BAD_COMMAND;
 return apply(io,(c_system_config&~4110u)|(buttons?0:2u|((model&3u)<<2)|((model&4u)<<10)));
}
unsigned c_system_fish(const nn_control_io *io,unsigned enable,unsigned buttons) {
 return apply(io,(c_system_config&~48u)|(buttons?0:16u|((enable&1u)<<5)));
}
unsigned c_system_roi(const nn_control_io *io,unsigned mode) {
 return mode<4?apply(io,(c_system_config&~3072u)|(mode<<10)):NN_BAD_COMMAND;
}
static unsigned cam_rd(const nn_control_io *io,unsigned r) {return io->read(0x300+4*r);}
static unsigned cam_wr(const nn_control_io *io,unsigned r,unsigned v) {
 io->write(0x300+4*r,v);return (io->read(0x344)&6u)?3u:0u;
}
static unsigned cam_wait(const nn_control_io *io,unsigned ack) {
 uint32_t began=io->ticks();unsigned s;
 for(;;) {
  s=cam_rd(io,4);if((s&0x100u)||(io->read(0x344)&6u))return 3;
  if(s&0x20u)return 4;
  if(!(s&2u))return ack&&(s&0x80u)?1u:0u;
  if((uint32_t)(io->ticks()-began)>10000000u)return 2;
 }
}
static unsigned cam_send(const nn_control_io *io,unsigned byte,unsigned command) {
 unsigned rc=cam_wr(io,3,byte);if(!rc)rc=cam_wr(io,4,command);if(!rc)rc=cam_wait(io,1);
 if(rc)cam_wr(io,4,0x41);return rc;
}
unsigned c_camera_write(const nn_control_io *io,unsigned addr,unsigned data) {
 unsigned rc=cam_send(io,0x60,0x90);if(!rc)rc=cam_send(io,addr>>8,0x10);
 if(!rc)rc=cam_send(io,addr&255,0x10);if(!rc)rc=cam_send(io,data,0x50);return rc;
}
unsigned c_camera_read(const nn_control_io *io,unsigned addr,unsigned *data) {
 unsigned rc=cam_send(io,0x60,0x90);if(!rc)rc=cam_send(io,addr>>8,0x10);
 if(!rc)rc=cam_send(io,addr&255,0x10);if(!rc)rc=cam_send(io,0x61,0x90);
 if(!rc)rc=cam_wr(io,4,0x68);if(!rc)rc=cam_wait(io,0);
 if(!rc){*data=cam_rd(io,3);if(*data>255)rc=3;}return rc;
}
static unsigned camera_check(const nn_control_io *io) {
 unsigned rc,hi=0,lo=0,stream=0;
 rc=cam_wait(io,0);
 if(!rc)rc=c_camera_read(io,0x320e,&hi);if(!rc)rc=c_camera_read(io,0x320f,&lo);if(!rc)rc=c_camera_read(io,0x0100,&stream);
 if(!rc && (((hi<<8)|lo)!=1500 || !(stream&1)))rc=6;
 c_camera_error=rc;c_camera_ready=!rc;return rc;
}
unsigned c_camera_resume(const nn_control_io *io) {
 c_camera_index=167;return camera_check(io);
}
unsigned c_camera_init(const nn_control_io *io) {
 unsigned rc=0;
 if(c_camera_ready)return 0;
 if(c_system_config&1u)return c_camera_error=7; /* deployed live camera: validate only, never restart */
 if(io->read(0x340)!=0x43493201u)return c_camera_error=5;
 if(cam_wr(io,2,0)||cam_wr(io,0,0x93)||cam_wr(io,1,0x02)||cam_wr(io,2,0x80))return c_camera_error=3;
 for(c_camera_index=0;c_camera_index<sizeof(camera_table)/sizeof(camera_table[0]);c_camera_index++) {
  const unsigned char *v=camera_table[c_camera_index];rc=c_camera_write(io,((unsigned)v[0]<<8)|v[1],v[2]);if(rc)break;
 }
 if(rc){c_camera_error=rc;return rc;}return camera_check(io);
}
unsigned c_weights_load(const nn_control_io *io) {
 uint32_t began;unsigned rc,s;
#if !defined(HDMI_INPUT_PROFILE) && !defined(DUAL_INPUT_PROFILE)
 if(!c_camera_ready)return NN_NOT_READY;
#endif
 if(!(c_system_config&1u)){rc=apply(io,c_system_config|1u);if(rc)return rc;}
 began=io->ticks();for(;;) {
  s=io->read(0x108);if(s&4u)return NN_FAULT;if((s&3u)==3u)return 0;
  if((uint32_t)(io->ticks()-began)>1000000000u)return NN_TIMEOUT;io->pause();
 }
}
