#ifndef CAMERA_AWB_FAST_H
#define CAMERA_AWB_FAST_H
#include "camera_light_policy.h"
/* Directions are derived from post-gain neutral pixels, not absolute RGB.
 * Exposure is common to RGB: ratios remain usable during a safe AE step.
 * Reversals force eight fine updates to damp direction-only overshoot. */
typedef struct { unsigned char red,blue,red_fine,blue_fine; } camera_awb_history;
static inline void camera_awb_restart(camera_awb_history *h) {h->red=h->blue=h->red_fine=h->blue_fine=0;}
static inline unsigned camera_awb_channel(unsigned gain,unsigned direction,unsigned char *history,unsigned char *fine) {
    unsigned previous=*history&3,run,step;
    if(direction!=1&&direction!=2) {*history=0;if(*fine)--*fine;return gain;}
    if(previous&&previous!=direction)*fine=8;
    run=previous==direction?(*history>>2)+1:1;if(run>3)run=3;
    *history=(unsigned char)((run<<2)|direction);
    if(*fine) {step=8;--*fine;}
    else {step=run>=2?((gain>>3)&~7u):((gain>>5)&~7u);if(step<8)step=8;if(step>64)step=64;}
    if(direction==1)return gain>640-step?640:gain+step;
    return gain<128+step?128:gain-step;
}
static inline uint32_t camera_light_choose_fast(camera_awb_history *h,uint32_t flags,uint32_t settings,uint32_t stats) {
    uint32_t next=camera_light_choose(flags&~2u,settings,stats);
    unsigned count=(stats>>14)&1023,r,b;
    /* Colour sums already exclude dark, clipped and strongly coloured pixels.
     * An unrelated lamp/window must not block valid neutral colour feedback:
     * otherwise initial gains can cause clipping and permanently inhibit AWB.
     * AE retains its separate highlight guard and2800 half-line exposure cap. */
    if(!(flags&2)||!(flags&(1u<<10))||count<256) {
        camera_awb_restart(h);return next;
    }
    r=camera_awb_channel((settings>>10)&1023,stats&3,&h->red,&h->red_fine);
    b=camera_awb_channel(settings&1023,(stats>>2)&3,&h->blue,&h->blue_fine);
    return (next&0xfff00000u)|(r<<10)|b;
}
#endif
