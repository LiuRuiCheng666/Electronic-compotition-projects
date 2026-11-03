`timescale 1ns/1ps
`default_nettype none
// Immutable checked DDR RGB frame, two small asynchronous line banks.
// Bundled request row/bank remains stable until the completion toggle crosses
// back. First visible frame starts only after row zero has been prefetched.
module nn_ddr_picture_display #(
    parameter integer SERIAL_CACHE_WRITE=0,VIEW_MODES=0,PACKED_LINE_RAM=0,
    parameter integer ROI_ENABLE=0,LOCAL_PIXEL_RESET=0,UKIYO_BOTTOM_EN=0,
    parameter [31:0] WARP_OFFSET=32'h00400000,
    parameter integer DECIMATE_X=1,LINE_BANKS=3,
    parameter integer ORIGINAL_BOX_FILTER=0,
    parameter integer ORIGINAL_VERTICAL_FILTER=0,
    parameter integer MATCHED_VERTICAL_FILTER=0,
    parameter integer PARALLEL_UNPACK=0,RUNTIME_BASE=0,COMPARE_MODE=0,RECOVER_UNDERFLOW=0,
    parameter integer W=640,H=480,SCALE=2,TIMEOUT_BITS=20,
    parameter integer ZOOM_NUM=1,ZOOM_DEN=1,
    parameter integer CAT_WIDE_STRENGTH=0,
    parameter integer MAX_BURST_BEATS=(COMPARE_MODE!=0)?64:(PARALLEL_UNPACK!=0)?16:256,
    parameter integer DW=1920,DH=1080,HT=2200,VT=1125,
    parameter integer HS_BEGIN=2008,HS_END=2052,VS_BEGIN=1084,VS_END=1089,
    parameter [31:0] BASE_ADDR=32'h0300_0000
)(
    input wire clk,pixel_clk,rst_n,enable,pixel_rst_n,
    input wire [2:0] runtime_style,input wire runtime_fisheye,
    input wire [1:0] runtime_roi,
    // Pixel-clock request: 0 compare, 1 original full, 2 styled full.
    input wire [1:0] runtime_view,output wire [1:0] active_view,
    input wire [31:0] runtime_base, runtime_original_base,
    output wire [7:0] red,green,blue,
    output wire hs,vs,de,
    output wire fault,output wire [1:0] fault_detail,
    output wire [15:0] underflow_total,last_underflow_row,
    // Pixel-domain saturating counters: {partial_frames, blank_frames}.
    // Count every HDMI raster after the first picture has appeared, including
    // failed launch with no row underflow. This is a held-snapshot payload.
    output wire [31:0] frame_quality,
    output wire [5:0] debug_state,
    output wire quiescent,
    output wire read_urgent,
    output wire read_critical,
    output wire frame_shown,
    output wire publication_window,
    output reg [31:0] araddr, output wire [7:0] arlen,
    output wire arvalid,input wire arready,
    input wire [127:0] rdata,input wire [1:0] rresp,
    input wire rlast,rvalid,output wire rready
);
    wire local_pixel_rst_n=LOCAL_PIXEL_RESET?pixel_rst_n:rst_n;
    reg hs_raw,vs_raw,de_raw;
    localparam integer DISPLAY_W=(COMPARE_MODE!=0)?2*W:W;
    localparam integer BANK_W=$clog2(LINE_BANKS);
    localparam integer ROW_W=(H<2)?1:$clog2(H);
    localparam integer LANES=(COMPARE_MODE!=0)?2:1, MEM_W=DISPLAY_W/(LANES*DECIMATE_X), MEM_BITS=24*LANES;
    localparam integer AW=$clog2(MEM_W),ROW_BYTES=W*3,ROW_BEATS=ROW_BYTES/16;
    reg original_part;
    reg [1:0] view_frame,req_view,req_roi,view_core,roi_core,quarter_core;
    reg mode_draining;
    wire full_pixel=(VIEW_MODES!=0 && view_frame!=0);
    wire full_core=(VIEW_MODES!=0 && view_core!=0);
    assign active_view=(VIEW_MODES!=0)?view_frame:2'd0;
    function full_original;
        input [1:0] view_mode,roi,quarter;
        input [15:0] source_row;
        begin
            full_original=(view_mode==1) ||
                (roi==1 && (source_row<H/4 || source_row>=H*3/4 || quarter==0 || quarter==3)) ||
                (roi==2 && quarter>=2) || (roi==3 && quarter<2);
        end
    endfunction
    wire next_full_original=full_original(view_core,roi_core,quarter_core+2'd1,row_core);
    localparam integer ORIGINAL_UNIT=(SERIAL_CACHE_WRITE!=0)?4:8;
    localparam integer STYLE_UNIT=(SERIAL_CACHE_WRITE!=0)?3:6;
    reg cache_half;
    reg [23:0] cache_first_rgb;
    wire [4:0] pixel_bytes=(COMPARE_MODE!=0)?(original_part?(full_core?ORIGINAL_UNIT:ORIGINAL_UNIT*DECIMATE_X):(full_core?STYLE_UNIT:STYLE_UNIT*DECIMATE_X)):3;
    localparam integer ROW_STEP=(DECIMATE_X==2)?2:(ZOOM_DEN>SCALE*ZOOM_NUM)?ZOOM_DEN/(SCALE*ZOOM_NUM):1;
    localparam integer IMAGE_W=DISPLAY_W*SCALE*ZOOM_NUM/ZOOM_DEN;
    localparam integer IMAGE_H=H*SCALE*ZOOM_NUM/ZOOM_DEN;
    localparam integer X0=(DW-IMAGE_W)/2,Y0=(DH-IMAGE_H)/2;
    wire [11:0] image_w=full_pixel?DW:IMAGE_W;
    wire [11:0] image_h=full_pixel?DH:IMAGE_H;
    wire [11:0] image_x0=full_pixel?0:X0;
    wire [11:0] image_y0=full_pixel?0:Y0;
    wire [15:0] row_step=full_pixel?1:ROW_STEP;
    reg [ROW_W-1:0] display_row;
    (* syn_ramstyle="block_ram" *) reg [MEM_BITS-1:0] line0[0:MEM_W-1],line1[0:MEM_W-1],line2[0:MEM_W-1];
    reg req_toggle;reg [BANK_W-1:0] req_bank;
    reg [ROW_W-1:0] req_row;
    reg ack_toggle;
    wire critical_pixel;
    reg core_fault;
    reg [2:0] diagnostic_reason;
    (* async_reg="true", syn_preserve=1 *) reg critical_meta;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] critical_sync;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin critical_meta<=1;critical_sync<=3;end
        else begin critical_meta<=critical_pixel;critical_sync<={critical_sync[0],critical_meta};end
    end
    // Keep the emergency reservation across the row-request CDC round trip.
    // Dropping it when state becomes idle lets a long NN burst take the gap.
    assign read_critical=(COMPARE_MODE!=0) && enable && !core_fault && critical_sync[1];
    // Named first stages let the SDC cut only the metastability inputs.
    (* async_reg="true", syn_preserve=1 *) reg req_meta,ack_meta,en_meta,err_meta;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] req_sync,ack_sync,en_sync,err_sync;
    // Bundled payload is held until ack. Preserve this core-side boundary:
    // address arithmetic must not be retimed into the pixel clock domain.
    (* syn_preserve=1, syn_keep=1 *) reg [ROW_W-1:0] row_core;
    // Common VGA strides use one add/subtract, rather than a DSP input
    // register that synthesis may absorb across the bundled-data boundary.
    function [31:0] display_row_offset;
        input [15:0] row;
        input integer stride_bytes;
        reg [31:0] wide_row;
        begin
            wide_row={16'd0,row};
            case(stride_bytes)
                1920:display_row_offset=(wide_row<<11)-(wide_row<<7);
                3840:display_row_offset=(wide_row<<12)-(wide_row<<8);
                5120:display_row_offset=(wide_row<<12)+(wide_row<<10);
                2560:display_row_offset=(wide_row<<11)+(wide_row<<9);
                default:display_row_offset=wide_row*stride_bytes;
            endcase
        end
    endfunction
    reg [2:0] state;
    assign debug_state={diagnostic_reason,state};
    (* syn_preserve=1 *) reg [BANK_W-1:0] bank;
    reg [15:0] remaining,burst_left;
    reg [215:0] shift_data;
    reg [31:0] frame_base_core;
    reg [31:0] original_base_core;
    reg mixed_source_core;
    // req_row crosses only into row_core under the existing bundled-data
    // request handshake. Region decoding then runs entirely in core_clk.
    wire [31:0] resolved_frame_base=frame_base_core-
        ((mixed_source_core && row_core>=((H*54/100+7)/8)*8 &&
          row_core<((H*80/100)/8)*8)?WARP_OFFSET:32'd0);
    reg unpack;
    reg [4:0] bytes_left;
    reg [1:0] component;
    reg [7:0] saved_r,saved_g;
    reg [AW-1:0] write_col;
    reg [TIMEOUT_BITS-1:0] watchdog;
    wire [8:0] boundary_beats=(13'd4096-{1'b0,araddr[11:0]})>>4;
    wire [15:0] boundary_chunk=(remaining<boundary_beats)?remaining:boundary_beats;
    wire [15:0] chunk=boundary_chunk<MAX_BURST_BEATS?boundary_chunk:MAX_BURST_BEATS;
    assign arlen=chunk-1'b1;
    assign arvalid=(state==1)&&!core_fault;
    assign read_urgent=(COMPARE_MODE!=0) && enable && !core_fault &&
                       (state!=0 || req_sync[1]!=ack_toggle);
    assign rready=(state==2)&&((PARALLEL_UNPACK!=0)?((COMPARE_MODE!=0)?({1'b0,bytes_left}<({1'b0,pixel_bytes}<<1)):(bytes_left<pixel_bytes)):!unpack)&&(burst_left!=0);
    wire consume_pixel=(PARALLEL_UNPACK!=0)?(state==2 && bytes_left>=pixel_bytes):(unpack && component==2);
    wire write_pixel=(SERIAL_CACHE_WRITE!=0)?(consume_pixel && cache_half):consume_pixel;
    // Each decimated pair consumes four source pixels, keeping pixels0 and2.
    // Full source rows remain burst-read; only display cache pixels are reduced.
    wire [47:0] original_box;
    genvar box_lane,box_channel;
    generate for(box_lane=0;box_lane<2;box_lane=box_lane+1)begin:G_ORIGINAL_BOX
     for(box_channel=0;box_channel<3;box_channel=box_channel+1)begin:G_CHANNEL
      // RGBX stores unsigned RGB7. Sum adjacent source pixels to obtain
      // their mean in RGB8, instead of discarding every other pixel.
      assign original_box[box_lane*24+box_channel*8+:8]=
       {1'b0,shift_data[box_lane*64+box_channel*8+:7]}+
       {1'b0,shift_data[box_lane*64+32+box_channel*8+:7]};
     end
    end endgenerate
    wire [23:0] serial_rgb=original_part?
        ((ORIGINAL_BOX_FILTER!=0 && DECIMATE_X==2 && !full_core)?original_box[23:0]:
         {shift_data[22:16],1'b0,shift_data[14:8],1'b0,shift_data[6:0],1'b0}):shift_data[23:0];
    wire [MEM_BITS-1:0] write_rgb=(SERIAL_CACHE_WRITE!=0)?{serial_rgb,cache_first_rgb}:
        (COMPARE_MODE!=0 && original_part)?
        ((ORIGINAL_BOX_FILTER!=0 && DECIMATE_X==2 && !full_core)?original_box:
        ((DECIMATE_X==2 && !full_core)?
        {shift_data[86:80],1'b0,shift_data[78:72],1'b0,shift_data[70:64],1'b0,
         shift_data[22:16],1'b0,shift_data[14:8],1'b0,shift_data[6:0],1'b0}:
        {shift_data[54:48],1'b0,shift_data[46:40],1'b0,shift_data[38:32],1'b0,
         shift_data[22:16],1'b0,shift_data[14:8],1'b0,shift_data[6:0],1'b0})):
        (PARALLEL_UNPACK!=0)?((DECIMATE_X==2 && !full_core)?{shift_data[71:48],shift_data[23:0]}:shift_data[MEM_BITS-1:0]):{shift_data[7:0],saved_g,saved_r};
    // One consumption leaves at most 15 valid bytes in the reservoir.
    // Drop guaranteed-zero high 96 bits before the four-way shift mux.
    // Refill still retains all 27 bytes across AXI/burst boundaries.
    wire [119:0] shifted_low=(SERIAL_CACHE_WRITE!=0)?
        ((DECIMATE_X==2 && !full_core)?(original_part?(shift_data>>64):(shift_data>>48)):
         (original_part?(shift_data>>32):(shift_data>>24))):
        (COMPARE_MODE!=0)?
        ((DECIMATE_X==2 && !full_core)?(original_part?(shift_data>>128):(shift_data>>96)):
                            (original_part?(shift_data>>64):(shift_data>>48))):
        (shift_data>>24);
    wire [215:0] shifted_pixels={96'd0,shifted_low};
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && consume_pixel && bytes_left>pixel_bytes+15)
        $fatal(1,"pixel reservoir consumption would discard valid bytes");
`endif
    wire [215:0] consumed_data=(COMPARE_MODE!=0 && consume_pixel)?shifted_pixels:shift_data;
    wire [4:0] refill_carry=(COMPARE_MODE!=0 && consume_pixel)?bytes_left-pixel_bytes:bytes_left;
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && SERIAL_CACHE_WRITE!=0 && rvalid && rready && refill_carry>4)
        $fatal(1,"single-pixel refill exceeds 20-byte reservoir bound");
`endif
    reg [215:0] refill_data;
    generate if(SERIAL_CACHE_WRITE!=0)begin:G_SERIAL_REFILL
    // With source steps {3,4,6,8}, 16-byte AXI beats leave carry {0..4}.
    // All upper 56 bits are therefore constant zero, not another wide mux.
    // Same byte concatenation as the five-way case, arranged as a regular
    // byte barrel shift to reduce high-fanout data mux wiring. No cycle added.
    wire [2:0] carry_bytes=(refill_carry<4)?refill_carry[2:0]:3'd4;
    wire [159:0] aligned_read={32'd0,rdata} << {carry_bytes,3'b0};
    wire [31:0] carry_data={
        (carry_bytes>=4)?consumed_data[31:24]:8'd0,
        (carry_bytes>=3)?consumed_data[23:16]:8'd0,
        (carry_bytes>=2)?consumed_data[15:8]:8'd0,
        (carry_bytes>=1)?consumed_data[7:0]:8'd0};
    always @* refill_data={56'd0,aligned_read | {128'd0,carry_data}};
    end else begin:G_PAIR_REFILL
    always @* case(refill_carry)
      0:refill_data={ 88'd0,rdata};
      1:refill_data={ 80'd0,rdata,consumed_data[7:0]};
      2:refill_data={ 72'd0,rdata,consumed_data[15:0]};
      3:refill_data={ 64'd0,rdata,consumed_data[23:0]};
      4:refill_data={ 56'd0,rdata,consumed_data[31:0]};
      5:refill_data={ 48'd0,rdata,consumed_data[39:0]};
      6:refill_data={ 40'd0,rdata,consumed_data[47:0]};
      7:refill_data={ 32'd0,rdata,consumed_data[55:0]};
      8:refill_data={ 24'd0,rdata,consumed_data[63:0]};
      9:refill_data={ 16'd0,rdata,consumed_data[71:0]};
      10:refill_data={ 8'd0,rdata,consumed_data[79:0]};
      default:refill_data={rdata,consumed_data[87:0]};
    endcase
    end endgenerate
    // RAM write port must not carry reset. The inactive bank alone is written.
    always @(posedge clk) begin
        if(PACKED_LINE_RAM==0 && write_pixel && bank==0)
            line0[write_col]<=write_rgb;
        if(PACKED_LINE_RAM==0 && write_pixel && bank==1)
            line1[write_col]<=write_rgb;
        if(PACKED_LINE_RAM==0 && COMPARE_MODE!=0 && write_pixel && bank==2)line2[write_col]<=write_rgb;
    end
    generate if(PARALLEL_UNPACK==0) begin : G_BYTE_UNPACK
    always @* diagnostic_reason=0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            req_meta<=0;req_sync<=0;ack_toggle<=0;state<=0;bank<=0;row_core<=0;
            remaining<=0;burst_left<=0;shift_data<=0;unpack<=0;
            bytes_left<=0;component<=0;saved_r<=0;saved_g<=0;
            write_col<=0;core_fault<=0;araddr<=BASE_ADDR;frame_base_core<=BASE_ADDR;original_base_core<=0;mixed_source_core<=0;watchdog<=0;
        end else begin
            req_meta<=req_toggle;
            req_sync<={req_sync[0],req_meta};
            if(state==0 || unpack || (arvalid&&arready) || (rvalid&&rready)) watchdog<=0;
            else begin
                watchdog<=watchdog+1'b1;
                if(&watchdog) core_fault<=1;
            end
            case(state)
                0: if(req_sync[1]!=ack_toggle && !core_fault) begin
                    bank<=req_bank;row_core<=req_row;frame_base_core<=(RUNTIME_BASE!=0)?runtime_base:BASE_ADDR;original_base_core<=runtime_original_base;mixed_source_core<=RUNTIME_BASE!=0 && UKIYO_BOTTOM_EN!=0 && runtime_style==2 && !runtime_fisheye;
                    remaining<=ROW_BEATS;component<=0;write_col<=0;state<=3;
                end
                3: begin araddr<=resolved_frame_base+display_row_offset(row_core,ROW_BYTES);state<=1;end
                1: if(arready&&arvalid) begin burst_left<=chunk;state<=2;end
                2: begin
                    if(rvalid && rready) begin
                        if(rresp!=0 || rlast!=(burst_left==1)) core_fault<=1;
                        shift_data<=rdata;bytes_left<=16;unpack<=1;
                        burst_left<=burst_left-1'b1;
                        remaining<=remaining-1'b1;araddr<=araddr+16;
                    end
                    if(!unpack && burst_left==0) begin
                        if(remaining==0) begin ack_toggle<=req_sync[1];state<=0;end
                        else state<=core_fault?0:1;
                    end
                end
                default: state<=0;
            endcase
            if(unpack) begin
                shift_data<=shift_data>>8;
                bytes_left<=bytes_left-1'b1;
                if(bytes_left==1) unpack<=0;
                case(component)
                    0:begin saved_r<=shift_data[7:0];component<=1;end
                    1:begin saved_g<=shift_data[7:0];component<=2;end
                    2:begin component<=0;if(write_col<W-1) write_col<=write_col+1'b1;end
                endcase
            end
        end
    end
    end else begin : G_PIXEL_UNPACK
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) diagnostic_reason<=0;
        else if(!core_fault && diagnostic_reason==0) begin
            if(state!=0 && bytes_left<3 && !(arvalid&&arready) && !(rvalid&&rready) && (&watchdog))
                diagnostic_reason<=state==1?3'd1:3'd2;
            else if(state==2 && rvalid && rready && rresp!=0) diagnostic_reason<=3'd3;
            else if(state==2 && rvalid && rready && rlast!=(burst_left==1)) diagnostic_reason<=3'd4;
            else if(state==2 && burst_left==0 && bytes_left<pixel_bytes && remaining==0 && bytes_left!=0)
                diagnostic_reason<=3'd5;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            req_meta<=0;req_sync<=0;ack_toggle<=0;state<=0;bank<=0;row_core<=0;
            remaining<=0;burst_left<=0;shift_data<=0;unpack<=0;
            bytes_left<=0;component<=0;saved_r<=0;saved_g<=0;
            cache_half<=0;cache_first_rgb<=0;
            view_core<=0;roi_core<=0;quarter_core<=0;original_part<=0;write_col<=0;core_fault<=0;araddr<=BASE_ADDR;frame_base_core<=BASE_ADDR;original_base_core<=0;mixed_source_core<=0;watchdog<=0;
        end else begin
            req_meta<=req_toggle;req_sync<={req_sync[0],req_meta};
            if(state==0 || bytes_left>=3 || (arvalid&&arready) || (rvalid&&rready)) watchdog<=0;
            else begin watchdog<=watchdog+1'b1;if(&watchdog) core_fault<=1;end
            case(state)
                0:if(req_sync[1]!=ack_toggle && !core_fault) begin
                    bank<=req_bank;row_core<=req_row;frame_base_core<=(RUNTIME_BASE!=0)?runtime_base:BASE_ADDR;original_base_core<=runtime_original_base;mixed_source_core<=RUNTIME_BASE!=0 && UKIYO_BOTTOM_EN!=0 && runtime_style==2 && !runtime_fisheye;
                    cache_half<=0;
                    view_core<=req_view;roi_core<=req_roi;quarter_core<=0;
                    original_part<=(VIEW_MODES!=0 && req_view!=0)?full_original(req_view,req_roi,0,req_row):(COMPARE_MODE!=0);
                    remaining<=(VIEW_MODES!=0 && req_view!=0)?
                        (full_original(req_view,req_roi,0,req_row)?W/16:W*3/64):
                        (COMPARE_MODE!=0)?W*4/16:ROW_BEATS;write_col<=0;bytes_left<=0;shift_data<=0;state<=3;
                end
                3:begin araddr<=((COMPARE_MODE!=0 && original_part)?original_base_core:resolved_frame_base)+
                    display_row_offset(row_core,(COMPARE_MODE!=0 && original_part)?W*4:ROW_BYTES)+
                    (full_core?quarter_core*(original_part?W:W*3/4):0);state<=1;end
                1:if(arready&&arvalid) begin burst_left<=chunk;state<=2;end
                2:begin
                    if(rvalid&&rready) begin
                        if(rresp!=0 || rlast!=(burst_left==1)) core_fault<=1;
                        // 0/1/2 carry bytes survive beat and 4 KiB boundaries.
                        if(COMPARE_MODE!=0 && consume_pixel)begin
                            // One RAM pixel write and refill may occur together.
                            // Carry remains bounded, including the four-source-pixel decimator.
                            shift_data<=refill_data;
                            bytes_left<=bytes_left-pixel_bytes+16;
                        end else begin
                            shift_data<=refill_data;
                            bytes_left<=bytes_left+16;
                        end
                        burst_left<=burst_left-1'b1;remaining<=remaining-1'b1;araddr<=araddr+16;
                    end else if(bytes_left>=pixel_bytes) begin
                        shift_data<=shifted_pixels;bytes_left<=bytes_left-pixel_bytes;
                        
                    end
                    if(SERIAL_CACHE_WRITE!=0 && consume_pixel)begin
                        cache_half<=~cache_half;
                        if(!cache_half)cache_first_rgb<=serial_rgb;
                    end
                    if(write_pixel && write_col<MEM_W-1)write_col<=write_col+1'b1;
                    if(burst_left==0 && bytes_left<pixel_bytes) begin
                        if(remaining==0) begin
                            if(bytes_left!=0 || (SERIAL_CACHE_WRITE!=0 && cache_half))core_fault<=1;
                            if(full_core && quarter_core!=3)begin
                                quarter_core<=quarter_core+2'd1;original_part<=next_full_original;
                                remaining<=next_full_original?W/16:W*3/64;
                                shift_data<=0;bytes_left<=0;state<=3;
                            end else if(!full_core && COMPARE_MODE!=0 && original_part)begin
                                original_part<=0;remaining<=ROW_BEATS;shift_data<=0;bytes_left<=0;state<=3;
                            end else begin ack_toggle<=req_sync[1];state<=0;end
                        end else state<=core_fault?0:1;
                    end
                end
                default:state<=0;
            endcase
        end
    end
    end endgenerate
    reg [11:0] x,y;
    wire safe_swap_pixel=(COMPARE_MODE!=0) &&
        (full_pixel?(y>=DH && y<VT-32):
         (y>=Y0+IMAGE_H || (Y0>32 && y<Y0-32)));
    (* async_reg="true", syn_preserve=1 *) reg swap_meta;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] swap_sync;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin swap_meta<=0;swap_sync<=0;end
        else begin swap_meta<=safe_swap_pixel;swap_sync<={swap_sync[0],swap_meta};end
    end
    // Close early enough to drain a row and prefetch the next frame before
    // the image starts. HDMI sync/de run continuously through publication.
    assign publication_window=swap_sync[1];
    reg launched,running,row_ready,picture_de,pixel_fault;reg [BANK_W-1:0] display_bank;
    reg pixel_quiet;
    reg frame_toggle;
    (* async_reg="true", syn_preserve=1 *) reg frame_meta;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] frame_sync;
    reg frame_seen;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin frame_meta<=0;frame_sync<=0;frame_seen<=0;end
        else begin frame_meta<=frame_toggle;frame_sync<={frame_sync[0],frame_meta};frame_seen<=frame_sync[1];end
    end
    assign frame_shown=frame_sync[1]^frame_seen;
    (* async_reg="true", syn_preserve=1 *) reg quiet_meta;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] quiet_sync;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin quiet_meta<=1;quiet_sync<=3;end
        else begin quiet_meta<=pixel_quiet;quiet_sync<={quiet_sync[0],quiet_meta};end
    end
    assign quiescent=quiet_sync[1] && state==0 && req_sync[1]==ack_toggle;
    wire [1:0] requested_view=(runtime_view<3)?runtime_view:2'd0;
    wire mode_change=(VIEW_MODES!=0 && requested_view!=view_frame && x==0 && y==DH);
    wire image_window=(x>=image_x0)&&(x<image_x0+image_w)&&(y>=image_y0)&&(y<image_y0+image_h);
    wire [11:0] image_col;
    generate if(DECIMATE_X==2 || ZOOM_DEN<=SCALE*ZOOM_NUM)begin:G_DECIMATED_COLUMN
     // Fractional phase avoids a constant divider on the pixel-clock RAM address.
     localparam COL_SCALE=SCALE*ZOOM_NUM*DECIMATE_X;
     reg [11:0] cached_col;
     reg [$clog2(COL_SCALE+ZOOM_DEN+1)-1:0] fraction;
     always @(posedge pixel_clk or negedge local_pixel_rst_n)begin
      if(!local_pixel_rst_n)begin cached_col<=0;fraction<=0;end
      else if(x==HT-1 || (!full_pixel && x==X0-1))begin cached_col<=0;fraction<=0;end
      else if(image_window)begin
       if(fraction+(full_pixel?2:ZOOM_DEN)>=(full_pixel?3:COL_SCALE))begin
        cached_col<=cached_col+1'b1;
        fraction<=fraction+(full_pixel?2:ZOOM_DEN)-(full_pixel?3:COL_SCALE);
       end else fraction<=fraction+(full_pixel?2:ZOOM_DEN);
      end
     end
     assign image_col=image_window?((DECIMATE_X==2 && !full_pixel)?(cached_col<<1):cached_col):0;
    end else assign image_col=image_window ? ((x-X0)*ZOOM_DEN)/(SCALE*ZOOM_NUM) : 0;
    endgenerate
    wire [11:0] sample_col;
    wire picture_valid;
    wire video_hs,video_vs,video_de;
    generate if(CAT_WIDE_STRENGTH!=0)begin : G_CAT_WIDE
     // Separate the existing scaling arithmetic from the remap/RAM address.
     reg [11:0] col_q;
     reg hs_q,vs_q,de_q,valid_q;
     wire effect_part=(COMPARE_MODE==0)||(col_q>=W);
     wire [$clog2(W)-1:0] local_col=(COMPARE_MODE!=0 && col_q>=W)?col_q-W:col_q;
     wire [$clog2(W)-1:0] mapped_col;
     cat_wide_angle_mapper #(.WIDTH(W),.STRENGTH(CAT_WIDE_STRENGTH)) u_wide_map(
      .out_x(local_col),.source_x(mapped_col));
     always @(posedge pixel_clk)col_q<=image_col;
     always @(posedge pixel_clk or negedge local_pixel_rst_n)begin
      if(!local_pixel_rst_n)begin hs_q<=0;vs_q<=0;de_q<=0;valid_q<=0;end
      else begin hs_q<=hs_raw;vs_q<=vs_raw;de_q<=de_raw;valid_q<=picture_de;end
     end
     assign sample_col=effect_part?((COMPARE_MODE!=0)?W+mapped_col:mapped_col):col_q;
     assign video_hs=hs_q;assign video_vs=vs_q;assign video_de=de_q;assign picture_valid=valid_q;
    end else begin : G_NO_CAT_WIDE
     assign sample_col=image_col;
     assign video_hs=hs_raw;assign video_vs=vs_raw;assign video_de=de_raw;assign picture_valid=picture_de;
    end endgenerate
    // ROI belongs to the immutable published front. Let its held payload
    // settle during row prefetch, then keep it for every scan of that front.
    (* async_reg="true",syn_preserve=1 *) reg [1:0] roi_meta,roi_sync;
    reg [1:0] roi_frame;
    always @(posedge pixel_clk or negedge local_pixel_rst_n)begin
        if(!local_pixel_rst_n)begin roi_meta<=0;roi_sync<=0;roi_frame<=0;end
        else begin
            roi_meta<=runtime_roi;roi_sync<=roi_meta;
            if(!running)roi_frame<=roi_sync;
        end
    end
    localparam ROI_Y_BEGIN=Y0+((H/4*SCALE*ZOOM_NUM+ZOOM_DEN-1)/ZOOM_DEN);
    localparam ROI_Y_END=Y0+((H*3/4*SCALE*ZOOM_NUM+ZOOM_DEN-1)/ZOOM_DEN);
    wire [11:0] roi_x=sample_col-W;
    wire roi_inside=(roi_frame==0) ||
        (roi_frame==1 && roi_x>=W/4 && roi_x<W*3/4 && y>=ROI_Y_BEGIN && y<ROI_Y_END) ||
        (roi_frame==2 && roi_x<W/2) || (roi_frame==3 && roi_x>=W/2);
    wire roi_original=(ROI_ENABLE!=0 && COMPARE_MODE!=0 && !full_pixel && sample_col>=W && !roi_inside);
    wire [11:0] resolved_sample_col=roi_original?sample_col-W:sample_col;
    wire [AW-1:0] read_col=full_pixel?(resolved_sample_col/2):resolved_sample_col/(LANES*DECIMATE_X);
    reg pair_high;
    always @(posedge pixel_clk)pair_high<=(DECIMATE_X==2 && !full_pixel)?resolved_sample_col[1]:resolved_sample_col[0];
    reg [ROW_W-1:0] visible_row;
    localparam integer ROW_SCALE=SCALE*ZOOM_NUM*((DECIMATE_X==2)?2:1);
    reg [$clog2(ROW_SCALE+ZOOM_DEN+1)-1:0] row_fraction;
    always @(posedge pixel_clk or negedge local_pixel_rst_n)begin
        if(!local_pixel_rst_n)begin visible_row<=0;row_fraction<=0;end
        else if(mode_change || mode_draining)begin visible_row<=0;row_fraction<=0;end
        else if(x==HT-1)begin
            if(y==image_y0-1 || y==VT-1)begin visible_row<=0;row_fraction<=0;end
            else if(y>=image_y0 && y<image_y0+image_h-1)begin
                if(full_pixel)begin
                    if(row_fraction+2>=3)begin visible_row<=visible_row+1'b1;row_fraction<=row_fraction+2-3;end
                    else row_fraction<=row_fraction+2;
                end else if(row_fraction+ZOOM_DEN>=ROW_SCALE)begin
                    // At most one source-row step when numerator <= scale.
                    // Keep the divider fallback for larger integer decimation.
                    if(ZOOM_DEN<=ROW_SCALE)begin
                        row_fraction<=row_fraction+ZOOM_DEN-ROW_SCALE;
                        visible_row<=visible_row+((DECIMATE_X==2)?2:1);
                    end else begin
                        row_fraction<=(row_fraction+ZOOM_DEN)%ROW_SCALE;
                        visible_row<=visible_row+((row_fraction+ZOOM_DEN)/ROW_SCALE)*((DECIMATE_X==2)?2:1);
                    end
                end else row_fraction<=row_fraction+ZOOM_DEN;
            end
        end
    end
    reg [MEM_BITS-1:0] q0,q1,q2;
    wire [MEM_BITS-1:0] q_extra[0:2];
    genvar extra_bank;
    generate for(extra_bank=0;extra_bank<3;extra_bank=extra_bank+1)begin:G_EXTRA_LINES
     if(PACKED_LINE_RAM==0 && LINE_BANKS>extra_bank+3 && COMPARE_MODE!=0)begin:G_PRESENT
      (* syn_ramstyle="block_ram" *) reg [MEM_BITS-1:0] line_data[0:MEM_W-1];
      reg [MEM_BITS-1:0] read_q;
      always @(posedge clk)if(write_pixel && bank==extra_bank+3)line_data[write_col]<=write_rgb;
      always @(posedge pixel_clk)read_q<=line_data[read_col];
      assign q_extra[extra_bank]=read_q;
     end else assign q_extra[extra_bank]=0;
    end endgenerate
    wire [MEM_BITS-1:0] selected_pair;
    wire [MEM_BITS-1:0] legacy_selected_pair=display_bank==5?q_extra[2]:display_bank==4?q_extra[1]:display_bank==3?q_extra[0]:display_bank==2?q2:display_bank==1?q1:q0;
    wire [23:0] selected_rgb=selected_pair>>(COMPARE_MODE!=0 && pair_high?24:0);
    generate if(PACKED_LINE_RAM==0)begin:G_LEGACY_READ
    always @(posedge pixel_clk) q0<=line0[read_col];
    always @(posedge pixel_clk) q1<=line1[read_col];
    if(COMPARE_MODE!=0)begin
     always @(posedge pixel_clk)q2<=line2[read_col];
    end else always @* q2=0;
    end else begin:G_UNUSED_LEGACY_READ
     always @* begin q0=0;q1=0;q2=0;end
    end endgenerate
    // Only the published row is read when vertical filtering is disabled.
    // A row-bank lease remains owned by the existing CDC/ready queue.
    // Coalescing depth reduces narrow RAM fragmentation and the six-way mux.
    generate if(PACKED_LINE_RAM!=0)begin:G_PACKED_LINE_RAM
      localparam PAW=$clog2(LINE_BANKS*MEM_W);
      (* syn_ramstyle="block_ram" *) reg [MEM_BITS-1:0] memory[0:LINE_BANKS*MEM_W-1];
      wire [PAW-1:0] wa=bank*MEM_W+write_col;
      wire [PAW-1:0] ra=display_bank*MEM_W+read_col;
      reg [MEM_BITS-1:0] read_q;
      always @(posedge clk)if(write_pixel)memory[wa]<=write_rgb;
      always @(posedge pixel_clk)read_q<=memory[ra];
      assign selected_pair=read_q;
      // This mode has one read port, so it cannot serve two-row interpolation.
      initial if(ORIGINAL_VERTICAL_FILTER!=0 || COMPARE_MODE==0)
        $fatal(1,"packed display RAM requires direct comparison renderer");
    end else assign selected_pair=legacy_selected_pair;endgenerate
    wire [BANK_W-1:0] filter_next_bank;
    wire filter_next_ready;
    wire output_picture_valid;
    generate if(ORIGINAL_VERTICAL_FILTER!=0 && COMPARE_MODE!=0)begin:G_VERTICAL_FILTER
        // All line RAM read ports already run at the same column. The next
        // completed row is immutable in the ready queue: no extra RAM/DDR.
        wire [MEM_BITS-1:0] next_pair=filter_next_bank==5?q_extra[2]:filter_next_bank==4?q_extra[1]:
            filter_next_bank==3?q_extra[0]:filter_next_bank==2?q2:filter_next_bank==1?q1:q0;
        wire [23:0] next_rgb=next_pair>>(pair_high?24:0);
        reg original_q;
        always @(posedge pixel_clk)original_q<=resolved_sample_col<W;
        wire [15:0] eighth_phase={row_fraction,3'b0};
        wire [2:0] phase=eighth_phase<ROW_SCALE?0:eighth_phase<ROW_SCALE*3?1:
            eighth_phase<ROW_SCALE*5?2:eighth_phase<ROW_SCALE*7?3:4;
        reg [23:0] current_q,next_q;
        reg [2:0] phase_q;
        reg hs1,vs1,de1,valid1,hs2,vs2,de2,valid2;
        reg [23:0] rgb2;
        function [7:0] blend;
            input [7:0] current,next;
            input [2:0] weight;
            reg [9:0] a,b,total;
            begin
                a={2'b0,current};b={2'b0,next};
                case(weight)
                    1:total=(a<<1)+a+b+2;
                    2:total=(a<<1)+(b<<1)+2;
                    3:total=a+(b<<1)+b+2;
                    4:total=(b<<2)+2;
                    default:total=(a<<2)+2;
                endcase
                blend=total[9:2];
            end
        endfunction
        // Separate the RAM-bank mux from the small shift/add interpolation.
        // Both panels and HDMI timing receive exactly the same two cycles.
        always @(posedge pixel_clk or negedge local_pixel_rst_n)begin
            if(!local_pixel_rst_n)begin
                current_q<=0;next_q<=0;phase_q<=0;rgb2<=0;
                hs1<=0;vs1<=0;de1<=0;valid1<=0;hs2<=0;vs2<=0;de2<=0;valid2<=0;
            end else begin
                current_q<=selected_rgb;next_q<=next_rgb;
                phase_q<=((MATCHED_VERTICAL_FILTER!=0 || original_q) && filter_next_ready)?phase:0;
                hs1<=video_hs;vs1<=video_vs;de1<=video_de;valid1<=picture_valid;
                hs2<=hs1;vs2<=vs1;de2<=de1;valid2<=valid1;
                rgb2<={blend(current_q[23:16],next_q[23:16],phase_q),
                       blend(current_q[15:8],next_q[15:8],phase_q),
                       blend(current_q[7:0],next_q[7:0],phase_q)};
            end
        end
        assign hs=hs2;assign vs=vs2;assign de=de2;
        assign output_picture_valid=valid2;
        assign {blue,green,red}=valid2?rgb2:24'b0;
    end else begin:G_DIRECT_OUTPUT
        assign hs=video_hs;assign vs=video_vs;assign de=video_de;
        assign output_picture_valid=picture_valid;
        assign {blue,green,red}=picture_valid?selected_rgb:24'b0;
    end endgenerate
    generate if(COMPARE_MODE!=0)begin:G_FRAME_QUALITY
        localparam integer COUNT_W=$clog2(((VIEW_MODES!=0)?DW*DH:IMAGE_W*IMAGE_H)+1);
        reg [COUNT_W-1:0] picture_pixels,expected_pixels;
        reg monitor_active;
        reg [15:0] blank_frames,partial_frames;
        assign frame_quality={partial_frames,blank_frames};
        always @(posedge pixel_clk or negedge local_pixel_rst_n)begin
            if(!local_pixel_rst_n)begin
                picture_pixels<=0;expected_pixels<=IMAGE_W*IMAGE_H;monitor_active<=0;blank_frames<=0;partial_frames<=0;
            end else begin
                if(output_picture_valid)begin
                    monitor_active<=1;
                    if(picture_pixels==0)expected_pixels<=full_pixel?DW*DH:IMAGE_W*IMAGE_H;
                    if(!(&picture_pixels))picture_pixels<=picture_pixels+1'b1;
                end
                if(x==HT-1 && y==VT-1)begin
                    picture_pixels<=0;
                    if(monitor_active)begin
                        if(picture_pixels==0)begin
                            if(!(&blank_frames))blank_frames<=blank_frames+1'b1;
                        end else if(picture_pixels!=expected_pixels)begin
                            if(!(&partial_frames))partial_frames<=partial_frames+1'b1;
                        end
                    end
                end
            end
        end
    end else assign frame_quality=0;endgenerate
    // Sticky pixel fault crosses back to the status LEDs; no video stall.
    (* async_reg="true", syn_preserve=1 *) reg pixel_fault_meta;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] pixel_fault_sync;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin pixel_fault_meta<=0;pixel_fault_sync<=0;end
        else begin
            pixel_fault_meta<=pixel_fault;
            pixel_fault_sync<={pixel_fault_sync[0],pixel_fault_meta};
        end
    end
    assign fault=core_fault|pixel_fault_sync[1];
    assign fault_detail={core_fault,pixel_fault_sync[1]};
    generate if(COMPARE_MODE!=0)begin : G_PREFETCH3
    reg filling,recovering;
    reg critical_level;
    reg next_ready_latched;
    assign critical_pixel=critical_level;
    (* mark_debug="true", syn_keep=1 *) reg [15:0] underflow_count;
    reg[15:0] last_bad_row;
    assign underflow_total=underflow_count;assign last_underflow_row=last_bad_row;
    reg [$clog2(LINE_BANKS+1)-1:0] ready_count;
    reg [BANK_W-1:0] consume_bank,produce_bank;
    assign filter_next_bank=consume_bank;
    assign filter_next_ready=next_ready_latched;
    reg [ROW_W-1:0] consume_row,produce_row;
    wire push=filling && ack_sync[1]==req_toggle;
    wire [15:0] upcoming_row=(y==VT-1)?0:
        visible_row+((y<DH-1 && row_fraction+2>=3)?1:0);
    wire [15:0] target_row=full_pixel?upcoming_row:visible_row;
    wire row_boundary=en_sync[1] && running && (full_pixel?
        ((y==VT-1 || y<DH-1) && (y==VT-1 || target_row!=display_row) && x==HT-8):
        (y>=Y0 && y<Y0+IMAGE_H && (y==Y0 || visible_row!=display_row) && x==X0-8));
    wire pop=row_boundary && ready_count!=0 && consume_row==target_row;
    always @(posedge pixel_clk or negedge local_pixel_rst_n)begin
     if(!local_pixel_rst_n)begin
      x<=0;y<=0;hs_raw<=0;vs_raw<=0;de_raw<=0;picture_de<=0;
      ack_meta<=0;en_meta<=0;err_meta<=0;ack_sync<=0;en_sync<=0;err_sync<=0;
      req_toggle<=0;req_bank<=0;req_row<=0;req_view<=0;req_roi<=0;view_frame<=0;mode_draining<=0;
      launched<=0;running<=0;display_bank<=0;row_ready<=0;pixel_fault<=0;
      pixel_quiet<=1;frame_toggle<=0;display_row<=0;
      recovering<=0;underflow_count<=0;last_bad_row<=0;critical_level<=1;next_ready_latched<=0;
      filling<=0;ready_count<=0;consume_bank<=0;produce_bank<=0;consume_row<=0;produce_row<=0;
     end else begin
      if(!en_sync[1] || recovering || ready_count<=(LINE_BANKS>=5?LINE_BANKS-3:0))critical_level<=1;
      else if(ready_count>=LINE_BANKS-1)critical_level<=0;
      ack_meta<=ack_toggle;en_meta<=enable;err_meta<=core_fault;
      ack_sync<={ack_sync[0],ack_meta};en_sync<={en_sync[0],en_meta};err_sync<={err_sync[0],err_meta};
      hs_raw<=x>=HS_BEGIN && x<HS_END;vs_raw<=y>=VS_BEGIN && y<VS_END;de_raw<=x<DW && y<DH;
      picture_de<=image_window && running && row_ready && en_sync[1] && !err_sync[1] && !pixel_fault;
      if(x==HT-1)begin x<=0;if(y==VT-1)y<=0;else y<=y+1'b1;end else x<=x+1'b1;
      if(en_sync[1] && running && row_ready && !err_sync[1] && !pixel_fault &&
         x==image_x0+image_w-1 && y==image_y0+image_h-1)frame_toggle<=~frame_toggle;
      if(!en_sync[1])begin
       next_ready_latched<=0;
       running<=0;row_ready<=0;
       // Do not cancel the outstanding read or mutate its bundled descriptor.
       if(!filling || push)begin
        recovering<=0;filling<=0;ready_count<=0;launched<=0;pixel_quiet<=1;
        consume_bank<=0;produce_bank<=0;consume_row<=0;produce_row<=0;
       end
      end else if(recovering || mode_draining || mode_change)begin
       if(mode_change)mode_draining<=1;
       next_ready_latched<=0;
       // Drain the accepted row before resetting the bundled descriptors.
       // Keep the front-frame loan until a complete frame is displayed.
       running<=0;row_ready<=0;pixel_quiet<=0;
       if((!filling || push) && (!(mode_draining || mode_change) || y>=DH))begin
        if(mode_draining || mode_change)begin view_frame<=requested_view;mode_draining<=0;end
        recovering<=0;filling<=0;ready_count<=0;launched<=0;
        consume_bank<=0;produce_bank<=0;consume_row<=0;produce_row<=0;
       end
      end else begin
       pixel_quiet<=0;launched<=1;
       if(push)begin
        filling<=0;produce_bank<=produce_bank==LINE_BANKS-1?0:produce_bank+1'b1;
        produce_row<=produce_row+row_step>=H?0:produce_row+row_step;
       end
       case({push,pop})
        2'b10:ready_count<=ready_count+1'b1;
        2'b01:ready_count<=ready_count-1'b1;
        default:ready_count<=ready_count;
       endcase
       // Before launch all 3 banks may fill; while displaying reserve its bank.
       if(!filling && ack_sync[1]==req_toggle && ready_count<(row_ready?LINE_BANKS-1:LINE_BANKS) && !err_sync[1] && !pixel_fault)begin
        req_bank<=produce_bank;req_row<=produce_row;req_view<=view_frame;req_roi<=roi_sync;req_toggle<=~req_toggle;filling<=1;
       end
       // A frame may be enabled after HDMI frame origin during blanking.
       // Permit row-zero launch before the image starts instead of losing
       // an entire HDMI frame when the origin was just missed.
       if(!running && ready_count>=LINE_BANKS-1 && consume_row==0 &&
          (full_pixel?(y==VT-1 && x==HT-16):
           ((x==0 && y==0) || (y==Y0 && x==X0-16))))running<=1;
       if(row_boundary)begin
        if(!pop)begin
          row_ready<=0;
          if(RECOVER_UNDERFLOW!=0)begin
           recovering<=1;running<=0;last_bad_row<=target_row;if(!(&underflow_count))underflow_count<=underflow_count+1'b1;
          end else pixel_fault<=1;
         end
        else begin
         // Freeze availability for the complete displayed source row. Never
         // blend the last row with row zero of the following frame.
         next_ready_latched<=(ready_count>=2 || push) && target_row+row_step<H;
         display_bank<=consume_bank;display_row<=target_row;row_ready<=1;
         consume_bank<=consume_bank==LINE_BANKS-1?0:consume_bank+1'b1;
         consume_row<=consume_row+row_step>=H?0:consume_row+row_step;
        end
       end
      end
     end
    end
    end else begin : G_LEGACY_ROWS
    assign underflow_total=0;assign last_underflow_row=0;
    assign critical_pixel=1'b0;
    assign filter_next_bank=0;assign filter_next_ready=0;
    always @(posedge pixel_clk or negedge local_pixel_rst_n) begin
        if(!local_pixel_rst_n) begin
            x<=0;y<=0;hs_raw<=0;vs_raw<=0;de_raw<=0;picture_de<=0;
            ack_meta<=0;en_meta<=0;err_meta<=0;
            ack_sync<=0;en_sync<=0;err_sync<=0;req_toggle<=0;req_bank<=0;req_row<=0;
            launched<=0;running<=0;display_bank<=0;row_ready<=0;pixel_fault<=0;
            pixel_quiet<=1;frame_toggle<=0;display_row<=0;
        end else begin
            ack_meta<=ack_toggle;en_meta<=enable;err_meta<=core_fault;
            ack_sync<={ack_sync[0],ack_meta};en_sync<={en_sync[0],en_meta};
            err_sync<={err_sync[0],err_meta};
            if(en_sync[1] && running && row_ready && !err_sync[1] && !pixel_fault &&
               x==image_x0+image_w-1 && y==image_y0+image_h-1) frame_toggle<=~frame_toggle;
            hs_raw<=(x>=HS_BEGIN && x<HS_END);vs_raw<=(y>=VS_BEGIN && y<VS_END);
            de_raw<=(x<DW && y<DH);
            picture_de<=image_window && running && row_ready && en_sync[1] && !err_sync[1] && !pixel_fault;
            if(x==HT-1) begin x<=0;if(y==VT-1)y<=0;else y<=y+1'b1;end
            else x<=x+1'b1;
            if(en_sync[1] && !launched) begin
                req_toggle<=~req_toggle;req_bank<=0;req_row<=0;launched<=1;pixel_quiet<=0;
            end
            if(!en_sync[1] && ack_sync[1]==req_toggle) begin
                launched<=0;running<=0;row_ready<=0;pixel_quiet<=1;
            end
            if(en_sync[1] && x==0 && y==0 && launched && ack_sync[1]==req_toggle && req_row==0)
                running<=1;
            if(en_sync[1] && running && y>=Y0 && y<Y0+IMAGE_H && (y==Y0 || visible_row!=display_row) && x==X0-8) begin
                if(ack_sync[1]!=req_toggle || req_row!=visible_row) begin
                    pixel_fault<=1;row_ready<=0;
                end else begin
                    display_bank<=req_bank;row_ready<=1;display_row<=visible_row;
                    req_bank<=!req_bank;
                    req_row<=(visible_row+ROW_STEP>=H)?0:visible_row+ROW_STEP;
                    req_toggle<=~req_toggle;
                end
            end
        end
    end
    end endgenerate
    initial begin
        if(SERIAL_CACHE_WRITE!=0 && (COMPARE_MODE==0 || PARALLEL_UNPACK==0))
            $fatal(1,"single-pixel cache writer requires paired comparison storage");
        if(VIEW_MODES!=0 && (COMPARE_MODE==0 || PARALLEL_UNPACK==0 || DECIMATE_X!=2 || W%64 || W*3/2!=DW || H*3/2!=DH || CAT_WIDE_STRENGTH!=0 || ORIGINAL_VERTICAL_FILTER!=0 || HT-DW<16 || VT-DH<33))
            $fatal(1,"runtime views require paired cache and 3:2 full-screen geometry");
        if((ROI_ENABLE!=0 && (COMPARE_MODE==0 || W%4 || H%4 || CAT_WIDE_STRENGTH!=0)) || LINE_BANKS<3 || LINE_BANKS>6 || (DECIMATE_X!=1 && DECIMATE_X!=2) || (DECIMATE_X==2 && (COMPARE_MODE==0 || PARALLEL_UNPACK==0 || ZOOM_DEN>SCALE*ZOOM_NUM*2 || W%4)) || CAT_WIDE_STRENGTH<0 || CAT_WIDE_STRENGTH>2 || (CAT_WIDE_STRENGTH!=0 && (W<16 || W%16)) || ZOOM_NUM<1 || ZOOM_DEN<1 || (DECIMATE_X==1 && ZOOM_DEN>SCALE*ZOOM_NUM && ZOOM_DEN%(SCALE*ZOOM_NUM)!=0) || IMAGE_W>DW || IMAGE_H>DH ||
           (W*SCALE*ZOOM_NUM)%ZOOM_DEN || (H*SCALE*ZOOM_NUM)%ZOOM_DEN || (COMPARE_MODE!=0 && (PARALLEL_UNPACK==0 || W*4%16)) || W*3%16 || X0<8 || Y0<0 || SCALE<1 || ROW_BEATS>256)
            $fatal(1,"unsupported DDR display geometry");
    end
endmodule
`default_nettype wire
