`timescale 1ns/1ps
`default_nettype none
module camera_video_frontend(
 input wire source_clk,pair_clk,pixel_clk,ctrl_clk,rst_n,
 input wire source_vs,source_valid,input wire [31:0] source_raw4,
 input wire [15:0] PADDR,input wire PSEL,PENABLE,PWRITE,input wire [31:0] PWDATA,
 output wire [31:0] PRDATA,output wire PREADY,PSLVERROR,
 output wire [31:0] rgbx,frame_id,good_frames,overflow_frames,
 output wire valid,sof,frame_done,frame_abort,
 output wire [10:0] x,output wire [9:0] y,
 output reg sensor_sof_toggle
);
 wire source_reset_n,pair_reset_n,pixel_reset_n,ctrl_reset_n;
 hdmi_reset_release u_sensor_release(.clk(source_clk),.rst_n(rst_n),.released_n(source_reset_n));
 hdmi_reset_release u_pair_release(.clk(pair_clk),.rst_n(rst_n),.released_n(pair_reset_n));
 hdmi_reset_release u_pixel_release(.clk(pixel_clk),.rst_n(rst_n),.released_n(pixel_reset_n));
 hdmi_reset_release u_ctrl_release(.clk(ctrl_clk),.rst_n(rst_n),.released_n(ctrl_reset_n));
 wire raw_vs,raw_de;wire [15:0] raw2;wire [31:0] raw_id;wire raw_error;
 camera_raw_lines u_lines(.source_clk(source_clk),.pair_clk(pair_clk),.rst_n(rst_n),
  .source_vs(source_vs),.source_valid(source_valid),.source_raw4(source_raw4),
  .pair_vs(raw_vs),.pair_de(raw_de),.pair_raw2(raw2),.frame_id(raw_id),.frame_error(raw_error),.overflow_frames(overflow_frames));
 reg source_vs_d;
 always @(posedge source_clk or negedge source_reset_n)
  if(!source_reset_n)begin source_vs_d<=0;sensor_sof_toggle<=0;end
  else begin source_vs_d<=source_vs;if(source_vs&&!source_vs_d)sensor_sof_toggle<=~sensor_sof_toggle;end
 wire [9:0] target_r,target_b;wire gain_send,gain_busy,gain_pulse;wire [19:0] gain_received;
 reg [9:0] applied_r,applied_b;reg [19:0] pending_gains;reg pending_gain,raw_vs_d;
 video_snapshot_cdc #(.WIDTH(20)) u_gains(.src_clk(ctrl_clk),.dst_clk(pair_clk),.rst_n(rst_n),
  .send(gain_send),.data({target_r,target_b}),.busy(gain_busy),.pulse(gain_pulse),.received(gain_received));
 always @(posedge pair_clk or negedge pair_reset_n)
  if(!pair_reset_n)begin applied_r<=512;applied_b<=320;pending_gains<={10'd512,10'd320};pending_gain<=0;raw_vs_d<=0;end
  else begin
   raw_vs_d<=raw_vs;
   if(raw_vs&&!raw_vs_d&&pending_gain)begin {applied_r,applied_b}<=pending_gains;pending_gain<=0;end
   if(gain_pulse)begin pending_gains<=gain_received;pending_gain<=1;end
  end
 wire rgb_vs,rgb_hs,rgb_de,rgb_valid;wire [47:0] rgb2;
 debayer_top_2to1 u_debayer(.in_pclk(pair_clk),.in_rstn(pair_reset_n),.raw_vs_i(raw_vs),.raw_hs_i(raw_de),
  .raw_de_i(raw_de),.raw_valid_i(raw_de),.raw_datax4_i({raw2[7:0],raw2[15:8]}),
  .r_gain({6'd0,applied_b}),.g_gain(16'd256),.b_gain({6'd0,applied_r}),
  .rgb_vs_o(rgb_vs),.rgb_hs_o(rgb_hs),.rgb_de_o(rgb_de),.rgb_valid_o(rgb_valid),.rgb_datax2_o(rgb2));
 // pair_clk and pixel_clk are phase-related outputs of the SAME PLL (1:2).
 // Keep these paths fully timed. Preserve the validated low/high pixel order.
 reg rgb_vs_d,phase;reg [23:0] pixel;reg pixel_vs,pixel_de,tag_vs_d;
 always @(posedge pixel_clk or negedge pixel_reset_n)begin
  if(!pixel_reset_n)begin rgb_vs_d<=0;phase<=0;pixel<=0;pixel_vs<=0;pixel_de<=0;tag_vs_d<=0;end
  else begin
   rgb_vs_d<=rgb_vs;
   if(rgb_vs&&!rgb_vs_d)phase<=1;else if(rgb_de)phase<=~phase;
   pixel<=phase?rgb2[23:0]:rgb2[47:24];pixel_vs<=rgb_vs;pixel_de<=rgb_de;tag_vs_d<=pixel_vs;
  end
 end
 wire frame_valid;wire [19:0] pixel_count;wire [3:0] error;
 rgbx_crop_scale_640 #(.HD720(1)) u_resize(.clk(pixel_clk),.rst_n(pixel_reset_n),.i_vs(pixel_vs),.i_de(pixel_de),
  .i_r(pixel[7:0]),.i_g(pixel[15:8]),.i_b(pixel[23:16]),
  .i_tag_strobe(pixel_vs&&!tag_vs_d),.i_tag_id(raw_id),.i_tag_valid(!raw_error),.i_meta_error(raw_error),
  .o_rgbx(rgbx),.o_valid(valid),.o_sof(sof),.o_eol(),.o_last(),.o_x(x),.o_y(y),.o_frame_id(frame_id),.o_frame_valid(frame_valid),
  .o_frame_done(frame_done),.o_frame_abort(frame_abort),.o_pixel_count(pixel_count),.o_frame_count(good_frames),.o_error(error));
 wire stats_valid,stats_busy,stats_pulse;wire [34:0] stats_data,stats_received;
 camera_light_stats_compact u_stats(.clk(pixel_clk),.rst_n(pixel_reset_n),.valid(valid),.sof(sof),.frame_done(frame_done),.frame_abort(frame_abort),
  .x(x),.y(y),.frame_id(frame_id),.rgb(rgbx[23:0]),.result_valid(stats_valid),.result(stats_data));
 video_snapshot_cdc #(.WIDTH(35)) u_statistics(.src_clk(pixel_clk),.dst_clk(ctrl_clk),.rst_n(rst_n),
  .send(stats_valid),.data(stats_data),.busy(stats_busy),.pulse(stats_pulse),.received(stats_received));
 camera_light_cpu_apb u_light(.clk(ctrl_clk),.rst_n(ctrl_reset_n),.stats_valid(stats_pulse),.stats(stats_received),
  .sensor_sof_toggle(sensor_sof_toggle),.gain_busy(gain_busy),.PADDR(PADDR),.PSEL(PSEL),.PENABLE(PENABLE),.PWRITE(PWRITE),.PWDATA(PWDATA),
  .PRDATA(PRDATA),.PREADY(PREADY),.PSLVERROR(PSLVERROR),.gain_r(target_r),.gain_b(target_b),.gains_send(gain_send));
endmodule
`default_nettype wire
