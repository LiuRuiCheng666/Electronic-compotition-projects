/* C inference admission control; real video scheduler retains all DDR ownership. */
#include "bsp.h"
#include <string.h>
#include "nn_control.h"
#include "nn_irq.h"
#include "c_system.h"
#include "camera_light.h"
#include "hdmi_input_diag.h"
#include "c_photo.h"
#include "c_net.h"
static const nn_control_io control_io;
static unsigned use_irq=1;

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

static uint32_t ticks_now(void) { return clint_getTimeLow(BSP_CLINT); }
static void poll_pause(void) { camera_light_service(&control_io);bsp_uDelay(1000); }
static const nn_control_io control_io={reg_read,reg_write,ticks_now,poll_pause};

static void show_control(void)
{
    nn_control_record r;
    if(!nn_control_probe(&control_io)) { bsp_printf("ERR wrong control image\r\n"); return; }
    nn_control_status(&control_io,&r);
    bsp_printf("control_id=0x%x completion_mode=%s cpu_mode=%d queued=%d inflight=%d pending_ack=%d\r\n",
        (int)NN_CONTROL_ID,use_irq?"IRQ":"POLL",(int)(r.flags&1),(int)((r.flags>>1)&1),(int)((r.flags>>2)&1),(int)((r.flags>>3)&1));
    bsp_printf("accepted_valid=%d accepted_frame=%d done_frame=%d task_result=%d fault=%d can_queue=%d scheduler_idle=%d\r\n",
        (int)((r.flags>>4)&1),(int)r.accepted_id,(int)r.done_id,(int)r.result,
        (int)((r.flags>>6)&1),(int)((r.flags>>7)&1),(int)((r.flags>>8)&1));
}
static void send_control(unsigned opcode)
{
    unsigned rc=nn_control_command(&control_io,opcode);
    bsp_printf("command=%d result=%s\r\n",(int)opcode,nn_control_error(rc));
    if(!rc && opcode==NN_MODE_AUTO)c_system_ui(&control_io,3,1);
    if(!rc && opcode==NN_MODE_CPU)c_system_ui(&control_io,use_irq?6:5,1);
    show_control();
}
static void run_tasks(const char *arg)
{
    unsigned count=0,i,rc;
    nn_control_record r;
    uint32_t began;
    if(!*arg) { bsp_printf("ERR use run 1..100\r\n"); return; }
    for(;*arg;arg++) {
        if(*arg<'0'||*arg>'9'||count>100) { bsp_printf("ERR use run 1..100\r\n"); return; }
        count=count*10+(unsigned)(*arg-'0');
    }
    if(count<1||count>100) { bsp_printf("ERR use run 1..100\r\n"); return; }
    rc=nn_control_command(&control_io,NN_MODE_CPU);
    if(rc) { bsp_printf("ERR %s\r\n",nn_control_error(rc)); return; }
    c_system_ui(&control_io,use_irq?6:5,1);
    for(i=0;i<count;i++) {
        began=ticks_now();
        if(use_irq && (rc=nn_irq_arm(&control_io))) { bsp_printf("ERR IRQ arm=%s\r\n",nn_control_error(rc));return; }
        rc=nn_control_command(&control_io,NN_START);
        if(rc) { bsp_printf("STOP task=%d result=%s; state preserved\r\n",(int)(i+1),nn_control_error(rc)); return; }
        rc=use_irq?nn_irq_wait(&control_io,BSP_CLINT_HZ*10u,&r):nn_control_wait(&control_io,BSP_CLINT_HZ*10u,&r);
        if(rc) { bsp_printf("STOP task=%d result=%s; inspect ctrl/nnstatus before ack or reset\r\n",(int)(i+1),nn_control_error(rc)); show_control(); return; }
        bsp_printf("task=%d accepted=%d done=%d result=PASS elapsed_ms=%d\r\n",
            (int)(i+1),(int)r.accepted_id,(int)r.done_id,(int)((uint32_t)(ticks_now()-began)/(BSP_CLINT_HZ/1000u)));
        rc=nn_control_command(&control_io,NN_ACK);
        if(use_irq)nn_irq_disarm(&control_io);
        if(rc) { bsp_printf("STOP ack=%s\r\n",nn_control_error(rc)); return; }
    }
    bsp_printf("run_complete=%d; CPU mode retained; use mode auto for continuous video\r\n",(int)count);
}

