`timescale 1ns/1ps
`default_nettype none
// Read-only YT8531 family discovery and actual negotiated gigabit gating.
// No vendor configuration, forced speed or LED register writes.
module a_phy_link_poll #(parameter integer CLK_HZ=10000000, POLL_CYCLES=100000)(
 input wire clk,rst_n,mdio_i,output wire mdio_o,mdio_oe,mdc,
 output reg found,link_gigabit,output reg[4:0]address,
 output reg[31:0]phy_id,output reg[15:0]specific_status
);
 reg start;reg[4:0]reg_address;wire busy,done,ta;wire[15:0]data;
 reg[2:0]state;reg[15:0]id_hi;reg[31:0]wait_count;
 a_mdio_clause22 #(.CLK_HZ(CLK_HZ),.MDC_HZ(1000000)) u_mdio(
  .clk(clk),.rst_n(rst_n),.start(start),.read_op(1'b1),.phy_addr(address),.reg_addr(reg_address),
  .write_data(16'd0),.mdio_i(mdio_i),.mdio_o(mdio_o),.mdio_oe(mdio_oe),.mdc(mdc),
  .busy(busy),.done(done),.ta_error(ta),.read_data(data));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=0;start<=0;reg_address<=2;address<=0;found<=0;
   link_gigabit<=0;phy_id<=0;specific_status<=0;wait_count<=0;id_hi<=0;end
  else begin
   start<=0;
   case(state)
    0:if(!busy)begin reg_address<=2;start<=1;state<=1;end
    1:if(done)begin
     if(ta || data!=16'h4f51)begin address<=address+1'b1;state<=0;end
     else begin id_hi<=data;reg_address<=3;start<=1;state<=2;end
    end
    2:if(done)begin
     if(!ta && (data&16'hfff0)==16'he910)begin found<=1;phy_id<={id_hi,data};state<=3;wait_count<=0;end
     else begin address<=address+1'b1;state<=0;end
    end
    3:if(wait_count==POLL_CYCLES-1)begin wait_count<=0;reg_address<=17;start<=1;state<=4;end
      else wait_count<=wait_count+1'b1;
    4:if(done)begin
     specific_status<=data;
     // Linux Motorcomm definitions: link10,resolved11,duplex13,speed15:14.
     link_gigabit<=!ta && data[10] && data[11] && data[13] && data[15:14]==2;
     if(ta)begin found<=0;phy_id<=0;state<=0;end else state<=3;
    end
    default:state<=0;
   endcase
  end
 end
endmodule
`default_nettype wire
