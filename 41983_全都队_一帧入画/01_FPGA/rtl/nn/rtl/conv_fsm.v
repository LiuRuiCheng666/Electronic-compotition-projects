//============================================================================
//  conv_fsm.v -- single-layer sequencer for the convolution core
//----------------------------------------------------------------------------
//  Turns "run this layer" into the control sequence the data path needs.
//  Before this module the whole schedule lived in the testbench; this is the
//  C-group piece that makes a layer run on its own.
//
//  Loop structure (this is the whole design)
//
//      for tile in tiles(NPIX, T)
//        for cog in COG                          COUT / P_CO
//          CLEAR the tile's accumulators
//          for cig in CING                       CIN / P_CI
//            LOAD weight group (cog, cig)        9 cycles (4-block read port)
//            MAC over the whole tile             T cycles
//          EMIT the tile                         T cycles
//
//  Why cig is INSIDE cog and the MAC runs over the WHOLE tile
//    The weight group stays in the buffer for the whole tile, so the weights
//    never change while a tile is computed.  That is what makes the wide
//    (32 B/cycle) weight port affordable, and it is also why the window cache
//    must support RANDOM reads: the read order (cog, cig, pixel) is not the
//    write order (pixel, cig).
//
//  Weight double buffering (optional, PREFETCH=1)
//    While the MAC consumes group g, load group g+1 into the other buffer.
//    DDR latency is variable: only swap after completion has been observed.
//    Prefetch the next INPUT group within an output group; the first group
//    remains serial. Existing two register buffers are used, with no new RAM.
//    Default is 0 for compatibility with standalone consumers.
//
//  Signal alignment (the part that is easy to get wrong)
//    mac_px  : pixel index of the MAC cycle currently being issued
//    The consumer (acc_bank) sees the MAC result one cycle later, so the
//    testbench/integration must delay mac_px by one cycle to match
//    mac_array.out_valid.  This module deliberately does NOT do that delay,
//    so the alignment is explicit at the integration point.
//
//  Not in this module (deliberately)
//    A'/B' coefficients come from outside (later the B group).  The FSM only
//    produces pp_valid and the coordinate tagging.
//============================================================================