static int identify(void)
{
    uint32_t id = reg_read(0);
    bsp_printf("backend=HW_PROBE; NN_control=%s\r\n",
        (reg_read(0x100)==NN_OBSERVER_ABI && reg_read(0x200)==NN_CONTROL_ID)?"CONNECTED":"NOT_CONNECTED");
    bsp_printf("peripheral_id=0x%x id_check=%s\r\n", (int)id,
               id == PROBE_ID ? "PASS" : "FAIL");
    if (id != PROBE_ID) {
        bsp_printf("ERR unexpected peripheral; further accesses blocked.\r\n");
        return 0;
    }
    return 1;
}

static void show_video(void)
{
    unsigned seq, bad, rate;
    if(!(reg_read(4)&2u)||reg_read(0x400)!=0x56494401u) {bsp_printf("ERR video diagnostics unavailable\r\n");return;}
    seq=reg_read(0x408);
    if((reg_read(0x404)&6u)!=2u) {bsp_printf("ERR video snapshot timeout; reset required\r\n");return;}
    bad=reg_read(0x434);rate=reg_read(0x438);
    bsp_printf("video_seq=%d uptime_ms=%d\r\n",(int)seq,(int)reg_read(0x40c));
    bsp_printf("capture=%d abort=%d stale=%d\r\n",(int)reg_read(0x410),(int)reg_read(0x414),(int)reg_read(0x418));
    bsp_printf("nn=%d new=%d scans=%d errors=0x%x\r\n",(int)reg_read(0x41c),(int)reg_read(0x420),(int)reg_read(0x424),(int)reg_read(0x428));
    bsp_printf("preprocessed=%d skipped=%d underflows=%d bad_row=%d\r\n",(int)reg_read(0x42c),(int)reg_read(0x430),(int)(bad&65535u),(int)(bad>>16));
    u32 quality=reg_read(0x43c);
    bsp_printf("blank_frames=%d partial_frames=%d\r\n",(int)(quality&65535u),(int)(quality>>16));
    bsp_printf("CAP=%d NEW=%d HDMI=%d\r\n",(int)(rate>>20),(int)((rate>>10)&1023u),(int)(rate&1023u));
}

