`timescale 1ns/1ps
`default_nettype none
// Synchronous RAM payload store for an externally counted FIFO.
// Peek-next addressing and write forwarding preserve zero-bubble FWFT behavior.
module sync_fwft_payload #(parameter WIDTH=32,ADDR_WIDTH=4)(
 input wire clk,rst_n,push,pop,input wire [ADDR_WIDTH-1:0] head,tail,
 input wire [ADDR_WIDTH:0] count,input wire [WIDTH-1:0] push_data,
 output wire [WIDTH-1:0] head_data
);
 (* syn_ramstyle="block_ram" *)reg [WIDTH-1:0] mem[0:(1<<ADDR_WIDTH)-1];
 reg [WIDTH-1:0] ram_q,forward_data;reg forwarding;
 wire [ADDR_WIDTH-1:0] read_address=pop?(head+1'b1):head;
 always @(posedge clk)begin
  if(rst_n&&push)mem[tail]<=push_data;
  ram_q<=mem[read_address];
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin forwarding<=0;forward_data<=0;end
  else begin
   forwarding<=push&&(count==0||(pop&&count==1));
   if(push)forward_data<=push_data;
  end
 end
 assign head_data=forwarding?forward_data:ram_q;
endmodule
`default_nettype wire
