`timescale 1ns/1ps
`default_nettype none
// Native HDMI pixel domain. The caller supplies active-high VS.
// A frame is accepted only after its next VS confirms exact geometry.
// Invalid frames emit ABORT, never a successful terminal descriptor.
module hdmi_rgbx_adapter #(parameter W=640,H=480)(
 input wire clk,rst_n,link_ok,i_vs,i_de,
 input wire [7:0] i_r,i_g,i_b,
 output reg [31:0] o_rgbx,output reg o_valid,o_sof,o_eol,o_last,
 output reg [10:0] o_x,output reg [9:0] o_y,
 output reg [31:0] frame_id,output reg frame_done,frame_abort,
 output reg [31:0] good_frames,bad_frames,
 output reg [15:0] measured_width,measured_height,
 output reg report_strobe,output reg [19:0] pixel_count);
 (* async_reg="true" *) reg [1:0] link_sync;
 reg vs_d,de_d,armed,bad;
 reg [11:0] x,y,line_width;
 wire vs_edge=i_vs&&!vs_d;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   link_sync<=0;vs_d<=0;de_d<=0;armed<=0;bad<=0;x<=0;y<=0;line_width<=0;
   o_rgbx<=0;o_valid<=0;o_sof<=0;o_eol<=0;o_last<=0;o_x<=0;o_y<=0;
   frame_id<=0;frame_done<=0;frame_abort<=0;good_frames<=0;bad_frames<=0;
   measured_width<=0;measured_height<=0;report_strobe<=0;pixel_count<=0;
  end else begin
   link_sync<={link_sync[0],link_ok};vs_d<=i_vs;de_d<=i_de;
   o_valid<=0;o_sof<=0;o_eol<=0;o_last<=0;
   frame_done<=0;frame_abort<=0;report_strobe<=0;
   if(!link_sync[1])begin
    if(armed&&pixel_count!=0)begin frame_abort<=1;bad_frames<=bad_frames+1'b1;report_strobe<=1;end
    armed<=0;bad<=0;x<=0;y<=0;pixel_count<=0;
   end else if(vs_edge)begin
    if(armed)begin
     measured_width<={4'd0,line_width};measured_height<={4'd0,y};
     if(!bad&&y==H&&pixel_count==W*H&&!i_de)begin frame_done<=1;good_frames<=good_frames+1'b1;end
     else begin frame_abort<=1;bad_frames<=bad_frames+1'b1;end
     report_strobe<=1;
    end
    frame_id<=frame_id+1'b1;armed<=1;bad<=0;x<=0;y<=0;pixel_count<=0;
   end else if(armed)begin
    if(i_de)begin
     if(x<W&&y<H)begin
      // Existing NN/display ABI: little-endian bytes R,G,B,0 (0x00BBGGRR).
      o_rgbx<={8'd0,i_b,i_g,i_r};o_valid<=1;o_x<=x[10:0];o_y<=y[9:0];
      o_sof<=x==0&&y==0;o_eol<=x==W-1;o_last<=x==W-1&&y==H-1;
      pixel_count<=pixel_count+1'b1;
     end else bad<=1;
     if(x!=4095)x<=x+1'b1;
    end
    if(de_d&&!i_de)begin
     line_width<=x;if(x!=W)bad<=1;
     x<=0;if(y!=4095)y<=y+1'b1;
    end
   end
  end
 end
endmodule

// Only increment-by-one source counters may use this Gray crossing.
module hdmi_counter_cdc(input wire src_clk,dst_clk,rst_n,
 input wire [31:0] count,output wire [31:0] received);
 wire source_rst_n,destination_rst_n;
 hdmi_reset_release u_source_release(.clk(src_clk),.rst_n(rst_n),.released_n(source_rst_n));
 hdmi_reset_release u_destination_release(.clk(dst_clk),.rst_n(rst_n),.released_n(destination_rst_n));

 reg [31:0] gray;
 (* async_reg="true" *) reg [31:0] meta,sync;
 always @(posedge src_clk or negedge source_rst_n)
  if(!source_rst_n)gray<=0;else gray<=count^(count>>1);
 always @(posedge dst_clk or negedge destination_rst_n)
  if(!destination_rst_n)begin meta<=0;sync<=0;end else begin meta<=gray;sync<=meta;end
 genvar i;
 generate for(i=0;i<32;i=i+1)begin:G_DECODE
  assign received[i]=^(sync>>i);
 end endgenerate
endmodule
`default_nettype wire
