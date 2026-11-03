`timescale 1ns/1ps
`default_nettype none
// DVI-style TMDS from the PC mode advertised by our base-only EDID.
// Decode every aligned symbol; HDMI preamble/guard-band timing must not
// suppress the first active symbol of a DVI scan line.
module pc_dvi_decode(input wire clk,ready,input wire [9:0] symbol,
 output reg c0,c1,de,output reg [7:0] pixel);
 wire [7:0] q=symbol[9]?~symbol[7:0]:symbol[7:0];
 wire [7:0] decoded;
 assign decoded[0]=q[0];
 genvar i;
 generate for(i=1;i<8;i=i+1)begin:G_BIT
  assign decoded[i]=symbol[8]?(q[i]^q[i-1]):~(q[i]^q[i-1]);
 end endgenerate
 reg seen_control=0;
 initial begin c0=1;c1=1;de=0;pixel=0;end
 always @(posedge clk)begin
  if(!ready)begin de<=0;pixel<=0;seen_control<=0;end
  else case(symbol)
   10'h354:begin c0<=0;c1<=0;de<=0;seen_control<=1;end
   10'h0ab:begin c0<=1;c1<=0;de<=0;seen_control<=1;end
   10'h154:begin c0<=0;c1<=1;de<=0;seen_control<=1;end
   10'h2ab:begin c0<=1;c1<=1;de<=0;seen_control<=1;end
   default:begin pixel<=decoded;de<=seen_control;end
  endcase
 end
endmodule
`default_nettype wire
