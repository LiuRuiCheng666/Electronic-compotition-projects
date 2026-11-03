`timescale 1ns/1ps
`default_nettype none
// Independent HDMI input source. PHY/PLL pins stay in the board top;
// this block consumes deserialized TMDS symbols and produces RGBX8 frames.
// There is no pixel READY: consumers must discard a whole unavailable frame.
module hdmi_input_frontend #(
 parameter integer W=1280,H=720,CTRL_HZ=100000000,INVERT_LANES=1,
 parameter EDID_FILE="hdmi_720p_edid.hex",
 parameter [15:0] APB_BASE_ADDR=16'h0600
)(
 input wire ctrl_clk,pixel_clk,display_clk,
 input wire ctrl_reset_n,video_reset_n,pixel_reset_n,apb_reset_n,
 input wire power_n,pll_locked,
 input wire [9:0] lane0,lane1,lane2,
 input wire scl_i,sda_i,
 output wire scl_o,scl_oe,sda_o,sda_oe,hpd_n,pll_reset_n,
 output wire delay_inc,delay_rst,delay_enable,present,
 output wire [31:0] rgbx,frame_id,good_frames,bad_frames,edid_reads,
 output wire valid,sof,eol,last,frame_done,frame_abort,report_strobe,
 output wire [10:0] x,output wire [9:0] y,
 output wire [15:0] measured_width,measured_height,
 output wire [19:0] pixel_count,
 output wire raw_vs,raw_hs,raw_de,
 input wire [31:0] skipped_frames_pixel,
 output wire [31:0] frames_display,skipped_display,
 input wire [15:0] PADDR,input wire PSEL,PENABLE,PWRITE,
 output wire [31:0] PRDATA,output wire PREADY,PSLVERROR
);
 wire decoder_reset_n;wire [7:0] rx_r,rx_g,rx_b;
        hdmi_sink_control #(.INIT_FILE(EDID_FILE),.HPD_WAIT(CTRL_HZ/10),.RETRY_WAIT(CTRL_HZ/5)) u_hdmi_sink(.clk(ctrl_clk),.rst_n(ctrl_reset_n),.power_n(power_n),
         .pll_locked(pll_locked),.decoder_reset_n(decoder_reset_n),
         .scl_i(scl_i),.sda_i(sda_i),.scl_o(scl_o),.scl_oe(scl_oe),
         .sda_o(sda_o),.sda_oe(sda_oe),
         .hpd_n(hpd_n),.pll_reset_n(pll_reset_n),.present(present),.edid_reads(edid_reads));
        dvi_decoder #(.DVI_MODE(1)) u_hdmi_decoder(.pclk(pixel_clk),.bdata((INVERT_LANES?~lane0:lane0)),
         .gdata((INVERT_LANES?~lane1:lane1)),.rdata((INVERT_LANES?~lane2:lane2)),.pll_lock(pll_locked&&ctrl_reset_n),
         .pll_rst_n(decoder_reset_n),.hsync(raw_hs),.vsync(raw_vs),.de(raw_de),.red(rx_r),.green(rx_g),.blue(rx_b),
         .DLY_INC(delay_inc),.DLY_RST(delay_rst),.DLY_ENA(delay_enable));
        hdmi_rgbx_adapter #(.W(W),.H(H)) u_hdmi_adapter(.clk(pixel_clk),.rst_n(pixel_reset_n),
         .link_ok(pll_locked),.i_vs(raw_vs),.i_de(raw_de),.i_r(rx_r),.i_g(rx_g),.i_b(rx_b),
         .o_rgbx(rgbx),.o_valid(valid),.o_sof(sof),.o_eol(eol),.o_last(last),
         .o_x(x),.o_y(y),.frame_id(frame_id),.frame_done(frame_done),.frame_abort(frame_abort),
         .good_frames(good_frames),.bad_frames(bad_frames),.measured_width(measured_width),.measured_height(measured_height),
         .report_strobe(report_strobe),.pixel_count(pixel_count));
        hdmi_rx_diag_apb #(.BASE_ADDR(APB_BASE_ADDR)) u_hdmi_diag(.clk(ctrl_clk),.rst_n(apb_reset_n),.rx_clk(pixel_clk),.rx_reset_n(video_reset_n),
         .report_strobe(report_strobe),.rx_report({bad_frames,good_frames,frame_id,measured_height,measured_width}),
         .present(present),.pll_locked(pll_locked),.edid_reads(edid_reads),
         .PADDR(PADDR),.PSEL(PSEL),.PENABLE(PENABLE),.PWRITE(PWRITE),.PRDATA(PRDATA),.PREADY(PREADY),.PSLVERROR(PSLVERROR));
        hdmi_counter_cdc u_hdmi_frames_cdc(.src_clk(pixel_clk),.dst_clk(display_clk),.rst_n(video_reset_n),
         .count(good_frames),.received(frames_display));
        hdmi_counter_cdc u_hdmi_skipped_cdc(.src_clk(pixel_clk),.dst_clk(display_clk),.rst_n(video_reset_n),
         .count(skipped_frames_pixel),.received(skipped_display));

endmodule
`default_nettype wire
