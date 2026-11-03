`timescale 1ns/1ps
module tb;
 reg core_clk=0,mipi_tx_feedback100=0;
 always #3.125 core_clk=~core_clk;always #5 mipi_tx_feedback100=~mipi_tx_feedback100;
 reg vid_rst_n=0,c_reset=0;
 reg[15:0]c_addr=0;reg c_sel=0,c_enable=0,c_write=0;reg[31:0]c_wdata=0;
 reg snapshot_pipeline_ready=1,snapshot_locked=0,weights_boot_ready=1,weights_boot_failed=0;
 reg copy_in_req_valid=0,c_admit_enable=1,style_inference_idle=1;
 reg[1:0]style_active=0;
 reg live_nn_start=0,live_nn_reset_n=1;
 wire live_nn_busy,live_nn_done,live_nn_pass,live_nn_fail,c_scheduler_req_ready;
 reg[2:0]live_nn_compute_fault=0;
 wire[1:0][31:0]m_awaddr,m_araddr;wire[1:0][7:0]m_awlen,m_arlen;
 wire[1:0][127:0]m_wdata;reg[1:0][127:0]m_rdata=0;
 wire[1:0]m_awvalid,m_wvalid,m_wlast,m_bready,m_arvalid,m_rready;
 reg[1:0]m_awready=3,m_wready=3,m_arready=3,m_bvalid=0,m_rvalid=0,m_rlast=3;
 reg[1:0][5:0]m_bid=0,m_rid=0;reg[1:0][1:0]m_bresp=0,m_rresp=0;
 reg cap_req=0,cap_send=0,cap_idle_model=1,cap_b_allow=1;
 reg[31:0]capture_wa=32'h02000000;reg[127:0]capture_data=128'hdeadbeef;
 reg cap_ack1=0,cap_ack2=0,cap_ack3=0;
 reg image_actual_busy_reg=0,image_actual_done_reg=0,image_actual_pass_reg=0;
 reg boot_nn_awvalid=0,boot_nn_wvalid=0,boot_nn_arvalid=0;
 wire boot_nn_awready=1,boot_nn_bready=1,boot_nn_arready=1,boot_nn_rready=1,boot_nn_rlast=1;
 reg nn_b_pending=0,nn_r_pending=0,nn_allow_b=1,nn_allow_r=1;
 wire boot_nn_bvalid=nn_b_pending&&nn_allow_b,boot_nn_rvalid=nn_r_pending&&nn_allow_r;
 integer core_ticks=0,starts=0,video_events=0;reg previous_video_done=0;
 reg axi_aw_pending=0,axi_b_pending=0,axi_r_pending=0;reg[31:0]axi_wa=0,axi_ra=0;
 reg[127:0]input_line=0,capture_line=0;
 @@DECL@@
 assign video_scheduler_req_ready=1;
 assign image_capture_idle=cap_idle_model;
 assign image_hold_ack=cap_ack3;
 assign cap_awaddr=capture_wa;assign cap_awlen=0;assign cap_awvalid=cap_req;
 assign cap_wdata=capture_data;assign cap_wlast=1;assign cap_wvalid=cap_send;
 assign cap_bready=1;assign cap_araddr=0;assign cap_arlen=0;assign cap_arvalid=0;assign cap_rready=1;
 assign image_actual_busy=image_actual_busy_reg;assign image_actual_done=image_actual_done_reg;
 assign image_actual_pass=image_actual_pass_reg;assign image_actual_fail=0;
 @@CONTROL@@
 @@RESET@@
 @@INST@@

 // CPU-local reset does not reset either simulated DDR transaction owner.
 always @(posedge core_clk or negedge vid_rst_n)begin
  if(!vid_rst_n)begin cap_ack1<=0;cap_ack2<=0;cap_ack3<=0;end
  else begin cap_ack1<=image_hold;cap_ack2<=cap_ack1;cap_ack3<=cap_ack2;end
 end
 always @(posedge core_clk or negedge live_nn_core_reset_n)begin
  if(!live_nn_core_reset_n)begin
   image_actual_busy_reg<=0;image_actual_done_reg<=0;image_actual_pass_reg<=0;core_ticks<=0;
   boot_nn_awvalid<=0;boot_nn_arvalid<=0;boot_nn_wvalid<=0;nn_b_pending<=0;nn_r_pending<=0;
  end else begin
   if(boot_nn_awvalid)begin boot_nn_awvalid<=0;boot_nn_wvalid<=1;end
   else if(boot_nn_wvalid)begin boot_nn_wvalid<=0;nn_b_pending<=1;end
   if(boot_nn_bvalid)nn_b_pending<=0;
   if(boot_nn_arvalid)begin boot_nn_arvalid<=0;nn_r_pending<=1;end
   if(boot_nn_rvalid)nn_r_pending<=0;
   if(image_nn_owner?image_nn_start:live_nn_start)begin
    image_actual_busy_reg<=1;image_actual_done_reg<=0;image_actual_pass_reg<=0;core_ticks<=0;
    boot_nn_awvalid<=1;boot_nn_arvalid<=1;starts<=starts+1;
   end else if(image_actual_busy_reg)begin
    if(core_ticks==7)begin image_actual_busy_reg<=0;image_actual_done_reg<=1;image_actual_pass_reg<=1;end
    else core_ticks<=core_ticks+1;
   end
  end
 end
 always @(posedge core_clk)if(vid_rst_n)begin
  if(live_nn_done&&!previous_video_done)video_events<=video_events+1;
  previous_video_done<=live_nn_done;
  if(image_axi_owner && (cap_awready||cap_wready||cap_bvalid||cap_arready||cap_rvalid))$fatal(1,"capture saw private AXI handshake");
  if(!image_axi_owner && (image_awready||image_wready||image_bvalid||image_arready||image_rvalid))$fatal(1,"private DMA saw capture AXI response");
  if(image_pause&&c_scheduler_req_ready)$fatal(1,"paused video still admits input slot");
  if(image_wvalid&&image_wstrb!=16'hffff)$fatal(1,"compact write mask reached physical port");
 end
 always @*begin
  m_rdata=0;m_rdata[1]=axi_ra==32'h07800000 ? input_line : 128'd0;
  m_bvalid=0;m_bvalid[1]=axi_b_pending&&(image_axi_owner||cap_b_allow);
  m_rvalid=0;m_rvalid[1]=axi_r_pending;
 end
 always @(posedge core_clk)if(vid_rst_n)begin
  if(m_awvalid[1]&&m_awready[1])begin
   if(axi_aw_pending||axi_b_pending)$fatal(1,"AW overlap");axi_wa<=m_awaddr[1];axi_aw_pending<=1;
  end
  if(m_wvalid[1]&&m_wready[1])begin
   if(!axi_aw_pending||!m_wlast[1])$fatal(1,"W without AW");
   if(axi_wa==32'h07800000)input_line<=m_wdata[1];
   else if(axi_wa==32'h02000000)capture_line<=m_wdata[1];else $fatal(1,"wrong write base");
   axi_aw_pending<=0;axi_b_pending<=1;
  end
  if(m_bvalid[1]&&m_bready[1])axi_b_pending<=0;
  if(m_arvalid[1]&&m_arready[1])begin
   if(axi_r_pending||m_araddr[1]!=32'h07800000)$fatal(1,"wrong AR");axi_ra<=m_araddr[1];axi_r_pending<=1;
  end
  if(m_rvalid[1]&&m_rready[1])axi_r_pending<=0;
 end
 task put(input[15:0]a,input[31:0]d);
  begin @(negedge mipi_tx_feedback100);c_addr=a;c_wdata=d;c_sel=1;c_write=1;c_enable=0;
   @(negedge mipi_tx_feedback100);c_enable=1;
   @(negedge mipi_tx_feedback100);c_sel=0;c_enable=0;c_write=0;end
 endtask
 task get(input[15:0]a,output[31:0]d);
  begin @(negedge mipi_tx_feedback100);c_addr=a;c_sel=1;c_write=0;c_enable=0;
   @(negedge mipi_tx_feedback100);c_enable=1;#1;
   if(!image_apb_ready||image_apb_error)$fatal(1,"APB image decode");d=image_apb_data;
   @(negedge mipi_tx_feedback100);c_sel=0;c_enable=0;end
 endtask
 reg[255:0]answer;
 task command(input[31:0]op,input[31:0]g,input[31:0]arg,input[15:0]mask,input[127:0]data,input[7:0]expect_status);
  reg[31:0]v;integer n;begin
   put(16'h2040,op);put(16'h2044,g);put(16'h2048,arg);put(16'h204c,{16'd0,mask});
   for(integer j=0;j<4;j=j+1)put(16'h2050+j*4,data[j*32+:32]);put(16'h2008,1);
   v=0;n=0;while(!v[1])begin get(16'h2004,v);n=n+1;if(n>500)$fatal(1,"image reply watchdog");end
   for(integer j=0;j<8;j=j+1)begin get(16'h2040+j*4,v);answer[j*32+:32]=v;end
   if(answer[31:0]!=={24'd0,expect_status})$fatal(1,"status got %d expected %d",answer[31:0],expect_status);
   put(16'h2008,10);repeat(5)@(negedge core_clk);
  end
 endtask
 task normal_job;
  begin @(negedge core_clk);live_nn_reset_n=0;repeat(4)@(negedge core_clk);live_nn_reset_n=1;
   repeat(5)@(negedge core_clk);live_nn_start=1;@(negedge core_clk);live_nn_start=0;
   repeat(25)@(negedge core_clk);end
 endtask
 reg[31:0]g;integer n;
 initial begin
  repeat(5)@(negedge mipi_tx_feedback100);vid_rst_n=1;repeat(10)@(negedge core_clk);
  copy_in_req_valid=1;@(negedge core_clk);copy_in_req_valid=0;
  normal_job();if(video_events!=1||starts!=1)$fatal(1,"first video completion");
  // Start capture AXI, then request the image lease while its B is stalled.
  cap_idle_model=0;cap_b_allow=0;cap_req=1;
  @(negedge core_clk);cap_req=0;cap_send=1;@(negedge core_clk);cap_send=0;
  command(0,0,0,0,0,1);command(1,0,2,0,0,1);
  if(image_axi_owner||!axi_b_pending||!image_pause||!cap_bready)$fatal(1,"lease stole stalled capture response");
  cap_b_allow=1;repeat(3)@(negedge core_clk);cap_idle_model=1;
  command(1,0,2,0,0,0);g=image_generation;
  if(!image_axi_owner||capture_line!=128'hdeadbeef)$fatal(1,"capture not preserved");
  command(9,g,0,16'hffff,128'h123456789abcdef00123456789abcdef,0);
  command(8,g,0,0,0,0);if(answer[255:128]!=128'h123456789abcdef00123456789abcdef)$fatal(1,"private port readback");
  // Wrong metadata slot must hold the launcher without accepting a job.
  nn_allow_b=0;nn_allow_r=0;command(2,g,0,0,0,0);
  if(starts!=1||image_nn_start||image_phase!=4)$fatal(1,"wrong style metadata launched compute");
  style_active=2;repeat(40)@(negedge core_clk);
  if(starts!=2||image_phase!=5||!image_nn_owner||!image_actual_done||!image_nn_write_pending||!image_nn_read_pending)
   $fatal(1,"private NN did not wait for actual DDR drain");
  if(live_nn_done||video_events!=1)$fatal(1,"private DONE leaked into video");
  nn_allow_r=1;repeat(8)@(negedge core_clk);if(image_phase!=5)$fatal(1,"write pending ignored");
  nn_allow_b=1;repeat(15)@(negedge core_clk);if(image_phase!=6||image_nn_owner)$fatal(1,"private result not ready");
  if(live_nn_done||video_events!=1)$fatal(1,"held private DONE leaked after NN owner release");
  command(3,g,0,0,0,1);repeat(20)@(negedge core_clk);
  if(image_active||image_pause||image_axi_owner||!c_scheduler_req_ready||live_nn_done||video_events!=1)
   $fatal(1,"release changed mode/created false video completion");
  // Actual video scheduler starts its first resumed task WITHOUT a reset;
  // it resets only after completing that task. Do not hide return-path bugs
  // by injecting a testbench-only reset here.
  @(negedge core_clk);live_nn_start=1;@(negedge core_clk);live_nn_start=0;
  repeat(30)@(negedge core_clk);
  if(video_events!=2||starts!=3)$fatal(1,"normal video did not recover without artificial reset");
  $display("PASS: extracted production top APB/AXI/NN controls, capture B fence, exclusive port responses, metadata guard, held private DONE isolation through release, video recovery (core/capture behavioral models)");$finish;
 end
 initial begin #2000000;$fatal(1,"watchdog");end
endmodule
