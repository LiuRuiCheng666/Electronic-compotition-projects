`timescale 1ns/1ps
`default_nettype none
// One elastic AXI address beat. All payload fields travel with VALID.
module axi_command_pipeline #(parameter WIDTH=40)(
 input wire clk,rst_n,input wire in_valid,output wire in_ready,
 input wire [WIDTH-1:0] in_payload,output reg out_valid,
 input wire out_ready,output reg [WIDTH-1:0] out_payload);
 assign in_ready=!out_valid || out_ready;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin out_valid<=0;out_payload<=0;end
  else if(in_ready)begin
   out_valid<=in_valid;
   if(in_valid)out_payload<=in_payload;
  end
 end
endmodule

// Registered capacity decouples DDR RREADY from consumer decode/arithmetic.
// Two register slots retain burst order, RRESP and RLAST. The head is a
// physical register, avoiding a block-RAM read on the consumer timing path.
module axi_read_response_pipeline(
 input wire clk,rst_n,input wire [127:0] in_data,input wire [1:0] in_resp,
 input wire in_last,in_valid,output wire in_ready,
 output wire [127:0] out_data,output wire [1:0] out_resp,
 output wire out_last,out_valid,input wire out_ready);
 reg head_valid,tail_valid;
 reg [130:0] head_data,tail_data;
 wire push=in_valid && in_ready,pop=out_valid && out_ready;
 wire [130:0] input_data={in_last,in_resp,in_data};
 assign in_ready=!tail_valid;
 assign out_valid=head_valid;
 assign {out_last,out_resp,out_data}=head_data;
 // Payload registers need no reset: validity gates every observation.
 always @(posedge clk)begin
  if(pop && tail_valid)head_data<=tail_data;
  else if(push && (!head_valid || pop))head_data<=input_data;
  if(push && head_valid && !pop)tail_data<=input_data;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin head_valid<=0;tail_valid<=0;end
  else begin
   if(pop)begin head_valid<=tail_valid;tail_valid<=0;end
   if(push)begin
    if(!head_valid || pop)head_valid<=1;
    else tail_valid<=1;
   end
  end
 end
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n && tail_valid && !head_valid)$fatal(1,"AXI response tail without head");
`endif
endmodule
`default_nettype wire
