#ifndef A_IMAGE_SESSION_H
#define A_IMAGE_SESSION_H
#include <stdint.h>
#include <stddef.h>
#define A_IMG_CHUNK 1368u
#define A_IMG_MAX_BYTES 4194304u
#define A_IMG_BITMAP_BYTES (((A_IMG_MAX_BYTES+A_IMG_CHUNK-1u)/A_IMG_CHUNK+7u)/8u)
enum { A_IMG_HELLO=1,A_IMG_STATUS=2,A_IMG_BEGIN=0x10,A_IMG_DATA=0x11,
 A_IMG_ACK=0x12,A_IMG_COMMIT=0x13,A_IMG_ABORT=0x14,A_IMG_RESULT=0x20 };
enum { A_IMG_OK=0,A_IMG_BUSY=1,A_IMG_FORMAT=2,A_IMG_STATE=3,A_IMG_RANGE=4,
 A_IMG_CRC=5,A_IMG_IO=6,A_IMG_INCOMPLETE=7,A_IMG_NOT_READY=8,
 A_IMG_TIMEOUT=9,A_IMG_OWNER=10,A_IMG_CONFLICT=11,A_IMG_UNSUPPORTED=12 };
enum { A_IMG_IDLE=0,A_IMG_RECEIVING=1,A_IMG_RUNNING=2,A_IMG_READY=3,A_IMG_RELEASING=4,A_IMG_FAULT=5 };
typedef struct {
 uint16_t width,height;
 uint8_t format,style; /* 1=RGB888, 2=RGBX8888, 3=negotiated packed RGBX7 (R/G/B<=127, X=0). */
 uint32_t stride,total,crc32;
} a_image_desc;
/* Input must already have passed Ethernet/IP/UDP and ANET header/CRC validation.
 * peer = (IPv4 in host numeric notation << 16) | source UDP port. */
typedef struct { uint8_t op;uint32_t session,sequence,offset,total;const uint8_t *payload;uint16_t length; } a_image_packet;
typedef struct { uint8_t op;uint32_t session,sequence,offset,total;uint16_t length;uint8_t payload[A_IMG_CHUNK]; } a_image_reply;
typedef struct {
 void *user;
 int (*reserve)(void *,const a_image_desc *,uint32_t *generation);
 int (*write)(void *,uint32_t generation,uint32_t offset,const uint8_t *,uint16_t);
 int (*compare)(void *,uint32_t generation,uint32_t offset,const uint8_t *,uint16_t); /* 1=same,0=conflict,-1=IO */
 int (*submit)(void *,uint32_t generation,uint32_t expected_crc); /* verify whole input CRC, then one task */
 int (*poll)(void *,uint32_t generation,a_image_desc *result); /* 0=running,1=result ready,-1=fault */
 int (*read)(void *,uint32_t generation,uint32_t offset,uint8_t *,uint16_t);
 int (*release)(void *,uint32_t generation,int cancel); /* 0=drained/released,1=still busy; never early free */
} a_image_backend;
/* reserve/write/submit/read: 0=completed success; BUSY means NOT started and no
 * outstanding operation retaining packet memory. No ambiguous submit success.
 * Hardware adapters must retain packet RAM until DMA/BRESP is complete.
 * No CPU per-byte DDR mover is supplied here. C owns actual DMA and NN scheduling. */
typedef struct {
 a_image_backend io;
 a_image_desc input,result;
 uint64_t peer;
 uint32_t session,generation,last_activity,received,total_chunks,last_session;
 uint64_t last_peer;
 uint32_t last_generation;
 uint8_t phase,release_cancel,terminal_status,have_last;
 uint8_t bitmap[A_IMG_BITMAP_BYTES];
 uint32_t receive_timeout_ms,run_timeout_ms,result_timeout_ms;
} a_image_session;
int a_image_desc_decode(const uint8_t *,uint16_t,a_image_desc *);
void a_image_desc_encode(const a_image_desc *,uint8_t out[32]);
void a_image_session_init(a_image_session *,const a_image_backend *);
void a_image_session_tick(a_image_session *,uint32_t now_ms);
/* Returns 1 with a reply, 0 only for invalid API arguments. No socket access.
 * Packet payload and reply buffer must not alias; keep RX RAM owned until return. */
int a_image_session_process(a_image_session *,uint64_t peer,const a_image_packet *,uint32_t now_ms,a_image_reply *);
#endif
