`timescale 1ns/1ps
// Up to four original inputs and three results, paired by frame ID. Core domain only.
// Compute completion queues a result, but original input release waits for display drain.
module camera_nn_compare_pipeline #(
 // Strict mode changes the front only after its final visible pixel.
 // A ready result waits with the old immutable front still enabled.
 parameter integer FRAME_ATOMIC=0,
 parameter integer UKIYO_BOTTOM_EN=0,STYLE_TAG_EN=0,
 parameter integer CAT_FISHEYE_EN=0,WARP_OVERLAP=1,RUNTIME_FISHEYE=0,
 parameter [31:0] INPUT0=32'h02000000,INPUT1=32'h02200000,INPUT2=32'h02400000,INPUT3=32'h02c00000,
 parameter [31:0] WARP_OFFSET=32'h00100000,
 parameter [31:0] OUTPUT0=32'h06400000,OUTPUT1=32'h06600000,OUTPUT2=32'h06800000
)(
 input wire [2:0] current_model_id, input wire [1:0] roi_requested,
 output reg [1:0] display_roi_mode,
 output wire snapshot_ready,
 output reg [2:0] display_model_id,
 output reg display_fisheye_enable,output wire [2:0] warp_model_id,output wire warp_fisheye_enable,
 input wire fisheye_enable,
 output wire inference_idle,
 output reg warp_start,input wire warp_done,warp_pass,warp_fail,
 output wire [31:0] warp_source_base,warp_dest_base,
 input wire clk,rst_n,enable,req_valid,output wire req_ready,
 input wire [1:0] req_bank,input wire [31:0] req_addr,req_frame_id,
 output wire done_valid,input wire done_ready,output wire [1:0] done_bank,
 output wire [31:0] done_frame_id,output wire done_error,
 output reg nn_start,nn_reset_n,input wire nn_done,nn_pass,nn_fail,display_fault,
 output reg [31:0] nn_input_base,output wire [31:0] nn_output_base,
 output reg display_enable,output wire [31:0] display_base,display_input_base,
 output reg [1:0] display_buffer,output reg [31:0] display_frame_id,
 input wire frame_shown,quiescent,publication_window,output reg fault,output wire [12:0] debug_state
);
 localparam IDLE=0,START=1,RUN=2,COMPLETE=3,RESET=4,FAILED=5,STOP=6,WARP_START=7,WARP_RUN=8;
 reg [3:0] state;
 reg drain,ready_valid,front_valid;
 reg front_shown;
 reg [2:0] occupied;
 reg [1:0] output_buffer,ready_buffer,current_input,ready_input,front_input;
 reg [31:0] current_id,ready_id;
 reg [2:0] current_style,pending_style,warp_style,ready_style;
 reg [1:0] current_roi,pending_roi,warp_roi,ready_roi;
 reg current_warp,pending_warp,warp_warp,ready_warp,display_warp;
 reg current_fish,pending_fish,warp_fish,ready_fish;
 wire requested_warp=CAT_FISHEYE_EN!=0 && (RUNTIME_FISHEYE==0 || fisheye_enable);
 reg pending_valid;reg [1:0] pending_buffer,pending_input,warp_buffer,warp_input;
 reg [31:0] pending_id,warp_id,failure_id;reg [1:0] failure_input,warp_state;
 wire overlap=((CAT_FISHEYE_EN!=0 || UKIYO_BOTTOM_EN!=0) && WARP_OVERLAP!=0);
 assign warp_model_id=overlap?warp_style:current_style;
 assign warp_fisheye_enable=overlap?warp_fish:current_fish;
 // Serial/no-geometry profile has no warp/pending state registers.
 assign debug_state={(overlap?warp_state:2'b00),(overlap?pending_valid:1'b0),front_valid,ready_valid,drain,occupied,state};
 reg [4:0] reset_count;
 wire may_replace_front=!front_valid || frame_shown ||
     (FRAME_ATOMIC==0 && front_shown && publication_window);
 wire free_valid=!(&occupied);
 wire [1:0] free_buffer=!occupied[0]?0:!occupied[1]?1:2;
 assign inference_idle=(state==IDLE) && !nn_start;
 assign snapshot_ready=inference_idle && front_valid && front_shown && !ready_valid && !drain &&
     !fault && !display_fault && (!overlap || (!pending_valid && warp_state==0));
 assign req_ready=state==IDLE && enable && free_valid && !fault && !display_fault;
 assign done_valid=(state==FAILED) || (drain && quiescent && front_valid && !fault && !display_fault);
 assign done_error=state==FAILED;
 assign done_bank=(state==FAILED)?(overlap?failure_input:current_input):front_input;
 assign done_frame_id=(state==FAILED)?(overlap?failure_id:current_id):display_frame_id;
 assign nn_output_base=output_buffer==0?OUTPUT0:output_buffer==1?OUTPUT1:OUTPUT2;
 assign warp_source_base=overlap?(warp_buffer==0?OUTPUT0:warp_buffer==1?OUTPUT1:OUTPUT2):nn_output_base;
 assign warp_dest_base=warp_source_base+WARP_OFFSET;
 assign display_base=(display_buffer==0?OUTPUT0:display_buffer==1?OUTPUT1:OUTPUT2)+(((RUNTIME_FISHEYE!=0 || UKIYO_BOTTOM_EN!=0)?display_warp:CAT_FISHEYE_EN!=0)?WARP_OFFSET:32'd0);
 assign display_input_base=front_input==0?INPUT0:front_input==1?INPUT1:front_input==2?INPUT2:INPUT3;
 generate if((CAT_FISHEYE_EN!=0 || UKIYO_BOTTOM_EN!=0) && WARP_OVERLAP!=0)begin : G_OVERLAP
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   current_style<=0;pending_style<=0;warp_style<=0;ready_style<=0;display_model_id<=0;
   current_roi<=0;pending_roi<=0;warp_roi<=0;ready_roi<=0;display_roi_mode<=0;
   current_fish<=0;pending_fish<=0;warp_fish<=0;ready_fish<=0;display_fisheye_enable<=0;
   current_warp<=0;pending_warp<=0;warp_warp<=0;ready_warp<=0;display_warp<=0;
   state<=IDLE;drain<=0;ready_valid<=0;front_valid<=0;front_shown<=0;occupied<=0;
   output_buffer<=0;ready_buffer<=0;current_input<=0;ready_input<=0;front_input<=0;
   current_id<=0;ready_id<=0;reset_count<=0;nn_input_base<=0;display_buffer<=0;display_frame_id<=0;display_enable<=0;
   warp_start<=0;nn_start<=0;nn_reset_n<=1;fault<=0;pending_valid<=0;pending_buffer<=0;pending_input<=0;pending_id<=0;
   warp_buffer<=0;warp_input<=0;warp_id<=0;warp_state<=0;failure_id<=0;failure_input<=0;
  end else begin
   nn_start<=0;warp_start<=0;
   if(frame_shown && display_enable)front_shown<=1;
   if(display_fault)begin fault<=1;display_enable<=0;state<=STOP;end
   else if(!fault)begin
    case(state)
     IDLE:if(req_valid&&req_ready)begin current_roi<=roi_requested;current_fish<=requested_warp;current_warp<=requested_warp;output_buffer<=free_buffer;occupied[free_buffer]<=1;
      nn_input_base<=req_addr;current_input<=req_bank;current_id<=req_frame_id;state<=START;end
     START:begin if(UKIYO_BOTTOM_EN!=0)current_warp<=current_fish || current_model_id==2;current_style<=STYLE_TAG_EN!=0?current_model_id:0;nn_start<=1;state<=RUN;end
     RUN:if(nn_done||nn_fail)begin
      if(!nn_pass||nn_fail)begin failure_input<=current_input;failure_id<=current_id;display_enable<=0;state<=FAILED;end
      else state<=COMPLETE;
     end
     COMPLETE:if(!pending_valid)begin
      pending_valid<=1;pending_roi<=current_roi;pending_fish<=current_fish;pending_style<=current_style;pending_warp<=current_warp;pending_buffer<=output_buffer;pending_input<=current_input;pending_id<=current_id;
      nn_reset_n<=0;reset_count<=0;state<=RESET;
     end
     RESET:if(reset_count==15)begin nn_reset_n<=1;state<=IDLE;end else reset_count<=reset_count+1'b1;
     FAILED:if(done_valid&&done_ready)begin fault<=1;display_enable<=0;state<=STOP;end
     STOP:nn_start<=0;
     default:begin fault<=1;display_enable<=0;state<=STOP;end
    endcase
    // Completed NN frames retain their occupied DDR slot until the warp and display drain.
    if(state!=FAILED&&state!=STOP&&!(state==RUN&&(nn_done||nn_fail)&&(!nn_pass||nn_fail)))begin
     case(warp_state)
      0:if(pending_valid)begin
       warp_roi<=pending_roi;warp_fish<=pending_fish;warp_style<=pending_style;warp_warp<=pending_warp;warp_buffer<=pending_buffer;warp_input<=pending_input;warp_id<=pending_id;pending_valid<=0;warp_state<=pending_warp?1:3;
      end
      1:begin warp_start<=1;warp_state<=2;end
      2:if(warp_done||warp_fail)begin
       if(!warp_pass||warp_fail)begin failure_input<=warp_input;failure_id<=warp_id;display_enable<=0;state<=FAILED;end
       else warp_state<=3;
      end
      3:if(!ready_valid)begin ready_valid<=1;ready_roi<=warp_roi;ready_fish<=warp_fish;ready_style<=warp_style;ready_warp<=warp_warp;ready_buffer<=warp_buffer;ready_input<=warp_input;ready_id<=warp_id;warp_state<=0;end
     endcase
    end
    if(state!=FAILED&&state!=STOP&&!(state==RUN&&(nn_done||nn_fail)&&(!nn_pass||nn_fail))&&
       !(warp_state==2&&(warp_done||warp_fail)&&(!warp_pass||warp_fail)))begin
     if(!drain)begin if(ready_valid&&may_replace_front)begin display_enable<=0;drain<=1;end end
     else if(quiescent&&(!front_valid||(done_valid&&done_ready)))begin
      if(front_valid)occupied[display_buffer]<=0;
      display_roi_mode<=ready_roi;display_fisheye_enable<=ready_fish;display_model_id<=ready_style;display_warp<=ready_warp;display_buffer<=ready_buffer;front_input<=ready_input;display_frame_id<=ready_id;
      ready_valid<=0;front_valid<=1;front_shown<=0;display_enable<=1;drain<=0;
     end
    end
   end else begin nn_start<=0;display_enable<=0;end
  end
 end
 end else begin : G_SERIAL
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   current_style<=0;pending_style<=0;warp_style<=0;ready_style<=0;display_model_id<=0;
   current_roi<=0;pending_roi<=0;warp_roi<=0;ready_roi<=0;display_roi_mode<=0;
   current_fish<=0;pending_fish<=0;warp_fish<=0;ready_fish<=0;display_fisheye_enable<=0;
   current_warp<=0;pending_warp<=0;warp_warp<=0;ready_warp<=0;display_warp<=0;
   state<=IDLE;drain<=0;ready_valid<=0;front_valid<=0;front_shown<=0;occupied<=0;
   output_buffer<=0;ready_buffer<=0;current_input<=0;ready_input<=0;front_input<=0;
   current_id<=0;ready_id<=0;reset_count<=0;nn_input_base<=0;
   display_buffer<=0;display_frame_id<=0;display_enable<=0;
   warp_start<=0;nn_start<=0;nn_reset_n<=1;fault<=0;
  end else begin
   nn_start<=0;warp_start<=0;
   if(frame_shown && display_enable)front_shown<=1;
   if(display_fault)begin fault<=1;display_enable<=0;state<=STOP;end
   else if(!fault)begin
    case(state)
     IDLE:if(req_valid && req_ready)begin
      current_roi<=roi_requested;current_fish<=requested_warp;current_warp<=requested_warp;output_buffer<=free_buffer;occupied[free_buffer]<=1;
      nn_input_base<=req_addr;current_input<=req_bank;current_id<=req_frame_id;state<=START;
     end
     START:begin if(UKIYO_BOTTOM_EN!=0)current_warp<=current_fish || current_model_id==2;current_style<=STYLE_TAG_EN!=0?current_model_id:0;nn_start<=1;state<=RUN;end
     RUN:if(nn_done || nn_fail)begin
      if(!nn_pass || nn_fail)begin display_enable<=0;state<=FAILED;end
      else state<=current_warp?WARP_START:COMPLETE;
     end
     WARP_START:begin warp_start<=1;state<=WARP_RUN;end
     WARP_RUN:if(warp_done || warp_fail)begin
      if(!warp_pass || warp_fail)begin display_enable<=0;state<=FAILED;end
      else state<=COMPLETE;
     end
     COMPLETE:if(!ready_valid)begin
      ready_valid<=1;ready_roi<=current_roi;ready_fish<=current_fish;ready_style<=current_style;ready_warp<=current_warp;ready_buffer<=output_buffer;ready_input<=current_input;ready_id<=current_id;
      nn_reset_n<=0;reset_count<=0;state<=RESET;
     end
     RESET:if(reset_count==15)begin nn_reset_n<=1;state<=IDLE;end
           else reset_count<=reset_count+1'b1;
     FAILED:if(done_valid && done_ready)begin fault<=1;display_enable<=0;state<=STOP;end
     STOP:begin nn_start<=0;display_enable<=0;end
     default:begin fault<=1;display_enable<=0;state<=STOP;end
    endcase
    if(state!=FAILED && state!=STOP &&
       !(state==RUN && (nn_done || nn_fail) && (!nn_pass || nn_fail)) &&
       !(state==WARP_RUN && (warp_done || warp_fail) && (!warp_pass || warp_fail)))begin
     if(!drain)begin
      if(ready_valid && may_replace_front)begin display_enable<=0;drain<=1;end
     end else if(quiescent && (!front_valid || (done_valid && done_ready)))begin
      // Only now may acquisition overwrite the old comparison's original input.
      if(front_valid)occupied[display_buffer]<=0;
      display_roi_mode<=ready_roi;display_fisheye_enable<=ready_fish;display_model_id<=ready_style;display_warp<=ready_warp;display_buffer<=ready_buffer;front_input<=ready_input;display_frame_id<=ready_id;
      ready_valid<=0;front_valid<=1;front_shown<=0;display_enable<=1;drain<=0;
     end
    end
   end else begin nn_start<=0;display_enable<=0;end
  end
 end
 end endgenerate
endmodule

// Up to four simultaneous immutable loans; stale or failed completion never releases.
module rgbx_input_slot_handoff3 #(
 parameter integer NUM_SLOTS=3,LATEST_ONLY=0,
 parameter [31:0] BASE0=32'h02000000,BASE1=32'h02200000,BASE2=32'h02400000,BASE3=32'h02c00000
)(
 input wire clk,rst_n,input wire [NUM_SLOTS-1:0] slot_valid,
 input wire [31:0] slot0_frame_id,slot1_frame_id,slot2_frame_id,slot3_frame_id,
 output wire req_valid,input wire req_ready,output reg [1:0] req_bank,
 output reg [31:0] req_addr,req_frame_id,input wire done_valid,
 output wire done_ready,input wire [1:0] done_bank,input wire [31:0] done_frame_id,
 input wire done_error,output reg [NUM_SLOTS-1:0] release_slots,
 output wire busy,output reg [2:0] error,
 output reg [31:0] accepted_count,released_count,failed_count,dropped_count
);
 reg [NUM_SLOTS-1:0] loaned,release_wait;
 reg pending;
 // Slot reuse does not preserve chronological order. Compare frame IDs,
 // modulo wrap, rather than selecting the next physical slot in a ring.
 wire [NUM_SLOTS-1:0] available=slot_valid & ~loaned & ~release_wait;
 wire a3=(NUM_SLOTS==4)?available[NUM_SLOTS-1]:1'b0;
 wire older01=$signed(slot0_frame_id-slot1_frame_id)<0;
 wire older23=$signed(slot2_frame_id-slot3_frame_id)<0;
 wire prefer01=LATEST_ONLY!=0?!older01:older01;
 wire prefer23=LATEST_ONLY!=0?!older23:older23;
 wire left_valid=|available[1:0];
 wire right_valid=available[2] || a3;
 wire [1:0] left_bank=available[0] && (!available[1] || prefer01)?0:1;
 wire [1:0] right_bank=available[2] && (!a3 || prefer23)?2:3;
 // Compare all cross-pairs in parallel. Selecting one-bit ordering results
 // avoids cascading two full32-bit subtractors through a32-bit ID mux.
 // Modulo-wrap ordering and the original tie decisions are unchanged.
 wire older02=$signed(slot0_frame_id-slot2_frame_id)<0;
 wire older03=$signed(slot0_frame_id-slot3_frame_id)<0;
 wire older12=$signed(slot1_frame_id-slot2_frame_id)<0;
 wire older13=$signed(slot1_frame_id-slot3_frame_id)<0;
 wire older_lr=left_bank==0?(right_bank==2?older02:older03):
                              (right_bank==2?older12:older13);
 wire prefer_lr=LATEST_ONLY!=0?!older_lr:older_lr;
 wire [1:0] chosen=left_valid && (!right_valid || prefer_lr)?left_bank:right_bank;
 wire [NUM_SLOTS-1:0] chosen_mask={{(NUM_SLOTS-1){1'b0}},1'b1}<<chosen;
 // Discard only complete, unloaned stale frames. Never touch an in-flight
 // request, current NN input, or either original retained by the display.
 wire [NUM_SLOTS-1:0] stale_mask=(LATEST_ONLY!=0 && !pending)?available & ~chosen_mask:0;
 wire [2:0] stale_count=(NUM_SLOTS==4)?
   ({2'd0,stale_mask[0]}+{2'd0,stale_mask[1]}+{2'd0,stale_mask[2]}+{2'd0,stale_mask[NUM_SLOTS-1]}):
   ({2'd0,stale_mask[0]}+{2'd0,stale_mask[1]}+{2'd0,stale_mask[2]});
 reg [2:0] dropped_increment;
 function [31:0] slot_id(input [1:0] index);
  case(index)
   0:slot_id=slot0_frame_id;1:slot_id=slot1_frame_id;
   2:slot_id=slot2_frame_id;default:slot_id=slot3_frame_id;
  endcase
 endfunction
 wire [31:0] completion_id=done_bank==0?slot0_frame_id:done_bank==1?slot1_frame_id:done_bank==2?slot2_frame_id:slot3_frame_id;
 assign req_valid=pending;
 assign done_ready=done_bank<NUM_SLOTS && loaned[done_bank] && slot_valid[done_bank];
 assign busy=|loaned;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   loaned<=0;release_wait<=0;pending<=0;
   req_bank<=0;req_addr<=0;req_frame_id<=0;release_slots<=0;error<=0;
   accepted_count<=0;released_count<=0;failed_count<=0;dropped_count<=0;dropped_increment<=0;
  end else begin
   release_slots<=stale_mask;release_wait<=(release_wait & slot_valid) | stale_mask;
   // Telemetry may lag the release pulse by one clock; ownership and release
   // decisions keep their original cycle. Do not cascade selection and the
   // wide diagnostic accumulator into one timing path.
   dropped_increment<=stale_count;
   if(dropped_increment!=0)dropped_count<=dropped_count+dropped_increment;
   // The scheduler's READY is independent of VALID. Wait until it can
   // consume a frame before latching the newest descriptor; once latched,
   // preserve normal valid/ready stability even if READY subsequently falls.
   if(!pending && available!=0 && (LATEST_ONLY==0 || req_ready))begin
    req_bank<=chosen;req_addr<=chosen==0?BASE0:chosen==1?BASE1:chosen==2?BASE2:BASE3;
    req_frame_id<=slot_id(chosen);pending<=1;
   end
   if(pending && !slot_valid[req_bank])begin error[2]<=1;pending<=0;end
   else if(req_valid && req_ready)begin
    loaned[req_bank]<=1;pending<=0;
    accepted_count<=accepted_count+1'b1;
   end
   if(done_valid && done_ready)begin
    if(done_frame_id!=completion_id)error[0]<=1;
    else if(done_error)begin error[1]<=1;failed_count<=failed_count+1'b1;end
    else begin
     loaned[done_bank]<=0;release_wait[done_bank]<=1;
     release_slots[done_bank]<=1'b1;released_count<=released_count+1'b1;
    end
   end
  end
 end
endmodule
