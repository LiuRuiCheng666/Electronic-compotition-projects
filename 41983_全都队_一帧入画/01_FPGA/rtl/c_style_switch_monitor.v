`timescale 1ns/1ps
`default_nettype none
// Source-clock measurement. End event is the LAST visible image pixel via
// frame_shown CDC, not the command ACK or just frame-buffer publication.
module c_style_switch_monitor #(
    parameter integer CORE_HZ=100000000,
    parameter integer TIMEOUT_CYCLES=CORE_HZ/2
)(
    input wire clk,rst,enabled,video_fault,
    input wire [2:0] requested_model,display_model,
    input wire [31:0] display_frame,
    input wire display_shown,
    output reg [31:0] elapsed_cycles,request_frame,shown_frame,
    output wire [31:0] flags
);
    reg armed,pending,valid,superseded,timedout,faulted;
    reg [2:0] previous_request,target;
    reg [31:0] timer;
    wire within_limit=valid && !superseded && !faulted && !timedout && elapsed_cycles<CORE_HZ/10;
    assign flags={21'd0,target[2],target[1:0],2'd0,within_limit,faulted,timedout,superseded,pending,valid};
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            armed<=0;pending<=0;valid<=0;superseded<=0;timedout<=0;faulted<=0;
            previous_request<=0;target<=0;timer<=0;elapsed_cycles<=0;request_frame<=0;shown_frame<=0;
        end else if(video_fault)begin
            armed<=0;pending<=0;valid<=0;faulted<=1;
        end else if(!armed)begin
            // Gate initial arming on readiness, not subsequent requests. The
            // weight mux drops ready during an ordinary model metadata reload;
            // disarming then loses the very request whose latency we measure.
            // Actual video faults still invalidate and disarm above.
            if(enabled)begin
                armed<=1;previous_request<=requested_model;
            end
        end else if(requested_model!=previous_request)begin
            previous_request<=requested_model;target<=requested_model;
            superseded<=pending;timedout<=0;faulted<=0;
            pending<=1;valid<=0;timer<=0;elapsed_cycles<=0;
            request_frame<=display_frame;shown_frame<=0;
        end else if(pending)begin
            if(display_shown && display_model==target && display_frame!=request_frame)begin
                elapsed_cycles<=timer+1'b1;shown_frame<=display_frame;
                pending<=0;valid<=1;
            end else if(timer>=TIMEOUT_CYCLES-1)begin
                elapsed_cycles<=TIMEOUT_CYCLES;timedout<=1;pending<=0;valid<=0;
            end else timer<=timer+1'b1;
        end
    end
endmodule
`default_nettype wire