`default_nettype none

module conv_fsm #(
    parameter integer REGISTER_BOUNDARY_FLAGS = 0,
    parameter integer P_CI     = 3,
    parameter integer P_CO     = 8,
    parameter integer TAP      = 9,
    parameter integer CH_W     = 8,
    parameter integer RD_B     = 32,
    parameter integer T        = 32,
    parameter integer PREFETCH = 0,
    parameter integer TILE_PREFETCH = 0,
    parameter integer CLEAR_ELIDE = 0,
    parameter integer STREAM_EMIT = 0,
    parameter integer RESIDENT_WEIGHTS = 0,
    parameter integer A4_FIXED_GEOMETRY = 0,
    parameter integer A4_FULL_W = 32,
    parameter integer A4_FULL_H = 24,
    parameter integer ELASTIC_WINDOW_INPUT = 0,
    parameter integer GW       = 16             // px / counter width
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- layer configuration ----
    input  wire                       start,
    input  wire [15:0]                cfg_cin,
    input  wire [15:0]                cfg_cout,
    input  wire [15:0]                cfg_h,
    input  wire [15:0]                cfg_w,
    input  wire [1:0]                 cfg_stride,
    input  wire [31:0]                cfg_wbase,
    output wire                       busy,
    output wire                       done,

    // ---- line buffers ----
    input  wire                       lb_win_valid,
    output wire                       lb_stall,
    output wire [15:0]                lb_cfg_w,
    output wire [15:0]                lb_cfg_h,
    output wire [1:0]                 lb_cfg_stride,

    // ---- window cache ----
    output wire                       wc_wr_valid,
    input  wire                       wc_wr_ready,
    input  wire                       wc_wr_busy,
    output reg                        wc_flush,
    input  wire [GW:0]               wc_count,
    output reg                        wc_release,
    output wire                       wc_read_bank,
    output reg  [GW-1:0]              wc_rd_addr,
    output reg  [GW-1:0]              wc_cig_sel,

    // ---- weight manager ----
    output reg                        wm_ld_req,
    output reg  [31:0]                wm_ld_base,
    output reg                        wm_ld_sel,
    input  wire                       wm_ld_done,
    input  wire                       wm_ld_busy,
    output reg                        wm_sel_buf,

    // ---- acc bank ----
    output reg                        acc_clr,
    output reg  [GW-1:0]              clr_px,
    output reg  [GW-1:0]              mac_px,      // pixel of the current MAC (tile-local)
    output reg  [GW-1:0]              rd_px,       // pixel being read out (tile-local)
    // FRAME-GLOBAL pixel index (tile_base + px_i).  rd_px restarts at 0 for
    // every tile, so a consumer that writes to a frame buffer MUST use this
    // one -- using rd_px makes every tile overwrite tile 0.
    output wire [GW-1:0]              px_global,

    // ---- mac array ----
    output reg                        mac_valid,
    output reg                        mac_first,
    output reg                        mac_emit,
    output reg [GW-1:0]                mac_global,
    output reg [7:0]                   mac_cog,

    // ---- postproc ----
    output reg                        pp_valid,
    input  wire                       pp_ready,
    output reg  [15:0]                out_row,
    output reg  [15:0]                out_col,

    // ---- B group hooks ----
    //  stat_valid taps the same wide accumulator read as pp_valid and feeds
    //  acc_reduce, so statistics are gathered without a second pass over the
    //  data (this is what makes the frame-reuse schedule possible).
    //  coeff_raddr is the coefficient-table entry for the current output
    //  group; it is constant for the whole group, so a registered table read
    //  settles once and stays valid.
    output wire                       stat_valid,
    output wire [7:0]                 coeff_raddr
);

    //------------------------------------------------------------------------
    //  Derived layer geometry
    //------------------------------------------------------------------------
    wire [15:0] cing_w = (cfg_cin  + P_CI - 1) / P_CI;
    wire [15:0] cog_w  = (cfg_cout + P_CO - 1) / P_CO;

    reg [15:0] cing_r, cog_r, w_r, h_r;
    reg [15:0] ow_r, oh_r;              // OUTPUT grid (differs from input when stride=2)
    reg [1:0]  stride_r;
    reg [31:0] wbase_r, npix_r, ntile_r;

    localparam integer LOCAL_PX_W=(A4_FIXED_GEOMETRY!=0)?((T>1)?$clog2(T):1):GW;
    localparam integer GROUP_INDEX_W=(A4_FIXED_GEOMETRY!=0)?2:GW;
    reg [GW-1:0] tile_i;
    reg [GROUP_INDEX_W-1:0] cog_i,cig_i;
    reg [LOCAL_PX_W-1:0] px_i;

    assign stat_valid  = pp_valid;
    assign coeff_raddr = 8'(cog_i);

    //------------------------------------------------------------------------
    //  Output grid
    //  With stride S and padding 1, kernel 3:
    //      OUT_W = (W-1)/S + 1        OUT_H = (H-1)/S + 1
    //  The line buffer handles the geometry (it only emits stride-aligned
    //  windows), so the FSM only needs the OUTPUT dimensions to walk the pixel
    //  index and to tag coordinates.
    //
    //  NOTE: these are computed from the cfg_* INPUTS directly in S_INIT, not
    //  from w_r/h_r/stride_r.  Those registers are written on the same cycle,
    //  so reading them there would use the PREVIOUS layer's values.
    //------------------------------------------------------------------------
    wire [15:0] cfg_ow = (cfg_stride == 2'd2) ?
                         (((cfg_w - 16'd1) >> 1) + 16'd1) : cfg_w;
    wire [15:0] cfg_oh = (cfg_stride == 2'd2) ?
                         (((cfg_h - 16'd1) >> 1) + 16'd1) : cfg_h;
    // A4 has only three compile-time input grids. Constant products avoid
    // spending a DSP on a runtime width*height multiplier for each scheduler.
    wire [31:0] a4_input_pixels=(cfg_w==A4_FULL_W && cfg_h==A4_FULL_H)?(A4_FULL_W*A4_FULL_H):
        (cfg_w==A4_FULL_W/2 && cfg_h==A4_FULL_H/2)?((A4_FULL_W/2)*(A4_FULL_H/2)):
        (cfg_w==A4_FULL_W/4 && cfg_h==A4_FULL_H/4)?((A4_FULL_W/4)*(A4_FULL_H/4)):32'd0;
    wire [31:0] cfg_npix = (A4_FIXED_GEOMETRY!=0)?
        ((cfg_stride==2)?(a4_input_pixels>>2):a4_input_pixels):(cfg_ow * cfg_oh);

    // pixels in the tile currently being processed
    wire [31:0] npix_cur32 = ((tile_i + 1) * T <= npix_r) ?
                             T : (npix_r - tile_i * T);
    // Geometry stays fixed throughout each tile. FLUSH settles this register
    // before FILL; the direct NEXT->PX shortcut is restricted to two full
    // cache tiles, where both the old and new lengths are T.
    localparam integer NPX_W=(A4_FIXED_GEOMETRY!=0)?$clog2(T+1):GW;
    reg [NPX_W-1:0] npx_cur_q;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)npx_cur_q<=0;
        else npx_cur_q<=npix_cur32[NPX_W-1:0];
    wire [GW-1:0] npx_cur=REGISTER_BOUNDARY_FLAGS?npx_cur_q:npix_cur32[GW-1:0];

    // Group addressing: groups are (cog, cig) in order.  Round each group up
    // to a complete ROM beat so every wide-ROM request remains aligned.
    wire [31:0] grp_bytes = ((P_CO * P_CI * TAP + RD_B - 1) / RD_B) * RD_B;
    wire [31:0] group_index=(A4_FIXED_GEOMETRY!=0)?
        ((cing_r==2)?((32'(cog_i)<<1)+32'(cig_i)):(32'(cog_i)+32'(cig_i))):
        ((cog_i * cing_r) + cig_i);
    wire [31:0] group_offset=(A4_FIXED_GEOMETRY!=0 && P_CO==4 && P_CI==4 && TAP==9 && RD_B==32)?
        ((group_index<<7)+(group_index<<5)):(group_index*grp_bytes);
    wire [31:0] cur_base  = wbase_r + group_offset;

    //------------------------------------------------------------------------
    //  States
    //------------------------------------------------------------------------
    localparam S_IDLE = 4'd0, S_INIT = 4'd1, S_FLUSH= 4'd2,
               S_FILL = 4'd3, S_CLR  = 4'd4, S_WLD  = 4'd5,
               S_WAIT = 4'd6, S_PX   = 4'd7, S_EMIT = 4'd8,
               S_NEXT = 4'd9, S_DONE = 4'd10, S_DRAIN = 4'd11;
    reg [3:0] st;
    reg pf_pending, pf_complete;
    reg [1:0] resident_valid;
    wire resident_mode=(RESIDENT_WEIGHTS!=0) && ((cing_r==1 && (cog_r==1 || cog_r==2)) || (cing_r==2 && cog_r==1));
    wire resident_bank=(cog_i!=0 || cig_i!=0);
    reg [31:0] fill_windows;
    wire producer_active = st!=S_IDLE && st!=S_INIT && st!=S_DONE && fill_windows<npix_r;
    assign wc_read_bank = (TILE_PREFETCH!=0) && tile_i[0];
    // These indices remain fixed throughout a tile/group. Precompute the
    // boundary decisions while MAC/weight work is running, instead of placing
    // an increment and wide comparison on the boundary counter enables.
    reg more_tiles_q,more_cogs_q,more_cigs_q,last_cig_q;
    wire more_tiles=REGISTER_BOUNDARY_FLAGS?more_tiles_q:(tile_i+1<ntile_r);
    wire more_cogs=REGISTER_BOUNDARY_FLAGS?more_cogs_q:(cog_i+1<cog_r);
    wire more_cigs=REGISTER_BOUNDARY_FLAGS?more_cigs_q:(cig_i+1<cing_r);
    wire last_cig=REGISTER_BOUNDARY_FLAGS?last_cig_q:(cig_i+1==cing_r);
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin more_tiles_q<=0;more_cogs_q<=0;more_cigs_q<=0;last_cig_q<=0;end
        else begin
            more_tiles_q<=tile_i+1<ntile_r;more_cogs_q<=cog_i+1<cog_r;
            more_cigs_q<=cig_i+1<cing_r;last_cig_q<=cig_i+1==cing_r;
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && REGISTER_BOUNDARY_FLAGS!=0)begin
        if((st==S_FILL || st==S_CLR || st==S_PX || st==S_EMIT) &&
           npx_cur!=npix_cur32)
            $fatal(1,"tile length not settled before use");
        if(st==S_PX && A4_FIXED_GEOMETRY!=0 && (cing_r>2 || cog_r>2 || npx_cur>T || npx_cur==0))
            $fatal(1,"A4 optimized group/tile counter range exceeded");
        if(st==S_NEXT && (more_tiles!=(tile_i+1<ntile_r) || more_cogs!=(cog_i+1<cog_r)))
            $fatal(1,"boundary flags not settled before NEXT");
        if(st==S_PX && (more_cigs!=(cig_i+1<cing_r) || last_cig!=(cig_i+1==cing_r)))
            $fatal(1,"input group flags not settled before MAC");
    end
`endif

    assign busy = (st != S_IDLE) && (st != S_DONE);
    assign done = (st == S_DONE);

    // ---- line buffer control ----
    //  Freeze the line buffers unless we are actually filling the cache.
    //  This is essential at start-up: the line buffer free-runs out of reset,
    //  and while cfg_w / cfg_h are still 0 (before S_INIT has run) its phase and
    //  row counters advance with meaningless parameters, leaving it in an
    //  arbitrary state when the real fill begins.
    // A registered window is an elastic output slot. A serializer's busy
    // cycle need not stop input columns when this slot is empty (notably
    // the skipped columns/rows of stride2). Stall only a live blocked window.
    assign lb_stall      = ((TILE_PREFETCH!=0) ? !producer_active : (st != S_FILL)) |
                          (!wc_wr_ready && (ELASTIC_WINDOW_INPUT==0 || lb_win_valid));
    assign lb_cfg_w      = w_r;
    assign lb_cfg_h      = h_r;
    assign lb_cfg_stride = stride_r;

    // ---- window cache write ----
    //  Gate on lb_win_valid as well!  win_valid has gaps (the line buffer is idle
    //  on the row overhead cycles), and writing on those cycles stores garbage
    //  and desynchronises the write count from the pixel index.
    assign wc_wr_valid = ((TILE_PREFETCH!=0) ? producer_active : (st == S_FILL)) && lb_win_valid;

    // ---- emit coordinate ----
    //------------------------------------------------------------------------
    //  Emit coordinate -- uses the OUTPUT grid, not the input grid
    //------------------------------------------------------------------------
    wire [31:0] tile_base = tile_i * T;

    // frame-global pixel index for the consumer's frame buffer
    assign px_global = tile_base[GW-1:0] + px_i;
    wire [31:0] px_abs    = tile_base + px_i;
    wire [15:0] emit_row  = (ow_r == 0) ? 16'd0 : (px_abs / ow_r);
    wire [15:0] emit_col  = (ow_r == 0) ? 16'd0 : (px_abs % ow_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE;
            cing_r <= 0; cog_r <= 0; w_r <= 0; h_r <= 0; stride_r <= 0;
            wbase_r <= 0; npix_r <= 0; ntile_r <= 0;
            tile_i <= 0; cog_i <= 0; cig_i <= 0; px_i <= 0;
            wm_ld_req <= 0; wm_ld_base <= 0; wm_ld_sel <= 0; wm_sel_buf <= 0;
            acc_clr <= 0; clr_px <= 0; mac_px <= 0; rd_px <= 0;
            mac_valid <= 0; mac_first<=0;mac_emit<=0;mac_global<=0;mac_cog<=0; pp_valid <= 0; out_row <= 0; out_col <= 0;
            wc_rd_addr <= 0; wc_cig_sel <= 0; wc_flush <= 0;
            pf_pending <= 1'b0;
            pf_complete <= 1'b0;
            fill_windows<=0;wc_release<=0;resident_valid<=0;
        end else begin
            // default: one-cycle strobes
            acc_clr   <= 1'b0;
            mac_valid <= 1'b0; mac_first<=1'b0;mac_emit<=0;
            pp_valid  <= 1'b0;
            wm_ld_req <= 1'b0;
            wc_flush  <= 1'b0;
            wc_release<=1'b0;
            if (TILE_PREFETCH!=0 && wc_wr_valid && wc_wr_ready) fill_windows<=fill_windows+1'b1;
            // ld_done is a pulse and can precede the end of the MAC tile.
            if (PREFETCH != 0 && pf_pending && wm_ld_done)
                pf_complete <= 1'b1;

            case (st)
            //----------------------------------------------------------------
            S_IDLE: if (start) st <= S_INIT;

            //----------------------------------------------------------------
            S_INIT: begin
                resident_valid<=0;
                w_r       <= cfg_w;
                h_r       <= cfg_h;
                stride_r  <= cfg_stride;
                wbase_r   <= cfg_wbase;
                cing_r    <= cing_w;
                cog_r     <= cog_w;
                ow_r      <= cfg_ow;
                oh_r      <= cfg_oh;
                // npix is the number of OUTPUT pixels; a stride-2 layer emits
                // roughly a quarter of the input pixels.
                npix_r    <= cfg_npix;
                fill_windows<=0;
                ntile_r   <= (cfg_npix + T - 1) / T;
                tile_i    <= 0;
                cog_i     <= 0;
                cig_i     <= 0;
                px_i      <= 0;
                wm_sel_buf<= 1'b0;
                pf_pending <= 1'b0;
                pf_complete <= 1'b0;
                st        <= S_FLUSH;
            end

            //----------------------------------------------------------------
            //  S_FLUSH: reset the window cache write pointer for a new tile
            //----------------------------------------------------------------
            S_FLUSH: begin
                wc_flush <= (TILE_PREFETCH==0);
                st       <= S_FILL;
            end

            //----------------------------------------------------------------
            //  S_FILL: stream one tile of windows into the cache
            //----------------------------------------------------------------
            S_FILL: begin
                if (TILE_PREFETCH!=0) begin
                    // Count only completely serialized windows. The producer
                    // fills the second tile while this one computes/emits.
                    if (wc_count>=npx_cur && !wc_wr_busy) begin
                        px_i<=0;cog_i<=0;cig_i<=0;st<=(CLEAR_ELIDE!=0)?S_WLD:S_CLR;
                    end
                end else if (lb_win_valid && wc_wr_ready) begin
                    if (px_i + 1 == npx_cur) begin
                        px_i  <= 0;
                        cog_i <= 0;
                        cig_i <= 0;
                        // The narrow win_cache accepted the bundle but still
                        // needs CING-1 cycles to finish its serial RAM writes.
                        st    <= S_DRAIN;
                    end else begin
                        px_i <= px_i + 1'b1;
                    end
                end
            end

            //----------------------------------------------------------------
            //  S_DRAIN: wait until the final bundle is fully serialized
            //----------------------------------------------------------------
            S_DRAIN: begin
                if (!wc_wr_busy)
                    st <= (CLEAR_ELIDE!=0)?S_WLD:S_CLR;
            end

            //----------------------------------------------------------------
            //  S_CLR: zero the tile's accumulators (one pixel per cycle)
            //----------------------------------------------------------------
            S_CLR: begin
                acc_clr <= 1'b1;
                clr_px  <= px_i;
                if (px_i + 1 == npx_cur) begin
                    px_i <= 0;
                    st   <= S_WLD;
                end else begin
                    px_i <= px_i + 1'b1;
                end
            end

            //----------------------------------------------------------------
            //  S_WLD: request the current group's weights
            //----------------------------------------------------------------
            S_WLD: begin
                if(resident_mode) begin
                    wm_sel_buf<=resident_bank;
                    if(resident_valid[resident_bank]) begin
                        wc_rd_addr<=0;wc_cig_sel<=cig_i;px_i<=0;st<=S_PX;
                    end else begin
                        wm_ld_req<=1;wm_ld_base<=cur_base;wm_ld_sel<=resident_bank;st<=S_WAIT;
                    end
                end else begin
                    if(PREFETCH==0 || !pf_pending) begin
                        wm_ld_req<=1;wm_ld_base<=cur_base;wm_ld_sel<=wm_sel_buf;
                    end
                    st<=S_WAIT;
                end
            end

            //----------------------------------------------------------------
            //  S_WAIT: wait for the weight load to finish, then start the MAC
            //    (waiting on ld_done, NOT on !busy: ld_req is registered, so
            //     busy is still low on the first cycle after the request)
            //----------------------------------------------------------------
            S_WAIT: begin
                if ((!resident_mode && PREFETCH != 0 && pf_pending) ?
                        (pf_complete || wm_ld_done) : wm_ld_done) begin
                    // A full S_WLD bubble separates the last registered MAC
                    // valid from this switch, including T=1 / partial tiles.
                    if (!resident_mode && PREFETCH != 0 && pf_pending) begin
                        wm_sel_buf <= ~wm_sel_buf;
                        pf_pending <= 1'b0;
                        pf_complete <= 1'b0;
                    end
                    if(resident_mode) resident_valid[wm_sel_buf]<=1;
                    wc_rd_addr <= {GW{1'b0}};
                    wc_cig_sel <= cig_i;
                    px_i       <= 0;
                    st         <= S_PX;
                end
            end

            //----------------------------------------------------------------
            //  S_PX: MAC over the tile for the current (cog, cig) group
            //----------------------------------------------------------------
            S_PX: begin
                // Issue exactly once into the buffer not used by this MAC.
                // Never speculate across output-group or tile boundaries.
                if (!resident_mode && PREFETCH != 0 && more_cigs &&
                        !pf_pending && !wm_ld_busy) begin
                    wm_ld_req <= 1'b1;
                    wm_ld_base <= cur_base + grp_bytes;
                    wm_ld_sel <= ~wm_sel_buf;
                    pf_pending <= 1'b1;
                    pf_complete <= 1'b0;
                end
                if(STREAM_EMIT==0 || more_cigs || pp_ready) begin
                mac_valid <= 1'b1;
                mac_emit <= (STREAM_EMIT!=0) && last_cig;
                mac_global<=tile_base[GW-1:0]+px_i;mac_cog<=8'(cog_i);
                mac_px    <= px_i;
                mac_first <= (CLEAR_ELIDE!=0) && (cig_i==0);

                if (px_i + 1 == npx_cur) begin
                    px_i <= 0;
                    // More input groups still to accumulate into the same
                    // accumulators -> go straight back for the next group,
                    // WITHOUT emitting.  EMIT happens once per OUTPUT group,
                    // after every input group has been accumulated.  (Doing it
                    // per input group was a real bug: with CING=2 it emitted
                    // twice as many pixels as the layer has.)
                    if (more_cigs) begin
                        cig_i <= cig_i + 1'b1;        // next input group
                        st    <= S_WLD;
                    end else begin
                        // last input group: pre-issue the accumulator read for
                        // emit pixel 0 (acc_bank registers its read data)
                        rd_px <= {GW{1'b0}};
                        st    <= (STREAM_EMIT!=0)?S_NEXT:S_EMIT;
                    end
                end else begin
                    px_i       <= px_i + 1'b1;
                    wc_rd_addr <= px_i + 1'b1;      // read one pixel ahead
                end
                end
            end

            //----------------------------------------------------------------
            //  S_EMIT: wide read + postproc, one pixel per cycle
            //    rd_px was issued on the previous cycle, so acc_rd_data is valid
            //    now and pp_valid can go high in the same cycle.
            //----------------------------------------------------------------
            S_EMIT: begin
                // The DDR-backed frame store can pause for an arbitrary
                // number of cycles.  Hold the accumulator address and pixel
                // index until the downstream write path reserves a slot.
                if (pp_ready) begin
                    pp_valid <= 1'b1;
                    out_row  <= emit_row;
                    out_col  <= emit_col;

                    if (px_i + 1 == npx_cur) begin
                        px_i <= 0;
                        st   <= S_NEXT;
                    end else begin
                        px_i  <= px_i + 1'b1;
                        rd_px <= px_i + 1'b1;    // pre-read the next pixel
                    end
                end
            end

            //----------------------------------------------------------------
            //  S_NEXT: advance (cig, cog, tile) -- reached after EMIT
            //----------------------------------------------------------------
            S_NEXT: begin
                if (more_cogs) begin
                    cig_i <= 16'd0;
                    cog_i <= cog_i + 1'b1;
                    st    <= (CLEAR_ELIDE!=0)?S_WLD:S_CLR;               // new output group: re-zero acc
                end else if (more_tiles) begin
                    cig_i  <= 16'd0;
                    cog_i  <= 16'd0;
                    tile_i <= tile_i + 1'b1;
                    wc_release <= (TILE_PREFETCH!=0);
                    if(TILE_PREFETCH!=0 && CLEAR_ELIDE!=0 && STREAM_EMIT!=0 &&
                       resident_mode && resident_valid[0] && cing_r==1 && cog_r==1 &&
                       wc_count==2*T && !wc_wr_busy)begin
                        // The next bank is already complete. Weights stay on bank0;
                        // the synchronous window RAM gets one lead cycle before MAC.
                        wc_rd_addr<=0;wc_cig_sel<=0;px_i<=0;st<=S_PX;
                    end else st<=S_FLUSH;
                end else begin
                    st <= S_DONE;
                end
            end

            //----------------------------------------------------------------
            S_DONE: if (!start) st <= S_IDLE;

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
