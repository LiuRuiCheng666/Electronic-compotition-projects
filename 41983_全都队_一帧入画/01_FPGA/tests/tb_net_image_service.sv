`timescale 1ns/1ps
module tb;
 reg cc=0,kc=0;always #5 cc=~cc;always #3.125 kc=~kc;
 reg rst=0,cr=0,sel=0,en=0,wr=0;reg[15:0]addr=0;reg[31:0]wd=0;
 wire[31:0]rd;wire ready,err;
 reg fence=0,coreidle=1,externalquiet=1;
 wire holdcap,pausevid,owner,active,nnowner,jv,mbusy,cbusy;
 reg jready=0,jdone=0,jdrain=1,jerror=0;
 wire[1:0]style;wire[31:0]inputbase,outputbase,generation;wire[3:0]phase;wire[7:0]terminal;
 wire[31:0]aw,ar;wire[7:0]awl,arl;wire av,wv,wl,br,arv,rr;
 wire[127:0]wdata;wire[15:0]strb;reg[127:0]rdata;
 reg awready=1,wready=1,arready=1,allowb=1,allowr=1;
 reg awpending=0,bpending=0,rpending=0;
 reg[31:0]wa=0,ra=0;reg[1:0]bresp=0,rresp=0;
 wire bv=bpending&&allowb,rv=rpending&&allowr;
 reg[7:0]raw[0:255],result[0:255];
 integer awcount=0,arcount=0,nncount=0;
 net_image_service #(.PREPARE_TIMEOUT_CYCLES(2000),.LEASE_TIMEOUT_CYCLES(20000),.DMA_TIMEOUT_BITS(10)) dut(
  .cpu_clk(cc),.core_clk(kc),.root_reset_n(rst),.cpu_reset(cr),
  .PADDR(addr),.PSEL(sel),.PENABLE(en),.PWRITE(wr),.PWDATA(wd),.PRDATA(rd),.PREADY(ready),.PSLVERROR(err),
  .capture_hold_ack(fence),.capture_idle(fence),.video_idle(fence),.core_idle(coreidle),.external_memory_quiet(externalquiet),
  .capture_hold(holdcap),.pause_video_jobs(pausevid),.use_upload_axi(owner),.lease_active(active),
  .nn_owner(nnowner),.nn_job_valid(jv),.nn_job_ready(jready),.nn_job_done(jdone),.nn_job_drained(jdrain),.nn_job_error(jerror),
  .nn_style(style),.nn_input_base(inputbase),.nn_output_base(outputbase),
  .generation(generation),.phase(phase),.terminal_status(terminal),.memory_busy(mbusy),.control_busy(cbusy),
  .awaddr(aw),.awlen(awl),.awvalid(av),.awready(awready),.wdata(wdata),.wstrb(strb),.wlast(wl),.wvalid(wv),.wready(wready),
  .bid(4'd0),.bresp(bresp),.bvalid(bv),.bready(br),.araddr(ar),.arlen(arl),.arvalid(arv),.arready(arready),
  .rid(4'd0),.rdata(rdata),.rresp(rresp),.rlast(1'b1),.rvalid(rv),.rready(rr));
 always @*begin
  rdata=0;
  if(ra>=32'h07800000&&ra<32'h07800100)
   for(integer i=0;i<16;i=i+1)rdata[i*8+:8]=raw[ra-32'h07800000+i];
  else if(ra>=32'h07c00000&&ra<32'h07c00100)
   for(integer i=0;i<16;i=i+1)rdata[i*8+:8]=result[ra-32'h07c00000+i];
 end
 always @(posedge kc)if(rst)begin
  if((av||wv||arv||bpending||rpending)&&!owner)$fatal(1,"AXI escaped exclusive lease");
  if(av&&awready)begin
   if(awpending||awl!=0||aw[3:0]!=0||aw<32'h07800000||aw>=32'h07800100)$fatal(1,"bad private AW");
   wa<=aw;awpending<=1;awcount<=awcount+1;
  end
  if(wv&&wready)begin
   if(!awpending||strb!=16'hffff||!wl)$fatal(1,"write/RMW handshake");
   for(integer i=0;i<16;i=i+1)raw[wa-32'h07800000+i]<=wdata[i*8+:8];
   awpending<=0;bpending<=1;
  end
  if(bv&&br)bpending<=0;
  if(arv&&arready)begin
   if(rpending||arl!=0||ar[3:0]!=0)$fatal(1,"bad private AR");
   if(!((ar>=32'h07800000&&ar<32'h07800100)||(ar>=32'h07c00000&&ar<32'h07c00100)))$fatal(1,"unexpected address");
   ra<=ar;rpending<=1;arcount<=arcount+1;
  end
  if(rv&&rr)rpending<=0;
  if(jv&&jready)begin
   if(!owner||!nnowner||style!=2||inputbase!=32'h07800000||outputbase!=32'h07c00000)$fatal(1,"private NN descriptor");
   nncount<=nncount+1;
  end
 end
 // The DMA result bank is shared with the dispatcher. A CPU that delays
 // ACK (including during a warm reset) must see an immutable full response;
 // no following DMA command may overwrite the shared data bank.
 reg held_response=0;reg[255:0]held_value;
 always @(posedge kc)begin
  if(!rst)held_response<=0;
  else begin
   if(held_response && dut.response_valid && dut.response!==held_value)
    $fatal(1,"shared response changed before CPU ACK");
   if(dut.response_valid && dut.dma_valid)
    $fatal(1,"new DMA overwrote unacknowledged response");
   held_response<=dut.response_valid && !dut.response_ready;
   held_value<=dut.response;
  end
 end
 task put(input[15:0]a,input[31:0]v);
  begin @(negedge cc);addr=a;wd=v;sel=1;en=0;wr=1;
   @(negedge cc);en=1;#1;if(err||!ready)$fatal(1,"APB write");
   @(negedge cc);sel=0;en=0;wr=0;end
 endtask
 task get(input[15:0]a,output[31:0]v);
  begin @(negedge cc);addr=a;sel=1;en=0;wr=0;
   @(negedge cc);en=1;#1;if(err||!ready)$fatal(1,"APB read");v=rd;
   @(negedge cc);sel=0;en=0;end
 endtask
 function[31:0]crc_model(input integer is_result,input integer count);
 reg[31:0]c;integer a,b;begin
 c=32'hffffffff;
 for(a=0;a<count;a=a+1)begin
  c=c^(is_result?result[a]:raw[a]);
  for(b=0;b<8;b=b+1)c=(c>>1)^(c[0]?32'hedb88320:0);
 end
 crc_model=~c;
 end endfunction
 reg[255:0]answer;
 task begin_command(input[31:0]op,input[31:0]g,input[31:0]offset,input[31:0]mask,input[127:0]data);
  begin put(16'h2040,op);put(16'h2044,g);put(16'h2048,offset);put(16'h204c,mask);
   for(integer i=0;i<4;i=i+1)put(16'h2050+i*4,data[i*32+:32]);put(16'h2008,1);end
 endtask
 task finish_command(input[7:0]status);
  integer n;reg[31:0]v;begin n=0;v=0;
   while(!v[1])begin get(16'h2004,v);n=n+1;if(n>1000)$fatal(1,"completion watchdog phase=%d",phase);end
   for(integer i=0;i<8;i=i+1)begin get(16'h2040+i*4,v);answer[i*32+:32]=v;end
   if(answer[31:0]!=={24'd0,status})$fatal(1,"unexpected command status %d expected %d",answer[31:0],status);
   repeat(100)@(negedge kc);
   put(16'h2008,10);repeat(5)@(negedge kc);
  end
 endtask
 task command(input[31:0]op,input[31:0]g,input[31:0]offset,input[31:0]mask,input[127:0]data,input[7:0]status);
  begin begin_command(op,g,offset,mask,data);finish_command(status);end
 endtask
 task acquire;
  begin command(0,0,0,0,0,1);repeat(4)@(negedge kc);command(1,0,2,0,0,0);
   if(!owner||!active||phase!=3)$fatal(1,"acquire failed");end
 endtask
 reg[31:0]g;integer before_ar,before_aw;reg[31:0]v;
 initial begin
  for(integer i=0;i<256;i=i+1)begin raw[i]=i;result[i]=255-i;end
  repeat(5)@(negedge cc);rst=1;repeat(5)@(negedge cc);
  get(16'h2000,v);if(v!=32'h4e494d02)$fatal(1,"mailbox ID");
  command(0,0,0,0,0,1);command(1,0,2,0,0,1);
  if(owner||!holdcap||!pausevid)$fatal(1,"lease before capture fence");
  fence=1;repeat(5)@(negedge kc);command(1,0,2,0,0,0);g=generation;
  before_ar=arcount;command(10,g,0,0,0,1);command(8,g+1,0,0,0,10);
  // Command compaction must never alias invalid op/address/mask/style bits
  // into a legal request. Check every discarded bit at the real APB boundary.
  before_aw=awcount;before_ar=arcount;
  for(integer badbit=4;badbit<32;badbit=badbit+1)
   command(32'h9|(32'h1<<badbit),g,0,16'hffff,128'h12345678,3);
  for(integer badbit=22;badbit<32;badbit=badbit+1)begin
   command(9,g,32'h1<<badbit,16'hffff,128'h12345678,6);
   if(answer[127:96]!=1)$fatal(1,"high offset lost range error");
  end
  for(integer badbit=16;badbit<32;badbit=badbit+1)
   command(9,g,0,32'hffff|(32'h1<<badbit),128'h12345678,3);
  for(integer badbit=2;badbit<32;badbit=badbit+1)
   command(1,g,32'h2|(32'h1<<badbit),0,0,3);
  if(arcount!=before_ar||awcount!=before_aw||generation!=g||phase!=3)
   $fatal(1,"compacted malformed command escaped to DDR or changed owner");
  if(arcount!=before_ar)$fatal(1,"stale result/foreign generation reached DDR");
  command(9,g,0,16'hffff,128'h00112233445566778899aabbccddeeff,0);
  command(8,g,0,0,0,0);if(answer[255:128]!=128'h00112233445566778899aabbccddeeff)$fatal(1,"APB-DDR readback");
  command(9,g,0,16'h00ff,128'hdeadbeefdeadbeef0123456789abcdef,0);
  command(8,g,0,0,0,0);if(answer[255:128]!=128'h00112233445566770123456789abcdef)$fatal(1,"RMW corrupted bytes");
  command(12,g,64,0,0,0);if(answer[159:128]!==crc_model(0,64))$fatal(1,"bulk raw CRC/APB byte order");
  command(12,g,64,1,0,2);
  before_ar=arcount;before_aw=awcount;
  command(8,g,1,0,0,6);if(answer[127:96]!=1||arcount!=before_ar||awcount!=before_aw)$fatal(1,"unaligned access escaped");
  jready=1;command(2,g,0,0,0,0);jready=0;coreidle=0;jdrain=0;
  command(2,g,0,0,0,0);if(nncount!=1)$fatal(1,"duplicate NN job");
  command(10,g,0,0,0,1);jdone=1;repeat(3)@(negedge kc);jdone=0;
  if(phase!=5)$fatal(1,"published before real completion drain");
  coreidle=1;jdrain=1;repeat(5)@(negedge kc);
  command(10,g,0,0,0,0);if(answer[255:128]!=128'hf0f1f2f3f4f5f6f7f8f9fafbfcfdfeff)$fatal(1,"private result address/bytes");
  command(13,g,64,0,0,0);if(answer[159:128]!==crc_model(1,64))$fatal(1,"bulk result CRC/APB byte order");
  before_aw=awcount;command(9,g,0,16'hffff,0,1);if(awcount!=before_aw)$fatal(1,"result phase writable");
  command(3,g,0,0,0,1);repeat(8)@(negedge kc);if(owner||active)$fatal(1,"release failed");
  // CPU reset during actual AXI W/B stalls. VALID and lease must persist.
  acquire();g=generation;wready=0;allowb=0;
  begin_command(9,g,32,16'hffff,128'habcdef);wait(wv);cr=1;
  repeat(35)begin @(negedge kc);if(!wv||wdata!=128'habcdef||!owner||!active)$fatal(1,"reset withdrew W/ownership");end
  wready=1;wait(bpending);
  repeat(35)begin @(negedge kc);if(!owner||!active||!br)$fatal(1,"released before B response");end
  allowb=1;repeat(40)@(negedge cc);
  if(owner||active||phase!=0||mbusy||awpending||bpending)$fatal(1,"warm reset recovery did not drain");
  get(16'h2004,v);if(!v[1]||!v[3]||v[0])$fatal(1,"orphan response absent");
  cr=0;finish_command(6);acquire();g=generation;
  command(8,g,32,0,0,0);if(answer[255:128]!=128'habcdef)$fatal(1,"completed write lost across CPU reset");
  command(4,g,0,0,0,1);repeat(8)@(negedge kc);
  if(active||owner||nncount!=1)$fatal(1,"final ownership/job count");
  $display("PASS: actual APB+CDC+lease+dispatch+128-bit AXI/RMW RTL with byte-addressed DDR model, private result gating, single NN descriptor, warm reset W/B drain (NN model not actual core)");$finish;
 end
 initial begin #2000000;$fatal(1,"watchdog");end
endmodule
