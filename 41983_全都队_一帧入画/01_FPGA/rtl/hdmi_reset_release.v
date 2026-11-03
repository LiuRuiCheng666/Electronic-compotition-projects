`timescale 1ns/1ps
`default_nettype none
// Assert without a running destination clock; deassert only after two edges
// of that destination clock. Only these asynchronous reset pins are exempt
// in SDC. All local functional reset/recovery paths remain timed.
module hdmi_reset_release(input wire clk,rst_n,output wire released_n);
 (* async_reg="true",syn_preserve=1 *)reg [1:0] release_sync;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)release_sync<=0;else release_sync<={release_sync[0],1'b1};
 assign released_n=release_sync[1];
endmodule
`default_nettype wire
