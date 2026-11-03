`timescale 1ns/1ps
// Three immutable output slots; compute and publication advance independently.
module camera_nn_scheduler #(
 parameter [31:0] OUTPUT0=32'h06400000,OUTPUT1=32'h06600000,OUTPUT2=32'h06800000
)(
 input wire clk,rst_n,enable,req_valid,
 output wire req_ready,input wire req_bank,input wire [31:0] req_addr,req_frame_id,
 output wire done_valid,input wire done_ready,output reg done_bank,
 output reg [31:0] done_frame_id,output reg done_error,
 output reg nn_start,nn_reset_n,input wire nn_done,nn_pass,nn_fail,display_fault,
 output reg [31:0] nn_input_base,output wire [31:0] nn_output_base,
 output reg display_enable,output wire [31:0] display_base,
 output reg [1:0] display_buffer,output reg [31:0] display_frame_id,
 input wire frame_shown,quiescent,output reg fault
);
 localparam IDLE=0,START=1,RUN=2,COMPLETE=3,RESET=4,STOP=5;
 reg [2:0] state;
 reg publish_state;
 reg [1:0] output_buffer,ready_buffer;
 reg [2:0] occupied;
 reg ready_valid,front_valid;
 reg [31:0] ready_frame_id;
 reg [4:0] reset_count;
 wire free_valid=!(&occupied);
 wire [1:0] free_buffer=!occupied[0]?0:!occupied[1]?1:2;
 assign req_ready=(state==IDLE) && enable && free_valid && !fault && !display_fault;
 assign done_valid=(state==COMPLETE) && (done_error || !ready_valid);
 assign nn_output_base=(output_buffer==0)?OUTPUT0:(output_buffer==1)?OUTPUT1:OUTPUT2;
 assign display_base=(display_buffer==0)?OUTPUT0:(display_buffer==1)?OUTPUT1:OUTPUT2;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;publish_state<=0;occupied<=0;
   ready_valid<=0;front_valid<=0;ready_buffer<=0;ready_frame_id<=0;
   done_bank<=0;done_frame_id<=0;done_error<=0;
   nn_start<=0;nn_reset_n<=1;nn_input_base<=0;output_buffer<=0;
   display_enable<=0;display_buffer<=0;display_frame_id<=0;reset_count<=0;fault<=0;
  end else if(!fault) begin
   nn_start<=0;
   case(state)
    IDLE:if(req_valid && req_ready) begin
     output_buffer<=free_buffer;occupied[free_buffer]<=1;
     nn_input_base<=req_addr;done_bank<=req_bank;done_frame_id<=req_frame_id;
     done_error<=0;state<=START;
    end
    START:begin nn_start<=1;state<=RUN;end
    RUN:if(nn_done || nn_fail) begin
     done_error<=!nn_pass || nn_fail || display_fault;state<=COMPLETE;
    end
    COMPLETE:if(done_valid && done_ready) begin
     if(done_error || display_fault) begin fault<=1;display_enable<=0;state<=STOP;end
     else begin
      ready_valid<=1;ready_buffer<=output_buffer;ready_frame_id<=done_frame_id;
      nn_reset_n<=0;reset_count<=0;state<=RESET;
     end
    end
    RESET:if(reset_count==15) begin nn_reset_n<=1;state<=IDLE;end
          else reset_count<=reset_count+1'b1;
    default:begin nn_start<=0;display_enable<=0;end
   endcase
   case(publish_state)
    0:if(ready_valid && (!front_valid || frame_shown)) begin
     display_enable<=0;publish_state<=1;
    end
    1:if(quiescent) begin
     if(front_valid) occupied[display_buffer]<=0;
     display_buffer<=ready_buffer;display_frame_id<=ready_frame_id;
     ready_valid<=0;front_valid<=1;display_enable<=1;publish_state<=0;
    end
   endcase
   if(display_fault || (state==COMPLETE && done_error && done_valid && done_ready)) begin
    fault<=1;display_enable<=0;nn_start<=0;state<=STOP;
   end
  end else begin nn_start<=0;display_enable<=0;end
 end
endmodule