static void dispatch(char *line)
{
    char *end;
    while (*line == ' ' || *line == '\t') ++line;
    end = line + strlen(line);
    while (end > line && (end[-1] == ' ' || end[-1] == '\t')) *--end = '\0';
    if (*line == '\0') return;
    if(strcmp(line,"hdmi")==0 || strcmp(line,"hdmi status")==0) {
        hdmi_input_status h;
        if(!hdmi_input_read(reg_read,0x600u,&h)) {bsp_printf("ERR HDMI diagnostics unavailable\r\n");return;}
        bsp_printf("HDMI id=0x%x present=%d pll_lock=%d seq=%d width=%d height=%d\r\n",(int)h.id,(int)h.present,(int)h.pll_lock,(int)h.sequence,(int)h.width,(int)h.height);
        bsp_printf("frame_id=%d good=%d rejected=%d edid_reads=%d; expected=1280x720@60 RGB\r\n",(int)h.frame_id,(int)h.good_frames,(int)h.bad_frames,(int)h.edid_reads);return;
    }
    if(strcmp(line,"hdmi perf")==0) {
        uint32_t flags=reg_read(0x704),display,frame;
        reg_read(0x108);display=reg_read(0x11c);frame=reg_read(0x70c);
        bsp_printf("source=%s global_frame=%d displayed_frame=%d lag_source_frames=%d; queue estimate, not panel latency\r\n",(flags&1)?"HDMI":"CAMERA",(int)frame,(int)display,(int)(int32_t)(frame-display));return;
    }
    if(strcmp(line,"source")==0||strcmp(line,"source status")==0) {
        uint32_t flags=reg_read(0x704);
        bsp_printf("source_id=0x%x active=%s requested=%s switching=%d override=%d frame=%d SW3=input SW2=style\r\n",(int)reg_read(0x700),(flags&1)?"HDMI":"CAMERA",(flags&2)?"HDMI":"CAMERA",(int)((flags>>2)&1),(int)((flags>>3)&1),(int)reg_read(0x70c));return;
    }
    if(strcmp(line,"source camera")==0||strcmp(line,"source hdmi")==0||strcmp(line,"source buttons")==0) {
        if(reg_read(0x700)!=0x53524301u) {bsp_printf("ERR source ABI mismatch\r\n");return;}
        reg_write(0x708,strcmp(line,"source buttons")==0?0:strcmp(line,"source hdmi")==0?3:1);
        bsp_printf("source accepted; switch at frame boundary\r\n");return;
    }
    if(camera_light_dispatch(&control_io,line))return;
    if((strncmp(line,"camera ",7)==0||strncmp(line,"weights ",8)==0||strncmp(line,"style ",6)==0||strncmp(line,"fish ",5)==0||strncmp(line,"ui ",3)==0)&&!nn_control_probe(&control_io)) {
        bsp_printf("ERR platform ABI mismatch; command blocked\r\n");return;
    }

    if (strcmp(line, "help") == 0) {
        bsp_printf("source status/camera/hdmi/buttons; hdmi status/perf; SW3=in SW2=style SW0=reset\r\n");
        bsp_printf("light help; version/probe/status/scratch/nnstatus/video/ctrl/switch; mode cpu/auto; start/ack/run N; irq on/off/status\r\ncamera init/id/status/read HHHH; weights load/status; style 0..4/buttons; fish off only; ui on/off/0..7; roi full/center/left/right\r\n");
        bsp_printf("START=1; IRQ=PLIC16; off=poll.\r\n");
    } else if (strcmp(line, "version") == 0) {
        bsp_printf("firmware=C_systemDemo v0.26-fifofast backend=HW_PROBE\r\n");
    } else if(strcmp(line,"video")==0) {
        show_video();
    } else if (strcmp(line, "probe") == 0 || strcmp(line, "status") == 0) {
        if (identify()) {
            bsp_printf("capabilities=0x%x cpu_hz=%d\r\n",
                       (int)reg_read(4), (int)reg_read(8));
            bsp_printf("ram_base=0x%x ram_bytes=%d\r\n",
                       (int)reg_read(12), (int)reg_read(16));
            bsp_printf("heartbeat=0x%x scratch=0x%x\r\n",
                       (int)reg_read(20), (int)reg_read(32));
        }
    } else if(strcmp(line,"camera status")==0) {
        bsp_printf("camera_ready=%d error=%d table_index=%d bridge=0x%x\r\n",(int)c_camera_ready,(int)c_camera_error,(int)c_camera_index,(int)reg_read(0x344));
    } else if(strcmp(line,"camera init")==0) {
        unsigned rc=c_camera_init(&control_io);bsp_printf("camera_init=%d ready=%d\r\n",(int)rc,(int)c_camera_ready);
    } else if(strcmp(line,"camera id")==0) {
        unsigned h=0,l=0,rc=c_camera_read(&control_io,0x3107,&h);if(!rc)rc=c_camera_read(&control_io,0x3108,&l);
        bsp_printf("camera_id=0x%x i2c_result=%d\r\n",(int)((h<<8)|l),(int)rc);
    } else if(strncmp(line,"camera read ",12)==0) {
        unsigned addr=0,val=0,n=0,d;const char *p=line+12;
        for(;*p;p++){d=*p>='0'&&*p<='9'?*p-'0':*p>='a'&&*p<='f'?*p-'a'+10:*p>='A'&&*p<='F'?*p-'A'+10:16;
          if(d>15||n++>=4){bsp_printf("ERR use camera read HHHH\r\n");return;}addr=(addr<<4)|d;}
        if(!n){bsp_printf("ERR missing address\r\n");return;}
        unsigned rc=c_camera_read(&control_io,addr,&val);bsp_printf("reg=0x%x value=0x%x result=%d\r\n",(int)addr,(int)val,(int)rc);
    } else if(strcmp(line,"weights load")==0 || strcmp(line,"weights status")==0) {
        unsigned rc=0;if(line[8]=='l')rc=c_weights_load(&control_io);
        unsigned flags=reg_read(0x108),fault=reg_read(0x10c);
        bsp_printf("weights_result=%s ready=%d failed=%d fault=%d payload_bytes=16384 crc_verified=%d\r\n",nn_control_error(rc),(int)((flags>>1)&1),(int)((flags>>2)&1),(int)(fault&7),(int)(((flags&6u)==2u)));
    } else if(strncmp(line,"style ",6)==0) {
        unsigned rc;if(strcmp(line+6,"buttons")==0)rc=c_system_style(&control_io,0,1);
        else if(line[6]>='0'&&line[6]<='4'&&!line[7])rc=c_system_style(&control_io,line[6]-'0',0);
        else {bsp_printf("ERR use style 0..4/buttons\r\n");return;}
        bsp_printf("style_command=%s; applied after inference\r\n",nn_control_error(rc));
    } else if(strncmp(line,"fish ",5)==0) {
        if(strcmp(line+5,"off")!=0){bsp_printf("ERR fish unavailable in Ethernet test build\r\n");return;}
        unsigned rc=c_system_fish(&control_io,0,0);
        bsp_printf("fish_command=%s; hardware disabled in Ethernet test build\r\n",nn_control_error(rc));
    } else if(strncmp(line,"roi ",4)==0) {
        unsigned mode,rc;
        if(!(reg_read(0x104)&8u)){bsp_printf("ERR ROI unavailable\r\n");return;}
        if(strcmp(line+4,"full")==0)mode=0;
        else if(strcmp(line+4,"center")==0)mode=1;
        else if(strcmp(line+4,"left")==0)mode=2;
        else if(strcmp(line+4,"right")==0)mode=3;
        else {bsp_printf("ERR use roi full/center/left/right\r\n");return;}
        rc=c_system_roi(&control_io,mode);
        bsp_printf("roi_command=%s mode=%d; applied per accepted frame\r\n",nn_control_error(rc),(int)mode);
    } else if(strncmp(line,"ui ",3)==0) {
        unsigned rc;if(strcmp(line+3,"off")==0)rc=c_system_ui(&control_io,c_system_config>>7,0);
        else if(strcmp(line+3,"on")==0)rc=c_system_ui(&control_io,c_system_config>>7,1);
        else if(line[3]>='0'&&line[3]<='7'&&!line[4])rc=c_system_ui(&control_io,line[3]-'0',1);
        else {bsp_printf("ERR use ui on/off/0..7\r\n");return;}
        bsp_printf("ui_command=%s; C tag=%d\r\n",nn_control_error(rc),(int)((c_system_config>>7)&7u));
    } else if (strcmp(line,"irq on")==0) {
        if(!nn_control_probe(&control_io)){bsp_printf("ERR wrong control image\r\n");return;}
        use_irq=1;bsp_printf("completion_mode=IRQ; PLIC16 armed per task\r\n");
    } else if (strcmp(line,"irq off")==0) {
        nn_irq_disarm(&control_io);use_irq=0;bsp_printf("completion_mode=POLL\r\n");
    } else if (strcmp(line,"irq status")==0) {
        bsp_printf("mode=%s irq_count=%d unexpected=%d trap_cause=0x%x trap_pc=0x%x\r\n",use_irq?"IRQ":"POLL",(int)nn_irq_count,(int)nn_irq_unexpected,(int)nn_trap_cause,(int)nn_trap_pc);
    } else if (strcmp(line, "ctrl") == 0) {
        show_control();
    } else if (strcmp(line, "mode cpu") == 0) {
        send_control(NN_MODE_CPU);
    } else if (strcmp(line, "mode auto") == 0) {
        send_control(NN_MODE_AUTO);
    } else if (strcmp(line, "start") == 0) {
        if(use_irq && nn_irq_arm(&control_io)){bsp_printf("ERR IRQ arm failed\r\n");return;}
        send_control(NN_START);
    } else if (strcmp(line, "ack") == 0) {
        send_control(NN_ACK);if(use_irq)nn_irq_disarm(&control_io);
    } else if (strncmp(line, "run ", 4) == 0) {
        run_tasks(line+4);
    } else if (strcmp(line, "photo sample") == 0) {
        c_photo_preview(&control_io);
    } else if (strcmp(line, "photo") == 0) {
        c_photo_capture(&control_io);
    } else if (strcmp(line, "photo release") == 0) {
        c_photo_release(&control_io);
    } else if (strcmp(line, "switch") == 0) {
        uint32_t flags,cycles,hz;
        if(!identify())return;
        if(!(reg_read(0x104)&4u) || reg_read(0x144)!=0x53574d01u){bsp_printf("ERR switch monitor unavailable\r\n");return;}
        (void)reg_read(0x108); /* coherent snapshot of the entire record */
        cycles=reg_read(0x134);flags=reg_read(0x140);hz=reg_read(0x120);
        bsp_printf("switch_endpoint=FULL_VISIBLE_FRAME_END; command_transport_excluded\r\n");
        bsp_printf("valid=%d pending=%d superseded=%d timeout=%d fault=%d below_100ms=%d target=%d\r\n",
          (int)(flags&1),(int)((flags>>1)&1),(int)((flags>>2)&1),(int)((flags>>3)&1),
          (int)((flags>>4)&1),(int)((flags>>5)&1),(int)((flags>>8)&7));
        bsp_printf("cycles=%d core_hz=%d elapsed_us=%d request_frame=%d shown_frame=%d\r\n",
          (int)cycles,(int)hz,(int)(hz>=1000000u?cycles/(hz/1000000u):0u),
          (int)reg_read(0x138),(int)reg_read(0x13c));
    } else if (strcmp(line, "nnstatus") == 0) {
        uint32_t id, flags, faults, model;
        if (!identify()) return;
        id=reg_read(0x100);
        bsp_printf("NN_observer_id=0x%x id_check=%s\r\n",(int)id,id==NN_OBSERVER_ABI?"PASS":"FAIL");
        if(id!=NN_OBSERVER_ABI)return;
        /* STATUS read waits for a fresh, coherent CDC snapshot. */
        flags=reg_read(0x108);faults=reg_read(0x10c);model=reg_read(0x110);
        bsp_printf("NN_observe=CONNECTED; CPU_start_ack=CONNECTED; completion_mode=%s\r\n",use_irq?"IRQ":"POLL");
        bsp_printf("nn_status=0x%x ddr_ready=%d boot_ready=%d boot_failed=%d busy=%d done_raw=%d\r\n",
          (int)flags,(int)(flags&1),(int)((flags>>1)&1),(int)((flags>>2)&1),(int)((flags>>3)&1),(int)((flags>>4)&1));
        bsp_printf("pass=%d fail=%d scheduler_fault=%d display_fault=%d idle=%d\r\n",
          (int)((flags>>5)&1),(int)((flags>>6)&1),(int)((flags>>7)&1),(int)((flags>>8)&1),(int)((flags>>9)&1));
        bsp_printf("boot_fault=%d compute_fault=%d active_model=%d requested_model=%d\r\n",
          (int)(faults&7),(int)((faults>>8)&7),(int)((model&3)|((model>>2)&4)),(int)(((model>>2)&3)|((model>>3)&4)));
        bsp_printf("input=0x%x output=0x%x displayed_frame=%d core_hz=%d\r\n",
          (int)reg_read(0x114),(int)reg_read(0x118),(int)reg_read(0x11c),(int)reg_read(0x120));
        bsp_printf("start_count=%d done_count=%d snapshot_valid=%d\r\n",
          (int)reg_read(0x124),(int)reg_read(0x128),(int)((reg_read(0x104)>>1)&1));
        bsp_printf("diagnostic_state=0x%x diagnostic_axi=0x%x\r\n",
          (int)reg_read(0x12c),(int)reg_read(0x130));
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
        bsp_printf("Use help.\r\n");
    }
}

