#include "bsp.h"
#include "c_system.h"
#include "camera_light.h"
#include "camera_awb_fast.h"
#include "camera_gain_policy.h"
#include <string.h>
#define R(o) io->read(0x500u+(o))
#define W(o,v) io->write(0x500u+(o),(v))
static unsigned wait_frames=4;
static unsigned analog_q=58;
static unsigned short last_seq;
static camera_awb_history awb_history;
static unsigned status(const nn_control_io *io,unsigned busy) {
    return (c_camera_ready?1u:0u)|(busy?2u:0u)|(R(0x20)&4u)|(wait_frames<<3);
}
/* Foreground only. Existing c_camera_write owns the only I2C controller.
 * Do not call io->pause here: that callback also services light control.
 */
static unsigned sensor_write(const nn_control_io *io,unsigned e,unsigned q,unsigned change_e,unsigned change_q) {
    unsigned short addr[7];unsigned data[7],n=0;
    addr[n]=0x3812;data[n++]=0;
    if(change_e) {addr[n]=0x3e00;data[n++]=e>>12;addr[n]=0x3e01;data[n++]=(e>>4)&255;addr[n]=0x3e02;data[n++]=(e&15)<<4;}
    if(change_q) {addr[n]=0x3e08;data[n++]=q>=64?0x81:0x80;addr[n]=0x3e09;data[n++]=q>=64?q/2:q;}
    addr[n]=0x3812;data[n++]=0x30;
    unsigned frame=R(0x24),began=io->ticks(),rc=0,i;
    while(R(0x24)==frame) {
        if((uint32_t)(io->ticks()-began)>BSP_CLINT_HZ/10u)return 8;
        bsp_uDelay(100);
    }
    for(i=0;i<n;i++)if((rc=c_camera_write(io,addr[i],data[i])))break;
    if(rc)c_camera_write(io,0x3812,0x30); /* best-effort group release */
    return rc;
}
static unsigned apply(const nn_control_io *io,unsigned old,unsigned next,unsigned mode,unsigned q) {
    unsigned rc=0;
    if((next>>20)<32||(next>>20)>2800||q<58||q>116||(q>=64&&(q&1)))return 9;
    /* Exposure includes sensor/RAW-buffer latency. Gain-only changes occur
     * at the next RAW read frame: discard two frames, use the third or later.
     */
    wait_frames=((old>>20)!=(next>>20)||q!=analog_q)?4:2;
    if((old>>20)!=(next>>20)||q!=analog_q) {
        if(!c_camera_ready||(R(0x20)&4u))return 7;
        W(0x20,status(io,1));rc=sensor_write(io,next>>20,q,(old>>20)!=(next>>20),q!=analog_q);
    }
    if(!rc) {analog_q=q;W(8,next>>20);W(12,next&0xfffffu);W(4,mode);}
    W(0x20,status(io,0)|(rc?4u:0u));
    /* Frames received while waiting for SOF/I2C completion are still old.
     * Start the settling interval after the physical update/command commit. */
    last_seq=R(0x10)>>16;
    return rc;
}
void camera_light_service(const nn_control_io *io) {
    static uint32_t last_tick;
    uint32_t now=io->ticks(),f,s,t,next;unsigned q,count,clips,y;unsigned short seq,delta;
    if((uint32_t)(now-last_tick)<BSP_CLINT_HZ/50u)return;
    last_tick=now;
    if(R(0)!=0x414c0002u)return;
    W(0x20,status(io,0));
    f=R(0x10);seq=f>>16;delta=seq-last_seq;
    if(!delta)return;last_seq=seq;
    if(wait_frames) {wait_frames=delta>=wait_frames?0:wait_frames-delta;W(0x20,status(io,0));return;}
    if(!(f&3)||!c_camera_ready||!(c_system_config&1u)||(f&16)) {camera_awb_restart(&awb_history);return;}
    s=R(0x14);t=R(0x18);next=camera_light_choose_fast(&awb_history,f,s,t);
    q=camera_gain_choose(analog_q,f,s,t);
    /* For modest highlights, lower analog gain first instead of dropping
     * both exposure and gain in the same update. Emergency AE still wins. */
    if(q<analog_q && ((t>>4)&1023)*4<=((t>>14)&1023) && (t>>24)*1024u<=160u*((t>>14)&1023))
        next=(next&0xfffffu)|(s&0xfff00000u);
    count=(t>>14)&1023;clips=(t>>4)&1023;y=(t>>24)<<10;
    /* Trade excess analog gain for exposure without a brightness jump. */
    if(q<analog_q && (s>>20)<2200 && clips*4<=count && y<=160u*count && !(clips*8>count && y>96u*count)) {
        unsigned e=((s>>20)*analog_q+q/2)/q;if(e>2800)e=2800;
        next=(next&0xfffffu)|(e<<20);
    }
    if(next!=s||q!=analog_q)apply(io,s,next,f&3,q);
    else {wait_frames=0;W(0x20,status(io,0));}
}
static int number(const char **p,unsigned *v) {
    unsigned n=0,d=0;
    while(**p==' ')++*p;
    while(**p>='0'&&**p<='9') {if(n>4095)return 0;n=n*10+(unsigned)(*(*p)++-'0');d++;}
    *v=n;return d!=0;
}
int camera_light_dispatch(const nn_control_io *io,const char *line) {
    unsigned f,s,t,mode,e,r,b,a=0,z=0,rc,q=analog_q;const char *p;
    if(strcmp(line,"light")&&strncmp(line,"light ",6))return 0;
    if(R(0)!=0x414c0002u) {bsp_printf("LIGHT ABI mismatch\r\n");return 1;}
    f=R(0x10);s=R(0x14);t=R(0x18);mode=f&3;e=s>>20;r=(s>>10)&1023;b=s&1023;
    if(!strcmp(line,"light")) {
        bsp_printf("LIGHT mode=%d ready=%d fault=%d seq=%d exp=%d R=%d B=%d\r\n",
            mode,(f>>2)&1,(f>>4)&1,f>>16,e,r,b);
        bsp_printf("samples=%d clipped=%d brightness_index=%d AE=%d neutral=%d red=%d blue=%d\r\n",
            (t>>14)&1023,(t>>4)&1023,t>>24,(f>>8)&3,(f>>10)&1,t&3,(t>>2)&3);
        bsp_printf("AE policy=BRIGHT8 target=112..160 max_exp=2800 clip_up=8pct clip_down=12.5pct emergency=25pct backlight=80..96 sensor_ana_base=0x80:0x3A\r\n");
        bsp_printf("AGC q=%d min=58 max=116 coarse=%d fine=%d\r\n",analog_q,analog_q>=64?0x81:0x80,analog_q>=64?analog_q/2:analog_q);
        bsp_printf("AWB streak_R=%d streak_B=%d wait_frames=%d\r\n",awb_history.red>>2,awb_history.blue>>2,wait_frames);
        return 1;
    }
    if(!strcmp(line,"light auto"))mode=3;
    else if(!strcmp(line,"light off"))mode=0;
    else if(!strcmp(line,"light reset")) {e=2200;r=512;b=320;mode=3;q=58;}
    else if(!strncmp(line,"light exp ",10)) {
        p=line+10;if(!number(&p,&a)||*p||a<32||a>2800)goto usage;
        e=a;mode&=2;
    } else if(!strncmp(line,"light gains ",12)) {
        p=line+12;if(!number(&p,&a)||!number(&p,&z)||*p||a<128||a>640||z<128||z>640)goto usage;
        r=a&~7u;b=z&~7u;mode&=1;
    } else goto usage;
    camera_awb_restart(&awb_history);
    rc=apply(io,s,(e<<20)|(r<<10)|b,mode,q);
    bsp_printf("LIGHT result=%d\r\n",rc);return 1;
usage:
    bsp_printf("light [auto|off|reset|exp 32..2800|gains R B (128..640)]\r\n");return 1;
}
