#include "nn_control.h"
int nn_control_probe(const nn_control_io *io)
{
    /* Do not touch the new window on older observer images. */
    return io->read(0x100)==NN_OBSERVER_ABI&&io->read(0x200)==NN_CONTROL_ID;
}
unsigned nn_control_command(const nn_control_io *io,unsigned opcode)
{
    if(!nn_control_probe(io))return NN_BAD_ID;
    io->write(0x204,opcode);
    return io->read(0x20c);
}
void nn_control_status(const nn_control_io *io,nn_control_record *r)
{
    r->flags=io->read(0x208); /* one coherent handshake, then retained IDs */
    r->accepted_id=io->read(0x210);r->done_id=io->read(0x214);r->result=io->read(0x218);
}
unsigned nn_control_wait(const nn_control_io *io,uint32_t timeout_ticks,nn_control_record *r)
{
    uint32_t begin=io->ticks();
    if(!nn_control_probe(io))return NN_BAD_ID;
    for(;;){
        nn_control_status(io,r);
        if(r->flags&8u){
            if(!(r->flags&16u)||r->result!=1u||r->accepted_id!=r->done_id)return NN_BAD_COMPLETION;
            return NN_COMMAND_OK;
        }
        if((uint32_t)(io->ticks()-begin)>=timeout_ticks)return NN_TIMEOUT;
        io->pause();
    }
    /* A timeout never resets NN/DDR, clears a pending result, or returns AUTO. */
}
const char *nn_control_error(unsigned e)
{
    static const char *const names[]={"OK","NOT_CPU_MODE","BUSY_OR_ACK_REQUIRED","NOT_READY",
        "HARDWARE_FAULT","NO_COMPLETION","BAD_COMMAND","WRONG_CONTROL_ID","TIMEOUT_STATE_PRESERVED","BAD_COMPLETION"};
    return e<sizeof(names)/sizeof(names[0])?names[e]:"UNKNOWN_RESULT";
}
