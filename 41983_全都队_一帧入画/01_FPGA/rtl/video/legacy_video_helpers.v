

// RGBX preprocessing definitions are embedded here so GUI project saves
// cannot remove their registration. The old standalone file is a stub.
// HD720=1: full1920x1080 ->1280x720, floor(3*u/2), floor(3*v/2).
// HD720=0 retains center1440x1080 ->640x480 point sampling.
// Source coordinate: (240 + floor(9*u/4), floor(9*v/4)).
// RGBX byte order at increasing addresses: R,G,B,0. No backpressure.
// All inputs/outputs belong to clk. A descriptor is consumed at the first
// source pixel after rising VS; repeats of the same frame_id are legal.
// o_last marks the last selected pixel; o_frame_done is delayed until the
// NEXT rising VS validates the entire source frame. Never commit on o_last.
module rgbx_crop_scale_640 #(parameter integer HD720=0) (
    input clk, input rst_n,
    input i_vs, input i_de,
    input [7:0] i_r, input [7:0] i_g, input [7:0] i_b,
    input i_tag_strobe, input [31:0] i_tag_id, input i_tag_valid,
    input i_meta_error,
    output reg [31:0] o_rgbx,
    output reg o_valid, output reg o_sof, output reg o_eol,
    output reg o_last,
    output reg [10:0] o_x, output reg [9:0] o_y,
    output reg [31:0] o_frame_id, output reg o_frame_valid,
    output reg o_frame_done, output reg o_frame_abort,
    output reg [19:0] o_pixel_count,
    output reg [31:0] o_frame_count,
    output reg [3:0] o_error
);
localparam OW=HD720?1280:640,OH=HD720?720:480,LEFT=HD720?0:240;
reg vs_d, de_d, armed, started, frame_bad;
reg [11:0] src_x, next_x;
reg [10:0] src_y, next_y;
reg [10:0] out_x;
reg [9:0] out_y;
reg pending, pending_valid, pending_bad;
reg [31:0] pending_id;
wire vs_rise = i_vs && !vs_d;
wire first_pixel = armed && !started && i_de;
wire have_tag = pending || i_tag_strobe;
wire tag_valid = i_tag_strobe ? i_tag_valid : pending_valid;
wire [31:0] tag_id = i_tag_strobe ? i_tag_id : pending_id;
wire selected = armed && i_de && (src_y == next_y) &&
                (src_x == next_x) && (out_x < OW);
wire usable = first_pixel ? (have_tag && tag_valid && !pending_bad &&
                            !(pending && i_tag_strobe) && !i_meta_error) :
                           (o_frame_valid && !frame_bad && !i_meta_error);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_d <= 0; de_d <= 0; armed <= 0; started <= 0; frame_bad <= 0;
        src_x <= 0; src_y <= 0; next_x <= LEFT; next_y <= 0;
        out_x <= 0; out_y <= 0;
        pending <= 0; pending_id <= 0; pending_valid <= 0; pending_bad <= 0;
        o_rgbx <= 0; o_valid <= 0; o_sof <= 0; o_eol <= 0; o_last <= 0;
        o_x <= 0; o_y <= 0; o_frame_id <= 0; o_frame_valid <= 0;
        o_frame_done <= 0; o_frame_abort <= 0;
        o_pixel_count <= 0; o_frame_count <= 0; o_error <= 0;
    end else begin
        vs_d <= i_vs; de_d <= i_de;
        o_valid <= 0; o_sof <= 0; o_eol <= 0; o_last <= 0;
        o_frame_done <= 0; o_frame_abort <= 0;
        if (i_tag_strobe) begin
            if (started && !vs_rise) begin
                // A late descriptor belongs to the already-started frame.
                // Discard it rather than reusing it for the next frame.
                pending <= 0;
                pending_bad <= 0;
                o_error[1] <= 1;
                frame_bad <= 1;
            end else begin
                pending <= 1;
                pending_id <= i_tag_id;
                pending_valid <= i_tag_valid;
                if (pending) begin
                    pending_bad <= 1;
                    o_error[2] <= 1; // descriptor overwritten before use
                    frame_bad <= 1;
                end
            end
        end
        if (i_meta_error) begin
            o_error[3] <= 1;
            frame_bad <= 1;
        end
        if (vs_rise) begin
            if (armed) begin
                if (started && !frame_bad && !i_meta_error &&
                    o_frame_valid && src_y == 1080 && src_x == 0 &&
                    o_pixel_count == OW*OH) begin
                    o_frame_done <= 1;
                    o_frame_count <= o_frame_count + 1'b1;
                end else begin
                    o_frame_abort <= 1;
                    if (!started || src_y != 1080 || src_x != 0 ||
                        o_pixel_count != OW*OH)
                        o_error[0] <= 1;
                end
            end
            armed <= 1; started <= 0; frame_bad <= i_meta_error;
            src_x <= 0; src_y <= 0; next_x <= LEFT; next_y <= 0;
            out_x <= 0; out_y <= 0; o_pixel_count <= 0;
            o_frame_valid <= 0;
        end else if (armed) begin
            if (first_pixel) begin
                started <= 1;
                pending <= 0;
                pending_bad <= 0;
                o_frame_id <= have_tag ? tag_id : 32'd0;
                o_frame_valid <= have_tag && tag_valid && !pending_bad &&
                                 !(pending && i_tag_strobe) && !i_meta_error;
                frame_bad <= !have_tag || !tag_valid || i_meta_error ||
                             pending_bad || (pending && i_tag_strobe);
                if (!have_tag || !tag_valid) o_error[1] <= 1;
            end
            if (i_de) begin
                if (src_x < 4095) src_x <= src_x + 1'b1;
                if (src_x >= 1920 || src_y >= 1080) begin
                    frame_bad <= 1;
                    o_error[0] <= 1;
                end
                if (selected) begin
                    if (usable) begin
                        o_rgbx <= {8'h00, i_b, i_g, i_r};
                        o_valid <= 1;
                        o_sof <= out_x == 0 && out_y == 0;
                        o_eol <= out_x == OW-1;
                        o_last <= out_x == OW-1 && out_y == OH-1;
                        o_x <= out_x; o_y <= out_y;
                        o_pixel_count <= o_pixel_count + 1'b1;
                    end
                    out_x <= out_x + 1'b1;
                    next_x <= next_x + (HD720 ? (out_x[0]?12'd2:12'd1) : (out_x[1:0] == 3 ? 12'd3 : 12'd2));
                end
            end
            if (de_d && !i_de) begin
                if (src_x != 1920) begin
                    frame_bad <= 1;
                    o_error[0] <= 1;
                end
                src_x <= 0;
                if (src_y < 2047) src_y <= src_y + 1'b1;
                out_x <= 0; next_x <= LEFT;
                if (src_y == next_y && out_y < OH) begin
                    next_y <= next_y + (HD720 ? (out_y[0]?11'd2:11'd1) : (out_y[1:0] == 3 ? 11'd3 : 11'd2));
                    out_y <= out_y + 1'b1;
                end
            end
        end
    end
end
endmodule

// Passive tap: source descriptor is transferred from the RAW video clock,
// while the RGB pixel stream is already serialized in pixel_clk.
module rgbx_preprocess_640 #(parameter integer HD720=0) (
    input raw_clk, input pixel_clk, input rst_n,
    input [31:0] raw_frame_id, input raw_frame_valid,
    input [1:0] raw_frame_bank, input [31:0] raw_frame_addr,
    input raw_frame_latch, input raw_meta_error,
    input i_vs, input i_de,
    input [7:0] i_r, input [7:0] i_g, input [7:0] i_b,
    output [31:0] o_rgbx,
    output o_valid, output o_sof, output o_eol, output o_last,
    output [10:0] o_x, output [9:0] o_y,
    output [31:0] o_frame_id, output o_frame_valid,
    output o_frame_done, output o_frame_abort,
    output [19:0] o_pixel_count,
    output [31:0] o_frame_count,
    output [3:0] o_error
);
wire descriptor_busy, descriptor_overrun, descriptor_pulse;
wire [66:0] descriptor;
(* async_reg = "true" *) reg [1:0] error_sync;
raw_frame_descriptor_cdc u_rgb_descriptor_cdc (
    .src_clk(raw_clk), .dst_clk(pixel_clk), .rst_n(rst_n),
    .src_pulse(raw_frame_latch),
    .src_data({raw_frame_addr, raw_frame_bank, raw_frame_valid, raw_frame_id}),
    .src_busy(descriptor_busy), .src_overrun(descriptor_overrun),
    .dst_pulse(descriptor_pulse), .dst_data(descriptor)
);
always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) error_sync <= 0;
    else error_sync <= {error_sync[0], raw_meta_error | descriptor_overrun};
