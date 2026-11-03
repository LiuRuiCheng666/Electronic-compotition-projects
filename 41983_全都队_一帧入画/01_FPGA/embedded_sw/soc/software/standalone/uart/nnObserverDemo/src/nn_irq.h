#ifndef NN_IRQ_H
#define NN_IRQ_H
#include "nn_control.h"
extern volatile uint32_t nn_irq_count,nn_irq_unexpected,nn_trap_cause,nn_trap_pc;
void nn_irq_init(void);
unsigned nn_irq_arm(const nn_control_io *io);
void nn_irq_disarm(const nn_control_io *io);
unsigned nn_irq_wait(const nn_control_io *io,uint32_t timeout,nn_control_record *r);
#endif
