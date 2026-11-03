`timescale 1ns/1ps
module tb;
 reg cc=0,kc=0;always #5 cc=~cc;always #3.125 kc=~kc;
 reg rst=0,cr=0,sel=0,en=0,wr=0;
 reg[15:0]addr=0;reg[31:0]wd=0;wire[31:0]rd;wire ready,err;
 wire qv,svr,reset_core,orphan_core,cb;reg qr=0,sv=0;
 wire[255:0]q;reg[255:0]s=0;
 net_image_mailbox dut(.cpu_clk(cc),.core_clk(kc),.root_reset_n(rst),.cpu_reset(cr),
  .PADDR(addr),.PSEL(sel),.PENABLE(en),.PWRITE(wr),.PWDATA(wd),
  .PRDATA(rd),.PREADY(ready),.PSLVERROR(err),.core_request_valid(qv),
  .core_request_ready(qr),.core_request(q),.core_response_valid(sv),
  .core_response_ready(svr),.core_response(s),.cpu_reset_core(reset_core),.cpu_orphan_core(orphan_core),.core_busy(cb));
 task put(input[15:0]a,input[31:0]v);
  begin @(negedge cc);addr=a;wd=v;sel=1;en=0;wr=1;
   @(negedge cc);en=1;@(negedge cc);sel=0;en=0;wr=0;end
 endtask
 task get(input[15:0]a,output[31:0]v);
  begin @(negedge cc);addr=a;sel=1;en=0;wr=0;
   @(negedge cc);en=1;#1;if(err||!ready)$fatal(1,"APB read failed");v=rd;
   @(negedge cc);sel=0;en=0;end
 endtask
 task request(input[31:0]seed);
  integer j;begin for(j=0;j<8;j=j+1)put(16'h2040+j*4,seed+j);put(16'h2008,1);end
 endtask
 task wait_q;
  integer n;begin n=0;while(!qv)begin @(negedge kc);n=n+1;if(n>100)$fatal(1,"request watchdog");end end
 endtask
 task take_q(input[31:0]seed);
  integer j;begin wait_q();for(j=0;j<8;j=j+1)if(q[j*32+:32]!==seed+j)$fatal(1,"request corruption");
   @(negedge kc);qr=1;@(negedge kc);qr=0;if(svr)$fatal(1,"response consumed before CPU ACK");end
 endtask
 task respond(input[31:0]seed);
  integer j;begin @(negedge kc);for(j=0;j<8;j=j+1)s[j*32+:32]=seed+j;
   sv=1;@(negedge kc);if(svr)$fatal(1,"response released before CPU ACK");end
 endtask
 task check_response(input[31:0]seed,input bit expected_orphan);
  integer n,j;reg[31:0]v;begin n=0;v=0;
   while(!v[1])begin get(16'h2004,v);n=n+1;if(n>100)$fatal(1,"completion watchdog");end
   if(v[0]||v[3]!==expected_orphan)$fatal(1,"completion status %h",v);
   for(j=0;j<8;j=j+1)begin get(16'h2040+j*4,v);if(v!==seed+j)$fatal(1,"response corruption");end
  end
 endtask
 integer i,j,accepted=0;reg[31:0]v;reg[255:0]saved;
 always @(posedge kc)if(rst&&qv&&qr)accepted<=accepted+1;
 always @(posedge kc)if(rst&&sv&&svr)sv<=0;
 initial begin
  repeat(4)@(negedge cc);rst=1;repeat(5)@(negedge cc);
  get(16'h2000,v);if(v!=32'h4e494d01)$fatal(1,"ID");
  request(32'h1000);wait_q();saved=q;
  put(16'h2040,32'hdeadbeef);put(16'h2008,1);put(16'h2008,2);
  repeat(20)begin @(negedge kc);if(!qv||q!==saved)$fatal(1,"unstable held command");end
  get(16'h2004,v);if(v[2:0]!=5)$fatal(1,"busy operations not rejected");
  take_q(32'h1000);repeat(8)@(negedge kc);respond(32'habcd0000);
  check_response(32'habcd0000,0);put(16'h2040,0);
  repeat(100)begin @(negedge kc);if(!sv||svr||!cb)$fatal(1,"response not retained during CPU read stall");end
  get(16'h2040,v);if(v!=32'habcd0000)$fatal(1,"unacknowledged response overwritten");
  put(16'h2008,10);get(16'h2004,v);if(v!=32'h20)$fatal(1,"ACK did not clear/ready missing");
  request(32'h2000);wait_q();cr=1;repeat(5)@(negedge cc);
  if(!reset_core||!orphan_core)$fatal(1,"reset/quarantine notification absent");cr=0;
  take_q(32'h2000);respond(32'habcd1000);check_response(32'habcd1000,1);
  put(16'h2008,1);get(16'h2004,v);if(!v[2]||!v[3])$fatal(1,"orphan commit accepted");
  put(16'h2008,10);repeat(5)@(negedge kc);if(orphan_core)$fatal(1,"quarantine not cleared after recovery ACK");
  // Local reset after completion must preserve the response until recovery ACK.
  request(32'h3000);take_q(32'h3000);respond(32'habcd2000);check_response(32'habcd2000,0);
  cr=1;repeat(4)@(negedge cc);cr=0;check_response(32'habcd2000,1);put(16'h2008,10);
  // Repeat across unrelated clock phases, with variable backend stalls.
  for(i=0;i<100;i=i+1)begin
   request(32'h4000+i*8);wait_q();saved=q;
   for(j=0;j<(i%13);j=j+1)begin @(negedge kc);if(q!==saved||!qv)$fatal(1,"payload stall");end
   take_q(32'h4000+i*8);repeat(i%7)@(negedge kc);
   respond(32'h8000+i*8);check_response(32'h8000+i*8,0);put(16'h2008,2);
  end
  repeat(10)@(negedge kc);if(accepted!=103||cb||qv)$fatal(1,"duplicate or missing requests %d",accepted);
  @(negedge cc);addr=16'h2041;sel=1;en=1;#1;if(!err)$fatal(1,"unaligned APB accepted");
  addr=16'h200c;#1;if(!err)$fatal(1,"unknown APB accepted");sel=0;en=0;
  $display("PASS: 103 CDC transactions, immutable commands, response ACK, CPU reset recovery, APB guards");$finish;
 end
 initial begin #1000000;$fatal(1,"watchdog");end
endmodule
