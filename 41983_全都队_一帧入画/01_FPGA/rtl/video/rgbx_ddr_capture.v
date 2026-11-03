`timescale 1ns/1ps
module rgbx_ddr_capture #(
    parameter LOCAL_PIXEL_RESET=0,
    parameter ENABLE_HOLD=0,
    parameter FRAME_PIXELS=307200,
    parameter NUM_SLOTS=2,
    parameter BURST_WORDS=16,
    parameter REQUIRE_NEW_FRAME=1,
    parameter FIFO_ADDR_WIDTH=10,
    parameter CONTROL_PIPELINE=0,
    parameter RGBX_FORMAT=0,
    parameter TIMEOUT_BITS=20,
    parameter BASE0=32'h02000000,
    parameter BASE1=32'h02200000,
    parameter BASE2=32'h02400000,
    parameter BASE3=32'h02c00000
)(
    input pixel_clk, input axi_clk, input rst_n, input cal_done, input pixel_rst_n,
    input [31:0] i_rgbx, input i_valid, input i_sof,
    input [31:0] i_frame_id, input i_frame_done, input i_frame_abort,
    input [NUM_SLOTS-1:0] release_slots,
    input hold,output hold_ack,output capture_idle,
    output [31:0] awaddr, output [7:0] awlen, output awvalid, input awready,
    output [127:0] wdata, output wlast, output wvalid, input wready,
    input [3:0] bid, input [1:0] bresp, input bvalid, output bready,
    output [31:0] araddr, output [7:0] arlen, output arvalid, input arready,
    input [3:0] rid, input [127:0] rdata, input [1:0] rresp,
    input rlast, input rvalid, output rready,
    output reg [NUM_SLOTS-1:0] slot_valid,
    output reg [31:0] slot0_frame_id, output reg [31:0] slot1_frame_id,output reg [31:0] slot2_frame_id,output reg [31:0] slot3_frame_id,
    output reg [31:0] commit_count, output reg commit_pulse,
    output reg [31:0] committed_addr,
    output reg [31:0] word_count, output reg [31:0] response_count,
    output reg [31:0] abort_count,
    output [7:0] error, output busy,
    output reg [31:0] skipped_frames
);
wire source_rst_n=LOCAL_PIXEL_RESET?pixel_rst_n:rst_n;
localparam WORDS=FRAME_PIXELS/4;
localparam BURSTS=WORDS/BURST_WORDS;
localparam BW=$clog2(BURST_WORDS);
localparam IDLE=0,FILL=1,AW=2,W=3,B=4,AR=5,R=6,DRAIN=7;
localparam DATA=2'd0,START=2'd1,END_OK=2'd2,END_BAD=2'd3;
reg [2:0] state;
reg [BW-1:0] fill_index,beat_index,read_index;
(* syn_ramstyle="block_ram" *) reg [127:0] burst_mem[0:BURST_WORDS-1];
reg [127:0] burst_q;
reg first_verified;
// Read ahead on an accepted beat. Hold current address during backpressure.
wire [BW-1:0] first_read_index=(state==R && rvalid && read_index!=BURST_WORDS-1)?read_index+1'b1:read_index;
wire [BW-1:0] burst_read_index=(state==AR || state==R)?first_read_index:((state==W && wready && beat_index!=BURST_WORDS-1)?beat_index+1'b1:beat_index);


reg [1:0] bank;reg frame_bad;
reg [1:0] free_bank;
integer free_index;
always @*begin
 free_bank=0;
 for(free_index=NUM_SLOTS-1;free_index>=0;free_index=free_index-1)
  if(!slot_valid[free_index])free_bank=free_index;
end
reg [31:0] frame_id,base_addr,burst_addr;
reg [6:0] axi_error;
reg [TIMEOUT_BITS-1:0] wait_cycles;
(* async_reg="true" *) reg [1:0] cal_sync,ready_sync,overflow_sync;
reg active,terminal_pending,terminal_bad,source_bad,overflow;
reg have_source_id;
reg [31:0] last_source_id;
reg [1:0] pack_index;
reg [95:0] pack_low;
wire hold_core=(ENABLE_HOLD!=0)&&hold;
(* async_reg="true" *) reg [2:0] hold_pixel_sync,hold_ack_sync;
reg hold_pixel_ack;
reg [31:0] source_id;
reg [31:0] source_pixels;
wire fifo_full,fifo_empty;
wire [129:0] fifo_data;
reg raw_read_pending,control_pending;
reg [1:0] kind_q;reg [31:0] id_q;
wire read_pending=CONTROL_PIPELINE?control_pending:raw_read_pending;
wire [1:0] decoded_kind=CONTROL_PIPELINE?kind_q:fifo_data[129:128];
wire [31:0] decoded_id=CONTROL_PIPELINE?id_q:fifo_data[31:0];
wire ready_core=state==IDLE && !raw_read_pending && !control_pending && fifo_empty && !hold_core &&
                cal_sync[1] && slot_valid!={NUM_SLOTS{1'b1}};
wire begin_frame=i_valid && i_sof && !active && !terminal_pending &&
                 ready_sync[1] && !hold_pixel_sync[2] && !fifo_full &&
                 (!REQUIRE_NEW_FRAME || !have_source_id || i_frame_id!=last_source_id);
wire emit_data=active && i_valid && !source_bad && pack_index==3;
wire fifo_we=!fifo_full && (terminal_pending || begin_frame || emit_data);
wire [129:0] fifo_input=terminal_pending ?
    {(terminal_bad ? END_BAD : END_OK),96'd0,source_id} :
    begin_frame ? {START,96'd0,i_frame_id} : {DATA,i_rgbx,pack_low};
wire fifo_re=!fifo_empty && !raw_read_pending && !control_pending &&
             (state==IDLE || state==FILL || state==DRAIN);
assign error={axi_error,overflow_sync[1]};
assign busy=state!=IDLE;
assign hold_ack=hold_core && hold_ack_sync[2];
assign capture_idle=state==IDLE && !raw_read_pending && !control_pending && fifo_empty;
// A hold prevents the NEXT SOF; the current frame and its END token finish.
// Source acknowledgement is delayed until the final token has been written.
// Independent core idle also requires FIFO/read-pipeline/AXI drain.
always @(posedge pixel_clk or negedge source_rst_n)begin
 if(!source_rst_n)begin hold_pixel_sync<=0;hold_pixel_ack<=0;end
 else begin
  hold_pixel_sync<={hold_pixel_sync[1:0],hold_core};
  hold_pixel_ack<=hold_pixel_sync[2] && !active && !terminal_pending;
 end
end
always @(posedge axi_clk or negedge rst_n)begin
 if(!rst_n)hold_ack_sync<=0;
 else hold_ack_sync<={hold_ack_sync[1:0],hold_pixel_ack};
end
assign awaddr=burst_addr; assign awlen=BURST_WORDS-1; assign awvalid=state==AW;
assign wdata=burst_q; assign wlast=beat_index==BURST_WORDS-1;
assign wvalid=state==W; assign bready=state==B;
assign araddr=base_addr; assign arlen=BURST_WORDS-1; assign arvalid=state==AR;
assign rready=state==R;

// RGBX_FORMAT: 0=arbitrary32-bit, 1=RGB8+zero pad, 2=RGB7+zero pad.
localparam FIFO_PAYLOAD=(RGBX_FORMAT==2)?84:(RGBX_FORMAT==1)?96:128;
wire [FIFO_PAYLOAD+1:0] fifo_encoded,fifo_compact;
wire [127:0] fifo_expanded;
generate if(RGBX_FORMAT!=0)begin:G_COMPACT_RGBX
 wire [FIFO_PAYLOAD-1:0] pixels;
 genvar pixel;
 for(pixel=0;pixel<4;pixel=pixel+1)begin:G_PIXEL
  if(RGBX_FORMAT==2)begin
   assign pixels[pixel*21+:21]={fifo_input[pixel*32+16+:7],fifo_input[pixel*32+8+:7],fifo_input[pixel*32+:7]};
   assign fifo_expanded[pixel*32+:32]={8'b0,1'b0,fifo_compact[pixel*21+14+:7],1'b0,fifo_compact[pixel*21+7+:7],1'b0,fifo_compact[pixel*21+:7]};
  end else begin
   assign pixels[pixel*24+:24]=fifo_input[pixel*32+:24];
   assign fifo_expanded[pixel*32+:32]={8'b0,fifo_compact[pixel*24+:24]};
  end
 end
 assign fifo_encoded={fifo_input[129:128],fifo_input[129:128]==DATA?pixels:{{(FIFO_PAYLOAD-32){1'b0}},fifo_input[31:0]}};
 assign fifo_data={fifo_compact[FIFO_PAYLOAD+:2],fifo_compact[FIFO_PAYLOAD+:2]==DATA?fifo_expanded:{96'b0,fifo_compact[31:0]}};
end else begin:G_FULL_RGBX
 assign fifo_encoded=fifo_input;
 assign fifo_expanded=0;
 assign fifo_data=fifo_compact;
end endgenerate
camera_style_async_fifo #(.DATA_WIDTH(FIFO_PAYLOAD+2),.ADDR_WIDTH(FIFO_ADDR_WIDTH))
u_stream_fifo (.i_arst(!rst_n),.i_wclk(pixel_clk),.i_we(fifo_we),
    .i_wdata(fifo_encoded),.i_rclk(axi_clk),.i_re(fifo_re),
    .o_full(fifo_full),.o_empty(fifo_empty),.o_rdata(fifo_compact));
`ifndef SYNTHESIS
initial begin
 if((BURST_WORDS!=16 && BURST_WORDS!=32) || FRAME_PIXELS%(4*BURST_WORDS)!=0)
  $fatal(1,"capture requires whole 16/32-beat packets");
 if((BASE0%(16*BURST_WORDS))!=0 || (BASE1%(16*BURST_WORDS))!=0 ||
    (BASE2%(16*BURST_WORDS))!=0 || (BASE3%(16*BURST_WORDS))!=0)
  $fatal(1,"capture base must be aligned to burst size for 4KiB safety");