void main(void)
{
    char line[LINE_CAPACITY];
    unsigned int used = 0;
    int overflow = 0;
    int previous_was_cr = 0;

    bsp_init();nn_irq_init();
    bsp_printf("\r\nC_systemDemo v0.26-fifofast\r\n");
    bsp_printf("backend=HW_PROBE; RAM32K.\r\n");
    bsp_printf("Send help.\r\n");
    if(nn_control_probe(&control_io)) {
        unsigned rc,old_flags=reg_read(0x208);
        c_system_config=reg_read(0x21c)&4095u;
        if(c_system_config&1u) {rc=c_camera_resume(&control_io);bsp_printf("warm_resume=1\r\n");}
        else {c_system_ui(&control_io,1,1);bsp_uDelay(10000);rc=c_camera_init(&control_io);}
        bsp_printf("camera_init_result=%d registers=%d vts_readback_check=%s ready=%d\r\n",(int)rc,(int)c_camera_index,rc?"FAIL":"PASS",(int)c_camera_ready);
        {c_system_ui(&control_io,2,1);rc=c_weights_load(&control_io);bsp_printf("weights_load=%s\r\n",nn_control_error(rc));}
        c_system_ui(&control_io,rc?4:(old_flags&1u)?6:3,1);
    } else bsp_printf("ERR ABI mismatch; camera/weights controls not accessed\r\n");
    prompt();

    c_net_init();
    while (1) {
        c_net_poll();
        camera_light_service(&control_io);
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
                    bsp_printf("ERR max63 chars.\r\n");
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
