`timescale 1ns/1ps
module tb;
reg clk=0,rst=0,start=0;always #5 clk=~clk;
reg [2:0] model=0;
wire busy,ready,failed,we,kind;wire[2:0]active;wire[7:0]idx;wire[63:0]data;
wire[31:0]addr;wire av,rr;reg rv=0;reg[127:0]memdata=0;
integer coeff=0,lut=0,reads=0,i;
a4_model_parameters #(.MODEL_COUNT(5)) dut(.clk(clk),.rst_n(rst),.start(start),.model(model),
.busy(busy),.ready(ready),.failed(failed),.active_model(active),.cfg_we(we),.cfg_tanh(kind),.cfg_index(idx),.cfg_data(data),
.araddr(addr),.arvalid(av),.arready(1'b1),.rdata(memdata),.rresp(2'b0),.rlast(1'b1),.rvalid(rv),.rready(rr));
always @(posedge clk)begin
 rv<=av;
 if(av)begin
  if(addr < 32'h01800000+model*4096+2048 || addr >= 32'h01800000+model*4096+2816)$fatal(1,"slot address alias %h model %d",addr,model);
  memdata<={4{addr}};reads=reads+1;
 end
 if(we)begin if(kind)lut=lut+1;else coeff=coeff+1;end
end
// APB command/readback: legacy 0..3 positions remain unchanged, bit12 selects slot4.
reg[15:0]pa=0;reg ps=0,pe=0,pw=0;reg[31:0]wd=0;wire[31:0]rd;wire pr;
wire[12:0]config_bits;reg[2:0]active_id=4,request_id=4;
c_nn_snapshot_apb #(.SAME_CLOCK(1),.ENABLE_ROI(1)) ctl(.src_clk(clk),.dst_clk(clk),.arst(!rst),
.deployment_started(1'b0),.status(10'd3),.boot_fault(3'd0),.compute_fault(3'd0),
.active_model(active_id),.requested_model(request_id),.display_model_id(3'd4),.display_shown(1'b0),.snapshot_lock(1'b0),
.input_base(32'd0),.output_base(32'd0),.display_frame_id(32'd0),.nn_start(1'b0),.nn_done(1'b0),.nn_pass(1'b0),.nn_fail(1'b0),
.diagnostic_state(32'd0),.diagnostic_axi(32'd0),.input_request_valid(1'b0),.scheduler_req_ready(1'b0),.scheduler_idle(1'b1),.input_frame_id(32'd0),
.platform_config(config_bits),.PADDR(pa),.PSEL(ps),.PENABLE(pe),.PWRITE(pw),.PWDATA(wd),.PRDATA(rd),.PREADY(pr));
task access(input bit wr,input[15:0]a,input[31:0]d,output[31:0]q);integer ticks;begin
 @(negedge clk);pa=a;ps=1;pw=wr;pe=0;wd=d;
 @(negedge clk);pe=1;#1;ticks=0;
 while(!pr)begin @(negedge clk);#1;ticks=ticks+1;if(ticks>50)$fatal(1,"APB timeout");end
 q=rd;@(negedge clk);pe=0;ps=0;pw=0;repeat(3)@(negedge clk);
end endtask
reg[255:0]dq=0;reg dv=0;wire dr,dout,lc;wire[2:0]ls;wire[255:0]reply;
net_image_dispatch dispatch(.clk(clk),.root_reset_n(rst),.cpu_quarantine(1'b0),.request_valid(dv),.request_ready(dr),.request(dq),
.response_valid(dout),.response_ready(1'b1),.response(reply),.lease_command_valid(lc),.lease_command_style(ls),
.lease_ack(1'b1),.lease_status(8'd0),.generation(32'd0),.phase(4'd2),.memory_allowed(1'b0),.memory_write_allowed(1'b0),.terminal_status(8'd0),
.dma_ready(1'b0),.dma_response_valid(1'b0),.dma_error(4'd0),.dma_response_data(128'd0));
task mailbox(input[31:0]slot,input bit good);begin
 wait(dr);@(negedge clk);dq=0;dq[31:0]=1;dq[95:64]=slot;dv=1;
 @(negedge clk);dv=0;
 if(good)begin if(!lc||ls!=4)$fatal(1,"mailbox style4 truncated");end
 wait(dout);#1;if(reply[31:0]!=(good?0:3))$fatal(1,"mailbox invalid style accepted");
 @(negedge clk);repeat(3)@(negedge clk);
end endtask
reg[31:0]q;
initial begin
 #1;rst=0;repeat(5)@(negedge clk);rst=1;repeat(8)@(negedge clk);
 for(i=0;i<5;i=i+1)begin
  model=i;coeff=0;lut=0;reads=0;start=1;@(negedge clk);start=0;
  wait(busy);wait(ready);@(negedge clk);
  if(failed||active!=i||coeff!=40||lut!=256||reads!=36)$fatal(1,"metadata %d %d %d %d",i,coeff,lut,reads);
 end
 model=5;start=1;@(negedge clk);start=0;repeat(4)@(negedge clk);
 if(!failed||ready)$fatal(1,"invalid model accepted");
 access(1,16'h204,32'h104207,q); // cfg=0x1042: override style4, UI enabled
 if(config_bits!=13'h1042)$fatal(1,"slot4 config lost %h",config_bits);
 access(0,16'h208,0,q);access(0,16'h21c,0,q);if(q!=32'h1042)$fatal(1,"snapshot config %h",q);
 access(0,16'h110,0,q);if(q!=32'h30)$fatal(1,"slot4 diagnostic bits %h",q);
 access(1,16'h204,32'h104607,q);access(0,16'h20c,0,q);if(q!=6||config_bits!=13'h1042)$fatal(1,"invalid style5 accepted");
 access(1,16'h204,32'h004e07,q);if(config_bits!=13'h4e)$fatal(1,"legacy style3 config changed");
 active_id=3;request_id=2;access(0,16'h208,0,q);access(0,16'h110,0,q);if(q!=11)$fatal(1,"legacy model bits changed %h",q);
 mailbox(4,1);mailbox(5,0);mailbox(8,0);
 $display("PASS: mailbox style4 and invalid-style checks; five metadata slots, address isolation, model5 rejection, style4 APB and legacy register compatibility");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