end
rgbx_crop_scale_640 #(.HD720(HD720)) u_crop_scale (
    .clk(pixel_clk), .rst_n(rst_n), .i_vs(i_vs), .i_de(i_de),
    .i_r(i_r), .i_g(i_g), .i_b(i_b),
    .i_tag_strobe(descriptor_pulse), .i_tag_id(descriptor[31:0]),
    .i_tag_valid(descriptor[32]), .i_meta_error(error_sync[1]),
    .o_rgbx(o_rgbx), .o_valid(o_valid), .o_sof(o_sof), .o_eol(o_eol),
    .o_last(o_last), .o_x(o_x), .o_y(o_y),
    .o_frame_id(o_frame_id), .o_frame_valid(o_frame_valid),
    .o_frame_done(o_frame_done), .o_frame_abort(o_frame_abort),
    .o_pixel_count(o_pixel_count), .o_frame_count(o_frame_count), .o_error(o_error)
);
endmodule

// RGBX DDR capture implementation (registered through this top file).
// Validation capture: two retained RGBX slots, no overwrite without release.
// DATA/START/END tokens share one FIFO, so commit never overtakes pixels.
// Reuses the project's synchronous-read dual_clock_fifo (one-cycle RAM).
// rgbx_ddr_capture is defined in rtl/video/rgbx_ddr_capture.v.


// Single outstanding consumer loan, all signals in core_clk domain.
// Frame descriptors remain stable under request backpressure. An accepted
// descriptor grants read ownership until a matching successful completion.
// Failed completions retain the slot for retry; stale completions never free it.
module rgbx_input_slot_handoff #(
    parameter BASE0=32'h02000000, parameter BASE1=32'h02200000,
    parameter integer DUAL_LOAN=0
)(
    input clk,input rst_n,
    input [1:0] slot_valid,
    input [31:0] slot0_frame_id,input [31:0] slot1_frame_id,
    output req_valid,input req_ready,
    output reg req_bank,output reg [31:0] req_addr,output reg [31:0] req_frame_id,
    input done_valid,output done_ready,
    input done_bank,input [31:0] done_frame_id,input done_error,
    output reg [1:0] release_slots,
    output busy,output reg [2:0] error,
    output reg [31:0] accepted_count,
    output reg [31:0] released_count,
    output reg [31:0] failed_count
);
generate if(DUAL_LOAN!=0) begin : G_DUAL_LOAN
reg [1:0] loaned,release_wait;
reg pending,preferred;
wire [1:0] available=slot_valid & ~loaned & ~release_wait;
wire chosen=available[preferred]?preferred:!preferred;
assign req_valid=pending;
assign done_ready=loaned[done_bank] && slot_valid[done_bank];
assign busy=|loaned;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  loaned<=0;release_wait<=0;pending<=0;preferred<=0;
  req_bank<=0;req_addr<=0;req_frame_id<=0;release_slots<=0;error<=0;
  accepted_count<=0;released_count<=0;failed_count<=0;
 end else begin
  release_slots<=0;release_wait<=release_wait & slot_valid;
  if(!pending && available!=0)begin
   req_bank<=chosen;req_addr<=chosen?BASE1:BASE0;
   req_frame_id<=chosen?slot1_frame_id:slot0_frame_id;pending<=1;
  end
  if(pending && !slot_valid[req_bank])begin error[2]<=1;pending<=0;end
  else if(req_valid && req_ready)begin
   loaned[req_bank]<=1;pending<=0;preferred<=!req_bank;
   accepted_count<=accepted_count+1'b1;
  end
  if(done_valid && done_ready)begin
   if(done_frame_id!=(done_bank?slot1_frame_id:slot0_frame_id))error[0]<=1;
   else if(done_error)begin error[1]<=1;failed_count<=failed_count+1'b1;end
   else begin
    loaned[done_bank]<=0;release_wait[done_bank]<=1;
    release_slots<=done_bank?2'b10:2'b01;released_count<=released_count+1'b1;
   end
  end
 end
end
end else begin : G_SINGLE_LOAN
localparam SELECT=0,REQUEST=1,PROCESS=2,RELEASE_WAIT=3;
reg [1:0] state;
reg preferred;
wire chosen=slot_valid[preferred]?preferred:!preferred;
assign req_valid=state==REQUEST;
assign done_ready=state==PROCESS && slot_valid[req_bank];
assign busy=state==PROCESS || state==RELEASE_WAIT;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=SELECT;preferred<=0;req_bank<=0;req_addr<=0;req_frame_id<=0;
        release_slots<=0;error<=0;
        accepted_count<=0;released_count<=0;failed_count<=0;
    end else begin
        release_slots<=0;
        case(state)
        SELECT: if(slot_valid!=0) begin
            req_bank<=chosen;
            req_addr<=chosen?BASE1:BASE0;
            req_frame_id<=chosen?slot1_frame_id:slot0_frame_id;
            state<=REQUEST;
        end
        REQUEST: if(!slot_valid[req_bank]) begin
            error[2]<=1;state<=SELECT;
        end else if(req_ready) begin
            accepted_count<=accepted_count+1'b1;state<=PROCESS;
        end
        PROCESS: if(!slot_valid[req_bank]) begin
            error[2]<=1;failed_count<=failed_count+1'b1;state<=SELECT;
        end else if(done_valid) begin
            if(done_bank!=req_bank || done_frame_id!=req_frame_id) begin
                error[0]<=1; // Consume and reject stale/mismatched completion.
            end else begin
                preferred<=!req_bank;
                if(done_error) begin
                    error[1]<=1;failed_count<=failed_count+1'b1;
                    state<=SELECT;
                end else begin
                    release_slots<=req_bank?2'b10:2'b01;
                    released_count<=released_count+1'b1;state<=RELEASE_WAIT;
                end
            end
        end
        RELEASE_WAIT: if(!slot_valid[req_bank]) state<=SELECT;
        endcase
    end
end
end endgenerate
endmodule

