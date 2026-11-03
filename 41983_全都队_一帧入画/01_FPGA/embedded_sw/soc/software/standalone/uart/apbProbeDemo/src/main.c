/* C controlDemo: UART command shell, hardware control not connected yet. */
#include "bsp.h"
#include <string.h>

#define LINE_CAPACITY 64

static void prompt(void)
{
    bsp_printf("C> ");
}

#define APB_BASE ((uintptr_t)0xF8100000u)
#define PROBE_ID 0x434D0001u

static uint32_t reg_read(unsigned offset)
{
    uint32_t value;
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
    value = *(volatile uint32_t *)(APB_BASE + offset);
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
    return value;
}

static void reg_write(unsigned offset, uint32_t value)
{
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
    *(volatile uint32_t *)(APB_BASE + offset) = value;
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
}

static int identify(void)
{
    uint32_t id = reg_read(0);
    bsp_printf("backend=HW_PROBE; NN_control=NOT_CONNECTED\r\n");
    bsp_printf("peripheral_id=0x%x id_check=%s\r\n", (int)id,
               id == PROBE_ID ? "PASS" : "FAIL");
    if (id != PROBE_ID) {
        bsp_printf("ERR unexpected peripheral; further accesses blocked.\r\n");
        return 0;
    }
    return 1;
}

static void dispatch(char *line)
{
    char *end;
    while (*line == ' ' || *line == '\t') ++line;
    end = line + strlen(line);
    while (end > line && (end[-1] == ' ' || end[-1] == '\t')) *--end = '\0';
    if (*line == '\0') return;

    if (strcmp(line, "help") == 0) {
        bsp_printf("Commands: help version probe status scratch\r\n");
        bsp_printf("Real APB bring-up peripheral; NO NN inference or IRQ test.\r\n");
    } else if (strcmp(line, "version") == 0) {
        bsp_printf("firmware=C_apbProbeDemo v0.1 backend=HW_PROBE\r\n");
    } else if (strcmp(line, "probe") == 0 || strcmp(line, "status") == 0) {
        if (identify()) {
            bsp_printf("capabilities=0x%x cpu_hz=%d\r\n",
                       (int)reg_read(4), (int)reg_read(8));
            bsp_printf("ram_base=0x%x ram_bytes=%d\r\n",
                       (int)reg_read(12), (int)reg_read(16));
            bsp_printf("heartbeat=0x%x scratch=0x%x\r\n",
                       (int)reg_read(20), (int)reg_read(32));
        }
    } else if (strcmp(line, "scratch") == 0) {
        uint32_t original, first, second, restored;
        if (!identify()) return;
        original = reg_read(32);
        reg_write(32, 0xA55A1234u);
        first = reg_read(32);
        reg_write(32, 0x5AA5FEDCu);
        second = reg_read(32);
        reg_write(32, original);
        restored = reg_read(32);
        bsp_printf("readback1=0x%x readback2=0x%x restored=0x%x\r\n",
                   (int)first, (int)second, (int)restored);
        bsp_printf("hardware_scratch_test=%s\r\n",
                   first == 0xA55A1234u && second == 0x5AA5FEDCu &&
                   restored == original ? "PASS" : "FAIL");
    } else {
        bsp_printf("ERR unknown command: %s\r\n", line);
        bsp_printf("Use help for available commands.\r\n");
    }
}

void main(void)
{
    char line[LINE_CAPACITY];
    unsigned int used = 0;
    int overflow = 0;
    int previous_was_cr = 0;

    bsp_init();
    bsp_printf("\r\nC_apbProbeDemo v0.1\r\n");
    bsp_printf("backend=HW_PROBE; firmware runs in 16KB on-chip RAM.\r\n");
    bsp_printf("Send help followed by CR or LF.\r\n");
    prompt();

    while (1) {
        while (uart_readOccupancy(BSP_UART_TERMINAL)) {
            unsigned char ch = uart_read(BSP_UART_TERMINAL);

            /* Treat CR+LF as one terminator, including split UART packets. */
            if (ch == '\n' && previous_was_cr) {
                previous_was_cr = 0;
                continue;
            }
            previous_was_cr = (ch == '\r');
            if (ch == '\r' || ch == '\n') {
                bsp_printf("\r\n");
                if (overflow) {
                    bsp_printf("ERR line too long; maximum 63 characters.\r\n");
                } else {
                    line[used] = '\0';
                    dispatch(line);
                }
                used = 0;
                overflow = 0;
                prompt();
                continue;
            }

            /* Discard the remainder of an overlong command until terminator. */
            if (overflow) {
                continue;
            }
            if (ch == '\b' || ch == 127) {
                if (used > 0) {
                    --used;
                    bsp_printf("\b \b");
                }
            } else if ((ch >= 32 && ch <= 126) || ch == '\t') {
                if (used < LINE_CAPACITY - 1) {
                    line[used++] = ch;
                    bsp_printf("%c", ch);
                } else {
                    overflow = 1;
                }
            }
        }
    }
}
