`timescale 1ns/1ps
`default_nettype none
// RGBX frame events only; native source IDs remain in source diagnostics.
// Single small asynchronous FIFO, fast destination, no source backpressure.
module video_stream_cdc(
 input wire source_clk,dest_clk,rst_n,
 input wire [31:0] i_rgbx,input wire i_valid,i_sof,i_done,i_abort,
 output reg [31:0] o_rgbx,output reg o_valid,o_sof,o_done,o_abort,
 output reg [31:0] overflow_count
);
 wire full,empty;wire [27:0] data;
 reg dropping,pending_abort;reg read_pending;
 wire event_in=i_valid||i_done||i_abort;
 wire write_enable=!full&&(pending_abort||(event_in&&(!dropping||i_sof)));
 wire [27:0] word_in=pending_abort?{4'b0001,24'd0}:{i_valid,i_sof,i_done,i_abort,i_rgbx[23:0]};
 wire read_enable=!empty;
 camera_style_async_fifo #(.DATA_WIDTH(28),.ADDR_WIDTH(5)) u_fifo(
  .i_arst(!rst_n),.i_wclk(source_clk),.i_we(write_enable),.i_wdata(word_in),.o_full(full),
  .i_rclk(dest_clk),.i_re(read_enable),.o_empty(empty),.o_rdata(data));
 wire source_reset_n,dest_reset_n;
 hdmi_reset_release u_source_release(.clk(source_clk),.rst_n(rst_n),.released_n(source_reset_n));
 hdmi_reset_release u_dest_release(.clk(dest_clk),.rst_n(rst_n),.released_n(dest_reset_n));
 always @(posedge source_clk or negedge source_reset_n)begin
  if(!source_reset_n)begin dropping<=0;pending_abort<=0;overflow_count<=0;end
  else if(full&&event_in&&!dropping)begin dropping<=1;pending_abort<=1;overflow_count<=overflow_count+1'b1;end
  else begin
   if(pending_abort&&!full)pending_abort<=0;
   if(i_sof&&!full&&!pending_abort)dropping<=0;
  end
 end
 always @(posedge dest_clk or negedge dest_reset_n)begin
  if(!dest_reset_n)begin read_pending<=0;o_rgbx<=0;o_valid<=0;o_sof<=0;o_done<=0;o_abort<=0;end
  else begin
   read_pending<=read_enable;o_valid<=0;o_sof<=0;o_done<=0;o_abort<=0;
   if(read_pending)begin {o_valid,o_sof,o_done,o_abort}<=data[27:24];o_rgbx<={8'd0,data[23:0]};end
  end
 end
endmodule
`default_nettype wire
