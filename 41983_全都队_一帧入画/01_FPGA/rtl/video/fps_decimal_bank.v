`timescale 1ns/1ps
`default_nettype none
// Time-share one10-bit binary-to-BCD converter among six low-rate counters.
// This changes only OSD number formatting, never video or FPS measurements.
module fps_decimal_bank(input wire clk,rst_n,input wire [59:0] values,output reg [71:0] digits);
 reg [21:0] shift;reg [3:0] bit_count;reg [2:0] channel;
 reg [71:0] staged;reg load;
 reg [21:0] adjusted;
 wire [9:0] selected=values[channel*10+:10];
 always @*begin
  adjusted=shift;
  if(shift[13:10]>=5)adjusted[13:10]=shift[13:10]+4'd3;
  if(shift[17:14]>=5)adjusted[17:14]=shift[17:14]+4'd3;
  if(shift[21:18]>=5)adjusted[21:18]=shift[21:18]+4'd3;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin digits<=0;shift<=0;staged<=0;bit_count<=0;channel<=0;load<=1;end
  else if(load)begin shift<={12'd0,(selected>999?10'd999:selected)};bit_count<=0;load<=0;end
  else begin
   shift<=adjusted<<1;
   if(bit_count==9)begin
    staged[channel*12+:12]<=(adjusted<<1)>>10;
    load<=1;
    if(channel==5)begin digits<={12'((adjusted<<1)>>10),staged[59:0]};channel<=0;end
    else channel<=channel+1'b1;
   end else bit_count<=bit_count+1'b1;
  end
 end
endmodule
`default_nettype wire
