`timescale 1ns/1ps
`default_nettype none
// Coherent front-frame readback shares the existing display read port. No
// frame-sized storage, new DDR channel, or pixel clock mux is introduced.
module frame_snapshot_service #(
 parameter integer W=1280,H=720,TIMEOUT_BITS=21,
 parameter [15:0] APB_BASE=16'h0800
)(
 input wire cpu_clk,core_clk,cpu_reset,core_reset_n,
 input wire can_lock,input wire [31:0] display_frame,original_base,result_base,
 input wire [2:0] display_style,input wire [1:0] display_roi,input wire display_fish,
 output wire locked,
 input wire [15:0] PADDR,input wire PSEL,PENABLE,PWRITE,input wire [31:0] PWDATA,
 output wire [31:0] PRDATA,output wire PREADY,PSLVERROR,
 input wire [31:0] video_araddr,input wire [7:0] video_arlen,
 input wire video_arvalid,output wire video_arready,
 output wire [127:0] video_rdata,output wire [1:0] video_rresp,
 output wire video_rlast,video_rvalid,input wire video_rready,
 output wire [31:0] araddr,output wire [7:0] arlen,
 output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [1:0] rresp,
 input wire rlast,rvalid,output wire rready
);
 wire [15:0] paddr;wire psel,penable,pwrite,pready,perror;
 wire [31:0] pwdata,prdata;
 apb_async_bridge u_apb(.s_clk(cpu_clk),.d_clk(core_clk),.arst(cpu_reset || !core_reset_n),
  .s_paddr(PADDR),.s_psel(PSEL),.s_penable(PENABLE),.s_pwrite(PWRITE),.s_pwdata(PWDATA),
  .s_prdata(PRDATA),.s_pready(PREADY),.s_pslverror(PSLVERROR),
  .d_paddr(paddr),.d_psel(psel),.d_penable(penable),.d_pwrite(pwrite),.d_pwdata(pwdata),
  .d_prdata(prdata),.d_pready(pready),.d_pslverror(perror));
 wire [31:0] photo_araddr;wire photo_arvalid,photo_arready;
 wire [127:0] photo_rdata;wire [1:0] photo_rresp;
 wire photo_rlast,photo_rvalid,photo_rready;
 c_frame_readback #(.W(W),.H(H),.TIMEOUT_BITS(TIMEOUT_BITS),.APB_BASE(APB_BASE)) u_readback(
  .clk(core_clk),.rst_n(core_reset_n),.can_lock(can_lock),.display_frame(display_frame),
  .original_base(original_base),.result_base(result_base),.display_style(display_style),
  .display_roi(display_roi),.display_fish(display_fish),.locked(locked),
  .PADDR(paddr),.PSEL(psel),.PENABLE(penable),.PWRITE(pwrite),.PWDATA(pwdata),
  .PRDATA(prdata),.PREADY(pready),.PSLVERROR(perror),
  .araddr(photo_araddr),.arvalid(photo_arvalid),.arready(photo_arready),
  .rdata(photo_rdata),.rresp(photo_rresp),.rlast(photo_rlast),.rvalid(photo_rvalid),.rready(photo_rready));
 cat_fisheye_axi_mux u_read_mux(.clk(core_clk),.rst_n(core_reset_n),.debug_read_state(),
  .d_araddr(video_araddr),.d_arlen(video_arlen),.d_arvalid(video_arvalid),.d_arready(video_arready),
  .d_rdata(video_rdata),.d_rresp(video_rresp),.d_rlast(video_rlast),.d_rvalid(video_rvalid),.d_rready(video_rready),
  .w_araddr(photo_araddr),.w_arlen(8'd0),.w_arvalid(photo_arvalid),.w_arready(photo_arready),
  .w_rdata(photo_rdata),.w_rresp(photo_rresp),.w_rlast(photo_rlast),.w_rvalid(photo_rvalid),.w_rready(photo_rready),
  .m_araddr(araddr),.m_arlen(arlen),.m_arvalid(arvalid),.m_arready(arready),
  .m_rdata(rdata),.m_rresp(rresp),.m_rlast(rlast),.m_rvalid(rvalid),.m_rready(rready));
endmodule
`default_nettype wire
