#ifndef HDMI_INPUT_DIAG_H
#define HDMI_INPUT_DIAG_H
#include <stdint.h>
/* Portable read-only APB driver. base is in the callback's address space.
 * Reading SEQUENCE freezes the following four payload words in hardware.
 * No camera/AE/AWB, UART, interrupt or board-specific dependency. */
typedef struct {
    uint32_t id, sequence, frame_id, good_frames, bad_frames, edid_reads;
    uint16_t width, height;
    uint8_t present, pll_lock;
} hdmi_input_status;
static inline int hdmi_input_read(uint32_t (*read_reg)(unsigned),
                                  unsigned base, hdmi_input_status *s)
{
    uint32_t flags, wh;
    if (!read_reg || !s) return 0;
    s->id=read_reg(base);
    if (s->id!=0x48444d01u) return 0;
    flags=read_reg(base+4);s->present=flags&1u;s->pll_lock=(flags>>1)&1u;
    s->sequence=read_reg(base+8);
    wh=read_reg(base+12);s->width=wh&65535u;s->height=wh>>16;
    s->frame_id=read_reg(base+16);s->good_frames=read_reg(base+20);
    s->bad_frames=read_reg(base+24);s->edid_reads=read_reg(base+28);
    return 1;
}
#endif
