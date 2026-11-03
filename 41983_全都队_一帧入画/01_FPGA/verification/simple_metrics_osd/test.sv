
`timescale 1ns/1ps
module tb_simple_osd;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg[11:0]x=0,y=0;reg[3:0]ui=8;
 reg[7:0]r=0,g=0,b=0;reg hs=0,vs=0,de=0,tick=0;
 wire[7:0]o_r,o_g,o_b;wire o_hs,o_vs,o_de;wire[9:0]display_fps;
 nn_fps_osd #(.PIXEL_HZ(100000),.FRAME_WIDTH(1280),.FRAME_HEIGHT(720)) dut(
 .clk(clk),.rst_n(rst_n),.x(x),.y(y),.debug_status(26'h3ffffff),
 .source_hdmi(1'b1),.cpu_ui(ui),.network_state(12'hf84),
 .source_fps(10'd123),.new_fps(10'd7),.camera_capture_fps(10'd98),
 .picture_index(1'b0),.frame_commit(1'b0),.frame_tick(tick),.capture_fps(10'd16),
 .r(r),.g(g),.b(b),.hs(hs),.vs(vs),.de(de),
 .o_r(o_r),.o_g(o_g),.o_b(o_b),.o_hs(o_hs),.o_vs(o_vs),.o_de(o_de),
 .image_fps(),.hdmi_hz(display_fps));
 reg[319:0]expected="RES:1280X720  PROC FPS:016  DISP FPS:050";
 integer i,j,checks=0,fd;reg[26:0]q0,q1,q2;
 task check_passthrough;
 input[11:0]yy;
 begin
  q0=0;q1=0;q2=0;
  for(j=0;j<80;j=j+1)begin
   @(negedge clk);x=(j*29)%1920;y=yy;r=j*3;g=j*5;b=j*7;
   hs=j%2;vs=(j%7)==0;de=(j%3)!=0;
   @(posedge clk);q2=q1;q1=q0;q0={hs,vs,de,r,g,b};#1;
   if(j>=2 && {o_hs,o_vs,o_de,o_r,o_g,o_b}!==q2)$fatal(1,"Passthrough/latency mismatch y=%0d j=%0d",yy,j);
   checks=checks+1;
  end
 end endtask
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  for(i=0;i<100000;i=i+1)begin @(negedge clk);tick=(i%2000)==0;end
  @(negedge clk);tick=0;
  repeat(100)@(negedge clk);
  if(display_fps!==50)$fatal(1,"Measured display FPS incorrect: %0d",display_fps);
  y=20;
  for(i=0;i<40;i=i+1)begin
   x=32+i*16;#1;
   if(dut.character!==expected[319-i*8-:8])$fatal(1,"Text mismatch col=%0d char=%0d expected=%0d",i,dut.character,expected[319-i*8-:8]);
   checks=checks+1;
  end
  // Every old information row must pass the original video, even with error
  // bits/network phases asserted. Also exercise blanking and sync alignment.
  check_passthrough(0);check_passthrough(44);check_passthrough(68);
  check_passthrough(100);check_passthrough(719);check_passthrough(1079);
  // OSD switch remains functional, including within the new metrics bar.
  @(negedge clk);ui=0;repeat(5)@(negedge clk);
  check_passthrough(20);
  @(negedge clk);ui=8;repeat(5)@(negedge clk);x=32+4*16;y=20;de=1;r=17;g=34;b=51;
  // First pixel of numeral '1' is the known background; its center is white.
  repeat(4)@(negedge clk);
  if({o_r,o_g,o_b}!==24'h000000)$fatal(1,"Expected black glyph background");
  x=32+4*16+4;repeat(4)@(negedge clk);
  if({o_r,o_g,o_b}!==24'hffffff)$fatal(1,"Expected white numeral stroke");
  // Dump actual pipelined RTL pixels for a reviewable screen-label preview.
  fd=$fopen("metrics.ppm","w");$fwrite(fd,"P3\n640 16\n255\n");
  for(i=20;i<36;i=i+1)for(j=32;j<672;j=j+1)begin
   @(negedge clk);x=j;y=i;repeat(4)@(negedge clk);
   $fwrite(fd,"%0d %0d %0d\n",o_r,o_g,o_b);
  end
  $fclose(fd);
  $display("PASS: simplified OSD text, measured FPS, removed rows, enable, RGB/sync 3-stage latency checks=%0d",checks);
  $finish;
 end
 initial begin #2000000;$fatal(1,"Timeout");end
endmodule
