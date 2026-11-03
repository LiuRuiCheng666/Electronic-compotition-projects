`timescale 1ns/1ps
`default_nettype none
// SW1 active low. One step per debounced press; holding never repeats.
// Request lives in the display pixel domain. Renderer commits it in blanking.
module display_view_control #(
 parameter integer DEBOUNCE_CYCLES=2970000
)(
 input wire clk,rst_n,button_n,
 output reg [1:0] requested_view
);
 localparam integer CW=(DEBOUNCE_CYCLES<2)?1:$clog2(DEBOUNCE_CYCLES);
 (* async_reg="true",syn_preserve=1 *) reg button_meta;
 (* async_reg="true",syn_preserve=1 *) reg button_sync;
 reg stable;
 reg [CW-1:0] count;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin button_meta<=1;button_sync<=1;stable<=1;count<=0;requested_view<=0;end
  else begin
   button_meta<=button_n;button_sync<=button_meta;
   if(button_sync==stable)count<=0;
   else if(count==DEBOUNCE_CYCLES-1)begin
    count<=0;stable<=button_sync;
    if(!button_sync)requested_view<=requested_view==2?0:requested_view+2'd1;
   end else count<=count+1'b1;
  end
 end
endmodule
`default_nettype wire
