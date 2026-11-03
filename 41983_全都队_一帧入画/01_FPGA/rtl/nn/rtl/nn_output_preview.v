`timescale 1ns/1ps
`default_nettype none
// Two parameterized RGB banks, captured from the existing CRC byte stream.
// Write the inactive bank, publish at VS, and wait for acknowledgement.
// No frame-sized register array and no new AXI master.
module nn_output_preview #(
    parameter integer SCALE_X=60, SCALE_Y=45,
    parameter integer IMAGE_W=32, IMAGE_H=24,
    parameter integer DISPLAY_H=IMAGE_H*SCALE_Y
)(
    input wire core_clk, pixel_clk, rst_n,
    input wire byte_valid, input wire [7:0] byte_data,
    input wire result_ready,
    input wire in_vs, in_hs, in_de,
    input wire [7:0] in_r, in_g, in_b,
    output wire [7:0] out_r, out_g, out_b,
    output reg out_vs, out_hs, out_de,
    output reg preview_active,
    output reg frame_accepted
);
    localparam integer PIXELS=IMAGE_W*IMAGE_H, PIXEL_AW=$clog2(PIXELS);
    (* syn_ramstyle="block_ram" *) reg [23:0] mem0 [0:PIXELS-1];
    (* syn_ramstyle="block_ram" *) reg [23:0] mem1 [0:PIXELS-1];
    reg [PIXEL_AW-1:0] write_pixel;
    reg [1:0] component;
    reg [7:0] saved_r, saved_g;
    reg captured;
    reg write_bank, publish_toggle, publish_pending;
    reg ack_toggle;
    (* async_reg="true" *) reg [1:0] ack_sync;
    wire write_enable=byte_valid && !captured && !publish_pending && !result_ready && component==2;
    // Keep the RAM write process free of reset to permit block RAM inference.
    always @(posedge core_clk)
        if(write_enable && !write_bank) mem0[write_pixel] <= {byte_data,saved_g,saved_r};
    always @(posedge core_clk)
        if(write_enable && write_bank) mem1[write_pixel] <= {byte_data,saved_g,saved_r};
    always @(posedge core_clk or negedge rst_n) begin
        if(!rst_n) begin
            write_pixel<=0; component<=0; saved_r<=0; saved_g<=0; captured<=0;
            write_bank<=0; publish_toggle<=0; publish_pending<=0;
            ack_sync<=0; frame_accepted<=0;
        end else begin
            ack_sync<={ack_sync[0],ack_toggle};
            if(!result_ready) frame_accepted<=0;
            if(captured && result_ready && !publish_pending && !frame_accepted) begin
                publish_toggle<=~publish_toggle; publish_pending<=1;
            end
            if(publish_pending && ack_sync[1]==publish_toggle) begin
                frame_accepted<=1; publish_pending<=0; write_bank<=~write_bank;
                write_pixel<=0; component<=0; captured<=0;
            end
            if(byte_valid && !captured && !publish_pending && !result_ready) begin
            case(component)
                0: begin saved_r<=byte_data; component<=1; end
                1: begin saved_g<=byte_data; component<=2; end
                2: begin
                    component<=0;
                    if(write_pixel==PIXELS-1) captured<=1;
                    else write_pixel<=write_pixel+1'b1;
                end
                default: component<=0;
            endcase
            end
        end
    end
    (* async_reg="true" *) reg [1:0] ready_sync;
    reg display_bank;
    reg vs_d, de_d;
    reg [$clog2(SCALE_X+1)-1:0] repeat_x;
    reg [$clog2(DISPLAY_H+IMAGE_H+1)-1:0] repeat_y;
    reg [$clog2(IMAGE_W)-1:0] col;
    reg [$clog2(IMAGE_H)-1:0] row;
    wire [PIXEL_AW-1:0] read_pixel=row*IMAGE_W+col;
    reg [23:0] ram_q0, ram_q1;
    reg [23:0] camera_q;
    always @(posedge pixel_clk) ram_q0<=mem0[read_pixel];
    always @(posedge pixel_clk) ram_q1<=mem1[read_pixel];
    assign {out_b,out_g,out_r}=preview_active ? (display_bank ? ram_q1 : ram_q0) : camera_q;
    always @(posedge pixel_clk or negedge rst_n) begin
        if(!rst_n) begin
            ready_sync<=0; vs_d<=0; de_d<=0;
            display_bank<=1; ack_toggle<=0;
            repeat_x<=0; repeat_y<=0; col<=0; row<=0;
            camera_q<=0; out_vs<=0; out_hs<=0; out_de<=0; preview_active<=0;
        end else begin
            ready_sync<={ready_sync[0],publish_toggle};
            vs_d<=in_vs; de_d<=in_de;
            camera_q<={in_b,in_g,in_r};
            out_vs<=in_vs; out_hs<=in_hs; out_de<=in_de;
            // Change display source only in vertical blanking, never mid-frame.
            if(in_vs && !vs_d) begin
                if(ready_sync[1]!=ack_toggle) begin
                    // Bank is encoded by toggle parity: first publish=1/bank0.
                    // Only a single control bit crosses domains, not a bank bus.
                    display_bank<=~ready_sync[1]; preview_active<=1;
                    ack_toggle<=ready_sync[1];
                end
                repeat_x<=0; repeat_y<=0; col<=0; row<=0;
            end else if(in_de) begin
                if(repeat_x==SCALE_X-1) begin
                    repeat_x<=0;
                    if(col!=IMAGE_W-1) col<=col+1'b1;
                end else repeat_x<=repeat_x+1'b1;
            end else if(de_d) begin
                repeat_x<=0; col<=0;
                // Fractional repeat supports 48 rows across all 1080 lines.
                if(repeat_y+IMAGE_H>=DISPLAY_H) begin
                    repeat_y<=repeat_y+IMAGE_H-DISPLAY_H;
                    if(row!=IMAGE_H-1) row<=row+1'b1;
                end else repeat_y<=repeat_y+IMAGE_H;
            end
        end
    end
