// Read-only two-domain diagnostic snapshots. Each held payload remains stable
// until the next request. A blocking sequence read waits for BOTH ACKs.
// CPU then reads those frozen source banks directly: no redundant CPU shadow.
// Payload is invalid while busy/poisoned; reads are single-master APB accesses.
// A stopped source clock times out and poisons this bridge until reset.
module video_diag_apb #(parameter integer TIMEOUT_BITS=20)(
 input wire cpu_clk,core_clk,pixel_clk,arst,
 input wire [255:0] core_data,input wire [159:0] pixel_data,
 input wire [15:0] PADDR,input wire PSEL,PENABLE,PWRITE,
 output reg [31:0] PRDATA,output wire PREADY,PSLVERROR);
 (* async_reg="true",syn_preserve=1 *)reg [1:0] cpu_reset=3,core_reset=3,pixel_reset=3;
 always @(posedge cpu_clk or posedge arst)if(arst)cpu_reset<=3;else cpu_reset<={cpu_reset[0],1'b0};
 always @(posedge core_clk or posedge arst)if(arst)core_reset<=3;else core_reset<={core_reset[0],1'b0};
 always @(posedge pixel_clk or posedge arst)if(arst)pixel_reset<=3;else pixel_reset<={pixel_reset[0],1'b0};
 reg request,core_ack,pixel_ack;
 (* async_reg="true",syn_preserve=1 *)reg[1:0]core_req_sync,pixel_req_sync,core_ack_sync,pixel_ack_sync;
 reg[255:0]core_held;reg[159:0]pixel_held;
 wire[255:0]core_snapshot=core_held;
 wire[159:0]pixel_snapshot=pixel_held;
 reg[1:0]state;reg[TIMEOUT_BITS-1:0]timeout;
 reg valid,poisoned;reg[31:0]sequence_id;
 always @(posedge core_clk or posedge core_reset[1])begin
  if(core_reset[1])begin core_req_sync<=0;core_ack<=0;core_held<=0;end
  else begin
   core_req_sync<={core_req_sync[0],request};
   if(core_req_sync[1]!=core_ack)begin core_held<=core_data;core_ack<=core_req_sync[1];end
  end
 end
 always @(posedge pixel_clk or posedge pixel_reset[1])begin
  if(pixel_reset[1])begin pixel_req_sync<=0;pixel_ack<=0;pixel_held<=0;end
  else begin
   pixel_req_sync<={pixel_req_sync[0],request};
   if(pixel_req_sync[1]!=pixel_ack)begin pixel_held<=pixel_data;pixel_ack<=pixel_req_sync[1];end
  end
 end
 wire access=PSEL&&PENABLE;
 wire trigger=access&&!PWRITE&&PADDR==16'h0408;
 always @(posedge cpu_clk or posedge cpu_reset[1])begin
  if(cpu_reset[1])begin
   request<=0;core_ack_sync<=0;pixel_ack_sync<=0;state<=0;timeout<=0;
   valid<=0;poisoned<=0;sequence_id<=0;
  end else begin
   core_ack_sync<={core_ack_sync[0],core_ack};pixel_ack_sync<={pixel_ack_sync[0],pixel_ack};
   case(state)
    0:if(trigger)begin
     if(poisoned)state<=2;
     else begin request<=~request;timeout<=0;state<=1;end
    end
    1:if(core_ack_sync[1]==request&&pixel_ack_sync[1]==request)begin
     sequence_id<=sequence_id+1'b1;valid<=1;state<=2;
    end else if(&timeout)begin poisoned<=1;valid<=0;state<=2;end
      else timeout<=timeout+1'b1;
    2:if(access)state<=0;
    default:state<=0;
   endcase
  end
 end
 assign PREADY=(PADDR==16'h0408&&!PWRITE)?state==2:1'b1;
 reg valid_address;
 assign PSLVERROR=access&&(PWRITE||!valid_address);
 always @*begin
  PRDATA=0;valid_address=1;
  case(PADDR)
   16'h0400:PRDATA=32'h56494401;
   16'h0404:PRDATA={29'd0,poisoned,valid,state==1};
   16'h0408:PRDATA=sequence_id;
   16'h040c:PRDATA=core_snapshot[31:0];
   16'h0410:PRDATA=core_snapshot[63:32];
   16'h0414:PRDATA=core_snapshot[95:64];
   16'h0418:PRDATA=core_snapshot[127:96];
   16'h041c:PRDATA=core_snapshot[159:128];
   16'h0420:PRDATA=core_snapshot[191:160];
   16'h0424:PRDATA=core_snapshot[223:192];
   16'h0428:PRDATA=core_snapshot[255:224];
   16'h042c:PRDATA=pixel_snapshot[31:0];
   16'h0430:PRDATA=pixel_snapshot[63:32];
   16'h0434:PRDATA=pixel_snapshot[95:64];
   16'h0438:PRDATA=pixel_snapshot[127:96];
   16'h043c:PRDATA=pixel_snapshot[159:128];
   default:valid_address=0;
  endcase
 end
endmodule
