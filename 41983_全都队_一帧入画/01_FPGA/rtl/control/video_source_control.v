`timescale 1ns/1ps
`default_nettype none
// SW3 short press selects input. SW2 style and SW0 global reset are independent.
module video_source_control #(parameter DEBOUNCE_CYCLES=1000000)(
 input wire clk,rst_n,button_n,active_source,input wire [31:0] source_frame_id,
 input wire [15:0] PADDR,input wire PSEL,PENABLE,PWRITE,input wire [31:0] PWDATA,
 output reg [31:0] PRDATA,output wire PREADY,PSLVERROR,requested_source
);
 wire local_reset_n;
 hdmi_reset_release u_release(.clk(clk),.rst_n(rst_n),.released_n(local_reset_n));
 (* async_reg="true" *)reg [1:0] button_sync,active_sync;
 reg stable,button_source,override_enable,override_source;reg [19:0] debounce;
 assign requested_source=override_enable?override_source:button_source;
 assign PREADY=1;
 assign PSLVERROR=PSEL&&PENABLE&&(PADDR<16'h0700||PADDR>16'h070c||PADDR[1:0]!=0||(PWRITE&&PADDR!=16'h0708));
 always @*begin
  PRDATA=0;
  case(PADDR)
   16'h0700:PRDATA=32'h53524301;
   16'h0704:PRDATA={28'd0,override_enable,(requested_source!=active_sync[1]),requested_source,active_sync[1]};
   16'h0708:PRDATA={30'd0,override_source,override_enable};
   16'h070c:PRDATA=source_frame_id;
  endcase
 end
 always @(posedge clk or negedge local_reset_n)begin
  if(!local_reset_n)begin button_sync<=3;active_sync<=0;stable<=1;button_source<=0;override_enable<=0;override_source<=0;debounce<=0;end
  else begin
   button_sync<={button_sync[0],button_n};active_sync<={active_sync[0],active_source};
   if(button_sync[1]==stable)debounce<=0;
   else if(debounce==DEBOUNCE_CYCLES-1)begin stable<=button_sync[1];debounce<=0;if(!button_sync[1])button_source<=~button_source;end
   else debounce<=debounce+1'b1;
   if(PSEL&&PENABLE&&PWRITE&&PADDR==16'h0708)begin override_enable<=PWDATA[0];override_source<=PWDATA[1];end
  end
 end
endmodule
`default_nettype wire
