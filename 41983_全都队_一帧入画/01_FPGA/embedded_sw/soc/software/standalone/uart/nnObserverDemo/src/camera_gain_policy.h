#ifndef CAMERA_GAIN_POLICY_H
#define CAMERA_GAIN_POLICY_H
#include <stdint.h>
/* SC431HAI linear analog gain: coarse80,fine3A = q58 (2.791x),
 * coarse81,fine3A = q116 (5.583x). q>=64 is encoded in even steps.
 * Exposure remains limited to2800 half-lines at VTS1500/30FPS. */
static inline unsigned camera_gain_choose(unsigned q,uint32_t flags,uint32_t settings,uint32_t stats) {
 unsigned count=(stats>>14)&1023,clips=(stats>>4)&1023,y=(stats>>24)<<10,e=settings>>20;
 if(!(flags&1)||count<256)return q;
 if(q>58 && (clips*4>count || (clips*8>count && y>96u*count) || y>160u*count || e<2200))return q<=62?58:q-4;
 if(e>=2780 && ((y<112u*count && clips*25<count*2) || (y<80u*count && clips*4<count)))return q>=112?116:q+4;
 return q;
}
#endif
