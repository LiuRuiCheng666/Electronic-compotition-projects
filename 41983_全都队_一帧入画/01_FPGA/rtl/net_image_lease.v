`timescale 1ns/1ps
`default_nettype none
// Private-image ownership coordinator, not yet connected to the board.
// PREPARE pauses the video producers but never owns DDR. ACQUIRE is allowed
// only after the capture acknowledgement and all existing work have drained.
// The private NN result is returned over the network, not published into the
// video front-buffer queue. This preserves the original display ownership.
module net_image_lease #(
 parameter integer PREPARE_TIMEOUT_CYCLES=320000000,
 parameter integer LEASE_TIMEOUT_CYCLES=1600000000
)(
 input wire clk,root_reset_n,
 input wire command_valid,input wire[2:0]command,
 input wire[31:0]command_generation,input wire[2:0]command_style,
 output reg command_ack,output reg[7:0]command_status,
 input wire capture_hold_ack,capture_idle,video_idle,core_idle,memory_quiet,
 input wire memory_activity,
 output wire capture_hold,pause_video_jobs,use_upload_axi,
 output wire lease_active,memory_allowed,memory_write_allowed,owns_nn,
 output wire job_valid,input wire job_ready,job_done,job_drained,job_error,
 output reg[31:0]generation,last_released_generation,
 output reg[2:0]style,
 output wire[3:0]phase,output reg[7:0]terminal_status
);
 localparam IDLE=0,PREPARING=1,PREPARED=2,OWNED=3,START=4,RUNNING=5,RESULT=6,DRAIN=7;
 localparam PREPARE=0,ACQUIRE=1,SUBMIT=2,RELEASE=3,CANCEL=4;
 localparam OK=0,BUSY=1,STATE=3,IO=6,TIMEOUT=9,OWNER=10;
 localparam PW=PREPARE_TIMEOUT_CYCLES<2?1:$clog2(PREPARE_TIMEOUT_CYCLES+1);
 localparam LW=LEASE_TIMEOUT_CYCLES<2?1:$clog2(LEASE_TIMEOUT_CYCLES+1);
 reg[3:0]state;
 localparam CW=PW>LW?PW:LW;
 reg[CW-1:0]shared_count;
 wire[PW-1:0]prepare_count=shared_count[PW-1:0];
 wire[LW-1:0]inactive_count=shared_count[LW-1:0];
 reg cancel_pending,finished,failed;
 wire quiescent=capture_hold_ack&&capture_idle&&video_idle&&core_idle&&memory_quiet;
 wire same_owner=command_generation==generation;
 assign phase=state;
 assign capture_hold=state!=IDLE;
 assign pause_video_jobs=state!=IDLE;
 assign lease_active=state>=OWNED;
 assign use_upload_axi=state>=OWNED;
 assign memory_allowed=(state==OWNED || state==RESULT) && !cancel_pending && !failed;
 assign memory_write_allowed=state==OWNED && !cancel_pending && !failed;
 assign owns_nn=state==START || state==RUNNING;
 assign job_valid=state==START;
 always @(posedge clk or negedge root_reset_n)begin
  if(!root_reset_n)begin
   state<=IDLE;generation<=32'h80000000;last_released_generation<=0;style<=0;
   shared_count<=0;cancel_pending<=0;finished<=0;failed<=0;
   command_ack<=0;command_status<=0;terminal_status<=0;
  end else begin
   command_ack<=command_valid;
   if(state==PREPARING || state==PREPARED)begin
    if(prepare_count==PREPARE_TIMEOUT_CYCLES-1)begin state<=IDLE;terminal_status<=TIMEOUT;end
    else shared_count<=prepare_count+1'b1;
   end
   if(lease_active)begin
    if(memory_activity || command_valid)shared_count<=0;
    else if(inactive_count==LEASE_TIMEOUT_CYCLES-1)begin
     cancel_pending<=1;terminal_status<=TIMEOUT;
     if(state==OWNED || state==RESULT)state<=DRAIN;
    end else shared_count<=inactive_count+1'b1;
   end
   case(state)
    PREPARING:if(quiescent && prepare_count!=PREPARE_TIMEOUT_CYCLES-1)state<=PREPARED;
    START:if(job_ready)begin state<=RUNNING;finished<=0;failed<=0;end
    RUNNING:begin
     if(job_done)finished<=1;
     if(job_error)begin failed<=1;terminal_status<=IO;end
     if((finished||job_done||failed||job_error)&&job_drained&&core_idle)begin
      if(cancel_pending||failed||job_error)state<=DRAIN;else state<=RESULT;
     end
    end
    DRAIN:if(memory_quiet && core_idle && job_drained)begin
     state<=IDLE;last_released_generation<=generation;
    end
    default:begin end
   endcase
   if(command_valid)begin
    command_status<=OK;
    case(command)
     PREPARE:begin
      if(state==IDLE)begin state<=PREPARING;shared_count<=0;terminal_status<=0;command_status<=BUSY;end
      else if(state!=PREPARED)command_status<=BUSY;
     end
     ACQUIRE:begin
      if(command_style>=5)command_status<=STATE;
      else if(state==PREPARED && quiescent)begin
       generation<=generation==32'hffffffff ? 32'h80000001 : generation+1'b1;
       style<=command_style;state<=OWNED;shared_count<=0;
       cancel_pending<=0;finished<=0;failed<=0;terminal_status<=0;
      end else command_status<=BUSY;
     end
     SUBMIT:begin
      if(!same_owner || !lease_active)command_status<=OWNER;
      else if(state==OWNED && memory_quiet)begin state<=START;finished<=0;failed<=0;end
      else if(state==START || state==RUNNING || state==RESULT)command_status<=OK;
      else command_status<=BUSY;
     end
     RELEASE,CANCEL:begin
      if(state==IDLE && command_generation==last_released_generation)command_status<=OK;
      else if(!same_owner || !lease_active)command_status<=OWNER;
      else begin
       cancel_pending<=1;
       if(state==OWNED || state==RESULT)state<=DRAIN;
       command_status<=BUSY;
      end
     end
     default:command_status<=STATE;
    endcase
   end
  end
 end
endmodule
`default_nettype wire
