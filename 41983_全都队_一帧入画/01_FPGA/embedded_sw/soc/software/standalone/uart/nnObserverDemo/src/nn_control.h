#ifndef NN_CONTROL_H
#define NN_CONTROL_H
#include <stdint.h>
#define NN_OBSERVER_ABI 0x41435206u
#define NN_CONTROL_ID 0x41434302u
enum { NN_MODE_CPU=1,NN_MODE_AUTO=2,NN_START=3,NN_ACK=4 };
enum { NN_COMMAND_OK=0,NN_NOT_CPU=1,NN_BUSY=2,NN_NOT_READY=3,
       NN_FAULT=4,NN_NO_EVENT=5,NN_BAD_COMMAND=6,NN_BAD_ID=7,NN_TIMEOUT=8,NN_BAD_COMPLETION=9 };
typedef struct {
    uint32_t (*read)(unsigned);
    void (*write)(unsigned,uint32_t);
    uint32_t (*ticks)(void);
    void (*pause)(void);
} nn_control_io;
typedef struct {uint32_t flags,accepted_id,done_id,result;} nn_control_record;
int nn_control_probe(const nn_control_io *io);
unsigned nn_control_command(const nn_control_io *io,unsigned opcode);
void nn_control_status(const nn_control_io *io,nn_control_record *r);
unsigned nn_control_wait(const nn_control_io *io,uint32_t timeout_ticks,nn_control_record *r);
const char *nn_control_error(unsigned error);
#endif
