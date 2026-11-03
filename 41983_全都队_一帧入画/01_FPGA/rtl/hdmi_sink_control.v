`timescale 1ns/1ps
`default_nettype none
// Runs from the board oscillator-derived 100MHz clock, even with no HDMI source.
module hdmi_sink_control #(parameter HPD_WAIT=10000000,RETRY_WAIT=20000000,INIT_FILE="hdmi_720p_edid.hex")(
 input wire clk,rst_n,power_n,pll_locked,decoder_reset_n,
 input wire scl_i,sda_i,output wire scl_o,scl_oe,sda_o,sda_oe,
 output wire hpd_n,pll_reset_n,output wire present,
 output wire [31:0] edid_reads);
 (* async_reg="true" *)reg [1:0] power_sync,lock_sync,decoder_sync;
 reg [24:0] hpd_count,retry_count;
 reg [7:0] reset_count;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   power_sync<=3;lock_sync<=0;decoder_sync<=3;
   hpd_count<=0;retry_count<=0;reset_count<=255;
  end else begin
   power_sync<={power_sync[0],power_n};lock_sync<={lock_sync[0],pll_locked};
   decoder_sync<={decoder_sync[0],decoder_reset_n};
   if(!present)begin hpd_count<=0;retry_count<=0;reset_count<=255;end
   else begin
    if(hpd_count<HPD_WAIT)hpd_count<=hpd_count+1'b1;
    if(reset_count!=0)begin reset_count<=reset_count-1'b1;retry_count<=0;end
    else if(lock_sync[1]&&!decoder_sync[1])begin reset_count<=255;retry_count<=0;end
    else if(lock_sync[1]&&decoder_sync[1])retry_count<=0;
    else if(retry_count==RETRY_WAIT)begin reset_count<=255;retry_count<=0;end
    else retry_count<=retry_count+1'b1;
   end
  end
 end
 assign present=!power_sync[1];
 // The board's Q3 inverts FPGA HPD_N before the connector HPD pin.
 assign hpd_n=!rst_n||!present||hpd_count<HPD_WAIT;
 assign pll_reset_n=rst_n&&present&&reset_count==0;
 assign scl_o=0;assign scl_oe=0;assign sda_o=0;
 hdmi_ddc_edid #(.INIT_FILE(INIT_FILE)) u_edid(.clk(clk),.rst_n(rst_n),.scl_i(scl_i),.sda_i(sda_i),
  .sda_low(sda_oe),.read_count(edid_reads));
endmodule

module hdmi_rx_diag_apb #(parameter [15:0] BASE_ADDR=16'h0600)(
 input wire clk,rst_n,rx_clk,rx_reset_n,report_strobe,
 input wire [127:0] rx_report,input wire present,pll_locked,
 input wire [31:0] edid_reads,
 input wire [15:0] PADDR,input wire PSEL,PENABLE,PWRITE,
 output reg [31:0] PRDATA,output wire PREADY,PSLVERROR);
 wire busy,pulse;wire [127:0] received;
 reg [127:0] latest,snapshot;reg [31:0] sequence_id;
 (* async_reg="true" *)reg [1:0] lock_sync;
 video_snapshot_cdc #(.WIDTH(128)) u_snapshot(
  .src_clk(rx_clk),.dst_clk(clk),.rst_n(rx_reset_n),
  .send(report_strobe),.data(rx_report),.busy(busy),.pulse(pulse),.received(received));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin latest<=0;snapshot<=0;sequence_id<=0;lock_sync<=0;end
  else begin
   lock_sync<={lock_sync[0],pll_locked};
   if(pulse)begin latest<=received;sequence_id<=sequence_id+1'b1;end
   if(PSEL&&PENABLE&&!PWRITE&&PADDR==BASE_ADDR+16'h0008)snapshot<=latest;
  end
 end
 assign PREADY=1;
 assign PSLVERROR=PSEL&&PENABLE&&(PWRITE||PADDR<BASE_ADDR||PADDR>BASE_ADDR+16'h001c||PADDR[1:0]!=0);
 always @*begin
  PRDATA=0;
  case(PADDR-BASE_ADDR)
   16'h0000:PRDATA=32'h48444d01;
   16'h0004:PRDATA={30'd0,lock_sync[1],present};
   16'h0008:PRDATA=sequence_id;
   16'h000c:PRDATA=snapshot[31:0]; // height[31:16],width[15:0]
   16'h0010:PRDATA=snapshot[63:32]; // source frame ID
   16'h0014:PRDATA=snapshot[95:64]; // exact geometry frames
   16'h0018:PRDATA=snapshot[127:96];// rejected frames
   16'h001c:PRDATA=edid_reads;
  endcase
 end
endmodule
`default_nettype wire
