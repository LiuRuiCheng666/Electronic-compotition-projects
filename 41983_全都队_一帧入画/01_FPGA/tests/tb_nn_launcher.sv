`timescale 1ns/1ps
module tb;
 reg clk=0;always #3.125 clk=~clk;
 reg rst=0,owner=0,req=0,wr=0,wf=0,busy=0,done=0,pass=1,fail=0,quiet=1;
 reg[2:0]fault=0;wire ready,resetn,start,jdone,drained,error;wire[2:0]state;
 integer starts=0;
 net_image_nn_launcher #(.RESET_CYCLES(3),.RELEASE_CYCLES(2)) dut(
  .clk(clk),.root_reset_n(rst),.owner(owner),.request_valid(req),.request_ready(ready),
  .weights_ready(wr),.weights_failed(wf),.core_busy(busy),.core_done(done),.core_pass(pass),.core_fail(fail),
  .core_fault(fault),.memory_quiet(quiet),.local_reset_n(resetn),.core_start(start),
  .job_done(jdone),.job_drained(drained),.job_error(error),.debug_state(state));
 always @(posedge clk)if(rst&&start)starts<=starts+1;
 task wait_state(input[2:0]wanted);
  integer n;begin n=0;while(state!=wanted)begin @(negedge clk);n=n+1;if(n>100)$fatal(1,"state watchdog");end end
 endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;owner=1;req=1;busy=1;quiet=0;
  repeat(8)begin @(negedge clk);if(!resetn||ready||start||state!=0)$fatal(1,"reset interrupted old core/DDR");end
  busy=0;quiet=1;done=1;wait_state(1);
  wait_state(3);wr=1;
  repeat(8)begin @(negedge clk);if(ready||start)$fatal(1,"stale DONE accepted as fresh core");end
  done=0;wait(ready);@(negedge clk);req=0;busy=1;
  repeat(5)begin @(negedge clk);if(!resetn||jdone)$fatal(1,"active core reset/completed early");end
  wr=0;wf=1;done=1;
  repeat(5)begin @(negedge clk);if(jdone||!resetn)$fatal(1,"busy core retired/reset");end
  busy=0;quiet=0;
  repeat(5)begin @(negedge clk);if(jdone||drained)$fatal(1,"DDR outstanding ignored");end
  quiet=1;wait_state(5);if(!jdone||!drained||error||starts!=1)$fatal(1,"successful task result");
  owner=0;wait_state(0);done=0;
  // Metadata failure completes the accepted job as failed, without starting NN.
  owner=1;req=1;wait_state(3);wait(ready);@(negedge clk);req=0;
  wait_state(5);if(!error||!drained||starts!=1)$fatal(1,"metadata failure started compute");
  owner=0;wait_state(0);wf=0;wr=1;
  owner=1;req=1;wait_state(3);wait(ready);@(negedge clk);req=0;busy=1;
  repeat(3)@(negedge clk);fail=1;fault=3;done=1;busy=0;quiet=0;
  repeat(8)begin @(negedge clk);if(jdone||!resetn)$fatal(1,"fault bypassed actual drain");end
  quiet=1;wait_state(5);if(!error||!drained||starts!=2)$fatal(1,"compute failure result");
  owner=0;wait_state(0);
  $display("PASS: NN launcher old-core drain, stale DONE rejection, metadata failure without compute, active reset isolation, error completion after DDR drain");$finish;
 end
 initial begin #100000;$fatal(1,"watchdog");end
endmodule
