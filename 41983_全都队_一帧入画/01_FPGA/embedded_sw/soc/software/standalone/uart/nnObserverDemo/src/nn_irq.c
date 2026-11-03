/* ISR masks PLIC, foreground owns APB records and ACK. No APB access in ISR. */
#include "nn_irq.h"
#include "bsp.h"
#include "riscv.h"
#include "plic.h"
#define NN_PLIC_ID SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT
volatile uint32_t nn_irq_count,nn_irq_unexpected,nn_trap_cause,nn_trap_pc;
static uint32_t armed_epoch;
extern void trap_entry(void);
void trap(void) {
 uint32_t cause=csr_read(mcause),claim;
 if(cause!=0x8000000bu) {
  nn_trap_cause=cause;nn_trap_pc=csr_read(mepc);
  csr_clear(mstatus,MSTATUS_MIE);for(;;) { __asm__ volatile("nop"); }
 }
 while((claim=plic_claim(BSP_PLIC,BSP_PLIC_CPU_0))!=0) {
  plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,claim,0);
  if(claim==NN_PLIC_ID)nn_irq_count++;else nn_irq_unexpected++;
  plic_release(BSP_PLIC,BSP_PLIC_CPU_0,claim);
 }
}
void nn_irq_init(void) {
 plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,NN_PLIC_ID,0);
 plic_set_threshold(BSP_PLIC,BSP_PLIC_CPU_0,0);
 plic_set_priority(BSP_PLIC,NN_PLIC_ID,1);
 csr_write(mtvec,trap_entry);csr_set(mie,MIE_MEIE);csr_set(mstatus,MSTATUS_MIE);
}
void nn_irq_disarm(const nn_control_io *io) {
 (void)nn_control_command(io,6);plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,NN_PLIC_ID,0);
}
unsigned nn_irq_arm(const nn_control_io *io) {
 uint32_t saved=csr_read(mstatus),claim;unsigned rc,n;
 csr_clear(mstatus,MSTATUS_MIE);
 rc=nn_control_command(io,6);
 if(!rc) {
  /* Source deassertion crosses IRQ CDC before APB round trip completes. */
  plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,NN_PLIC_ID,1);
  for(n=0;n<4;n++){claim=plic_claim(BSP_PLIC,BSP_PLIC_CPU_0);if(!claim)break;plic_release(BSP_PLIC,BSP_PLIC_CPU_0,claim);}
  if(n==4){plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,NN_PLIC_ID,0);rc=NN_FAULT;}
  armed_epoch=nn_irq_count;if(!rc)rc=nn_control_command(io,5);
 }
 if(saved&MSTATUS_MIE)csr_set(mstatus,MSTATUS_MIE);
 return rc;
}
unsigned nn_irq_wait(const nn_control_io *io,uint32_t timeout,nn_control_record *r) {
 uint32_t began=io->ticks();
 /* No STATUS polling while waiting: actual external interrupt required. */
 while(nn_irq_count==armed_epoch) {
  if((uint32_t)(io->ticks()-began)>=timeout)return NN_TIMEOUT;
  io->pause();
 }
 nn_control_status(io,r);
 return (r->flags&8u)&&(r->flags&16u)&&r->result==1u&&r->accepted_id==r->done_id?NN_COMMAND_OK:NN_BAD_COMPLETION;
}