// CAMERA_FPS required implementation embedded for GUI registration resilience.
module camera_fps_monitor #(parameter integer CORE_HZ=100000000)(
 input wire core_clk,pixel_clk,rst_n,capture_commit,
 input wire display_done,display_valid,input wire [31:0] display_id,
 output wire [9:0] capture_fps,output reg new_frame_event,
 output wire cdc_error);
 reg [$clog2(CORE_HZ)-1:0] seconds;
 reg [9:0] count,snapshot;
 reg send_snapshot;
 wire busy,pulse;wire [66:0] data;
 always @(posedge core_clk or negedge rst_n)begin
  if(!rst_n)begin seconds<=0;count<=0;snapshot<=0;send_snapshot<=0;end
  else begin
   send_snapshot<=0;
   if(seconds==CORE_HZ-1)begin
    seconds<=0;snapshot<=count+capture_commit;count<=0;send_snapshot<=1;
   end else begin
    seconds<=seconds+1'b1;
    if(capture_commit && count<999)count<=count+1'b1;
   end
  end
 end
 raw_frame_descriptor_cdc u_capture_fps_cdc(.src_clk(core_clk),.dst_clk(pixel_clk),.rst_n(rst_n),
 .src_pulse(send_snapshot),.src_data({57'd0,snapshot}),.src_busy(busy),.src_overrun(cdc_error),.dst_pulse(pulse),.dst_data(data));
 assign capture_fps=data[9:0];
 reg seen;reg [31:0] last_id;
 always @(posedge pixel_clk or negedge rst_n)begin
  if(!rst_n)begin seen<=0;last_id<=0;new_frame_event<=0;end
  else begin
   new_frame_event<=0;
   if(display_done && display_valid && (!seen || display_id!=last_id))begin
    seen<=1;last_id<=display_id;new_frame_event<=1;
   end
  end
 end
endmodule

`timescale 1ns/1ps
module camera_fps_osd #(parameter integer PIXEL_HZ=148500000)(
 input wire clk,rst_n,input wire [11:0] x,y,
 input wire [9:0] source_fps,
 input wire picture_index,frame_commit,frame_tick,input wire [9:0] capture_fps,
 input wire [7:0] r,g,b,input wire hs,vs,de,
 output reg [7:0] o_r,o_g,o_b,output reg o_hs,o_vs,o_de,
 output reg [9:0] image_fps,hdmi_hz);
 reg [27:0] seconds;
 reg [9:0] images,frames;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin seconds<=0;images<=0;frames<=0;image_fps<=0;hdmi_hz<=0;end
  else if(seconds==PIXEL_HZ-1)begin
   seconds<=0;image_fps<=images+frame_commit;hdmi_hz<=frames+frame_tick;
   images<=0;frames<=0;
  end else begin
   seconds<=seconds+1'b1;
   if(frame_commit && images<999)images<=images+1'b1;
   if(frame_tick && frames<999)frames<=frames+1'b1;
  end
 end
 function [34:0] glyph;
 input [7:0] ch;
 begin case(ch)
 8'd48:glyph=35'h3a33ae62e;
 8'd49:glyph=35'h11842108e;
 8'd50:glyph=35'h3a211111f;
 8'd51:glyph=35'h78217043e;
 8'd52:glyph=35'h08ca97c42;
 8'd53:glyph=35'h7e10f043e;
 8'd54:glyph=35'h3a10f462e;
 8'd55:glyph=35'h7c2222108;
 8'd56:glyph=35'h3a317462e;
 8'd57:glyph=35'h3a317842e;
 8'd73:glyph=35'h7c842109f;
 8'd77:glyph=35'h4775ac631;
 8'd71:glyph=35'h3a30bc62e;
 8'd70:glyph=35'h7e10f4210;
 8'd80:glyph=35'h7a31f4210;
 8'd83:glyph=35'h3e107043e;
 8'd67:glyph=35'h3a308422e;
 8'd72:glyph=35'h4631fc631;
 8'd68:glyph=35'h7a318c63e;
 8'd58:glyph=35'h008401080;
 8'd65:glyph=35'h3a31fc631;
 8'd78:glyph=35'h4739ace71;
 8'd69:glyph=35'h7e10f421f;
 8'd82:glyph=35'h7a31f4a31;
 8'd87:glyph=35'h4631ad771;
 default:glyph=0;endcase end endfunction
 reg [7:0] character;reg [34:0] bits;
 integer char_index,gx,gy;
 reg ink,box;
 always @* begin
  char_index=0;gx=0;gy=0;character=32;bits=0;ink=0;
  box=x>=32 && x<32+43*12 && y>=44 && y<60;
  if(box)begin
   char_index=(x-32)/12;gx=((x-32)%12)/2;gy=(y-44)/2;
   case(char_index)
    0:character=8'd67;
    1:character=8'd65;
    2:character=8'd80;
    3:character=8'd32;
    4:character=8'd70;
    5:character=8'd80;
    6:character=8'd83;
    7:character=8'd58;
    8:character=8'd32;
    9:character=48+capture_fps/100;
    10:character=48+(capture_fps/10)%10;
    11:character=48+capture_fps%10;
    12:character=8'd32;
    13:character=8'd82;
    14:character=8'd65;
    15:character=8'd87;
    16:character=8'd32;
    17:character=8'd70;
    18:character=8'd80;
    19:character=8'd83;
    20:character=8'd58;
    21:character=48+image_fps/100;
    22:character=48+(image_fps/10)%10;
    23:character=48+image_fps%10;
    24:character=8'd32;
    25:character=8'd32;
    26:character=8'd72;
    27:character=8'd68;
    28:character=8'd77;
    29:character=8'd73;
    30:character=8'd58;
    31:character=48+hdmi_hz/100;
    32:character=48+(hdmi_hz/10)%10;
    33:character=48+hdmi_hz%10;
    34:character=8'd32;
    35:character=8'd32;
    36:character=8'd83;
    37:character=8'd82;
    38:character=8'd67;
    39:character=8'd58;
    40:character=48+source_fps/100;
    41:character=48+(source_fps/10)%10;
    42:character=48+source_fps%10;
    default:character=32;
   endcase
   bits=glyph(character);
   if(gx<5 && gy<7)ink=bits[34-gy*5-gx];
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin o_r<=0;o_g<=0;o_b<=0;o_hs<=0;o_vs<=0;o_de<=0;end
  else begin
   o_hs<=hs;o_vs<=vs;o_de<=de;
   o_r<=de&&box?(ink?8'hff:8'd0):r;
   o_g<=de&&box?(ink?8'hff:8'd0):g;
   o_b<=de&&box?(ink?8'hff:8'd0):b;
  end
 end
endmodule

// Embedded to avoid GUI source-list registration failures.
// Fixed display tone curve: common RGB gain preserves channel ratios.
// 3 registered stages; controls and RGB have identical delay.
module camera_tone_mapper(
 input wire clk,rst_n,i_bypass,input wire [7:0] i_r,i_g,i_b,input wire i_hs,i_vs,i_de,
 output reg [7:0] o_r,o_g,o_b,output reg o_hs,o_vs,o_de);
 wire [7:0] rg_max=(i_r>i_g)?i_r:i_g;
 wire [7:0] rgb_max=(rg_max>i_b)?rg_max:i_b;
 function [11:0] tone_gain;
 input [7:0] level;
 begin case(level)
 8'd0:tone_gain=12'd0;
 8'd1:tone_gain=12'd1024;
 8'd2:tone_gain=12'd1024;
 8'd3:tone_gain=12'd1024;
 8'd4:tone_gain=12'd1024;
 8'd5:tone_gain=12'd1024;
 8'd6:tone_gain=12'd1024;
 8'd7:tone_gain=12'd1024;
 8'd8:tone_gain=12'd1024;
 8'd9:tone_gain=12'd1024;
 8'd10:tone_gain=12'd1024;
 8'd11:tone_gain=12'd1024;
 8'd12:tone_gain=12'd1024;
 8'd13:tone_gain=12'd1024;
 8'd14:tone_gain=12'd1024;
 8'd15:tone_gain=12'd1024;
 8'd16:tone_gain=12'd1024;
 8'd17:tone_gain=12'd1009;
 8'd18:tone_gain=12'd982;
 8'd19:tone_gain=12'd971;
 8'd20:tone_gain=12'd948;
 8'd21:tone_gain=12'd939;
 8'd22:tone_gain=12'd920;
 8'd23:tone_gain=12'd913;
 8'd24:tone_gain=12'd896;
 8'd25:tone_gain=12'd891;
 8'd26:tone_gain=12'd877;
 8'd27:tone_gain=12'd873;
 8'd28:tone_gain=12'd860;
 8'd29:tone_gain=12'd857;
 8'd30:tone_gain=12'd845;
 8'd31:tone_gain=12'd843;
 8'd32:tone_gain=12'd832;
 8'd33:tone_gain=12'd815;
 8'd34:tone_gain=12'd806;
 8'd35:tone_gain=12'd790;
 8'd36:tone_gain=12'd776;
 8'd37:tone_gain=12'd762;
 8'd38:tone_gain=12'd755;
 8'd39:tone_gain=12'd742;
 8'd40:tone_gain=12'd730;
 8'd41:tone_gain=12'd719;
 8'd42:tone_gain=12'd714;
 8'd43:tone_gain=12'd703;
 8'd44:tone_gain=12'd693;
 8'd45:tone_gain=12'd683;
 8'd46:tone_gain=12'd679;
 8'd47:tone_gain=12'd670;
 8'd48:tone_gain=12'd662;
 8'd49:tone_gain=12'd654;
 8'd50:tone_gain=12'd651;
 8'd51:tone_gain=12'd643;
 8'd52:tone_gain=12'd636;
 8'd53:tone_gain=12'd628;
 8'd54:tone_gain=12'd626;
 8'd55:tone_gain=12'd620;
 8'd56:tone_gain=12'd613;
 8'd57:tone_gain=12'd607;
 8'd58:tone_gain=12'd605;
 8'd59:tone_gain=12'd599;
 8'd60:tone_gain=12'd594;
 8'd61:tone_gain=12'd588;
 8'd62:tone_gain=12'd587;
 8'd63:tone_gain=12'd582;
 8'd64:tone_gain=12'd576;
 8'd65:tone_gain=12'd572;
 8'd66:tone_gain=12'd563;
 8'd67:tone_gain=12'd558;
 8'd68:tone_gain=12'd550;
 8'd69:tone_gain=12'd546;
 8'd70:tone_gain=12'd538;
 8'd71:tone_gain=12'd534;
 8'd72:tone_gain=12'd530;
 8'd73:tone_gain=12'd523;
 8'd74:tone_gain=12'd519;
 8'd75:tone_gain=12'd512;
 8'd76:tone_gain=12'd509;
 8'd77:tone_gain=12'd503;
 8'd78:tone_gain=12'd499;
 8'd79:tone_gain=12'd493;
 8'd80:tone_gain=12'd490;
 8'd81:tone_gain=12'd487;
 8'd82:tone_gain=12'd481;
 8'd83:tone_gain=12'd479;
 8'd84:tone_gain=12'd473;
 8'd85:tone_gain=12'd470;
 8'd86:tone_gain=12'd465;
 8'd87:tone_gain=12'd462;
 8'd88:tone_gain=12'd460;
 8'd89:tone_gain=12'd455;
 8'd90:tone_gain=12'd453;
 8'd91:tone_gain=12'd448;
 8'd92:tone_gain=12'd446;
 8'd93:tone_gain=12'd441;
 8'd94:tone_gain=12'd439;
 8'd95:tone_gain=12'd434;
 8'd96:tone_gain=12'd432;
 8'd97:tone_gain=12'd428;
 8'd98:tone_gain=12'd426;
 8'd99:tone_gain=12'd422;
 8'd100:tone_gain=12'd418;
 8'd101:tone_gain=12'd414;
 8'd102:tone_gain=12'd412;
 8'd103:tone_gain=12'd408;
 8'd104:tone_gain=12'd404;
 8'd105:tone_gain=12'd400;
 8'd106:tone_gain=12'd399;
 8'd107:tone_gain=12'd395;
 8'd108:tone_gain=12'd392;
 8'd109:tone_gain=12'd388;
 8'd110:tone_gain=12'd387;
 8'd111:tone_gain=12'd383;
 8'd112:tone_gain=12'd380;
 8'd113:tone_gain=12'd377;
 8'd114:tone_gain=12'd376;
 8'd115:tone_gain=12'd372;
 8'd116:tone_gain=12'd369;
 8'd117:tone_gain=12'd366;
 8'd118:tone_gain=12'd365;
 8'd119:tone_gain=12'd362;
 8'd120:tone_gain=12'd359;
 8'd121:tone_gain=12'd356;
 8'd122:tone_gain=12'd355;
 8'd123:tone_gain=12'd352;
 8'd124:tone_gain=12'd349;
 8'd125:tone_gain=12'd347;
 8'd126:tone_gain=12'd346;
 8'd127:tone_gain=12'd343;
 8'd128:tone_gain=12'd340;
 8'd129:tone_gain=12'd340;
 8'd130:tone_gain=12'd339;
 8'd131:tone_gain=12'd337;
 8'd132:tone_gain=12'd336;
 8'd133:tone_gain=12'd335;
 8'd134:tone_gain=12'd335;
 8'd135:tone_gain=12'd332;
 8'd136:tone_gain=12'd332;
 8'd137:tone_gain=12'd331;
 8'd138:tone_gain=12'd331;
 8'd139:tone_gain=12'd328;
 8'd140:tone_gain=12'd328;
 8'd141:tone_gain=12'd327;
 8'd142:tone_gain=12'd327;
 8'd143:tone_gain=12'd325;
 8'd144:tone_gain=12'd324;
 8'd145:tone_gain=12'd324;
 8'd146:tone_gain=12'd323;
 8'd147:tone_gain=12'd321;
 8'd148:tone_gain=12'd320;
 8'd149:tone_gain=12'd320;
 8'd150:tone_gain=12'd320;
 8'd151:tone_gain=12'd318;
 8'd152:tone_gain=12'd317;
 8'd153:tone_gain=12'd317;
 8'd154:tone_gain=12'd316;
 8'd155:tone_gain=12'd314;
 8'd156:tone_gain=12'd314;
 8'd157:tone_gain=12'd314;
 8'd158:tone_gain=12'd313;
 8'd159:tone_gain=12'd311;
 8'd160:tone_gain=12'd311;
 8'd161:tone_gain=12'd311;
 8'd162:tone_gain=12'd309;
 8'd163:tone_gain=12'd308;
 8'd164:tone_gain=12'd308;
 8'd165:tone_gain=12'd306;
 8'd166:tone_gain=12'd306;
 8'd167:tone_gain=12'd304;
 8'd168:tone_gain=12'd304;
 8'd169:tone_gain=12'd303;
 8'd170:tone_gain=12'd302;
 8'd171:tone_gain=12'd301;
 8'd172:tone_gain=12'd301;
 8'd173:tone_gain=12'd299;
 8'd174:tone_gain=12'd299;
 8'd175:tone_gain=12'd297;
 8'd176:tone_gain=12'd297;
 8'd177:tone_gain=12'd297;
 8'd178:tone_gain=12'd295;
 8'd179:tone_gain=12'd295;
 8'd180:tone_gain=12'd295;
 8'd181:tone_gain=12'd293;
 8'd182:tone_gain=12'd293;
 8'd183:tone_gain=12'd291;
 8'd184:tone_gain=12'd291;
 8'd185:tone_gain=12'd291;
 8'd186:tone_gain=12'd290;
 8'd187:tone_gain=12'd289;
 8'd188:tone_gain=12'd289;
 8'd189:tone_gain=12'd288;
 8'd190:tone_gain=12'd287;
 8'd191:tone_gain=12'd286;
 8'd192:tone_gain=12'd286;
 8'd193:tone_gain=12'd286;
 8'd194:tone_gain=12'd284;
 8'd195:tone_gain=12'd284;
 8'd196:tone_gain=12'd283;
 8'd197:tone_gain=12'd282;
 8'd198:tone_gain=12'd281;
 8'd199:tone_gain=12'd281;
 8'd200:tone_gain=12'd281;
 8'd201:tone_gain=12'd279;
 8'd202:tone_gain=12'd279;
 8'd203:tone_gain=12'd278;
 8'd204:tone_gain=12'd278;
 8'd205:tone_gain=12'd276;
 8'd206:tone_gain=12'd276;
 8'd207:tone_gain=12'd275;
 8'd208:tone_gain=12'd275;
 8'd209:tone_gain=12'd275;
 8'd210:tone_gain=12'd274;
 8'd211:tone_gain=12'd273;
 8'd212:tone_gain=12'd272;
 8'd213:tone_gain=12'd272;
 8'd214:tone_gain=12'd271;
 8'd215:tone_gain=12'd271;
 8'd216:tone_gain=12'd271;
 8'd217:tone_gain=12'd269;
 8'd218:tone_gain=12'd269;
 8'd219:tone_gain=12'd268;
 8'd220:tone_gain=12'd268;
 8'd221:tone_gain=12'd267;
 8'd222:tone_gain=12'd267;
 8'd223:tone_gain=12'd266;
 8'd224:tone_gain=12'd266;
 8'd225:tone_gain=12'd266;
 8'd226:tone_gain=12'd264;
 8'd227:tone_gain=12'd264;
 8'd228:tone_gain=12'd263;
 8'd229:tone_gain=12'd263;
 8'd230:tone_gain=12'd262;
 8'd231:tone_gain=12'd262;
 8'd232:tone_gain=12'd261;
 8'd233:tone_gain=12'd261;
 8'd234:tone_gain=12'd260;
 8'd235:tone_gain=12'd260;
 8'd236:tone_gain=12'd259;
 8'd237:tone_gain=12'd259;
 8'd238:tone_gain=12'd258;
 8'd239:tone_gain=12'd258;
 8'd240:tone_gain=12'd256;
 8'd241:tone_gain=12'd256;
 8'd242:tone_gain=12'd255;
 8'd243:tone_gain=12'd255;
 8'd244:tone_gain=12'd254;
 8'd245:tone_gain=12'd254;
 8'd246:tone_gain=12'd253;
 8'd247:tone_gain=12'd253;
 8'd248:tone_gain=12'd252;
 8'd249:tone_gain=12'd252;
 8'd250:tone_gain=12'd251;
 8'd251:tone_gain=12'd251;
 8'd252:tone_gain=12'd250;
 8'd253:tone_gain=12'd250;
 8'd254:tone_gain=12'd249;
 8'd255:tone_gain=12'd249;
 default:tone_gain=12'd256;
 endcase end endfunction
 (* syn_ramstyle="block_ram" *) reg[11:0] gain_rom[0:255];
 initial begin
gain_rom[0]=12'd0;
gain_rom[1]=12'd1024;
gain_rom[2]=12'd1024;
gain_rom[3]=12'd1024;
gain_rom[4]=12'd1024;
gain_rom[5]=12'd1024;
gain_rom[6]=12'd1024;
gain_rom[7]=12'd1024;
gain_rom[8]=12'd1024;
gain_rom[9]=12'd1024;
gain_rom[10]=12'd1024;
gain_rom[11]=12'd1024;
gain_rom[12]=12'd1024;
gain_rom[13]=12'd1024;
gain_rom[14]=12'd1024;
gain_rom[15]=12'd1024;
gain_rom[16]=12'd1024;
gain_rom[17]=12'd1009;
gain_rom[18]=12'd982;
gain_rom[19]=12'd971;
gain_rom[20]=12'd948;
gain_rom[21]=12'd939;
gain_rom[22]=12'd920;
gain_rom[23]=12'd913;
gain_rom[24]=12'd896;
gain_rom[25]=12'd891;
gain_rom[26]=12'd877;
gain_rom[27]=12'd873;
gain_rom[28]=12'd860;
gain_rom[29]=12'd857;
gain_rom[30]=12'd845;
gain_rom[31]=12'd843;
gain_rom[32]=12'd832;
gain_rom[33]=12'd815;
gain_rom[34]=12'd806;
gain_rom[35]=12'd790;
gain_rom[36]=12'd776;
gain_rom[37]=12'd762;
gain_rom[38]=12'd755;
gain_rom[39]=12'd742;
gain_rom[40]=12'd730;
gain_rom[41]=12'd719;
gain_rom[42]=12'd714;
gain_rom[43]=12'd703;
gain_rom[44]=12'd693;
gain_rom[45]=12'd683;
gain_rom[46]=12'd679;
gain_rom[47]=12'd670;
gain_rom[48]=12'd662;
gain_rom[49]=12'd654;
gain_rom[50]=12'd651;
gain_rom[51]=12'd643;
gain_rom[52]=12'd636;
gain_rom[53]=12'd628;
gain_rom[54]=12'd626;
gain_rom[55]=12'd620;
gain_rom[56]=12'd613;
gain_rom[57]=12'd607;
gain_rom[58]=12'd605;
gain_rom[59]=12'd599;
gain_rom[60]=12'd594;
gain_rom[61]=12'd588;
gain_rom[62]=12'd587;
gain_rom[63]=12'd582;
gain_rom[64]=12'd576;
gain_rom[65]=12'd572;
gain_rom[66]=12'd563;
gain_rom[67]=12'd558;
gain_rom[68]=12'd550;
gain_rom[69]=12'd546;
gain_rom[70]=12'd538;
gain_rom[71]=12'd534;
gain_rom[72]=12'd530;
gain_rom[73]=12'd523;
gain_rom[74]=12'd519;
gain_rom[75]=12'd512;
gain_rom[76]=12'd509;
gain_rom[77]=12'd503;
gain_rom[78]=12'd499;
gain_rom[79]=12'd493;
gain_rom[80]=12'd490;
gain_rom[81]=12'd487;
gain_rom[82]=12'd481;
gain_rom[83]=12'd479;
gain_rom[84]=12'd473;
gain_rom[85]=12'd470;
gain_rom[86]=12'd465;
gain_rom[87]=12'd462;
gain_rom[88]=12'd460;
gain_rom[89]=12'd455;
gain_rom[90]=12'd453;
gain_rom[91]=12'd448;
gain_rom[92]=12'd446;
gain_rom[93]=12'd441;
gain_rom[94]=12'd439;
gain_rom[95]=12'd434;
gain_rom[96]=12'd432;
gain_rom[97]=12'd428;
gain_rom[98]=12'd426;
gain_rom[99]=12'd422;
gain_rom[100]=12'd418;
gain_rom[101]=12'd414;
gain_rom[102]=12'd412;
gain_rom[103]=12'd408;
gain_rom[104]=12'd404;
gain_rom[105]=12'd400;
gain_rom[106]=12'd399;
gain_rom[107]=12'd395;
gain_rom[108]=12'd392;
gain_rom[109]=12'd388;
gain_rom[110]=12'd387;
gain_rom[111]=12'd383;
gain_rom[112]=12'd380;
gain_rom[113]=12'd377;
gain_rom[114]=12'd376;
gain_rom[115]=12'd372;
gain_rom[116]=12'd369;
gain_rom[117]=12'd366;
gain_rom[118]=12'd365;
gain_rom[119]=12'd362;
gain_rom[120]=12'd359;
gain_rom[121]=12'd356;
gain_rom[122]=12'd355;
gain_rom[123]=12'd352;
gain_rom[124]=12'd349;
gain_rom[125]=12'd347;
gain_rom[126]=12'd346;
gain_rom[127]=12'd343;
gain_rom[128]=12'd340;
gain_rom[129]=12'd340;
gain_rom[130]=12'd339;
gain_rom[131]=12'd337;
gain_rom[132]=12'd336;
gain_rom[133]=12'd335;
gain_rom[134]=12'd335;
gain_rom[135]=12'd332;
gain_rom[136]=12'd332;
gain_rom[137]=12'd331;
gain_rom[138]=12'd331;
gain_rom[139]=12'd328;
gain_rom[140]=12'd328;
gain_rom[141]=12'd327;
gain_rom[142]=12'd327;
gain_rom[143]=12'd325;
gain_rom[144]=12'd324;
gain_rom[145]=12'd324;
gain_rom[146]=12'd323;
gain_rom[147]=12'd321;
gain_rom[148]=12'd320;
gain_rom[149]=12'd320;
gain_rom[150]=12'd320;
gain_rom[151]=12'd318;
gain_rom[152]=12'd317;
gain_rom[153]=12'd317;
gain_rom[154]=12'd316;
gain_rom[155]=12'd314;
gain_rom[156]=12'd314;
gain_rom[157]=12'd314;
gain_rom[158]=12'd313;
gain_rom[159]=12'd311;
gain_rom[160]=12'd311;
gain_rom[161]=12'd311;
gain_rom[162]=12'd309;
gain_rom[163]=12'd308;
gain_rom[164]=12'd308;
gain_rom[165]=12'd306;
gain_rom[166]=12'd306;
gain_rom[167]=12'd304;
gain_rom[168]=12'd304;
gain_rom[169]=12'd303;
gain_rom[170]=12'd302;
gain_rom[171]=12'd301;
gain_rom[172]=12'd301;
gain_rom[173]=12'd299;
gain_rom[174]=12'd299;
gain_rom[175]=12'd297;
gain_rom[176]=12'd297;
gain_rom[177]=12'd297;
gain_rom[178]=12'd295;
gain_rom[179]=12'd295;
gain_rom[180]=12'd295;
gain_rom[181]=12'd293;
gain_rom[182]=12'd293;
gain_rom[183]=12'd291;
gain_rom[184]=12'd291;
gain_rom[185]=12'd291;
gain_rom[186]=12'd290;
gain_rom[187]=12'd289;
gain_rom[188]=12'd289;
gain_rom[189]=12'd288;
gain_rom[190]=12'd287;
gain_rom[191]=12'd286;
gain_rom[192]=12'd286;
gain_rom[193]=12'd286;
gain_rom[194]=12'd284;
gain_rom[195]=12'd284;
gain_rom[196]=12'd283;
gain_rom[197]=12'd282;
gain_rom[198]=12'd281;
gain_rom[199]=12'd281;
gain_rom[200]=12'd281;
gain_rom[201]=12'd279;
gain_rom[202]=12'd279;
gain_rom[203]=12'd278;
gain_rom[204]=12'd278;
gain_rom[205]=12'd276;
gain_rom[206]=12'd276;
gain_rom[207]=12'd275;
gain_rom[208]=12'd275;
gain_rom[209]=12'd275;
gain_rom[210]=12'd274;
gain_rom[211]=12'd273;
gain_rom[212]=12'd272;
gain_rom[213]=12'd272;
gain_rom[214]=12'd271;
gain_rom[215]=12'd271;
gain_rom[216]=12'd271;
gain_rom[217]=12'd269;
gain_rom[218]=12'd269;
gain_rom[219]=12'd268;
gain_rom[220]=12'd268;
gain_rom[221]=12'd267;
gain_rom[222]=12'd267;
gain_rom[223]=12'd266;
gain_rom[224]=12'd266;
gain_rom[225]=12'd266;
gain_rom[226]=12'd264;
gain_rom[227]=12'd264;
gain_rom[228]=12'd263;
gain_rom[229]=12'd263;
gain_rom[230]=12'd262;
gain_rom[231]=12'd262;
gain_rom[232]=12'd261;
gain_rom[233]=12'd261;
gain_rom[234]=12'd260;
gain_rom[235]=12'd260;
gain_rom[236]=12'd259;
gain_rom[237]=12'd259;
gain_rom[238]=12'd258;
gain_rom[239]=12'd258;
gain_rom[240]=12'd256;
gain_rom[241]=12'd256;
gain_rom[242]=12'd255;
gain_rom[243]=12'd255;
gain_rom[244]=12'd254;
gain_rom[245]=12'd254;
gain_rom[246]=12'd253;
gain_rom[247]=12'd253;
gain_rom[248]=12'd252;
gain_rom[249]=12'd252;
gain_rom[250]=12'd251;
gain_rom[251]=12'd251;
gain_rom[252]=12'd250;
gain_rom[253]=12'd250;
gain_rom[254]=12'd249;
gain_rom[255]=12'd249;
 end
 reg[11:0] gain_s1;
 always @(posedge clk) gain_s1<=gain_rom[rgb_max];
 reg bypass_s1;
 wire[11:0] selected_gain=bypass_s1?12'd256:gain_s1;
 reg [7:0] r_s1,g_s1,b_s1;
 reg hs_s1,vs_s1,de_s1,hs_s2,vs_s2,de_s2;
 // Explicit shift/add products preserve scarce DSPs for the NN.
 function [15:0] mul4;
 input [3:0] pixel;input [11:0] gain;
 reg[15:0] a,b,c,d;
 begin a=pixel[0]?{4'b0,gain}:16'b0;b=pixel[1]?{3'b0,gain,1'b0}:16'b0;
 c=pixel[2]?{2'b0,gain,2'b0}:16'b0;d=pixel[3]?{1'b0,gain,3'b0}:16'b0;
 mul4=(a+b)+(c+d);end endfunction
 reg[15:0] rl_s2,rh_s2,bl_s2,bh_s2;
 reg[19:0] r_s3,g_s3,b_s3;
 reg[19:0] g_s2;
 reg hs_s3,vs_s3,de_s3;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   bypass_s1<=0;r_s1<=0;g_s1<=0;b_s1<=0;
   hs_s1<=0;vs_s1<=0;de_s1<=0;hs_s2<=0;vs_s2<=0;de_s2<=0;
   rl_s2<=0;rh_s2<=0;g_s2<=0;bl_s2<=0;bh_s2<=0;r_s3<=0;g_s3<=0;b_s3<=0;hs_s3<=0;vs_s3<=0;de_s3<=0;
   o_r<=0;o_g<=0;o_b<=0;o_hs<=0;o_vs<=0;o_de<=0;
  end else begin
   bypass_s1<=i_bypass;r_s1<=i_r;g_s1<=i_g;b_s1<=i_b;
   hs_s1<=i_hs;vs_s1<=i_vs;de_s1<=i_de;
   rl_s2<=mul4(r_s1[3:0],selected_gain);rh_s2<=mul4(r_s1[7:4],selected_gain);
   g_s2<=g_s1*selected_gain;
   bl_s2<=mul4(b_s1[3:0],selected_gain);bh_s2<=mul4(b_s1[7:4],selected_gain);
   r_s3<={4'b0,rl_s2}+{rh_s2,4'b0};g_s3<=g_s2;b_s3<={4'b0,bl_s2}+{bh_s2,4'b0};
   hs_s3<=hs_s2;vs_s3<=vs_s2;de_s3<=de_s2;
   hs_s2<=hs_s1;vs_s2<=vs_s1;de_s2<=de_s1;
   o_r<=(|r_s3[19:16])?8'hff:r_s3[15:8];
   o_g<=(|g_s3[19:16])?8'hff:g_s3[15:8];
   o_b<=(|b_s3[19:16])?8'hff:b_s3[15:8];
   o_hs<=hs_s3;o_vs<=vs_s3;o_de<=de_s3;
  end
 end
endmodule


// Core counters survive per-picture session resets. Stable bundled snapshot CDC.
module nn_fps_monitor #(parameter integer LOCAL_PIXEL_RESET=0,CORE_HZ=100000000,BUFFER_BITS=1)(
 input wire core_clk,pixel_clk,rst_n,done,pass,fail,pixel_rst_n,
 input wire display_enable,
 input wire [BUFFER_BITS-1:0] display_buffer,
 input wire frame_shown,
 output reg [9:0] nn_fps,new_fps,
 output reg[31:0] success_total,new_total,shown_total);
 wire local_pixel_rst_n=LOCAL_PIXEL_RESET?pixel_rst_n:rst_n;
 reg [31:0] seconds;
 reg [9:0] nn_count,new_count;
 reg done_d,enable_d,pending;
 reg [BUFFER_BITS-1:0] buffer_d;
 wire nn_event=done && !done_d && pass && !fail;
 wire publication=display_enable && (!enable_d || display_buffer!=buffer_d);
 wire new_event=display_enable && frame_shown && (pending || publication) && !fail;
 reg [19:0] snapshot;
 reg request_toggle,ack_toggle;
 (* async_reg="true" *) reg [1:0] ack_sync;
 (* async_reg="true" *) reg [2:0] request_sync;
 wire idle=ack_sync[1]==request_toggle;
 function [9:0] sat_inc;
 input [9:0] value;input event_in;
 begin sat_inc=(event_in && value<999)?value+1'b1:value;end
 endfunction
 always @(posedge core_clk or negedge rst_n) begin
  if(!rst_n)begin success_total<=0;new_total<=0;shown_total<=0;seconds<=0;nn_count<=0;new_count<=0;done_d<=0;enable_d<=0;buffer_d<=0;pending<=0;snapshot<=0;request_toggle<=0;ack_sync<=0;end
  else begin
   if(nn_event)success_total<=success_total+1'b1;
   if(new_event)new_total<=new_total+1'b1;
   if(display_enable&&frame_shown)shown_total<=shown_total+1'b1;
   ack_sync<={ack_sync[0],ack_toggle};done_d<=done;enable_d<=display_enable;buffer_d<=display_buffer;
   if(!display_enable) pending<=0;
   else if(new_event) pending<=0;
   else if(publication) pending<=1;
   if(seconds==CORE_HZ-1)begin
    seconds<=0;
    if(idle)begin snapshot<={sat_inc(nn_count,nn_event),sat_inc(new_count,new_event)};request_toggle<=~request_toggle;end
    nn_count<=0;new_count<=0;
   end else begin seconds<=seconds+1'b1;nn_count<=sat_inc(nn_count,nn_event);new_count<=sat_inc(new_count,new_event);end
  end
 end
 always @(posedge pixel_clk or negedge local_pixel_rst_n)begin
  if(!local_pixel_rst_n)begin request_sync<=0;ack_toggle<=0;nn_fps<=0;new_fps<=0;end
  else begin
   request_sync<={request_sync[1:0],request_toggle};
   if(request_sync[2]!=ack_toggle)begin {nn_fps,new_fps}<=snapshot;ack_toggle<=request_sync[2];end
  end
 end
endmodule
module nn_fps_osd #(parameter integer PIXEL_HZ=148500000,SHOW_STATUS=0,NETWORK_STATUS=0,FRAME_WIDTH=1280,FRAME_HEIGHT=720)(
 input wire clk,rst_n,input wire [11:0] x,y,
 input wire [25:0] debug_status,input wire source_hdmi,
 input wire [3:0] cpu_ui,input wire [11:0] network_state,
 input wire [9:0] source_fps,new_fps,camera_capture_fps,
 input wire picture_index,frame_commit,frame_tick,input wire [9:0] capture_fps,
 input wire [7:0] r,g,b,input wire hs,vs,de,
 output reg [7:0] o_r,o_g,o_b,output reg o_hs,o_vs,o_de,
 output reg [9:0] image_fps,hdmi_hz);
 // Three read-only display metrics; all video/control timing stays unchanged.
 // capture_fps is successful NN completions/s, hdmi_hz is output VS edges/s.
 wire [71:0] decimal_digits;
 fps_decimal_bank u_decimal(.clk(clk),.rst_n(rst_n),
   .values({30'd0,hdmi_hz,10'd0,capture_fps}),.digits(decimal_digits));
 (* async_reg="true",syn_preserve=1 *)reg [3:0]cpu_ui_meta,cpu_ui_sync;
 always @(posedge clk or negedge rst_n)
   if(!rst_n)begin cpu_ui_meta<=4'b1000;cpu_ui_sync<=4'b1000;end
   else begin cpu_ui_meta<=cpu_ui;cpu_ui_sync<=cpu_ui_meta;end
 reg [27:0] seconds;
 reg [9:0] images,frames;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin seconds<=0;images<=0;frames<=0;image_fps<=0;hdmi_hz<=0;end
  else if(seconds==PIXEL_HZ-1)begin
   seconds<=0;image_fps<=images+frame_commit;hdmi_hz<=frames+frame_tick;
   images<=0;frames<=0;
  end else begin
   seconds<=seconds+1'b1;
   if(frame_commit && images<999)images<=images+1'b1;
   if(frame_tick && frames<999)frames<=frames+1'b1;
  end
 end
 function [34:0] glyph;
 input [7:0] ch;
 begin case(ch)
 8'd48:glyph=35'h3a33ae62e;
 8'd49:glyph=35'h11842108e;
 8'd50:glyph=35'h3a211111f;
 8'd51:glyph=35'h78217043e;
 8'd52:glyph=35'h08ca97c42;
 8'd53:glyph=35'h7e10f043e;
 8'd54:glyph=35'h3a10f462e;
 8'd55:glyph=35'h7c2222108;
 8'd56:glyph=35'h3a317462e;
 8'd57:glyph=35'h3a317842e;
 8'd73:glyph=35'h7c842109f;
 8'd77:glyph=35'h4775ac631;
 8'd71:glyph=35'h3a30bc62e;
 8'd70:glyph=35'h7e10f4210;
 8'd80:glyph=35'h7a31f4210;
 8'd83:glyph=35'h3e107043e;
 8'd67:glyph=35'h3a308422e;
 8'd72:glyph=35'h4631fc631;
 8'd68:glyph=35'h7a318c63e;
 8'd58:glyph=35'h008401080;
 8'd85:glyph=35'h46318c62e;
 8'd79:glyph=35'h3a318c62e;
 8'd75:glyph=35'h4654c5631;
 8'd66:glyph=35'h7a31f463e;
 8'd65:glyph=35'h3a31fc631;
 8'd78:glyph=35'h4739ace71;
 8'd69:glyph=35'h7e10f421f;
 8'd82:glyph=35'h7a31f4a31;
 8'd87:glyph=35'h4631ad771;
 8'd84:glyph=35'h7c8421084;
 8'd76:glyph=35'h42108421f;
 8'd86:glyph=35'h46318c544;
 8'd89:glyph=35'h462a21084;
 8'd90:glyph=35'h7c222221f;
 8'd46:glyph=35'h000000084;
 8'd88:glyph=35'h462a22a31;
 default:glyph=0;endcase end endfunction
 reg [7:0] character;
 integer char_index,gx,gy;
 reg box;
 always @* begin
  char_index=0;gx=0;gy=0;character=8'd32;
  box=cpu_ui_sync[3] && x>=32 && x<32+40*16 && y>=20 && y<36;
  if(box)begin
   char_index=(x-32)>>4;gx=((x-32)&15)>>1;gy=(y-20)>>1;
   case(char_index)
    0:character=8'd82;
    1:character=8'd69;
    2:character=8'd83;
    3:character=8'd58;
    4:character=8'd48+(FRAME_WIDTH/1000)%10;
    5:character=8'd48+(FRAME_WIDTH/100)%10;
    6:character=8'd48+(FRAME_WIDTH/10)%10;
    7:character=8'd48+(FRAME_WIDTH/1)%10;
    8:character=8'd88;
    9:character=8'd48+(FRAME_HEIGHT/100)%10;
    10:character=8'd48+(FRAME_HEIGHT/10)%10;
    11:character=8'd48+(FRAME_HEIGHT/1)%10;
    12:character=8'd32;
    13:character=8'd32;
    14:character=8'd80;
    15:character=8'd82;
    16:character=8'd79;
    17:character=8'd67;
    18:character=8'd32;
    19:character=8'd70;
    20:character=8'd80;
    21:character=8'd83;
    22:character=8'd58;
    23:character=8'd48+decimal_digits[8+:4];
    24:character=8'd48+decimal_digits[4+:4];
    25:character=8'd48+decimal_digits[0+:4];
    26:character=8'd32;
    27:character=8'd32;
    28:character=8'd68;
    29:character=8'd73;
    30:character=8'd83;
    31:character=8'd80;
    32:character=8'd32;
    33:character=8'd70;
    34:character=8'd80;
    35:character=8'd83;
    36:character=8'd58;
    37:character=8'd48+decimal_digits[32+:4];
    38:character=8'd48+decimal_digits[28+:4];
    39:character=8'd48+decimal_digits[24+:4];
    default:character=8'd32;
   endcase
  end
 end
 // Separate character selection, glyph ROM and pixel composition.
 // RGB and all HDMI qualifiers travel through the same three stages.
 reg [7:0] char_q;
 reg [2:0] gx_q,gy_q,gx_qq,gy_qq;
 reg box_q,box_qq;
 reg [34:0] glyph_q;
 reg [26:0] video_q,video_qq;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   char_q<=32;gx_q<=0;gy_q<=0;gx_qq<=0;gy_qq<=0;
   box_q<=0;box_qq<=0;glyph_q<=0;video_q<=0;video_qq<=0;
   o_r<=0;o_g<=0;o_b<=0;o_hs<=0;o_vs<=0;o_de<=0;
  end else begin
   char_q<=character;gx_q<=gx;gy_q<=gy;box_q<=box;
   video_q<={hs,vs,de,r,g,b};
   glyph_q<=glyph(char_q);gx_qq<=gx_q;gy_qq<=gy_q;box_qq<=box_q;
   video_qq<=video_q;
   {o_hs,o_vs,o_de}<=video_qq[26:24];
   o_r<=video_qq[24]&&box_qq?((gx_qq<5 && gy_qq<7 && glyph_q[34-gy_qq*5-gx_qq])?8'hff:8'd0):video_qq[23:16];
   o_g<=video_qq[24]&&box_qq?((gx_qq<5 && gy_qq<7 && glyph_q[34-gy_qq*5-gx_qq])?8'hff:8'd0):video_qq[15:8];
   o_b<=video_qq[24]&&box_qq?((gx_qq<5 && gy_qq<7 && glyph_q[34-gy_qq*5-gx_qq])?8'hff:8'd0):video_qq[7:0];
  end
 end
endmodule

// Registered dual-port RAM and two-stage Gray pointer synchronization.
// Capture must remain safe when the core and pixel clocks are unrelated.
// camera_style_async_fifo is defined in rtl/video/camera_style_async_fifo.v.



// Coherent, display-only status mailbox. No feedback into image ownership.
module net_image_status_view(
 input wire core_clk,core_rst_n,pixel_clk,pixel_rst_n,
 input wire [3:0] phase,input wire [7:0] terminal_status,
 input wire [31:0] fresh_visible_total,
 output reg [11:0] pixel_state
);
 reg busy_seen,wait_fresh;reg[31:0]fresh_baseline;
 reg[11:0]held;reg request_toggle;
 (* async_reg="true",syn_preserve=1 *)reg ack_meta,ack_sync;
 (* async_reg="true",syn_preserve=1 *)reg req_meta,req_sync;
 reg ack_toggle;
 wire[3:0]effective_phase=phase!=0?phase:(busy_seen||wait_fresh)?4'd8:4'd0;
 always @(posedge core_clk or negedge core_rst_n)begin
  if(!core_rst_n)begin busy_seen<=0;wait_fresh<=0;fresh_baseline<=0;held<=0;request_toggle<=0;ack_meta<=0;ack_sync<=0;end
  else begin
   ack_meta<=ack_toggle;ack_sync<=ack_meta;
   if(phase!=0)begin busy_seen<=1;wait_fresh<=0;end
   else if(busy_seen)begin busy_seen<=0;wait_fresh<=1;fresh_baseline<=fresh_visible_total;end
   else if(wait_fresh && fresh_visible_total!=fresh_baseline)wait_fresh<=0;
   // Always send another snapshot after ACK. This also recovers independently
   // reset pixel logic when the phase has not changed.
   if(request_toggle==ack_sync)begin held<={terminal_status,effective_phase};request_toggle<=~request_toggle;end
  end
 end
 always @(posedge pixel_clk or negedge pixel_rst_n)begin
  if(!pixel_rst_n)begin req_meta<=0;req_sync<=0;ack_toggle<=0;pixel_state<=0;end
  else begin
   req_meta<=request_toggle;req_sync<=req_meta;
   if(req_sync!=ack_toggle)begin pixel_state<=held;ack_toggle<=req_sync;end
  end
 end
endmodule
