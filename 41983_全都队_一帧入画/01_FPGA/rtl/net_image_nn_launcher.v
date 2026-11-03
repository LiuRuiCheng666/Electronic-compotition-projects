`timescale 1ns/1ps
`default_nettype none
// Private task reset/start/completion guard. Owner must be granted only after
// the normal NN and all its DDR transactions are idle. Reset is applied once
// before each private inference, preserving deployed coefficient/weight RAM.
// Never resets an active task on cancellation or CPU-local reset.
module net_image_nn_launcher #(
 parameter integer RESET_CYCLES=4,RELEASE_CYCLES=4
)(
 input wire clk,root_reset_n,owner,request_valid,
 output wire request_ready,
 input wire weights_ready,weights_failed,core_busy,core_done,core_pass,core_fail,
 input wire[2:0]core_fault,input wire memory_quiet,
 output wire local_reset_n,core_start,job_done,job_drained,job_error,
 output wire[2:0]debug_state
);
 localparam IDLE=0,RESET=1,RELEASE=2,ARMED=3,ACTIVE=4,COMPLETE=5,RETURN_RESET=6,RETURN_RELEASE=7;
 localparam N=RESET_CYCLES>RELEASE_CYCLES?RESET_CYCLES:RELEASE_CYCLES;
 localparam CW=N<2?1:$clog2(N);
 reg[2:0]state;
 reg[CW-1:0]count;
 reg failed,seen_busy,reset_high;
 assign debug_state=state;
 // A registered reset output avoids decoder glitches on multi-bit state
 // transitions feeding the shared core's asynchronous reset release chain.
 assign local_reset_n=reset_high;
 assign request_ready=state==ARMED && memory_quiet && !core_busy &&
  (weights_failed||(weights_ready&&!core_done&&!core_fail&&core_fault==0));
 assign core_start=request_valid&&request_ready&&!weights_failed;
 assign job_done=state==COMPLETE;
 // After ownership falls, keep the lease in DRAIN until the held private
 // DONE has been cleared and reset release has settled for normal video.
 assign job_drained=(state==IDLE||(state==COMPLETE&&owner))&&memory_quiet&&!core_busy;
 assign job_error=failed;
 always @(posedge clk or negedge root_reset_n)begin
  if(!root_reset_n)begin state<=IDLE;count<=0;failed<=0;seen_busy<=0;reset_high<=1;end
  else begin
   case(state)
    IDLE:if(owner&&request_valid&&!core_busy&&memory_quiet)begin state<=RESET;count<=0;failed<=0;seen_busy<=0;reset_high<=0;end
    RESET:if(count==RESET_CYCLES-1)begin state<=RELEASE;count<=0;reset_high<=1;end else count<=count+1'b1;
    RELEASE:if(count==RELEASE_CYCLES-1)begin state<=ARMED;count<=0;end else count<=count+1'b1;
    ARMED:if(request_valid&&request_ready)begin
     if(weights_failed)begin failed<=1;state<=COMPLETE;end else state<=ACTIVE;
    end
    ACTIVE:begin
     if(core_busy)seen_busy<=1;
     if(core_fail||core_fault!=0)failed<=1;
     if(core_done&&!core_busy&&memory_quiet&&(seen_busy||core_fail||core_fault!=0))begin
      if(!core_pass||core_fail||core_fault!=0)failed<=1;
      state<=COMPLETE;
     end
    end
    COMPLETE:if(!owner&&memory_quiet&&!core_busy)begin state<=RETURN_RESET;count<=0;reset_high<=0;end
    RETURN_RESET:if(count==RESET_CYCLES-1)begin state<=RETURN_RELEASE;count<=0;reset_high<=1;end else count<=count+1'b1;
    RETURN_RELEASE:if(count==RELEASE_CYCLES-1)begin state<=IDLE;count<=0;end else count<=count+1'b1;
    default:begin state<=IDLE;reset_high<=1;end
   endcase
  end
 end
`ifndef SYNTHESIS
 initial if(RESET_CYCLES<1||RELEASE_CYCLES<1)$fatal(1,"NN launcher reset/release must be nonzero");
 always @(posedge clk)if(root_reset_n && state!=IDLE && state!=COMPLETE && state!=RETURN_RESET && state!=RETURN_RELEASE && !owner)
  $fatal(1,"Private NN ownership withdrawn before completion/drain");
`endif
endmodule
`default_nettype wire
