#ifndef C_IMAGE_BACKEND_H
#define C_IMAGE_BACKEND_H
#include "a_image_session.h"
/* One immutable APB request/reply. execute returns A_IMG_BUSY only if the
 * request was NOT started; completed RTL status is returned in words[0].
 * All DMA commands retain their 16-byte payload in hardware until drained. */
typedef int (*c_image_execute)(void *,uint32_t words[8]);
typedef struct {
 c_image_execute execute;void *io;
 a_image_desc input;
 uint32_t generation,result_crc;
 uint16_t width,height;
 uint8_t converted,submitted,result_ready,poisoned; /* converted:0=raw,1=RGBX7,2=unowned */
} c_image_context;
void c_image_backend_init(c_image_context *,c_image_execute,void *,uint16_t,uint16_t,a_image_backend *);
/* Shared nibble CRC implementation with the Ethernet mailbox service. */
uint32_t a_net_crc32_byte(uint32_t,uint8_t);
#endif
