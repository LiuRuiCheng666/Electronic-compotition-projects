#ifndef A_NET_SERVICE_H
#define A_NET_SERVICE_H
#include "a_image_session.h"
typedef struct {
 void *context;
 int (*read)(void *,uint32_t relative_offset,uint32_t *value);
 int (*write)(void *,uint32_t relative_offset,uint32_t value);
} a_net_mb_io;
enum { A_MB_NONE=0,A_MB_READY=1,A_MB_BUSY=2,A_MB_IO=-1,A_MB_ABI=-2,A_MB_STALE=-3,A_MB_RANGE=-4 };
typedef struct {
 a_image_packet packet;
 uint32_t token,peer_ip;
 uint64_t peer_mac;
 uint16_t peer_port;
#ifdef A_NET_DIRECT_RX_BASE
 uint8_t payload[32]; /* Non-DATA descriptors only; DATA remains in owned RX RAM. */
#else
 uint8_t payload[A_IMG_CHUNK];
#endif
} a_net_mb_request;
typedef struct {
 a_net_mb_io io;
 a_image_session session;
 a_net_mb_request request;
 a_image_reply reply;
 uint32_t last_errors,last_done_token;
 uint8_t pending; /* 0=new RX,1=reply not queued,2=TX queued, RX release pending */
} a_net_service;
/* IO must provide ordered, fenced APB operations and surface bus faults.
 * One CPU owner only. The proposed mailbox address is NOT installed in C's SoC. */
int a_net_mb_receive(const a_net_mb_io *,a_net_mb_request *);
int a_net_mb_send(const a_net_mb_io *,const a_net_mb_request *,const a_image_reply *);
int a_net_mb_release(const a_net_mb_io *,uint32_t token);
int a_net_mb_take_events(const a_net_mb_io *,uint32_t *errors,uint32_t *done_token);
int a_net_service_init(a_net_service *,const a_net_mb_io *,const a_image_backend *);
/* Call regularly even without RX so session timeouts can drain safely.
 * Never repeats session processing while TX is busy or RX release is retried. */
int a_net_service_poll(a_net_service *,uint32_t now_ms);
uint32_t a_net_crc32_byte(uint32_t crc,uint8_t byte);
#endif
