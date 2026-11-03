`timescale 1ns/1ps
`default_nettype none
// Private page 0x0500. C owns the EXISTING camera I2C bridge on page 0x0300.
// Configuration survives a CPU-only restart; cold video reset clears it.
module camera_light_cpu_apb(
 input wire clk,rst_n,stats_valid,input wire[34:0] stats,
 input wire sensor_sof_toggle,gain_busy,
 input wire[15:0] PADDR,input wire PSEL,PENABLE,PWRITE,input wire[31:0] PWDATA,
 output reg[31:0] PRDATA,output wire PREADY,PSLVERROR,
 output reg[9:0] gain_r,gain_b,output reg gains_send);
 reg[34:0] latest;
 reg[15:0] frame_seq;
 reg[11:0] exposure,staged_exposure;
 reg[19:0] staged_gains;
 reg[1:0] mode;
 reg[5:0] runtime_status;
 reg[31:0] snap_flags,snap_settings,snap_stats;
 (* async_reg="true" *) reg[1:0] sof_sync;
 reg sof_seen;reg[15:0] sof_count;
 wire access=PSEL&&PENABLE;
 wire known=PADDR>=16'h0500&&PADDR<=16'h0524&&PADDR[1:0]==0;
 assign PREADY=!(access&&PWRITE&&PADDR==16'h0504&&gain_busy);
 assign PSLVERROR=access&&!known;
 always @*begin
  PRDATA=0;
  case(PADDR)
   16'h0500:PRDATA=32'h414c0002;
   16'h0504:PRDATA={29'd0,gain_busy,mode};
   16'h0508:PRDATA={20'd0,staged_exposure};
   16'h050c:PRDATA={12'd0,staged_gains};
   16'h0510:PRDATA={frame_seq,5'd0,latest[6],latest[1:0],runtime_status[5:3],runtime_status[2:0],mode};
   16'h0514:PRDATA=snap_settings;
   16'h0518:PRDATA=snap_stats;
   16'h051c:PRDATA=snap_flags;
   16'h0520:PRDATA={26'd0,runtime_status};
   16'h0524:PRDATA={16'd0,sof_count};
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   latest<=0;frame_seq<=0;exposure<=2200;staged_exposure<=2200;
   staged_gains<={10'd512,10'd320};gain_r<=512;gain_b<=320;mode<=3;
   runtime_status<=0;snap_flags<=0;snap_settings<=0;snap_stats<=0;
   sof_sync<=0;sof_seen<=0;sof_count<=0;gains_send<=0;
  end else begin
   gains_send<=0;sof_sync<={sof_sync[0],sensor_sof_toggle};
   if(sof_sync[1]!=sof_seen)begin sof_seen<=sof_sync[1];sof_count<=sof_count+1'b1;end
   if(stats_valid)begin latest<=stats;frame_seq<=frame_seq+1'b1;end
   if(access&&PREADY)begin
    if(!PWRITE&&PADDR==16'h0510)begin
     snap_flags<=PRDATA;snap_settings<={exposure,gain_r,gain_b};
     snap_stats<={latest[34:27],latest[26:17],latest[16:7],latest[5:4],latest[3:2]};
    end
    if(PWRITE)case(PADDR)
     16'h0508:staged_exposure<=PWDATA[11:0];
     16'h050c:staged_gains<=PWDATA[19:0];
     16'h0504:begin
      exposure<=staged_exposure;mode<=PWDATA[1:0];
      gain_r<={staged_gains[19:13],3'd0};gain_b<={staged_gains[9:3],3'd0};
      gains_send<=1;
     end
     16'h0520:runtime_status<=PWDATA[5:0];
    endcase
   end
  end
 end
endmodule
`default_nettype wire
