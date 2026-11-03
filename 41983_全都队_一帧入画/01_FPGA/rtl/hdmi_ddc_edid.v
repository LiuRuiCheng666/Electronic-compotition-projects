`timescale 1ns/1ps
`default_nettype none
// Read-only EDID EEPROM at DDC address 0x50. All outputs are open-drain:
// sda_low=1 pulls SDA low, otherwise the external pull-up owns the line.
// Pointer writes and repeated START are supported; EDID cannot be modified.
module hdmi_ddc_edid #(parameter INIT_FILE="hdmi_720p_edid.hex")(
 input wire clk,rst_n,scl_i,sda_i,output reg sda_low,
 output reg [31:0] read_count);
 (* async_reg="true" *) reg [2:0] scl_sync,sda_sync;
 reg scl_d,sda_d;
 wire up=scl_sync[2]&&!scl_d,down=!scl_sync[2]&&scl_d;
 wire start=scl_sync[2]&&scl_d&&!sda_sync[2]&&sda_d;
 wire stop=scl_sync[2]&&scl_d&&sda_sync[2]&&!sda_d;
 reg [7:0] rom[0:127];
 initial $readmemh(INIT_FILE,rom);
 localparam ADDR=0,PTR=1,IGNORE=2,ACK=3,SEND=4,MACK=5,WAIT=6;
 reg [2:0] state,next_state,bits;
 reg [1:0] phase;
 reg ack;
 reg [7:0] shift,pointer,tx_shift;
 wire [7:0] incoming={shift[6:0],sda_sync[2]};
 wire [7:0] current_byte=pointer[7]?8'h00:rom[pointer[6:0]];
 wire [7:0] following=pointer+8'd1;
 wire [7:0] next_byte=following[7]?8'h00:rom[following[6:0]];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   scl_sync<=7;sda_sync<=7;scl_d<=1;sda_d<=1;sda_low<=0;
   state<=WAIT;next_state<=WAIT;bits<=0;phase<=0;ack<=0;
   shift<=0;pointer<=0;tx_shift<=0;read_count<=0;
  end else begin
   scl_sync<={scl_sync[1:0],scl_i};sda_sync<={sda_sync[1:0],sda_i};
   scl_d<=scl_sync[2];sda_d<=sda_sync[2];
   if(start)begin state<=ADDR;bits<=0;sda_low<=0;end
   else if(stop)begin state<=WAIT;sda_low<=0;end
   else case(state)
    ADDR,PTR,IGNORE:if(up)begin
     shift<=incoming;
     if(bits==7)begin
      bits<=0;phase<=0;state<=ACK;
      if(state==ADDR)begin
       ack<=incoming[7:1]==7'h50;
       next_state<=(incoming[7:1]!=7'h50) ? WAIT : (incoming[0] ? SEND : PTR);
      end else begin
       ack<=1;next_state<=IGNORE;
       if(state==PTR)pointer<=incoming;
      end
     end else bits<=bits+1'b1;
    end
    ACK:if(down)begin
     if(phase==0)begin sda_low<=ack;phase<=1;end
     else begin
      state<=next_state;bits<=0;sda_low<=0;
      if(next_state==SEND)begin
       sda_low<=!current_byte[7];tx_shift<={current_byte[6:0],1'b1};
       read_count<=read_count+1'b1;
      end
     end
    end
    SEND:begin
     if(up)begin
      if(bits==7)begin state<=MACK;phase<=0;end
      else bits<=bits+1'b1;
     end
     if(down)begin sda_low<=!tx_shift[7];tx_shift<={tx_shift[6:0],1'b1};end
    end
    MACK:begin
     if(down&&phase==0)begin sda_low<=0;phase<=1;end
     if(up&&phase==1)begin
      if(sda_sync[2])state<=WAIT;
      else begin pointer<=following;tx_shift<=next_byte;phase<=2;end
     end
     if(down&&phase==2)begin
      sda_low<=!tx_shift[7];tx_shift<={tx_shift[6:0],1'b1};
      state<=SEND;bits<=0;read_count<=read_count+1'b1;
     end
    end
    default:sda_low<=0;
   endcase
  end
 end
endmodule
`default_nettype wire
