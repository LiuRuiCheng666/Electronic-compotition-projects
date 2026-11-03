`timescale 1ns/1ps
module tb;
 reg cpu_reset=0;
 reg rst=0,nclk=0,cclk=0,nrun=1;always #4 if(nrun)nclk=~nclk;always #5 cclk=~cclk;
 reg[7:0]data=0;reg valid=0,err=0;wire[7:0]tx;wire tv;
 wire[7:0]rx_data;wire rx_valid,rx_error;reg[3:0]lo=0;reg lo_valid=0;
 always @(posedge nclk)begin lo<=data[7:4];lo_valid<=valid;end
 net_physical_link phys(.osc_inst1_CLKOUT(cclk),.rxc(nclk),.reset_n(rst),.mdio_i(1'b1),
  .rxd_hi_i(data[3:0]),.rxd_lo_i(lo),.rx_dv_HI(valid),.rx_dv_LO(lo_valid),
  .rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),.tx_data(tx),.tx_valid(tv));
 initial begin force phys.power_wait=20'h80000;force phys.gigabit=1'b1;end

 reg[15:0]addr=0;reg sel=0,en=0,wr=0;reg[31:0]wd=0;wire[31:0]q;wire ready,error,irq;
 wire[31:0]gu,ga,drop,bf,bh,ag,ac,af,copied,asent,usent;
 a_net_service_endpoint dut(.net_clk(nclk),.cpu_clk(cclk),.reset_n(rst),.cpu_reset(cpu_reset),
  .gmii_rx_data(rx_data),.gmii_rx_valid(rx_valid),.gmii_rx_error(rx_error|err),.gmii_tx_data(tx),.gmii_tx_valid(tv),
  .PADDR(addr),.PSEL(sel),.PENABLE(en),.PWRITE(wr),.PWDATA(wd),.PRDATA(q),.PREADY(ready),.PSLVERROR(error),.irq(irq),
  .good_udp(gu),.good_arp(ga),.busy_drops(drop),.bad_fcs(bf),.bad_header(bh),
  .app_good(ag),.app_bad_crc(ac),.app_bad_format(af),.rx_copied(copied),.arp_sent(asent),.udp_sent(usent));
 reg[7:0]mem[0:2047];reg[31:0]words[0:349];integer f,frames=0;reg prev=0;
 always @(posedge nclk)begin
  if(tv)$fwrite(f,"%02x\n",tx);
  if(prev&&!tv)begin $fwrite(f,"END\n");frames=frames+1;end
  prev<=tv;
 end
 task send(input string name,input integer size);begin
  $readmemh(name,mem);
  for(integer j=0;j<size;j++)begin @(negedge nclk);valid=1;data=mem[j];end
  @(negedge nclk);valid=0;repeat(3)@(negedge nclk);
 end endtask
 task bus(input[15:0]a,input w,input[31:0]d,output[31:0]r);integer g;begin
  @(negedge cclk);addr=16'h1000+a;sel=1;en=0;wr=w;wd=d;
  @(negedge cclk);en=1;#1;g=0;
  while(!ready)begin @(negedge cclk);#1;g++;if(g>20)$fatal(1,"APB stuck");end
  if(error)$fatal(1,"APB error %h",a);r=q;
  @(negedge cclk);en=0;sel=0;
 end endtask
 reg[31:0]v,tok,tmp;integer guard;
 task await_rx;begin
  guard=0;v=0;
  while(!v[0])begin bus(4,0,0,v);guard++;if(guard>3000)$fatal(1,"RX timeout");end
 end endtask
 task check_rx(input integer n,input integer op,input integer seq);reg[31:0]want;begin
  await_rx();bus(8,0,0,tok);
  bus(16'h10,0,0,v);if(v!=32'hc0a80003)$fatal(1,"peer IP");
  bus(16'h14,0,0,v);if(v!=40001)$fatal(1,"peer port");
  bus(16'h18,0,0,v);if(v!={(16'(n)),8'd0,8'(op)})$fatal(1,"kind %h",v);
  bus(16'h1c,0,0,v);if(v!=32'h10203040)$fatal(1,"session");
  bus(16'h20,0,0,v);if(v!=seq)$fatal(1,"sequence");
  bus(16'h2c,0,0,v);if(v!=32'h22334455)$fatal(1,"MAClo");
  bus(16'h30,0,0,v);if(v!=32'h0011)$fatal(1,"MAChi");
  for(integer j=0;j<n;j+=4)begin
   want=0;for(integer k=0;k<4&&j+k<n;k++)want=want|((32'(((j+k)*17+3)&255))<<(8*k));
   bus(16'h800+j,0,0,v);if(v!=want)$fatal(1,"RX bytes %d %h !=%h",j,v,want);
  end
 end endtask
 task release_rx;begin bus(12,1,tok,v);end endtask
 task queue_reply(input string file_name,input integer n);begin
  $readmemh(file_name,words);
  bus(16'h40,1,32'hc0a80003,v);bus(16'h44,1,40001,v);
  bus(16'h48,1,32'h22334455,v);bus(16'h4c,1,32'h0011,v);
  bus(16'h50,1,n,v);bus(16'h5c,0,0,tmp);
  for(integer j=0;j<(n+3)/4;j++)bus(16'h54,1,words[j],v);
  bus(16'h58,1,tmp,v);
 end endtask
 task complete_tx;begin
  guard=0;v=0;while(!v[3])begin bus(4,0,0,v);guard++;if(guard>1000)$fatal(1,"TX done missing");end
  if(v[1]||v[4])$fatal(1,"TX completion state %h",v);
  bus(16'h68,1,1,v);
 end endtask
 initial begin
  f=$fopen("tx_frames.txt","w");repeat(5)@(negedge cclk);rst=1;repeat(8)@(negedge cclk);
  send("req0.mem",86);check_rx(0,2,1);release_rx();queue_reply("reply0.mem",32);complete_tx();
  send("bad_app.mem",91);repeat(1500)@(negedge nclk);bus(4,0,0,v);
  if(v[0]||ac!=1||frames!=1)$fatal(1,"invalid ANET accepted/replied");
  send("bad_fcs.mem",91);repeat(300)@(negedge nclk);bus(4,0,0,v);
  if(v[0]||bf!=1)$fatal(1,"invalid FCS accepted");
  send("req5.mem",91);check_rx(5,2,2);
  // Link flap must not clear a CPU-owned endpoint mailbox or generation.
  force phys.gigabit=1'b0;repeat(10)@(negedge nclk);
  check_rx(5,2,2);if(rx_valid)$fatal(1,"RX admitted while link down");
  force phys.gigabit=1'b1;repeat(12)@(negedge nclk);check_rx(5,2,2);
  // A full next datagram waits in validated raw/app RAM while CPU holds RX.
  send("req1368.mem",1454);repeat(1600)@(negedge nclk);
  send("req0.mem",86);repeat(200)@(negedge nclk);
  check_rx(5,2,2);if(drop<1)$fatal(1,"no busy drop");release_rx();
  check_rx(1368,8'h11,3);release_rx();
  queue_reply("reply5.mem",37);complete_tx();queue_reply("reply1368.mem",1400);complete_tx();
  // Delay ARP behind a large UDP; then queue the next UDP during ARP.
  queue_reply("reply1368.mem",1400);send("arp.mem",72);
  wait(dut.state==8);wait(dut.u_tx.ar&&dut.tx_busy);
  @(negedge nclk);nrun=0;
  // Clock pause stresses the independent CPU/network handshake, not speed.
  complete_tx();queue_reply("reply0.mem",32);bus(4,0,0,v);
  if(!v[1])$fatal(1,"queued UDP not owned");nrun=1;
  wait(dut.tx_done&&dut.tx_owner_mailbox==0);
  repeat(6)@(negedge cclk);bus(4,0,0,v);
  if(!v[1]||v[3])$fatal(1,"ARP completion freed mailbox UDP");
  complete_tx();repeat(20)@(negedge nclk);
  if(frames!=6||copied!=3||asent!=1||usent!=5)$fatal(1,"counts %d %d %d %d",frames,copied,asent,usent);
  // Partial frame reset may not publish a stale packet.
  @(negedge nclk);valid=1;data=8'h55;repeat(10)@(negedge nclk);rst=0;valid=0;
  repeat(5)@(negedge cclk);rst=1;repeat(10)@(negedge cclk);bus(4,0,0,v);
  if(v!=0||irq||tv)$fatal(1,"stale state after reset");
  // Hardware transport must survive held CPU reset and never enqueue HELLO.
  cpu_reset=1;repeat(8)@(negedge nclk);
  send("req5.mem",91);repeat(300)@(negedge nclk);
  send("arp.mem",72);wait(frames==7);repeat(30)@(negedge nclk);
  send("hello0.mem",86);wait(frames==8);repeat(30)@(negedge nclk);
  send("hello5.mem",91);wait(frames==9);repeat(30)@(negedge nclk);
  send("hello1368.mem",1454);wait(frames==10);repeat(30)@(negedge nclk);
  send("bad_hello.mem",91);repeat(2000)@(negedge nclk);if(frames!=10)$fatal(1,"bad HELLO replied");
  if(copied!=0 || irq)$fatal(1,"hardware HELLO leaked into reset CPU mailbox");
  cpu_reset=0;repeat(12)@(negedge cclk);
  send("req5.mem",91);check_rx(5,2,2);release_rx();
  // A HELLO arriving behind a live CPU long reply shares TX without truncation.
  queue_reply("reply1368.mem",1400);send("hello0.mem",86);
  wait(dut.state==9);if(!dut.tx_busy)$fatal(1,"HELLO did not wait behind CPU TX");
  complete_tx();wait(frames==12);repeat(30)@(negedge nclk);
  if(usent!=5 || asent!=1)$fatal(1,"shared TX ownership counters");
  $fclose(f);$display("PASS: recovered-clock PHY fabric plus GMII/APB endpoint, held CPU RX preserved across link flap, validated RX byte copy, held RX/backpressure, CRC/FCS rejection, generic TX and ARP completion ownership under asynchronous clocks and clock pause");$finish;
 end
 initial begin #2000000;$fatal(1,"watchdog");end
endmodule
