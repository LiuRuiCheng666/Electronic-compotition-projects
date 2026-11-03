`timescale 1ns/1ps
`default_nettype none
// Core-clock decoder for the immutable APB mailbox. This is not a board
// backend yet. Data and offsets must remain stable until the response.
// W0 op: lease PREPARE..CANCEL 0..4, raw read/write 8/9, result read 10,
// status 11. W1 generation, W2 byte offset (style for ACQUIRE), W3 mask,
// W4..7 data. Response W0 status, W1 generation, W2 phase/flags,
// W3 terminal status (DMA error bits for memory ops), W4..7 read data.
// CPU quarantine rejects pending commands and cancels the private lease;
// an in-flight DMA is ALWAYS consumed before cancellation releases DDR.
module net_image_dispatch(
 input wire clk,root_reset_n,cpu_quarantine,
 input wire request_valid,output wire request_ready,input wire[255:0]request,
 output wire response_valid,input wire response_ready,output wire[255:0]response,
 output reg lease_command_valid,output reg[2:0]lease_command,
 output wire[31:0]lease_command_generation,output wire[2:0]lease_command_style,
 input wire lease_ack,input wire[7:0]lease_status,
 input wire[31:0]generation,input wire[3:0]phase,
 input wire memory_allowed,memory_write_allowed,input wire[7:0]terminal_status,
 output wire dma_valid,input wire dma_ready,output wire dma_write,dma_result,
 output wire[31:0]dma_generation,dma_offset,output wire[127:0]dma_data,
 output wire[15:0]dma_mask,input wire dma_response_valid,output wire dma_response_ready,
 input wire[3:0]dma_error,input wire[127:0]dma_response_data
);
 localparam IDLE=0,LEASE_WAIT=1,DMA_ISSUE=2,DMA_WAIT=3,REPLY=4,RECOVER_WAIT=5,CRC_STEP=6;
 localparam OK=0,BUSY=1,STATE=3,IO=6,OWNER=10;
 wire[31:0]op=request[31:0];
 wire crc_op=op==12||op==13;
 reg[2:0]state;
 reg recovery;
 reg[127:0]response_header;
 reg response_has_data,response_has_crc;
 reg[21:0]scan_offset;
 wire[21:0]scan_end=request[85:64];
 wire scan_mode=crc_op;
 reg[4:0]scan_nibble;
 reg[31:0]scan_crc;
 wire[3:0]scan_data=dma_response_data[scan_nibble*4+:4];
 function[31:0]crc_nibble;
  input[31:0]c;input[3:0]n;
  reg[31:0]t;
  begin
   case(c[3:0]^n)
    0:t=0;1:t=32'h1db71064;2:t=32'h3b6e20c8;3:t=32'h26d930ac;
    4:t=32'h76dc4190;5:t=32'h6b6b51f4;6:t=32'h4db26158;7:t=32'h5005713c;
    8:t=32'hedb88320;9:t=32'hf00f9344;10:t=32'hd6d6a3e8;11:t=32'hcb61b38c;
    12:t=32'h9b64c2b0;13:t=32'h86d3d2d4;14:t=32'ha00ae278;15:t=32'hbdbdf21c;
   endcase
   crc_nibble=(c>>4)^t;
  end
 endfunction
 wire[31:0]scan_next=crc_nibble(scan_crc,scan_data);
 wire scan_bad_packed=op==12 && request[96] &&
   ((scan_nibble[2:1]==3 && scan_data!=0) ||
    (scan_nibble[2:1]!=3 && scan_nibble[0] && scan_data[3]));
 // DMA resp_data remains unchanged after its response handshake until the
 // next DMA command. No next command is possible until this mailbox reply
 // is acknowledged. Reuse that stable bank instead of copying 128 bits.
 assign response={response_has_crc?{96'd0,~scan_crc}:response_has_data?dma_response_data:128'd0,response_header[127:64],generation,response_header[31:0]};

 wire active=phase>=3;
 wire recovery_needed=cpu_quarantine||recovery;

 wire memory_op=op==8||op==9||op==10||crc_op;
 wire known_op=op<=4||memory_op||op==11;
 // Lease recovery commands use the current generation, never an old CPU word.
 assign lease_command_generation=(state==RECOVER_WAIT || (state==REPLY&&recovery_needed))?generation:request[63:32];
 assign lease_command_style=request[66:64];
 assign request_ready=state==IDLE && (!recovery_needed||!active);
 assign response_valid=state==REPLY;
 assign dma_valid=state==DMA_ISSUE;
 assign dma_write=op==9;assign dma_result=op==10||op==13;
 assign dma_generation=request[63:32];assign dma_offset=scan_mode?{10'd0,scan_offset}:request[95:64];
 assign dma_mask=request[111:96];assign dma_data=request[255:128];
 assign dma_response_ready=state==DMA_WAIT;
 task reply_status;
  input[7:0]status;
  begin
   response_header<=0;response_has_data<=0;response_has_crc<=0;response_header[31:0]<=status;
   response_header[95:64]<={26'd0,memory_write_allowed,memory_allowed,phase};
   response_header[127:96]<=terminal_status;state<=REPLY;
  end
 endtask
 always @(posedge clk or negedge root_reset_n)begin
  if(!root_reset_n)begin
   state<=IDLE;response_header<=0;response_has_data<=0;response_has_crc<=0;scan_offset<=0;scan_nibble<=0;scan_crc<=0;lease_command_valid<=0;lease_command<=0;recovery<=0;
  end else begin
   lease_command_valid<=0;
   if(cpu_quarantine)recovery<=1;
   else if(phase==0 && state==IDLE)recovery<=0;
   case(state)
    IDLE:begin
     if(recovery_needed && active)begin
      lease_command<=4;lease_command_valid<=1;state<=RECOVER_WAIT;
     end else if(request_valid && request_ready)begin
      if(recovery_needed)reply_status(STATE);
      else if(!known_op || (op==1 && (request[95:67]!=0 || request[66:64]>=5)) ||
              (memory_op && request[127:112]!=0))reply_status(STATE);
      else if(op<=4)begin lease_command<=op[2:0];lease_command_valid<=1;state<=LEASE_WAIT;end
      else if(op==11)reply_status(OK);
      else if(request[63:32]!=generation || !active)reply_status(OWNER);
      else if(!memory_allowed || (op==9&&!memory_write_allowed) || ((op==10||op==13)&&phase!=6))reply_status(BUSY);
      else if(crc_op && (request[95:86]!=0 || request[85:64]==0 ||
              request[67:64]!=0 || request[127:97]!=0 ||
              (op==13 && (request[96] || request[95:64]>2764800))))reply_status(STATE);
      else begin
       scan_offset<=0;scan_crc<=32'hffffffff;
       state<=DMA_ISSUE;
      end
     end
    end
    LEASE_WAIT:if(lease_ack)begin
     if(recovery_needed)reply_status(STATE);else reply_status(lease_status);
    end
    DMA_ISSUE:if(dma_ready)state<=DMA_WAIT;
    DMA_WAIT:if(dma_response_valid)begin
     if(dma_error!=0 || recovery_needed)begin
      reply_status(IO);response_header[127:96]<={28'd0,dma_error};
     end else if(scan_mode)begin scan_nibble<=0;state<=CRC_STEP;end
     else begin reply_status(OK);response_header[127:96]<=0;response_has_data<=1;end
    end
    CRC_STEP:begin
     if(recovery_needed || !memory_allowed || request[63:32]!=generation)reply_status(IO);
     else if(scan_bad_packed)reply_status(2);
     else begin
      scan_crc<=scan_next;
      if(scan_nibble==31)begin
       if({1'b0,scan_offset}+23'd16>={1'b0,scan_end})begin reply_status(OK);response_has_crc<=1;end
       else begin scan_offset<=scan_offset+22'd16;state<=DMA_ISSUE;end
      end else scan_nibble<=scan_nibble+1'b1;
     end
    end
    REPLY:begin
     // The mailbox retains this immutable response until the CPU ACK crosses
     // back. CPU reset must still cancel/drain ownership while that CPU is
     // absent; never require software acknowledgement to release AXI safely.
     if(recovery_needed && active && phase!=7)begin
      lease_command<=4;lease_command_valid<=1;
     end
     if(response_ready)state<=IDLE;
    end
    RECOVER_WAIT:if(lease_ack)state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