endmodule

// One inference at a time. Restart only after the checked output has actually
// reached the display at VS. Keep the last good preview while the NN resets.
module nn_video_scheduler #(
    parameter integer PAUSE_CYCLES=0,
    parameter integer RESET_CYCLES=32
)(
    input wire clk,rst_n,enable,camera_ready,camera_failed,
    input wire nn_done,nn_pass,nn_failed,frame_accepted,
    output reg capture_request,session_reset_n,start,ever_started,
    output reg success_seen
);
    localparam BOOT=0,RESET_SESSION=1,CAPTURE=2,RUN=3,DISPLAY=4,PAUSE=5,HALT=6;
    localparam TIMER_W=$clog2(PAUSE_CYCLES+RESET_CYCLES+1);
    reg [2:0] state;
    reg [TIMER_W-1:0] timer;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=BOOT; timer<=0; capture_request<=0; session_reset_n<=0;
            start<=0; ever_started<=0; success_seen<=0;
        end else begin
            start<=0;
            if(camera_failed || nn_failed) state<=HALT;
            else case(state)
                BOOT: if(enable) begin state<=RESET_SESSION; timer<=0; end
                RESET_SESSION: begin
                    if(timer==RESET_CYCLES-1 && !camera_ready) begin
                        session_reset_n<=1; capture_request<=1; state<=CAPTURE;
                    end else if(timer<RESET_CYCLES-1) timer<=timer+1'b1;
                end
                CAPTURE: if(camera_ready) begin start<=1; ever_started<=1; state<=RUN; end
                RUN: if(nn_done) begin
                    if(nn_pass) begin success_seen<=1; state<=DISPLAY; end
                    else state<=HALT;
                end
                DISPLAY: if(frame_accepted) begin
                    capture_request<=0; session_reset_n<=0; timer<=0;
                    state<=(PAUSE_CYCLES == 0) ? RESET_SESSION : PAUSE;
                end
                PAUSE: if((PAUSE_CYCLES == 0) || timer==PAUSE_CYCLES-1) begin timer<=0; state<=RESET_SESSION; end
                       else timer<=timer+1'b1;
                HALT: state<=HALT;
                default: state<=HALT;
            endcase
        end
    end
endmodule
`default_nettype wire
