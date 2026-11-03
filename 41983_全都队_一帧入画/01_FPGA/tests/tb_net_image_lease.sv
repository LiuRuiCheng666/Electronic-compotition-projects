`timescale 1ns/1ps
module tb;
 reg clk=0;always #3.125 clk=~clk;
 reg reset=0,cv=0;reg[2:0]cmd=0;reg[31:0]cg=0;reg[1:0]cs=2;
 wire ack;wire[7:0]status,terminal;
 reg hold_ack=0,cap_idle=0,vid_idle=0,core_idle=1,mquiet=1,activity=1;
 wire hold_cap,pause_video,axi_owner,active,access_ok,write_ok,nn_owner,jv;
 reg jr=0,jdone=0,jdrain=1,jerror=0;
 wire[31:0]gen,released;wire[1:0]style;wire[3:0]phase;
 integer starts=0;
 net_image_lease #(.PREPARE_TIMEOUT_CYCLES(20),.LEASE_TIMEOUT_CYCLES(60)) dut(
  .clk(clk),.root_reset_n(reset),.command_valid(cv),.command(cmd),.command_generation(cg),.command_style(cs),
  .command_ack(ack),.command_status(status),.capture_hold_ack(hold_ack),.capture_idle(cap_idle),
  .video_idle(vid_idle),.core_idle(core_idle),.memory_quiet(mquiet),.memory_activity(activity),
  .capture_hold(hold_cap),.pause_video_jobs(pause_video),.use_upload_axi(axi_owner),.lease_active(active),
  .memory_allowed(access_ok),.memory_write_allowed(write_ok),.owns_nn(nn_owner),.job_valid(jv),
  .job_ready(jr),.job_done(jdone),.job_drained(jdrain),.job_error(jerror),
  .generation(gen),.last_released_generation(released),.style(style),.phase(phase),.terminal_status(terminal));
 always @(posedge clk)if(reset&&jv&&jr)starts<=starts+1;
 task command(input[2:0]op,input[31:0]g,input[7:0]expect_status);
  begin
   @(negedge clk);cmd=op;cg=g;cv=1;
   @(negedge clk);if(!ack||status!==expect_status)$fatal(1,"command status op=%d got=%d expected=%d",op,status,expect_status);
   cv=0;
  end
 endtask
 task acquire;
  begin
   command(0,0,1);repeat(2)@(negedge clk);if(phase!=2)$fatal(1,"prepare did not drain");
   command(1,0,0);if(!active||!write_ok||!axi_owner||style!=cs)$fatal(1,"acquire outputs");
  end
 endtask
 task await_idle;
  integer count;
  begin
   count=0;while(phase!=0)begin @(negedge clk);count=count+1;if(count>200)$fatal(1,"lease drain watchdog");end
   if(active||axi_owner||hold_cap||pause_video||access_ok||nn_owner)$fatal(1,"ownership not released");
  end
 endtask
 reg[31:0]g;
 initial begin
  repeat(5)@(negedge clk);reset=1;
  command(0,0,1);if(!hold_cap||!pause_video||active||axi_owner)$fatal(1,"prepare took DDR prematurely");
  command(1,0,1);repeat(25)@(negedge clk);await_idle();
  if(gen!=32'h80000000||terminal!=9)$fatal(1,"failed preparation reserved a generation");
  hold_ack=1;cap_idle=1;vid_idle=1;
  acquire();g=gen;
  command(2,g+1,10);if(phase!=3||jv)$fatal(1,"foreign generation submitted");
  mquiet=0;command(2,g,1);if(jv)$fatal(1,"submit before DMA drain");mquiet=1;
  command(2,g,0);if(!jv||access_ok||write_ok)$fatal(1,"commit failed to fence memory");
  command(2,g,0);command(4,g,1);
  repeat(10)begin @(negedge clk);if(!jv||!active||!axi_owner||gen!=g)$fatal(1,"cancel retracted pending NN request");end
  jr=1;@(negedge clk);jr=0;core_idle=0;jdrain=0;
  jdone=1;@(negedge clk);jdone=0;
  repeat(5)begin @(negedge clk);if(!active||phase!=5)$fatal(1,"NN ownership released before drain");end
  core_idle=1;jdrain=1;await_idle();if(released!=g||starts!=1)$fatal(1,"canceled job ownership");
  command(3,g,0);
  cs=3;acquire();g=gen;jr=1;command(2,g,0);@(negedge clk);jr=0;core_idle=0;jdrain=0;
  command(2,g,0);if(starts!=2)$fatal(1,"duplicate submit executed twice");
  jdone=1;@(negedge clk);jdone=0;repeat(3)@(negedge clk);
  if(phase!=5||access_ok)$fatal(1,"un-drained result published");core_idle=1;jdrain=1;
  repeat(2)@(negedge clk);if(phase!=6||!access_ok||write_ok)$fatal(1,"result permissions");
  command(3,g+1,10);if(phase!=6)$fatal(1,"foreign release");
  mquiet=0;command(3,g,1);
  repeat(10)begin @(negedge clk);if(!active||!axi_owner||access_ok)$fatal(1,"release ignored live DMA");end
  mquiet=1;await_idle();if(released!=g)$fatal(1,"release token");command(3,g,0);
  // NN error without DONE still waits for real core/AXI drain.
  acquire();g=gen;jr=1;command(2,g,0);@(negedge clk);jr=0;core_idle=0;jdrain=0;
  jerror=1;@(negedge clk);jerror=0;repeat(5)@(negedge clk);
  if(phase!=5||!active||access_ok)$fatal(1,"error freed busy core");core_idle=1;jdrain=1;
  await_idle();if(terminal!=6||released!=g)$fatal(1,"error terminal status");
  // Idle client timeout requests cancellation, never early DMA reuse.
  acquire();g=gen;activity=0;mquiet=0;
  repeat(70)@(negedge clk);if(phase!=7||!active||!axi_owner||access_ok||terminal!=9)$fatal(1,"timeout drain gate");
  mquiet=1;await_idle();activity=1;
  // Timeout while NN VALID is waiting must preserve that VALID to handshake.
  acquire();g=gen;command(2,g,0);activity=0;jdrain=0;
  repeat(70)begin @(negedge clk);if(!jv||!active)$fatal(1,"timeout retracted NN request");end
  jr=1;@(negedge clk);jr=0;core_idle=0;
  jdone=1;@(negedge clk);jdone=0;core_idle=1;jdrain=1;await_idle();
  if(starts!=4||released!=g||terminal!=9)$fatal(1,"timeout job accounting");
  $display("PASS: lease pre-drain/expiry, generation and permissions, exactly-once NN submission, cancellation before acceptance, NN/DMA drain on error/timeout, release replay");$finish;
 end
 initial begin #1000000;$fatal(1,"watchdog");end
endmodule
