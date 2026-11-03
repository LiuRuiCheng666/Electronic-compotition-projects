`timescale 1ns/1ps
module tb;
 reg clk=0;always #3.125 clk=~clk;
 reg rst=0,quarantine=0,qv=0,sready=0;reg[255:0]q=0;
 wire qr,sv;wire[255:0]s;
 reg[31:0]generation=32'h80000001;reg[3:0]phase=3;reg allowed=1,writable=1;
 wire lv;wire[2:0]lc;wire[31:0]lg;wire[1:0]ls;
 wire dv,dw,dr,drr;wire[31:0]dg,offset;wire[127:0]data;wire[15:0]mask;
 reg drv=0,busy=0;reg[127:0]answer=0;reg[3:0]error=0;integer cycles=0,delay_count=0,count=0,pattern=0,fault_at=0,i;
 wire dready=!busy && cycles%4!=0;
 net_image_dispatch dut(.clk(clk),.root_reset_n(rst),.cpu_quarantine(quarantine),
 .request_valid(qv),.request_ready(qr),.request(q),.response_valid(sv),.response_ready(sready),.response(s),
 .lease_command_valid(lv),.lease_command(lc),.lease_command_generation(lg),.lease_command_style(ls),
 .lease_ack(1'b0),.lease_status(8'd0),.generation(generation),.phase(phase),.memory_allowed(allowed),
 .memory_write_allowed(writable),.terminal_status(8'd0),.dma_valid(dv),.dma_ready(dready),.dma_write(dw),
 .dma_result(dr),.dma_generation(dg),.dma_offset(offset),.dma_data(data),.dma_mask(mask),
 .dma_response_valid(drv),.dma_response_ready(drr),.dma_error(error),.dma_response_data(answer));
 function[7:0]value_at(input integer address);
 reg[7:0]v;begin
 v=(address*37+11)^((address>>5)&255);
 if(pattern!=0)v=(address%4==3)?0:(v&127);
 if(pattern==2 && address==17)v=v|128;
 if(pattern==3 && address==19)v=1;
 value_at=v;
 end endfunction
 function[31:0]golden(input integer length);
 reg[31:0]c;integer a,b;begin
 c=32'hffffffff;
 for(a=0;a<length;a=a+1)begin
  c=c^value_at(a);
  for(b=0;b<8;b=b+1)c=(c>>1)^(c[0]?32'hedb88320:0);
 end
 golden=~c;
 end endfunction
 always @(posedge clk)if(rst)begin
 cycles<=cycles+1;
 if(dv&&dready)begin
  if(dw||dg!=generation||offset!=count*16)$fatal(1,"bad CRC DMA offset/gen/write %d count %d",offset,count);
  if(dr!=(q[31:0]==13))$fatal(1,"wrong memory selected");
  busy<=1;delay_count<=cycles%3+1;count<=count+1;
  for(i=0;i<16;i=i+1)answer[i*8+:8]<=value_at(offset+i);
  error<=(fault_at!=0 && count+1==fault_at)?2:0;
 end
 if(busy&&!drv)begin if(delay_count==0)drv<=1;else delay_count<=delay_count-1;end
 if(drv&&drr)begin drv<=0;busy<=0;end
 end
 task begin_cmd(input[31:0]op,input[31:0]length,input[31:0]flags,input[31:0]gen);
 begin
 count=0;@(negedge clk);q={128'd0,flags,length,gen,op};qv=1;
 while(!qr)@(negedge clk);
 @(negedge clk);qv=0;
 end endtask
 task finish_cmd(input[31:0]expected,input integer check_crc);
 reg[255:0]saved;integer watchdog;begin
 watchdog=0;while(!sv)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>10000000)$fatal(1,"CRC watchdog");end
 if(s[31:0]!=expected)$fatal(1,"CRC status got %d expected %d",s[31:0],expected);
 if(check_crc && (s[159:128]!==golden(q[95:64]) || count!=q[95:64]/16))$fatal(1,"CRC mismatch length %d got %h expected %h count %d",q[95:64],s[159:128],golden(q[95:64]),count);
 saved=s;repeat(5)begin @(negedge clk);if(!sv||s!==saved)$fatal(1,"CRC reply not immutable");end
 sready=1;@(negedge clk);sready=0;
 end endtask
 task run(input integer op,input integer length,input integer flags,input integer status,input integer check_crc);
 begin begin_cmd(op,length,flags,generation);finish_cmd(status,check_crc);end endtask
 initial begin
 repeat(5)@(negedge clk);rst=1;
 run(12,16,0,0,1);run(12,48,0,0,1);run(12,1024,0,0,1);
 pattern=1;run(12,1024,1,0,1);
 pattern=2;run(12,1024,1,2,0);pattern=3;run(12,1024,1,2,0);
 pattern=0;run(12,0,0,3,0);if(count!=0)$fatal(1,"zero length DMA");
 run(12,17,0,3,0);run(12,4194304,0,3,0);run(12,16,2,3,0);
 begin_cmd(12,16,0,generation+1);finish_cmd(10,0);if(count!=0)$fatal(1,"wrong generation DMA");
 run(13,16,0,1,0);phase=6;run(13,1024,0,0,1);run(13,2764816,0,3,0);run(13,16,1,3,0);
 fault_at=3;run(13,1024,0,6,0);fault_at=0;
 begin_cmd(13,1024,0,generation);wait(dut.state==6);@(negedge clk);quarantine=1;finish_cmd(6,0);quarantine=0;
 // Reset the unit, then revoke a lease during CRC accumulation.
 rst=0;repeat(3)@(negedge clk);rst=1;
 begin_cmd(13,1024,0,generation);wait(dut.state==6);@(negedge clk);allowed=0;finish_cmd(6,0);allowed=1;
 // Full 720p result byte count and independent bitwise polynomial reference.
 run(13,2764800,0,0,1);
 $display("PASS: hardware CRC raw/result, full720p, packed bounds, generation, range, DMA fault, reset/lease revoke, stalls and immutable replies");$finish;
 end
 initial begin #1000000000;$fatal(1,"global watchdog");end
endmodule
