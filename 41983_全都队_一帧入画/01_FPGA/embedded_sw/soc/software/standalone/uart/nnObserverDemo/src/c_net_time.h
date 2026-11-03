#ifndef C_NET_TIME_H
#define C_NET_TIME_H
#include <stdint.h>
/* Low32 quotient of a64-bit tick counter by a32-bit ticks/ms divisor.
 * hi%div discards only complete2^32-ms turns. No64-bit runtime division. */
static inline uint32_t c_net_ticks_to_ms(uint32_t hi,uint32_t lo,uint32_t div){
 uint32_t rem=hi%div,q=0;unsigned i;
 for(i=32;i;i--){rem=rem*2u+((lo>>(i-1))&1u);q<<=1;if(rem>=div){rem-=div;q|=1u;}}
 return q;
}
#endif