end
always @(posedge pixel_clk)if(source_rst_n && i_valid)begin
 if(RGBX_FORMAT==2 && (i_rgbx & 32'hff808080)!=0)$fatal(1,"RGB7 capture input violates zero padding");
 if(RGBX_FORMAT==1 && i_rgbx[31:24]!=0)$fatal(1,"RGB8 capture input violates zero padding");
end
`endif

always @(posedge pixel_clk or negedge source_rst_n) begin
    if(!source_rst_n) begin
        ready_sync<=0;active<=0;terminal_pending<=0;terminal_bad<=0;
        source_bad<=0;overflow<=0;pack_index<=0;pack_low<=0;
        source_id<=0;source_pixels<=0;skipped_frames<=0;
        have_source_id<=0;last_source_id<=0;
    end else begin
        ready_sync<={ready_sync[0],ready_core};
        if(terminal_pending && !fifo_full) terminal_pending<=0;
        if(i_valid && i_sof) begin
            if(begin_frame) begin
                active<=1;source_bad<=0;source_id<=i_frame_id;
                have_source_id<=1;last_source_id<=i_frame_id;
                source_pixels<=1;pack_low[31:0]<=i_rgbx;pack_index<=1;
            end else skipped_frames<=skipped_frames+1'b1;
        end else if(active && i_valid) begin
            source_pixels<=source_pixels+1'b1;
            pack_index<=pack_index+1'b1;
            case(pack_index)
                0:pack_low[31:0]<=i_rgbx;
                1:pack_low[63:32]<=i_rgbx;
                2:pack_low[95:64]<=i_rgbx;
                3:if(fifo_full) begin source_bad<=1;overflow<=1;end
            endcase
            if(source_pixels>=FRAME_PIXELS) source_bad<=1;
        end
        if(active && (i_frame_done || i_frame_abort)) begin
            active<=0;terminal_pending<=1;
            terminal_bad<=source_bad || i_frame_abort ||
                          source_pixels!=FRAME_PIXELS || pack_index!=0;
        end
    end
end

wire progress=(state==AW && awready)||(state==W && wready)||
              (state==B && bvalid)||(state==AR && arready)||(state==R && rvalid);
wire reading_bad=rid!=0 || rresp!=0 ||
                 rdata!=burst_q || rlast!=(read_index==BURST_WORDS-1);
always @(posedge axi_clk)begin
 if(state==FILL && read_pending && decoded_kind==DATA && word_count<WORDS)begin
  burst_mem[fill_index]<=fifo_data[127:0];
 end
 // No asynchronous reset on RAM ports; valid states gate use of stale RAM data.
 burst_q<=burst_mem[burst_read_index];
end
always @(posedge axi_clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;cal_sync<=0;overflow_sync<=0;raw_read_pending<=0;control_pending<=0;kind_q<=0;id_q<=0;
        slot_valid<=0;slot0_frame_id<=0;slot1_frame_id<=0;slot2_frame_id<=0;slot3_frame_id<=0;
        commit_count<=0;commit_pulse<=0;committed_addr<=0;
        word_count<=0;response_count<=0;abort_count<=0;
        fill_index<=0;beat_index<=0;read_index<=0;
        bank<=0;frame_bad<=0;first_verified<=0;frame_id<=0;base_addr<=0;burst_addr<=0;
        axi_error<=0;wait_cycles<=0;
    end else begin
        cal_sync<={cal_sync[0],cal_done};
        overflow_sync<={overflow_sync[0],overflow};
        raw_read_pending<=fifo_re;
        control_pending<=CONTROL_PIPELINE?raw_read_pending:0;
        if(CONTROL_PIPELINE && raw_read_pending)begin
            kind_q<=fifo_data[129:128];id_q<=fifo_data[31:0];
        end
        commit_pulse<=0;
        slot_valid<=slot_valid & ~release_slots;
        if(state==AW || state==W || state==B || state==AR || state==R) begin
            if(progress) wait_cycles<=0;
            else if(&wait_cycles) begin axi_error[3]<=1;frame_bad<=1;end
            else wait_cycles<=wait_cycles+1'b1;
        end else wait_cycles<=0;
        // Timeout diagnoses failure, but never cancels an accepted AXI
        // transaction. Keep VALID/data stable until the slave responds.
        case(state)
        IDLE: if(read_pending) begin
            if(decoded_kind==START && cal_sync[1] && slot_valid!={NUM_SLOTS{1'b1}}) begin
                bank<=free_bank;
                base_addr<=free_bank==0?BASE0:free_bank==1?BASE1:free_bank==2?BASE2:BASE3;
                burst_addr<=free_bank==0?BASE0:free_bank==1?BASE1:free_bank==2?BASE2:BASE3;
                frame_id<=decoded_id;
                word_count<=0;response_count<=0;fill_index<=0;
                frame_bad<=0;first_verified<=0;state<=FILL;
            end else begin axi_error[2]<=1;state<=DRAIN;end
        end
        FILL: if(read_pending) begin
            case(decoded_kind)
            DATA: begin
                if(word_count>=WORDS) begin
                    axi_error[5]<=1;frame_bad<=1;state<=DRAIN;
                end else begin
                    if(fill_index==BURST_WORDS-1) begin
                        fill_index<=0;beat_index<=0;state<=AW;
                    end else fill_index<=fill_index+1'b1;
                end
            end
            END_OK,END_BAD: begin
                if(decoded_kind==END_BAD) axi_error[4]<=1;
                if(word_count!=WORDS || response_count!=BURSTS || fill_index!=0 ||
                   decoded_id!=frame_id) axi_error[5]<=1;
                if(decoded_kind==END_OK && !frame_bad &&
                   word_count==WORDS && response_count==BURSTS && fill_index==0 &&
                   decoded_id==frame_id && first_verified) begin
                    slot_valid[bank]<=1;
                    if(bank==0)slot0_frame_id<=frame_id;
                    else if(bank==1)slot1_frame_id<=frame_id;
                    else if(bank==2)slot2_frame_id<=frame_id;
                    else slot3_frame_id<=frame_id;
                    commit_count<=commit_count+1'b1;
                    commit_pulse<=1;committed_addr<=base_addr;state<=IDLE;
                end
                else begin abort_count<=abort_count+1'b1;state<=IDLE;end
            end
            default: begin axi_error[2]<=1;frame_bad<=1;state<=DRAIN;end
            endcase
        end
        AW: if(awready) state<=W;
        W: if(wready) begin
            word_count<=word_count+1'b1;
            if(beat_index==BURST_WORDS-1) state<=B;
            else beat_index<=beat_index+1'b1;
        end
        B: if(bvalid) begin
            response_count<=response_count+1'b1;
            if(bid!=0 || bresp!=0) begin axi_error[0]<=1;frame_bad<=1;end
            burst_addr<=burst_addr+16*BURST_WORDS;
            // Verify first DDR burst before reusing its staging RAM. Commit
            // still waits for the complete frame and every write response.
            if(response_count==0)begin read_index<=0;state<=AR;end
            else state<=FILL;
        end
        AR: if(arready) state<=R;
        R: if(rvalid) begin
            if(reading_bad) begin axi_error[1]<=1;frame_bad<=1;end
            if(rlast) begin
                first_verified<=!frame_bad && !reading_bad;
                state<=FILL;
            end else if(read_index!=BURST_WORDS-1) read_index<=read_index+1'b1;
        end
        DRAIN: if(read_pending && decoded_kind>=END_OK) begin
            abort_count<=abort_count+1'b1;state<=IDLE;
        end
        endcase
    end
end
endmodule
