`timescale 1ns/1ps
`default_nettype none
// One immutable 8-word command and one completion across CPU/core clocks.
// The CPU window is reused for the response after the core has finished; it
// cannot be overwritten while busy or before response acknowledgement.
// Only the DDR/system root reset clears toggles. A CPU-local reset preserves
// outstanding work and raises an orphan flag plus a synchronized core reset
// notification, for the lease coordinator to cancel and drain safely.
module net_image_mailbox #(parameter[15:0]BASE=16'h2000,parameter integer COMPACT_COMMANDS=0)(
 input wire cpu_clk,core_clk,root_reset_n,cpu_reset,
 input wire[15:0]PADDR,input wire PSEL,PENABLE,PWRITE,input wire[31:0]PWDATA,
 output reg[31:0]PRDATA,output wire PREADY,output reg PSLVERROR,
 output wire core_request_valid,input wire core_request_ready,
 output wire[255:0]core_request,
 input wire core_response_valid,output wire core_response_ready,
 input wire[255:0]core_response,
 output wire cpu_reset_core,cpu_orphan_core,
 output wire core_busy
);
 wire cpu_root_n,core_root_n;
 hdmi_reset_release cpu_release(.clk(cpu_clk),.rst_n(root_reset_n),.released_n(cpu_root_n));
 hdmi_reset_release core_release(.clk(core_clk),.rst_n(root_reset_n),.released_n(core_root_n));
 reg[31:0]window[0:7];
 reg request_toggle,busy_cpu,completed,rejected,orphan,cpu_reset_previous,done_seen;
 (* async_reg="true" *)reg[2:0]done_sync;
 reg done_toggle,request_seen;
 (* async_reg="true" *)reg[2:0]request_sync;
 (* async_reg="true" *)reg[2:0]cpu_reset_sync;
 (* async_reg="true" *)reg[2:0]orphan_sync;
 // The dispatcher already owns an immutable registered response until its
 // ready handshake. Keep that handshake pending through CPU ACK instead of
 // duplicating the entire response in a second bank of core registers.
 reg ack_toggle;
 (* async_reg="true" *)reg[2:0]ack_sync;
 localparam CORE_IDLE=0,CORE_REQUEST=1,CORE_RESPONSE=2,CORE_ACK=3;
 reg[1:0]core_state;
 wire[15:0]rel=PADDR-BASE;
 wire selected=PSEL && PADDR[15:8]==BASE[15:8];
 wire access=selected&&PENABLE;
 wire window_address=rel>=16'h0040 && rel<=16'h005c && rel[1:0]==0;
 wire control_write=access&&PWRITE&&rel==8&&!cpu_reset;
 // Typed image commands use op<=13, offsets below 4MiB and 16-bit masks.
 // Preserve invalid high bits as an invalid flag, so malformed commands
 // still fail closed instead of wrapping into a legal command or address.
 // Generic mailbox instances retain every command bit (default parameter).
 function[31:0]command_word;
  input[2:0]index;input[31:0]value;
  begin
   command_word=value;
   if(COMPACT_COMMANDS!=0)case(index)
    0:command_word={27'd0,|value[31:4],value[3:0]};
    2:command_word={9'd0,|value[31:22],value[21:0]};
    3:command_word={15'd0,|value[31:16],value[15:0]};
    default:command_word=value;
   endcase
  end
 endfunction
 assign PREADY=1'b1;
 assign core_request_valid=core_state==CORE_REQUEST;
 assign core_response_ready=core_state==CORE_ACK && ack_sync[2]==request_seen;
 assign core_busy=core_state!=CORE_IDLE || request_sync[2]!=request_seen;
 assign cpu_reset_core=cpu_reset_sync[2];
 assign cpu_orphan_core=orphan_sync[2];
 genvar g;
 generate for(g=0;g<8;g=g+1)begin:G_WORD
  assign core_request[g*32+:32]=window[g];
 end endgenerate
 always @*begin
  PRDATA=0;PSLVERROR=0;
  if(selected)begin
   if(rel[1:0]!=0)PSLVERROR=1;
   else if(window_address)PRDATA=window[rel[4:2]];
   else case(rel)
    0:PRDATA=32'h4e494d02;
    4:PRDATA={26'd0,cpu_root_n,cpu_reset,orphan,rejected,completed,busy_cpu};
    8:PRDATA=0;
    default:PSLVERROR=1;
   endcase
   if(PWRITE && rel!=8 && !window_address)PSLVERROR=1;
  end
 end
 integer i;
 always @(posedge cpu_clk or negedge cpu_root_n)begin
  if(!cpu_root_n)begin
   for(i=0;i<8;i=i+1)window[i]<=0;
   request_toggle<=0;busy_cpu<=0;completed<=0;rejected<=0;orphan<=0;
   done_sync<=0;done_seen<=0;cpu_reset_previous<=0;ack_toggle<=0;
  end else begin
   done_sync<={done_sync[1:0],done_toggle};
   cpu_reset_previous<=cpu_reset;
   if(cpu_reset&&!cpu_reset_previous)orphan<=1;
   if(access&&PWRITE&&window_address&&!cpu_reset)begin
    if(!busy_cpu&&!completed&&!orphan)window[rel[4:2]]<=command_word(rel[4:2],PWDATA);
    else rejected<=1;
   end
   if(control_write)begin
    if(PWDATA[3])rejected<=0;
    if(PWDATA[0])begin
     if(!busy_cpu&&!completed&&!orphan)begin request_toggle<=!request_toggle;busy_cpu<=1;end
     else rejected<=1;
    end else if(PWDATA[1])begin
     if(!busy_cpu)begin
      if(completed)ack_toggle<=done_seen;
      completed<=0;orphan<=0;
     end
     else rejected<=1;
    end
   end
   if(done_sync[2]!=done_seen)begin
    done_seen<=done_sync[2];
    if(busy_cpu)begin
     for(i=0;i<8;i=i+1)window[i]<=core_response[i*32+:32];
     busy_cpu<=0;completed<=1;
    end else rejected<=1;
   end
  end
 end
 always @(posedge core_clk or negedge core_root_n)begin
  if(!core_root_n)begin
   request_sync<=0;orphan_sync<=0;request_seen<=0;done_toggle<=0;core_state<=CORE_IDLE;ack_sync<=0;
  end else begin
   request_sync<={request_sync[1:0],request_toggle};
   orphan_sync<={orphan_sync[1:0],orphan};
   ack_sync<={ack_sync[1:0],ack_toggle};
   case(core_state)
    CORE_IDLE:if(request_sync[2]!=request_seen)core_state<=CORE_REQUEST;
    CORE_REQUEST:if(core_request_ready)begin request_seen<=request_sync[2];core_state<=CORE_RESPONSE;end
    CORE_RESPONSE:if(core_response_valid)begin
     done_toggle<=request_seen;core_state<=CORE_ACK;
    end
    CORE_ACK:if(core_response_valid&&core_response_ready)core_state<=CORE_IDLE;
    default:core_state<=CORE_IDLE;
   endcase
  end
 end
 always @(posedge core_clk or negedge core_root_n or posedge cpu_reset)begin
  if(!core_root_n || cpu_reset)cpu_reset_sync<=3'b111;
  else cpu_reset_sync<={cpu_reset_sync[1:0],1'b0};
 end
endmodule
`default_nettype wire
