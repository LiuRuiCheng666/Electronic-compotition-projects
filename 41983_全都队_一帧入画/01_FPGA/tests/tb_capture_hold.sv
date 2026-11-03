`timescale 1ns/1ps
module tb;
 reg pc=0,kc=0;always #7 pc=~pc;always #3.125 kc=~kc;
 reg rst=0,hold=1;wire ack,idle;
 reg[31:0]pixel=0,id=0;reg iv=0,sof=0,done=0,abortframe=0;
 wire[31:0]aw,ar;wire[7:0]awl,arl;wire av,wv,wl,br,arv,rr;
 wire[127:0]wd;reg[127:0]rd;
 reg allowb=1,bpending=0,rpending=0;integer wi=0,ri=0,writes=0;
 wire bv=bpending&&allowb,rv=rpending,rlast=ri==15;
 reg[127:0]mem[0:15];
 wire[1:0]slots;wire[31:0]commits,aborts,words,responses,skipped;
 wire[7:0]error;wire busy;
 rgbx_ddr_capture #(.ENABLE_HOLD(1),.LOCAL_PIXEL_RESET(1),.CONTROL_PIPELINE(1),
  .FRAME_PIXELS(64),.NUM_SLOTS(2),.BURST_WORDS(16),.FIFO_ADDR_WIDTH(6)) dut(
  .pixel_clk(pc),.axi_clk(kc),.rst_n(rst),.pixel_rst_n(rst),.cal_done(1'b1),
  .hold(hold),.hold_ack(ack),.capture_idle(idle),
  .i_rgbx(pixel),.i_valid(iv),.i_sof(sof),.i_frame_id(id),.i_frame_done(done),.i_frame_abort(abortframe),
  .release_slots(2'b11),.awaddr(aw),.awlen(awl),.awvalid(av),.awready(1'b1),
  .wdata(wd),.wlast(wl),.wvalid(wv),.wready(1'b1),.bid(4'd0),.bresp(2'd0),.bvalid(bv),.bready(br),
  .araddr(ar),.arlen(arl),.arvalid(arv),.arready(1'b1),.rid(4'd0),.rdata(rd),.rresp(2'd0),
  .rlast(rlast),.rvalid(rv),.rready(rr),.slot_valid(slots),.slot0_frame_id(),.slot1_frame_id(),.slot2_frame_id(),.slot3_frame_id(),
  .commit_count(commits),.commit_pulse(),.committed_addr(),.word_count(words),.response_count(responses),
  .abort_count(aborts),.error(error),.busy(busy),.skipped_frames(skipped));
 always @*rd=mem[ri];
 always @(posedge kc)if(rst)begin
  if(av)begin if(awl!=15||aw!=32'h02000000)$fatal(1,"capture AW");wi<=0;end
  if(wv)begin
   if(wl!==(wi==15))$fatal(1,"WLAST");mem[wi]<=wd;wi<=wi+1;writes<=writes+1;
   if(wl)bpending<=1;
  end
  if(bv&&br)bpending<=0;
  if(arv)begin if(arl!=15||ar!=32'h02000000)$fatal(1,"verify AR");ri<=0;rpending<=1;end
  if(rv&&rr)begin if(rlast)rpending<=0;else ri<=ri+1;end
  if(ack&&idle&&(av||wv||arv||bpending||rpending))$fatal(1,"false drained fence");
 end
 task frame(input integer frameid,input integer pixels,input bit hold_mid,input bit bad);
  begin
   for(integer i=0;i<pixels;i=i+1)begin
    @(negedge pc);id=frameid;pixel=32'h10000000+i;iv=1;sof=i==0;
    if(hold_mid&&i==8)hold=1;
   end
   @(negedge pc);iv=0;sof=0;done=!bad;abortframe=bad;
   @(negedge pc);done=0;abortframe=0;
  end
 endtask
 task fence_wait;
  integer n;begin n=0;while(!(ack&&idle))begin @(negedge kc);n=n+1;if(n>2000)$fatal(1,"capture drain watchdog");end end
 endtask
 initial begin
  repeat(10)@(negedge pc);rst=1;repeat(25)@(negedge pc);fence_wait();
  frame(1,64,0,0);repeat(30)@(negedge pc);
  if(commits||writes||aborts||!ack||!idle)$fatal(1,"initial hold admitted frame");
  hold=0;repeat(25)@(negedge pc);allowb=0;
  frame(2,64,1,0);wait(bpending);wait(ack);
  repeat(30)begin @(negedge kc);if(idle||!br||!ack)$fatal(1,"hold withdrew pending B");end
  if(commits||words!=16)$fatal(1,"active frame dropped/premature commit");
  allowb=1;fence_wait();if(commits!=1||aborts||error||responses!=1)$fatal(1,"frame did not finish cleanly");
  for(integer i=0;i<64;i=i+1)
   if(mem[i/4][(i%4)*32+:32]!==32'h10000000+i)$fatal(1,"frame pixels changed by hold");
  frame(3,64,0,0);repeat(30)@(negedge pc);
  if(commits!=1||writes!=16||!ack||!idle)$fatal(1,"hold accepted next frame");
  hold=0;repeat(25)@(negedge pc);frame(4,64,0,0);
  repeat(120)@(negedge pc);if(commits!=2||writes!=32||error)$fatal(1,"resume did not recover");
  repeat(25)@(negedge pc);frame(5,16,1,1);fence_wait();
  if(aborts!=1||commits!=2||writes!=32)$fatal(1,"aborted short frame did not drain");
  $display("PASS: actual capture AXI/FIFO with independent clocks, initial/mid-frame hold, stalled B drain, full-frame bytes, blocked SOF, resume, abort drain");$finish;
 end
 initial begin #1000000;$fatal(1,"watchdog");end
endmodule
