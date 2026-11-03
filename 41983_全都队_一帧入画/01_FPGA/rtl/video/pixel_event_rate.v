`timescale 1ns/1ps
`default_nettype none
// Single-domain source FPS: no CDC/mailbox when source and OSD share a clock.
module pixel_event_rate #(parameter HZ=148500000)(input wire clk,rst_n,event_in,output reg[9:0]fps);
 reg[27:0]cycles;reg[9:0]count;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin cycles<=0;count<=0;fps<=0;end
  else if(cycles==HZ-1)begin cycles<=0;fps<=count+(event_in&&count!=1023);count<=0;end
  else begin cycles<=cycles+1'b1;if(event_in&&count!=1023)count<=count+1'b1;end
 end
endmodule
`default_nettype wire
