#ifndef CAMERA_LIGHT_POLICY_H
#define CAMERA_LIGHT_POLICY_H
#include <stdint.h>
/* Pure low-rate policy: packed register input/output, no I/O or NN ownership. */
static inline uint32_t camera_light_choose(uint32_t flags,uint32_t settings,uint32_t stats) {
    unsigned e=settings>>20,r=(settings>>10)&1023,b=settings&1023;
    unsigned red=stats&3,blue=(stats>>2)&3,step;
    unsigned clips=(stats>>4)&1023,brightness=(stats>>24)<<10,old_e=e;
    unsigned count=(stats>>14)&1023;
    if(!count)return settings;
    /* Bright8: target mean 112..160. Small bright sources may clip, but
     * must not hold an otherwise dark frame at the old 2.5% clip threshold.
     * Hysteresis: increase below8%, decrease above12.5%, hold between.
     * More than25% clipped triggers the original emergency quarter-step.
     * SC431HAI exposure is in half-lines, not1/16 lines. For VTS1500
     * the datasheet maximum is2989; keep the established2800 ceiling.
     */
    if((flags&1)&&e>2800)e=2800;
    else if(flags&1) {
        if(clips*4>count || brightness>160u*count || (clips*8>count && brightness>96u*count)) {
            step=e>>(clips*4>count?2:4);if(!step)step=1;
            e=e<=32+step?32:e-step;
        } else if((brightness<112u*count && clips*25<count*2) || (brightness<80u*count && clips*4<count)) {
            unsigned shift=(brightness<48u*count&&clips*100<count)?2:
                           (brightness<72u*count&&clips*100<count)?3:
                           (clips*40<count)?4:5;
            step=e>>shift;if(!step)step=1;e=e+step>2800?2800:e+step;
        }
    }
    /* Freeze colour during an exposure step. With AE manually disabled or
     * highlights holding exposure, valid neutral samples can still drive AWB.
     */
    if((flags&2)&&(flags&(1u<<10))&&e==old_e&&clips<=(count>>5)) {
        if(red==1)r=r>632?640:r+8;else if(red==2)r=r<136?128:r-8;
        if(blue==1)b=b>632?640:b+8;else if(blue==2)b=b<136?128:b-8;
    }
    return (e<<20)|(r<<10)|b;
}
#endif
