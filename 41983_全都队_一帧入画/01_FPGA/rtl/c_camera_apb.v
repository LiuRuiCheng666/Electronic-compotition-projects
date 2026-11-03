// CPU APB100 -> camera Wishbone5MHz. Held payload/response toggle handshake.
// Bus timeouts poison this bridge until reset; CPU can still read diagnostic ID/status.
module c_camera_apb(input wire cpu_clk,cam_clk,arst,
 input wire[15:0]PADDR,input wire PSEL,PENABLE,PWRITE,input wire[31:0]PWDATA,
 output reg[31:0]PRDATA,output wire PREADY,PSLVERROR,
 output wire[2:0]wb_addr,output wire[7:0]wb_wdata,output wire wb_write,wb_stb,
 input wire[7:0]wb_rdata,input wire wb_ack);
 (* async_reg="true",syn_preserve=1 *)reg[1:0] cr=3,pr=3;
 always @(posedge cpu_clk or posedge arst)if(arst)cr<=3;else cr<={cr[0],1'b0};
 always @(posedge cam_clk or posedge arst)if(arst)pr<=3;else pr<={pr[0],1'b0};
 reg request,ack;reg[11:0]payload,cmd;reg[8:0]response,result;
 (* async_reg="true",syn_preserve=1 *)reg[1:0]rq_sync,ack_sync;
 reg[1:0]cs,ps;reg[15:0]timeout;reg[7:0]ptimer;reg poisoned,error;
 wire access=PSEL&&PENABLE;
 wire bus_addr=PADDR[7:5]==0 && PADDR[4:2]<=4 && PADDR[1:0]==0;
 wire diagnostic=!PWRITE&&(PADDR==16'h0340||PADDR==16'h0344);
 assign PREADY=!bus_addr||poisoned||cs==2;
 assign PSLVERROR=access&&!bus_addr&&!diagnostic;
 assign wb_stb=ps==2;assign wb_write=cmd[11];assign wb_addr=cmd[10:8];assign wb_wdata=cmd[7:0];
 always @*begin
  PRDATA={23'd0,poisoned?9'h100:result};
  if(PADDR==16'h0340)PRDATA=32'h43493201;
  if(PADDR==16'h0344)PRDATA={29'd0,poisoned,error,cs==1};
 end
 always @(posedge cpu_clk or posedge cr[1])begin
  if(cr[1])begin request<=0;payload<=0;ack_sync<=0;cs<=0;timeout<=0;poisoned<=0;error<=0;result<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};
   case(cs)
    0:if(access&&bus_addr&&!poisoned)begin payload<={PWRITE,PADDR[4:2],PWDATA[7:0]};request<=~request;timeout<=0;cs<=1;end
    1:if(ack_sync[1]==request)begin result<=response;error<=error||response[8];cs<=2;end
      else if(&timeout)begin poisoned<=1;error<=1;result<=9'h100;cs<=2;end
      else timeout<=timeout+1'b1;
    2:if(access)cs<=0;
   endcase
  end
 end
 always @(posedge cam_clk or posedge pr[1])begin
  if(pr[1])begin rq_sync<=0;ack<=0;cmd<=0;response<=0;ps<=0;ptimer<=0;end
  else begin
   rq_sync<={rq_sync[0],request};
   case(ps)
    0:if(rq_sync[1]!=ack)begin cmd<=payload;ps<=1;end
    1:begin ps<=2;ptimer<=0;end
    2:if(wb_ack)begin response<={1'b0,wb_rdata};ack<=rq_sync[1];ps<=0;end
      else if(&ptimer)begin response<=9'h100;ack<=rq_sync[1];ps<=0;end
      else ptimer<=ptimer+1'b1;
   endcase
  end
 end
endmodule
