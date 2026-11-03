`timescale 1ns/1ps
`default_nettype none
// Clause 22 management engine. No PHY vendor configuration writes at startup.
// MDIO changes only while MDC is low; PHY read data is sampled on rising MDC.
module a_mdio_clause22 #(
 parameter integer CLK_HZ=100000000,
 parameter integer MDC_HZ=2500000
)(
 input wire clk,rst_n,start,read_op,
 input wire [4:0] phy_addr,reg_addr,input wire [15:0] write_data,
 input wire mdio_i,output wire mdio_o,mdio_oe,output reg mdc,
 output reg busy,done,ta_error,output reg [15:0] read_data
);
 localparam integer HALF=(CLK_HZ+2*MDC_HZ-1)/(2*MDC_HZ);
 localparam integer CW=HALF>1?$clog2(HALF):1;
 reg [CW-1:0] divider;
 reg [5:0] bit_index;
 reg rd;
 reg [4:0] pa,ra;
 reg [15:0] wd;
 reg [15:0] incoming;
 reg ta_bad;
 function bit_out;
  input [5:0] i;input r;input [4:0] p,a;input [15:0] d;
  begin
   if(i<32)bit_out=1;
   else case(i)
    32:bit_out=0;33:bit_out=1;
    34:bit_out=r;35:bit_out=!r;
    46:bit_out=1;47:bit_out=0;
    default:begin
     if(i<=40)bit_out=p[40-i];
     else if(i<=45)bit_out=a[45-i];
     else bit_out=d[63-i];
    end
   endcase
  end
 endfunction
 assign mdio_o=bit_out(bit_index,rd,pa,ra,wd);
 // Separate I/O and output-enable signals for Efinity GPIO bidirectional IP.
 assign mdio_oe=busy && (!rd || bit_index<46);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   divider<=0;bit_index<=0;rd<=0;pa<=0;ra<=0;wd<=0;
   mdc<=0;busy<=0;done<=0;ta_error<=0;read_data<=0;incoming<=0;ta_bad<=0;
  end else begin
   done<=0;
   if(!busy)begin
    mdc<=0;divider<=0;
    if(start)begin
     busy<=1;bit_index<=0;rd<=read_op;pa<=phy_addr;ra<=reg_addr;
     wd<=write_data;incoming<=0;ta_bad<=0;ta_error<=0;
    end
   end else if(divider==HALF-1)begin
    divider<=0;mdc<=!mdc;
    if(!mdc)begin
     if(rd && bit_index==47 && mdio_i)ta_bad<=1;
     if(rd && bit_index>=48)incoming<={incoming[14:0],mdio_i};
    end else if(bit_index==63)begin
     busy<=0;done<=1;ta_error<=ta_bad;read_data<=incoming;
    end else bit_index<=bit_index+1'b1;
   end else divider<=divider+1'b1;
  end
 end
endmodule
`default_nettype wire
