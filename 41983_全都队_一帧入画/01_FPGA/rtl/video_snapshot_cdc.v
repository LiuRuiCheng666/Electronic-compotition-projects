`timescale 1ns/1ps
`default_nettype none
module video_snapshot_cdc #(parameter WIDTH=35)(
 input wire src_clk,dst_clk,rst_n,input wire send,input wire [WIDTH-1:0] data,
 output wire busy,output reg pulse,output reg [WIDTH-1:0] received);
 wire source_rst_n,destination_rst_n;
 hdmi_reset_release u_source_release(.clk(src_clk),.rst_n(rst_n),.released_n(source_rst_n));
 hdmi_reset_release u_destination_release(.clk(dst_clk),.rst_n(rst_n),.released_n(destination_rst_n));

 reg request,ack; reg [WIDTH-1:0] held;
 (* async_reg="true" *) reg [1:0] req_sync,ack_sync;
 assign busy=request!=ack_sync[1];
 always @(posedge src_clk or negedge source_rst_n)
  if(!source_rst_n)begin request<=0;held<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};
   if(send&&!busy)begin held<=data;request<=~request;end
  end
 always @(posedge dst_clk or negedge destination_rst_n)
  if(!destination_rst_n)begin ack<=0;req_sync<=0;pulse<=0;received<=0;end
  else begin
   req_sync<={req_sync[0],request};pulse<=0;
   if(req_sync[1]!=ack)begin received<=held;pulse<=1;ack<=req_sync[1];end
  end
endmodule
`default_nettype wire
