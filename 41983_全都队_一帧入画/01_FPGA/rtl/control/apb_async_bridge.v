`timescale 1ns/1ps
`default_nettype none
// One blocking APB transaction, held through a request/acknowledge handshake.
// The target APB bus and its side effects stay entirely in the target domain.
module apb_async_bridge(
 input wire s_clk,d_clk,arst,
 input wire [15:0] s_paddr,input wire s_psel,s_penable,s_pwrite,
 input wire [31:0] s_pwdata,output wire [31:0] s_prdata,
 output wire s_pready,s_pslverror,
 output wire [15:0] d_paddr,output wire d_psel,d_penable,d_pwrite,
 output wire [31:0] d_pwdata,input wire [31:0] d_prdata,
 input wire d_pready,d_pslverror
);
 (* async_reg="true",syn_preserve=1 *)reg [1:0] s_reset=3,d_reset=3;
 always @(posedge s_clk or posedge arst)if(arst)s_reset<=3;else s_reset<={s_reset[0],1'b0};
 always @(posedge d_clk or posedge arst)if(arst)d_reset<=3;else d_reset<={d_reset[0],1'b0};
 reg request,ack;reg [1:0] s_state,d_state;
 (* async_reg="true",syn_preserve=1 *)reg [1:0] request_sync,ack_sync;
 reg [48:0] s_command,d_command;
 reg [32:0] d_response,s_response;
 assign {d_pwrite,d_paddr,d_pwdata}=d_command;
 assign d_psel=(d_state==1 || d_state==2);
 assign d_penable=(d_state==2);
 assign s_pready=(s_state==2);
 assign s_prdata=s_response[31:0];
 assign s_pslverror=s_pready && s_response[32];
 always @(posedge s_clk or posedge s_reset[1])begin
  if(s_reset[1])begin request<=0;s_state<=0;ack_sync<=0;s_command<=0;s_response<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};
   case(s_state)
    0:if(s_psel && s_penable)begin s_command<={s_pwrite,s_paddr,s_pwdata};request<=~request;s_state<=1;end
    1:if(ack_sync[1]==request)begin s_response<=d_response;s_state<=2;end
    2:if(s_psel && s_penable)s_state<=0;
    default:s_state<=0;
   endcase
  end
 end
 always @(posedge d_clk or posedge d_reset[1])begin
  if(d_reset[1])begin ack<=0;d_state<=0;request_sync<=0;d_command<=0;d_response<=0;end
  else begin
   request_sync<={request_sync[0],request};
   case(d_state)
    0:if(request_sync[1]!=ack)begin d_command<=s_command;d_state<=1;end
    1:d_state<=2;
    2:if(d_pready)begin d_response<={d_pslverror,d_prdata};ack<=request_sync[1];d_state<=0;end
    default:d_state<=0;
   endcase
  end
 end
endmodule
`default_nettype wire
