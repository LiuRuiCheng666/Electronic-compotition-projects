`timescale 1ns/1ps
module tb;
 reg clk=0;always #3.125 clk=~clk;
 reg rst=0,quarantine=0,qv=0,sready=0;wire qr,sv;
 reg[255:0]q=0;wire[255:0]s;
 wire lv,la;wire[2:0]lc;wire[31:0]lg,gen,last_gen;wire[1:0]ls,style;
 wire[7:0]lstatus,term;wire[3:0]phase;
 wire allowed,writable,active,holdcap,pausevid,owner,nnowner,jv;
 reg jready=0,jdone=0,jdrain=1,jerror=0,coreidle=1;
 wire dv,dw,dr,drr;reg dready=1,drv=0;wire[31:0]dg,offset;wire[15:0]mask;
 wire[127:0]data;reg[127:0]danswer=128'h112233445566778899aabbccddeeff00;
 reg[3:0]de=0;reg dma_busy=0,auto_dma=1;
 integer dma_count=0,nn_count=0;
 net_image_dispatch dut(.clk(clk),.root_reset_n(rst),.cpu_quarantine(quarantine),
  .request_valid(qv),.request_ready(qr),.request(q),.response_valid(sv),.response_ready(sready),.response(s),
  .lease_command_valid(lv),.lease_command(lc),.lease_command_generation(lg),.lease_command_style(ls),
  .lease_ack(la),.lease_status(lstatus),.generation(gen),.phase(phase),.memory_allowed(allowed),
  .memory_write_allowed(writable),.terminal_status(term),.dma_valid(dv),.dma_ready(dready),
  .dma_write(dw),.dma_result(dr),.dma_generation(dg),.dma_offset(offset),.dma_data(data),.dma_mask(mask),
  .dma_response_valid(drv),.dma_response_ready(drr),.dma_error(de),.dma_response_data(danswer));
 net_image_lease #(.PREPARE_TIMEOUT_CYCLES(200),.LEASE_TIMEOUT_CYCLES(1000)) lease(
  .clk(clk),.root_reset_n(rst),.command_valid(lv),.command(lc),.command_generation(lg),.command_style(ls),
  .command_ack(la),.command_status(lstatus),.capture_hold_ack(1'b1),.capture_idle(1'b1),
  .video_idle(1'b1),.core_idle(coreidle),.memory_quiet(!dma_busy&&!dv),.memory_activity(dma_busy||qv),
  .capture_hold(holdcap),.pause_video_jobs(pausevid),.use_upload_axi(owner),.lease_active(active),
  .memory_allowed(allowed),.memory_write_allowed(writable),.owns_nn(nnowner),
  .job_valid(jv),.job_ready(jready),.job_done(jdone),.job_drained(jdrain),.job_error(jerror),
  .generation(gen),.last_released_generation(last_gen),.style(style),.phase(phase),.terminal_status(term));
 always @(posedge clk)if(rst)begin
  if(dv&&dready)begin dma_busy<=1;dma_count<=dma_count+1;end
  if(dma_busy&&auto_dma&&!drv)drv<=1;
  if(drv&&drr)begin drv<=0;dma_busy<=0;end
  if(jv&&jready)nn_count<=nn_count+1;
 end
 task begin_request(input[31:0]op,input[31:0]g,input[31:0]arg,input[31:0]m);
  integer n;begin
   @(negedge clk);q={128'h123456789abcdef0123456789abcdef0,m,arg,g,op};qv=1;n=0;
   while(!qr)begin @(negedge clk);n=n+1;if(n>1000)$fatal(1,"request watchdog");end
   @(negedge clk);qv=0;
  end
 endtask
 task finish_request(input[7:0]expected);
  integer n;reg[255:0]saved;begin n=0;
   while(!sv)begin @(negedge clk);n=n+1;if(n>1000)$fatal(1,"response watchdog phase=%d",phase);end
   if(s[31:0]!=={24'd0,expected})$fatal(1,"status got=%d wanted=%d op=%d",s[31:0],expected,q[31:0]);
   saved=s;repeat(5)begin @(negedge clk);if(!sv||s!==saved)$fatal(1,"response changed under backpressure");end
   sready=1;@(negedge clk);sready=0;
  end
 endtask
 task command(input[31:0]op,input[31:0]g,input[31:0]arg,input[7:0]expected);
  begin begin_request(op,g,arg,0);finish_request(expected);end
 endtask
 task prepare_acquire;
  begin command(0,0,0,1);repeat(3)@(negedge clk);command(1,0,2,0);
   if(phase!=3||style!=2)$fatal(1,"acquire style/generation");end
 endtask
 reg[31:0]g;integer before_dma;
 initial begin
  repeat(5)@(negedge clk);rst=1;
  command(11,0,0,0);command(8,0,0,10);command(32'h100,0,0,3);
  prepare_acquire();g=gen;
  command(1,0,4,3);command(8,g+1,0,10);command(10,g,0,1);
  before_dma=dma_count;begin_request(9,g,0,32'h10000);finish_request(3);
  if(dma_count!=before_dma)$fatal(1,"malformed mask escaped");
  begin_request(9,g,32'h30,32'hffff);wait(dv);#1;
  if(!dw||dr||dg!=g||offset!=48||mask!=16'hffff||data!=128'h123456789abcdef0123456789abcdef0)$fatal(1,"DMA decode");
  finish_request(0);begin_request(8,g,48,0);finish_request(0);
  if(s[255:128]!=danswer)$fatal(1,"read result absent");
  de=2;command(8,g,48,6);if(s[127:96]!=2)$fatal(1,"DMA error lost");de=0;
  jready=1;command(2,g,0,0);jready=0;coreidle=0;jdrain=0;
  command(2,g,0,0);command(9,g,0,1);command(10,g,0,1);
  if(nn_count!=1)$fatal(1,"duplicate model start");
  jdone=1;@(negedge clk);jdone=0;repeat(3)@(negedge clk);
  if(phase!=5)$fatal(1,"premature result before drain");
  coreidle=1;jdrain=1;repeat(4)@(negedge clk);
  begin_request(10,g,0,0);wait(dv);#1;if(!dr||dw)$fatal(1,"result read decode");finish_request(0);
  before_dma=dma_count;command(9,g,0,1);if(dma_count!=before_dma)$fatal(1,"result writable");
  command(3,g,0,1);repeat(4)@(negedge clk);command(3,g,0,0);
  // A warm CPU reset during a stalled command cannot retract DMA VALID.
  prepare_acquire();g=gen;dready=0;auto_dma=0;
  begin_request(9,g,0,32'hffff);wait(dv);quarantine=1;
  repeat(20)begin @(negedge clk);if(!dv||!owner||!active||sv)$fatal(1,"DMA abandoned during reset");end
  dready=1;@(negedge clk);dready=0;
  repeat(20)begin @(negedge clk);if(!active||!owner||sv)$fatal(1,"lease released before DMA response");end
  auto_dma=1;finish_request(6);dready=1;
  repeat(20)@(negedge clk);if(phase!=0||owner)$fatal(1,"quarantine did not drain lease");
  command(0,0,0,3);quarantine=0;repeat(5)@(negedge clk);
  prepare_acquire();g=gen;command(4,g,0,1);repeat(8)@(negedge clk);
  if(phase!=0||dma_count!=5)$fatal(1,"final ownership/count %d",dma_count);
  $display("PASS: lease+dispatcher commands, generation, NN idempotence, memory permissions, CPU reset DMA drain, immutable replies (DMA/NN behavioral models)");$finish;
 end
 initial begin #1000000;$fatal(1,"watchdog");end
endmodule
