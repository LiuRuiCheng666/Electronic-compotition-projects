`timescale 1ns/1ps
`default_nettype none
// Fixed pixel clock, frame-boundary selection. Input clocks are never muxed.
// Existing NN/display loans drain normally; global IDs remain monotonic.
module video_frame_mux #(parameter TIMEOUT_CYCLES=14850000)(
 input wire clk,rst_n,requested_source,
 input wire [31:0] cam_rgbx,hdmi_rgbx,
 input wire cam_valid,cam_sof,cam_done,cam_abort,hdmi_valid,hdmi_sof,hdmi_done,hdmi_abort,
 output reg active_source,output reg [31:0] rgbx,frame_id,
 output reg valid,sof,frame_done,frame_abort,output reg [31:0] switch_count
);
 (* async_reg="true" *)reg [1:0] request_sync;
 reg in_frame;reg [23:0] idle_cycles;
 wire iv=active_source?hdmi_valid:cam_valid,isof=active_source?hdmi_sof:cam_sof;
 wire idone=active_source?hdmi_done:cam_done,iabort=active_source?hdmi_abort:cam_abort;
 wire [31:0] data=active_source?hdmi_rgbx:cam_rgbx;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin request_sync<=0;active_source<=0;in_frame<=0;idle_cycles<=0;rgbx<=0;frame_id<=0;valid<=0;sof<=0;frame_done<=0;frame_abort<=0;switch_count<=0;end
  else begin
   request_sync<={request_sync[0],requested_source};valid<=0;sof<=0;frame_done<=0;frame_abort<=0;
   if(iv||idone||iabort||!in_frame)idle_cycles<=0;else if(idle_cycles<TIMEOUT_CYCLES)idle_cycles<=idle_cycles+1'b1;
   if(!in_frame)begin
    if(request_sync[1]!=active_source)begin active_source<=request_sync[1];switch_count<=switch_count+1'b1;end
    else if(iv&&isof)begin in_frame<=1;frame_id<=frame_id+1'b1;rgbx<=data;valid<=1;sof<=1;end
   end else if(iabort||(request_sync[1]!=active_source&&idle_cycles==TIMEOUT_CYCLES)||isof)begin
    in_frame<=0;frame_abort<=1;
   end else if(idone)begin in_frame<=0;frame_done<=1;end
   else if(iv)begin rgbx<=data;valid<=1;end
  end
 end
endmodule
`default_nettype wire
