`timescale 1ns/1ps
`default_nettype none
// Same AE/AWB decisions and 35-bit report as AWB4, without twelve DSP blocks.
// Sparse sample accumulators and frame-rate shift/add ratio comparisons.
module camera_light_stats_compact #(parameter SAMPLE_LOG2=5,MIN_SAMPLES=256,MIN_NEUTRAL=32)(
 input wire clk,rst_n,valid,sof,frame_done,frame_abort,
 input wire [10:0] x,input wire [9:0] y,input wire [31:0] frame_id,
 input wire [23:0] rgb,output reg result_valid,output reg [34:0] result
);
 wire [7:0] r=rgb[7:0],g=rgb[15:8],b=rgb[23:16];
 wire [7:0] mx0=r>g?r:g,mn0=r<g?r:g;
 wire [7:0] mx=mx0>b?mx0:b,mn=mn0<b?mn0:b;
 wire neutral=mn>=16&&mx<224&&{mn,1'b0}>={1'b0,mx};
 wire sample=valid&&x[SAMPLE_LOG2-1:0]==(1<<(SAMPLE_LOG2-1))&&y[SAMPLE_LOG2-1:0]==(1<<(SAMPLE_LOG2-1));
 wire [7:0] lum={2'b0,r[7:2]}+{1'b0,g[7:1]}+{2'b0,b[7:2]};
 reg active,seen,finish_pending;reg [15:0] last_id;
 reg [9:0] count,clips,neutrals;
 reg [17:0] sy,sr,sg,sb;
 wire [23:0] green32={1'b0,sg,5'b0},red32={1'b0,sr,5'b0},blue32={1'b0,sb,5'b0};
 wire [23:0] green31=green32-sg,green33=green32+sg;
 wire [17:0] high_target=({8'd0,count}<<6)+({8'd0,count}<<5)+({8'd0,count}<<4);
 wire [17:0] low_target=({8'd0,count}<<6)+({8'd0,count}<<3);
 wire [1:0] ae=clips>(count>>3)?3:(clips>(count>>5)||sy>high_target)?2:sy<low_target?1:0;
 wire [1:0] red=green31>red32?1:green33<red32?2:0;
 wire [1:0] blue=green31>blue32?1:green33<blue32?2:0;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   active<=0;seen<=0;finish_pending<=0;last_id<=0;count<=0;clips<=0;neutrals<=0;
   sy<=0;sr<=0;sg<=0;sb<=0;result_valid<=0;result<=0;
  end else begin
   result_valid<=0;finish_pending<=0;
   if(finish_pending)begin result<={sy[17:10],count,clips,neutrals>=MIN_NEUTRAL,blue,red,ae};result_valid<=1;end
   if(sof)begin active<=!seen||frame_id[15:0]!=last_id;count<=0;clips<=0;neutrals<=0;sy<=0;sr<=0;sg<=0;sb<=0;end
   if(sample&&active&&count!=1023)begin
    count<=count+1'b1;sy<=sy+lum;
    if(mx>=240)clips<=clips+1'b1;
    if(neutral)begin neutrals<=neutrals+1'b1;sr<=sr+r;sg<=sg+g;sb<=sb+b;end
   end
   if(frame_done)begin
    if(active&&count>=MIN_SAMPLES)begin finish_pending<=1;last_id<=frame_id[15:0];seen<=1;end
    active<=0;
   end
   if(frame_abort)begin active<=0;result_valid<=0;finish_pending<=0;end
  end
 end
endmodule
`default_nettype wire
