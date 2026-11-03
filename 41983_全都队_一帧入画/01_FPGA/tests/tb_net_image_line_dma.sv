`timescale 1ns/1ps
module tb;
 reg clk=0;always #3.125 clk=~clk;
 reg reset=0,lease=1,write_enabled=1;reg[31:0]generation=7,result_base=32'h06000000,result_bytes=2764800;
 reg cv=0,cw=0,cr=0;wire ready,busy,rv;
 reg[31:0]cg=7,off=0;reg[127:0]cd=0;reg[15:0]mask=16'hffff;
 reg rr=0;wire[3:0]error;wire[127:0]answer;wire[31:0]answer_gen;
 wire[31:0]aw,ar;wire[7:0]awl,arl;wire av,wv,wl,bready,arv,rready;
 wire[127:0]wd;wire[15:0]ws;
 reg awready=1,wready=1,arready=1,allow_r=1,allow_b=1;
 reg[1:0]read_error=0,write_error=0;reg[3:0]read_id=0,write_id=0;reg extra_read=0;
 reg aw_owned=0,r_pending=0,b_pending=0;reg[31:0]ra=0,wa=0;
 integer remain=0,ars=0,aws=0,writes=0,reads=0;
 wire rvalid=r_pending&&allow_r,bvalid=b_pending&&allow_b;
 wire rlast=remain==1;
 reg[7:0]mem[0:511];reg[127:0]rd;
 always @*begin
  rd=128'hffeeddccbbaa99887766554433221100;
  if(ra>=32'h07800000 && ra<32'h07800200)
   for(integer i=0;i<16;i=i+1)rd[i*8+:8]=mem[ra-32'h07800000+i];
 end
 net_image_line_dma #(.TIMEOUT_BITS(4)) dut(
  .clk(clk),.root_reset_n(reset),.lease_valid(lease),.lease_write_enabled(write_enabled),.lease_generation(generation),
  .result_base(result_base),.result_bytes(result_bytes),.cmd_valid(cv),.cmd_ready(ready),
  .cmd_write(cw),.cmd_result(cr),.cmd_generation(cg),.cmd_offset(off),.cmd_data(cd),.cmd_mask(mask),
  .busy(busy),.resp_valid(rv),.resp_ready(rr),.resp_error(error),.resp_data(answer),.resp_generation(answer_gen),
  .awaddr(aw),.awlen(awl),.awvalid(av),.awready(awready),.wdata(wd),.wstrb(ws),.wlast(wl),.wvalid(wv),.wready(wready),
  .bid(write_id),.bresp(write_error),.bvalid(bvalid),.bready(bready),
  .araddr(ar),.arlen(arl),.arvalid(arv),.arready(arready),.rid(read_id),.rdata(rd),.rresp(read_error),
  .rlast(rlast),.rvalid(rvalid),.rready(rready));
 always @(posedge clk)if(reset)begin
  if(av&&awready)begin
   if(aw_owned || awl!=0 || aw[3:0]!=0 || aw<32'h07800000 || aw>=32'h07c00000)$fatal(1,"illegal AXI write");
   wa<=aw;aw_owned<=1;aws<=aws+1;
  end
  if(wv&&wready)begin
   if(!aw_owned || ws!=16'hffff || !wl)$fatal(1,"partial write escaped RMW");
   for(integer i=0;i<16;i=i+1)mem[wa-32'h07800000+i]<=wd[i*8+:8];
   aw_owned<=0;b_pending<=1;writes<=writes+1;
  end
  if(bvalid&&bready)b_pending<=0;
  if(arv&&arready)begin
   if(r_pending || arl!=0 || ar[3:0]!=0)$fatal(1,"illegal AR");
   ra<=ar;r_pending<=1;remain<=extra_read?2:1;ars<=ars+1;
  end
  if(rvalid&&rready)begin
   if(remain==1)r_pending<=0;else remain<=remain-1;
   reads<=reads+1;
  end
 end
 task command(input bit write_cmd,input bit result_cmd,input[31:0]offset,input[127:0]data,input[15:0]byte_mask);
  begin
   @(negedge clk);while(!ready)@(negedge clk);
   cw=write_cmd;cr=result_cmd;off=offset;cd=data;mask=byte_mask;cv=1;
   @(negedge clk);cv=0;
  end
 endtask
 task response(input[3:0]expected_error,input bit check_data,input[127:0]expected_data);
  integer g;
  begin
   g=0;while(!rv)begin @(negedge clk);g=g+1;if(g>300)$fatal(1,"response watchdog");end
   if(error!==expected_error || answer_gen!==cg)$fatal(1,"response error/gen %h %h",error,answer_gen);
   if(check_data&&answer!==expected_data)$fatal(1,"data mismatch %h",answer);
   rr=1;@(negedge clk);rr=0;
  end
 endtask
 integer before_aw,before_ar;
 initial begin
  for(integer i=0;i<512;i=i+1)mem[i]=i;
  repeat(5)@(negedge clk);reset=1;
  command(1,0,0,128'h00112233445566778899aabbccddeeff,16'hffff);response(0,0,0);
  command(0,0,0,0,0);response(0,1,128'h00112233445566778899aabbccddeeff);
  command(1,0,0,128'hdeadbeefdeadbeef0123456789abcdef,16'h00ff);response(0,0,0);
  command(0,0,0,0,0);response(0,1,128'h00112233445566770123456789abcdef);
  before_aw=aws;before_ar=ars;
  command(1,0,0,0,0);response(0,0,0);
  command(0,0,1,0,0);response(1,0,0);
  command(0,0,32'h00400000,0,0);response(1,0,0);
  command(1,1,0,0,16'hffff);response(1,0,0);
  cg=8;command(0,0,0,0,0);response(4,0,0);cg=7;
  result_base=32'h02000000;command(0,1,0,0,0);response(1,0,0);result_base=32'h06000000;
  result_base=32'h07c00000;command(0,1,0,0,0);response(1,0,0);result_base=32'h06000000;
  write_enabled=0;command(1,0,0,0,16'hffff);response(1,0,0);write_enabled=1;
  if(aws!=before_aw||ars!=before_ar)$fatal(1,"denied/no-op command reached DDR");
  command(0,0,32'h003ffff0,0,0);response(0,0,0);
  command(0,1,32'd2764784,0,0);response(0,0,0);
  command(0,1,0,0,0);response(0,1,128'hffeeddccbbaa99887766554433221100);
  // Bad read responses cannot be used as the old half of an RMW write.
  read_error=2;before_aw=aws;command(1,0,0,0,16'hff00);response(2,0,0);read_error=0;
  if(aws!=before_aw)$fatal(1,"bad RMW read wrote DDR");
  extra_read=1;command(1,0,0,0,16'h00ff);response(2,0,0);extra_read=0;
  if(aws!=before_aw)$fatal(1,"malformed read burst wrote DDR");
  write_error=2;command(1,0,16,128'h1234,16'hffff);response(2,0,0);write_error=0;
  // Cancellation during stalled AW must hold VALID/address through timeout.
  awready=0;command(1,0,32,128'h5678,16'hffff);
  repeat(4)@(negedge clk);lease=0;
  repeat(40)begin @(negedge clk);if(!av||aw!=32'h07800020||rv||!busy)$fatal(1,"outstanding AW retracted");end
  awready=1;response(12,0,0);lease=1;
  // W also remains stable after AW acceptance until the slave accepts it.
  wready=0;command(1,0,48,128'h9abc,16'hffff);wait(wv);
  lease=0;repeat(40)begin @(negedge clk);if(!wv||wd!=128'h9abc||rv)$fatal(1,"stalled W changed/retracted");end
  wready=1;response(12,0,0);lease=1;
  // A generation change is cancellation even if the valid bit remains set.
  allow_b=0;command(1,0,64,128'hdef0,16'hffff);wait(bready);generation=8;
  repeat(5)@(negedge clk);allow_b=1;response(4,0,0);generation=7;
  // Accepted read drains despite timeout/lease cancellation; no early reply.
  allow_r=0;command(0,0,0,0,0);repeat(5)@(negedge clk);lease=0;
  repeat(40)begin @(negedge clk);if(!rready||rv||!busy)$fatal(1,"read released before RLAST");end
  allow_r=1;response(12,0,0);lease=1;
  // Response ownership is stable under downstream backpressure.
  command(0,0,0,0,0);wait(rv);repeat(25)begin
   @(negedge clk);if(ready||!rv||answer!=128'h00112233445566770123456789abcdef)$fatal(1,"response changed while held");
  end
  response(0,1,128'h00112233445566770123456789abcdef);
  $display("PASS: actual AXI single-beat/RMW, range and generation gates, result read-only window, error/burst rejection, timeout and lease-loss drain, held response");$finish;
 end
 initial begin #1000000;$fatal(1,"watchdog");end
endmodule
