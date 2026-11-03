`timescale 1ns/1ps
`default_nettype none
// CPU and AXI use the SAME100MHz clock in this project. One16-byte AXI read
// returns one selected32-bit word; no frame or128-bit cache RAM is added.
// AXI transactions are NEVER cancelled after ARVALID, including on timeout.
module c_frame_readback #(
 parameter integer W=640,H=480,TIMEOUT_BITS=20,
 parameter [15:0] APB_BASE=16'h0600
)(
 input wire clk,rst_n,can_lock,
 input wire [31:0] display_frame,original_base,result_base,
 input wire [2:0] display_style,input wire [1:0] display_roi,input wire display_fish,
 output reg locked,
 input wire [15:0] PADDR,input wire PSEL,PENABLE,PWRITE,input wire [31:0] PWDATA,
 output reg [31:0] PRDATA,output wire PREADY,PSLVERROR,
 output reg [31:0] araddr,output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [1:0] rresp,input wire rvalid,rlast,output wire rready
);
 wire [15:0] register_offset=PADDR-APB_BASE;
 reg [1:0] state;
 reg source_style,valid,error,poisoned;
 reg [31:0] held_frame;
 reg [5:0] held_meta;
 reg [31:0] data;reg [1:0] lane;
 reg [TIMEOUT_BITS-1:0] timer;
 wire bus=PSEL&&PENABLE;
 wire busy=state!=0;
 wire [31:0] limit=source_style?W*H*3:W*H*4;
 wire legal=register_offset==16'h0000||register_offset==16'h0004||register_offset==16'h0008||register_offset==16'h000c||
     register_offset==16'h0010||
     register_offset==16'h0020||register_offset==16'h0024||register_offset==16'h0028||register_offset==16'h002c;
 assign PREADY=1;
 assign PSLVERROR=bus && (!legal || (PWRITE && register_offset!=16'h0004&&register_offset!=16'h0008&&register_offset!=16'h000c));
 assign arvalid=state==1;
 assign rready=state==2;
 always @*begin
  PRDATA=0;
  case(register_offset)
   16'h0000:PRDATA=32'h46524d01;
   16'h0004:PRDATA={26'd0,poisoned,can_lock,valid,error,busy,locked};
   16'h0008:PRDATA=araddr;
   16'h000c:PRDATA={31'd0,source_style};
   16'h0010:PRDATA=valid?data:32'd0;
   16'h0020:PRDATA=held_frame;16'h0024:PRDATA={26'd0,held_meta};
   16'h0028:PRDATA=W;16'h002c:PRDATA=H;
   default:;
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=0;locked<=0;source_style<=0;valid<=0;error<=0;poisoned<=0;
   held_frame<=0;held_meta<=0;data<=0;lane<=0;timer<=0;araddr<=0;
  end else begin
   if(locked && (!can_lock || display_frame!=held_frame))begin error<=1;poisoned<=1;valid<=0;end
   if(busy)begin
    if(!(&timer))timer<=timer+1'b1;
    else begin error<=1;poisoned<=1;valid<=0;end
   end else timer<=0;
   if(state==1&&arready)state<=2;
   if(state==2&&rvalid)begin
    if(rresp!=0||!rlast)begin error<=1;poisoned<=1;valid<=0;end
    // Drain malformed multibeat responses until LAST; never reroute midtransaction.
    if(rlast)begin state<=0;if(!poisoned && !(&timer) && rresp==0 && display_frame==held_frame)begin data<=rdata>>(lane*32);valid<=1;end end
   end
   if(bus&&PWRITE&&!PSLVERROR)begin
    case(register_offset)
     16'h0004:begin
      if(busy)error<=1;
      else if(PWDATA==0)begin locked<=0;valid<=0;error<=0;poisoned<=0;end
      else if(PWDATA==1 && can_lock && !locked)begin
       locked<=1;valid<=0;error<=0;poisoned<=0;source_style<=0;
       held_frame<=display_frame;
       held_meta<={display_style[2],display_fish,display_roi,display_style[1:0]};
      end else error<=1;
     end
     16'h000c:if(!locked||busy||PWDATA>1)error<=1;
                 else begin source_style<=PWDATA[0];valid<=0;end
     16'h0008:begin
      if(!locked||busy||poisoned||PWDATA[1:0]!=0||PWDATA>limit-4)begin error<=1;valid<=0;end
      else begin
       araddr<=(source_style?result_base:original_base)+{PWDATA[31:4],4'd0};lane<=PWDATA[3:2];
       state<=1;valid<=0;timer<=0;
      end
     end
     default:;
    endcase
   end
  end
 end
endmodule
`default_nettype wire
