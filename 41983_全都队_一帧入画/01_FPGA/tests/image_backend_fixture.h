#ifndef IMAGE_BACKEND_FIXTURE_H
#define IMAGE_BACKEND_FIXTURE_H
#include "a_image_session.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
/* Host-only memory fixture. Identity copy is NOT a neural network. */
static uint8_t fixture_input[A_IMG_MAX_BYTES],fixture_output[A_IMG_MAX_BYTES];
static a_image_desc fixture_desc;
static uint32_t fixture_generation;
static unsigned reserve_count,write_count,submit_count,release_count;
static int release_busy,poll_busy,write_error;
static uint32_t fixture_crc(const uint8_t *p,uint32_t n){
 uint32_t c=0xffffffffu,i;unsigned j;
 for(i=0;i<n;i++){c^=p[i];for(j=0;j<8;j++)c=(c>>1)^((c&1)?0xedb88320u:0u);}return c^0xffffffffu;
}
static int f_reserve(void *u,const a_image_desc *d,uint32_t *g){
 (void)u;fixture_desc=*d;*g=++fixture_generation;reserve_count++;return 0;
}
static int f_write(void *u,uint32_t g,uint32_t o,const uint8_t *p,uint16_t n){
 (void)u;if(g!=fixture_generation||o>fixture_desc.total||n>fixture_desc.total-o)return A_IMG_IO;
 if(write_error)return A_IMG_IO;
 memcpy(fixture_input+o,p,n);write_count++;return 0;
}
static int f_compare(void *u,uint32_t g,uint32_t o,const uint8_t *p,uint16_t n){
 (void)u;if(g!=fixture_generation||o>fixture_desc.total||n>fixture_desc.total-o)return -1;
 return !memcmp(fixture_input+o,p,n);
}
static int f_submit(void *u,uint32_t g,uint32_t expected){
 (void)u;if(g!=fixture_generation)return A_IMG_IO;
 if(fixture_crc(fixture_input,fixture_desc.total)!=expected)return A_IMG_CRC;
 memcpy(fixture_output,fixture_input,fixture_desc.total);submit_count++;return 0;
}
static int f_poll(void *u,uint32_t g,a_image_desc *d){
 (void)u;if(g!=fixture_generation)return -1;if(poll_busy){poll_busy--;return 0;}
 *d=fixture_desc;d->crc32=fixture_crc(fixture_output,d->total);return 1;
}
static int f_read(void *u,uint32_t g,uint32_t o,uint8_t *p,uint16_t n){
 (void)u;if(g!=fixture_generation||o>fixture_desc.total||n>fixture_desc.total-o)return A_IMG_IO;
 memcpy(p,fixture_output+o,n);return 0;
}
static int f_release(void *u,uint32_t g,int cancel){
 (void)u;(void)cancel;if(g!=fixture_generation)return A_IMG_IO;
 if(release_busy){release_busy--;return A_IMG_BUSY;}release_count++;return 0;
}
static a_image_backend fixture_backend(void){
 a_image_backend b={0,f_reserve,f_write,f_compare,f_submit,f_poll,f_read,f_release};return b;
}
#endif
