`timescale 1ns/1ps
`default_nettype none
// Network-only management peripheral; CPU/APB domain, independent of NN clocks.
// BASE=0x0900 is a proposed integration allocation, not installed in TEAM4.
module a_eth_mdio_apb #(
 parameter integer CLK_HZ=100000000,MDC_HZ=2500000,
 parameter [15:0] BASE=16'h0900
)(
 input wire clk,rst_n,input wire [15:0] PADDR,
 input wire PSEL,PENABLE,PWRITE,input wire [31:0] PWDATA,
 output reg [31:0] PRDATA,output wire PREADY,PSLVERROR,
 input wire mdio_i,output wire mdio_o,mdio_oe,mdc
);
 wire [15:0] off=PADDR-BASE;
 wire access=PSEL&&PENABLE;
 wire legal=(off==0||off==4||off==8||off==12||off==16||off==20||off==24||off==28);
 wire writable=(off==4||off==8||off==12);
 reg launch,rd,sticky_done,sticky_ta,rejected;
 reg [4:0] pa,ra;
 reg [15:0] wd;
 reg [31:0] seq;
 wire busy,finished,ta;
 wire [15:0] data;
 a_mdio_clause22 #(.CLK_HZ(CLK_HZ),.MDC_HZ(MDC_HZ)) u_mdio(
  .clk(clk),.rst_n(rst_n),.start(launch),.read_op(rd),.phy_addr(pa),.reg_addr(ra),
  .write_data(wd),.mdio_i(mdio_i),.mdio_o(mdio_o),.mdio_oe(mdio_oe),.mdc(mdc),
  .busy(busy),.done(finished),.ta_error(ta),.read_data(data));
 assign PREADY=1;
 assign PSLVERROR=access&&(!legal||(PWRITE&&!writable));
 always @*begin
  PRDATA=0;
  case(off)
   0:PRDATA=32'h41455401;
   4:PRDATA={28'd0,rejected,sticky_ta,sticky_done,(busy||launch)};
   8:PRDATA={20'd0,ra,pa,rd,1'b0};
   12:PRDATA={16'd0,wd};16:PRDATA={16'd0,data};20:PRDATA=seq;
   24:PRDATA=CLK_HZ;
   28:PRDATA=CLK_HZ/(2*((CLK_HZ+2*MDC_HZ-1)/(2*MDC_HZ)));
   default:;
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   launch<=0;rd<=1;pa<=0;ra<=0;wd<=0;
   seq<=0;sticky_done<=0;sticky_ta<=0;rejected<=0;
  end else begin
   launch<=0;
   if(finished)begin seq<=seq+1'b1;sticky_done<=1;sticky_ta<=ta;end
   if(access&&PWRITE&&!PSLVERROR)case(off)
    4:begin
     if(PWDATA[1])sticky_done<=0;
     if(PWDATA[2])sticky_ta<=0;
     if(PWDATA[3])rejected<=0;
    end
    12:if(!busy&&!launch)wd<=PWDATA[15:0];else rejected<=1;
    8:if(PWDATA[0])begin
     if(busy||launch||finished)rejected<=1;
     else begin
      pa<=PWDATA[6:2];ra<=PWDATA[11:7];rd<=PWDATA[1];launch<=1;
      sticky_done<=0;sticky_ta<=0;rejected<=0;
     end
    end
    default:;
   endcase
  end
 end
endmodule
`default_nettype wire
