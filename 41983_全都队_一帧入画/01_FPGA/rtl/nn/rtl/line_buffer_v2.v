//============================================================================
//  line_buffer_v2.v  --  3x3 window generator with reflection padding
//                         and runtime-configurable stride (1 or 2)
//----------------------------------------------------------------------------
//  Purpose
//    Front end of the convolution core.  Consumes a streaming, row-scan
//    pixel bus and emits one 3x3 window per INCLUDED output pixel.
//
//  Features
//    * P_CI parallel input channels (parameterised: 1 / 2 / 4 ... up to 32)
//    * streaming input, one output window per cycle while emitting
//    * reflection padding (PyTorch ReflectionPad2d(1) semantics) on all
//      4 borders, with NO extra address-remapping hardware
//    * two true-dual-port line RAM blocks per channel, read-first behaviour
//    * cfg_stride = 1 or 2  (2 = subsample to even rows / even columns)
//    * STALLABLE: the `stall` input freezes the whole pipeline (phase counter,
//      shift registers and outputs) so a slow consumer can back-pressure it.
//      While stalled the current window stays valid on the output, so a
//      downstream FIFO can absorb it with a normal valid/ready handshake --
//      assert stall whenever the consumer cannot accept.
//
//  Stride semantics
//    For stride S, padding 1, kernel 3:
//        OUT_W = (W - 1) / S + 1
//        OUT_H = (H - 1) / S + 1
//    Output pixel (i,j) uses the input window centred at (S*i, S*j):
//        rows {S*i-1, S*i, S*i+1}  x  cols {S*j-1, S*j, S*j+1}
//    All input rows and columns are still streamed in and stored, because
//    the windows of consecutive output rows overlap -- no input can be
//    skipped.  The only change is that a window is EMITTED for a subset of
//    the cycles.
//
//  Why 2 RAM blocks are enough  (the key idea)
//    Output row r needs input rows r-1, r, r+1.  When input row k arrives
//    (k = r+1) the two line buffers already hold rows k-2 and k-1:
//
//        block (k%2)     : port0 = WRITE row k    (addr = column)
//                          port1 = READ  row k-2  (same addr!)          <--+
//        block ((k+1)%2) : port0 = READ  row k-1                         |
//                                                                        |
//    The same-address read+write on block (k%2) relies on true-dual-port  |
//    READ-FIRST behaviour: the read returns the OLD value (row k-2) while |
//    the write stores the NEW value (row k). ----------------------------+
//
//  Why reflection padding needs no address remapping
//    Each border reuses a tap that is already available:
//        row r=0    : top row  (row -1) = bottom row (= current row)
//        row r=H-1  : bottom row(row H) = top row    (= row H-2)
//        col c=0    : left  tap         = right tap
//        col c=W-1  : right tap         = left  tap
//    Row reflection is applied on the shift-register push value, column
//    reflection on the window assembly mux.
//
//  Timing (cfg_w + 2 cycles per input row)
//    ph = 0 .. cfg_w-1 : accept input column, write RAM, issue read address
//                        (in_ready = 1 while row < cfg_h)
//    ph = 1 .. cfg_w   : RAM data valid -> push shift registers
//    ph = 2 .. cfg_w+1 : emit candidate window for column (ph-2)/stride,
//                        only when (ph-2) is stride-aligned
//    ph = cfg_w + 1    : closing cycle (in_ready = 0); realises the right
//                        border reflection
//
//    Windows are additionally gated by row: emitted only while (row-1) is
//    stride-aligned, so a stride-2 layer skips every other input row.
//
//  Notes / limitations
//    * cfg_w / cfg_h / cfg_stride may only change while the module is idle.
//    * Only stride 1 and 2 are supported (1 is the identity path).
//    * MAX_W must satisfy MAX_W <= 2**ADDR_W.
//    * The last input row (k = H) is a VIRTUAL row: no write, only reads.
//      For stride 2 with even H it is traversed but emits nothing.
//============================================================================

`default_nettype none

//----------------------------------------------------------------------------
//  Simple dual-port line RAM, READ-FIRST, one write port + one read port.
//  Keeping the port roles fixed matches Efinity's embedded-RAM template.
//----------------------------------------------------------------------------
module line_ram #(
    parameter integer DW = 8,
    parameter integer AW = 10,
    parameter integer DEPTH = (1<<AW)
)(
    input  wire           clk,
    input  wire           wr_en,
    input  wire [AW-1:0]  wr_addr,
    input  wire [DW-1:0]  wr_data,
    input  wire           rd_en,
    input  wire [AW-1:0]  rd_addr,
    output reg  [DW-1:0]  rd_data
);
    generate if(DEPTH>1024 && DEPTH<(1<<AW))begin:G_SEGMENTED
        localparam BANKS=(DEPTH+511)/512;
        wire [DW-1:0] bank_q[0:BANKS-1];
        reg [AW-10:0] read_bank;
        always @(posedge clk)if(rd_en)read_bank<=rd_addr[AW-1:9];
        genvar bank;
        for(bank=0;bank<BANKS;bank=bank+1)begin:G_BANK
            localparam WORDS=(DEPTH-bank*512>=512)?512:DEPTH-bank*512;
            (* syn_ramstyle="block_ram" *) reg [DW-1:0] mem[0:WORDS-1];
            reg [DW-1:0] q;
            always @(posedge clk)begin
                if(wr_en && wr_addr[AW-1:9]==bank)mem[wr_addr[8:0]]<=wr_data;
                if(rd_en && rd_addr[AW-1:9]==bank)q<=mem[rd_addr[8:0]];
            end
            assign bank_q[bank]=q;
        end
        always @*rd_data=bank_q[read_bank];
    end else begin:G_FLAT
        (* syn_ramstyle="block_ram" *) reg [DW-1:0] mem[0:DEPTH-1];
        always @(posedge clk)if(wr_en)mem[wr_addr]<=wr_data;
        always @(posedge clk)if(rd_en)rd_data<=mem[rd_addr];
    end endgenerate

endmodule


//----------------------------------------------------------------------------
//  Main module
//----------------------------------------------------------------------------
module line_buffer_v2 #(
    parameter integer P_CI   = 4,       // parallel input channels
    parameter integer CH_W   = 8,       // pixel width (int8)
    parameter integer MAX_W  = 640,     // max row width
    parameter integer ADDR_W = 10       // line RAM address width
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ---- back-pressure: freeze the pipeline when the consumer is not ready ----
    input  wire                    stall,

    // ---- layer configuration (update only while idle) ----
    input  wire [15:0]             cfg_w,       // active row width
    input  wire [15:0]             cfg_h,       // active row height
    input  wire [1:0]              cfg_stride,  // 1 or 2 (2 = subsample)

    // ---- input pixel stream (row scan, P_CI channels in parallel) ----
    input  wire                    in_valid,
    output wire                    in_ready,
    input  wire [P_CI*CH_W-1:0]    in_px,

    // ---- 3x3 window output ----
    output reg                     win_valid,
    output reg  [15:0]             win_row,
    output reg  [15:0]             win_col,
    output wire [P_CI*9*CH_W-1:0]  win_data    // per channel: 9 taps, row-major
);

    localparam integer PW = P_CI * CH_W;   // packed pixel word width

    //------------------------------------------------------------------------
    //  Stride decode  (only 1 and 2 are supported; anything else -> 1)
    //------------------------------------------------------------------------
    wire str1 = (cfg_stride != 2'd2);      // true when stride == 1

    //------------------------------------------------------------------------
    //  Phase / row counters
    //    ph  : 0 .. cfg_w+1  within a row
    //    row : 0 .. cfg_h    input row index k (cfg_h = virtual extra row)
    //------------------------------------------------------------------------
    reg [15:0] ph;
    reg [15:0] row;

    wire ph_last  = (ph  == (cfg_w + 16'd1));
    wire row_last = (row == cfg_h);

    wire take_input = (ph < cfg_w);                 // input column valid window
    wire real_row   = (row < cfg_h);                // false on the virtual last row
    // in_ready must also drop while stalled, otherwise the upstream source
    // would advance and the held input word would be lost.
    assign in_ready = take_input & real_row & ~stall;
    // Real input columns advance only on an actual valid/ready transfer.
    // Border overhead and the virtual final row do not consume input and may
    // advance autonomously.  This distinction is required once DDR inserts
    // arbitrary gaps between pixels.
    wire advance = ~stall & (~take_input | ~real_row | in_valid);

    // input delayed by one cycle so it lines up with the RAM read data
    reg [PW-1:0] in_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph    <= 16'd0;
            row   <= 16'd0;
            in_d1 <= {PW{1'b0}};
        end else if (advance) begin
            in_d1 <= in_px;
            if (ph_last) begin
                ph  <= 16'd0;
                row <= row_last ? 16'd0 : (row + 16'd1);
            end else begin
                ph <= ph + 16'd1;
            end
        end
    end

    //------------------------------------------------------------------------
    //  Line RAM access
    //------------------------------------------------------------------------
    wire wr_en     = in_valid & take_input & real_row & ~stall;

    // NOTE (subtle): rd_en must ALSO be frozen by `stall`.
    //   rd_mid / rd_top are REGISTERED RAM read outputs, so their value is
    //   "the word read on the previous cycle".  While the pipeline runs free
    //   the previous cycle's address is exactly ph-1, which is what the push
    //   expects.  If the read kept running while stalled, the address would
    //   stay at ph for many cycles and the registered output would drift to
    //   mem[ph] -- so the value pushed into the shift registers (and hence the
    //   emitted window) would depend on HOW LONG the stall lasted.
    //   Freezing rd_en makes the read data hold, which is the correct
    //   behaviour: the push then sees mem[ph-1] as it does when running free.
    wire rd_en     = take_input & advance;
    wire [ADDR_W-1:0] ram_addr = ph[ADDR_W-1:0];

    wire wr_par = row[0];                    // block that receives the write

    // per-channel read results
    wire [PW-1:0] rd_top;   // row k-2  (== top row of the window)
    wire [PW-1:0] rd_mid;   // row k-1  (== middle row)

    // Channels share identical addresses/enables. Pack them into two wide
    // synchronous line RAMs rather than four independent byte-wide RAM pairs.
    // Preserve exactly the same read-first, one-cycle and stall behavior.
    genvar gc;
    wire [PW-1:0] b0_rd,b1_rd;
    line_ram #(.DW(PW),.AW(ADDR_W),.DEPTH(MAX_W)) u_ram0(
        .clk(clk),.wr_en(~wr_par & wr_en),.wr_addr(ram_addr),.wr_data(in_px),
        .rd_en(rd_en),.rd_addr(ram_addr),.rd_data(b0_rd));
    line_ram #(.DW(PW),.AW(ADDR_W),.DEPTH(MAX_W)) u_ram1(
        .clk(clk),.wr_en(wr_par & wr_en),.wr_addr(ram_addr),.wr_data(in_px),
        .rd_en(rd_en),.rd_addr(ram_addr),.rd_data(b1_rd));
    assign rd_top=wr_par?b1_rd:b0_rd;
    assign rd_mid=wr_par?b0_rd:b1_rd;

    //------------------------------------------------------------------------
    //  Shift-register push values  (row-direction reflection)
    //------------------------------------------------------------------------
    wire push_phase  = (ph >= 16'd1) && (ph <= cfg_w);       // normal push
    wire close_phase = (ph == (cfg_w + 16'd1));              // border close

    // output row 0 (row == 1) : top row is reflected onto the current row
    // virtual last row (row == cfg_h) : bottom row is reflected onto top row
    // Single-row images (cfg_h == 1) make both conditions true at once, in
    // which case every window row is the one and only input row.
    wire single_row = (cfg_h == 16'd1);
    wire top_sel_cur = (row == 16'd1);
    wire bot_sel_top = (row == cfg_h);

    wire [PW-1:0] push_top = single_row ? rd_mid : (top_sel_cur ? in_d1 : rd_top);
    wire [PW-1:0] push_mid = rd_mid;
    wire [PW-1:0] push_bot = single_row ? rd_mid : (bot_sel_top ? rd_top : in_d1);

    //------------------------------------------------------------------------
    //  3-deep shift registers, one per window row
    //------------------------------------------------------------------------
    reg [PW-1:0] sr_t0, sr_t1, sr_t2;
    reg [PW-1:0] sr_m0, sr_m1, sr_m2;
    reg [PW-1:0] sr_b0, sr_b1, sr_b2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr_t0 <= {PW{1'b0}}; sr_t1 <= {PW{1'b0}}; sr_t2 <= {PW{1'b0}};
            sr_m0 <= {PW{1'b0}}; sr_m1 <= {PW{1'b0}}; sr_m2 <= {PW{1'b0}};
            sr_b0 <= {PW{1'b0}}; sr_b1 <= {PW{1'b0}}; sr_b2 <= {PW{1'b0}};
        end else if (advance && push_phase) begin
            sr_t0 <= sr_t1; sr_t1 <= sr_t2; sr_t2 <= push_top;
            sr_m0 <= sr_m1; sr_m1 <= sr_m2; sr_m2 <= push_mid;
            sr_b0 <= sr_b1; sr_b1 <= sr_b2; sr_b2 <= push_bot;
        end else if (advance && close_phase) begin
            // right border: keep the newest slot(s), shift so that the window
            // for the last column reuses the second-to-last column.
            // (sr_t2 must be HELD, not shifted, otherwise a 1-column image
            //  loses its only sample.)
            sr_t0 <= sr_t1; sr_t1 <= sr_t2;
            sr_m0 <= sr_m1; sr_m1 <= sr_m2;
            sr_b0 <= sr_b1; sr_b1 <= sr_b2;
        end
    end

    //------------------------------------------------------------------------
    //  Emit scheduling  (stride aware)
    //------------------------------------------------------------------------
    //  A window is emitted for output pixel (i, j) where
    //      i = (row - 1) / stride        (valid when (row-1) % stride == 0)
    //      j = (ph  - 2) / stride        (valid when (ph -2) % stride == 0)
    //  The shift-register contents at that moment are
    //      t0 = col (S*j - 1),  t1 = col (S*j),  t2 = col (S*j + 1)
    //  i.e. exactly the horizontal window of output column j.
    //------------------------------------------------------------------------
    wire [15:0] ph_m2 = ph - 16'd2;         // column candidate (before /stride)
    wire [15:0] row_m1 = row - 16'd1;       // row candidate    (before /stride)

    wire col_in_range = (ph >= 16'd2) && (ph <= (cfg_w + 16'd1));
    wire col_aligned  = str1 | ~ph_m2[0];   // stride 2 -> (ph-2) must be even
    wire col_ok       = col_in_range & col_aligned;

    wire row_valid    = (row >= 16'd1);
    wire row_aligned  = str1 | ~row_m1[0];  // stride 2 -> (row-1) must be even
    wire row_ok       = row_valid & row_aligned;

    wire        win_valid_c = col_ok & row_ok;
    wire [15:0] win_col_c   = str1 ? ph_m2 : {1'b0, ph_m2[15:1]};
    wire [15:0] win_row_c   = str1 ? row_m1 : {1'b0, row_m1[15:1]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_valid <= 1'b0;
            win_row   <= 16'd0;
            win_col   <= 16'd0;
        end else if (advance) begin
            win_valid <= win_valid_c;
            if (win_valid_c) begin
                win_row <= win_row_c;
                win_col <= win_col_c;
            end
        end else if (!stall) begin
            // Waiting for the next DDR pixel is not downstream backpressure:
            // suppress the old pulse so the cache cannot accept it twice.
            win_valid <= 1'b0;
        end
    end

    // NOTE: the window mux below is combinational over the shift registers,
    //       while win_col is a register.  The border selects MUST therefore
    //       use win_col (not the combinational column candidate), otherwise
    //       the left / right border tap substitution lags one cycle and the
    //       outer-most shift-register slot (which is stale across rows)
    //       leaks into the window.
    wire [16:0] col_center = str1 ? {1'b0, win_col} : {win_col, 1'b0};  // S*j
    wire at_left  = (win_col == 16'd0);
    wire at_right = ((col_center + 17'd1) >= {1'b0, cfg_w});
    // single-column images: every tap is the same sample
    wire single_col = (cfg_w == 16'd1);

    generate
        for (gc = 0; gc < P_CI; gc = gc + 1) begin : G_WIN
            wire [CH_W-1:0] t0 = sr_t0[gc*CH_W +: CH_W];
            wire [CH_W-1:0] t1 = sr_t1[gc*CH_W +: CH_W];
            wire [CH_W-1:0] t2 = sr_t2[gc*CH_W +: CH_W];
            wire [CH_W-1:0] m0 = sr_m0[gc*CH_W +: CH_W];
            wire [CH_W-1:0] m1 = sr_m1[gc*CH_W +: CH_W];
            wire [CH_W-1:0] m2 = sr_m2[gc*CH_W +: CH_W];
            wire [CH_W-1:0] b0 = sr_b0[gc*CH_W +: CH_W];
            wire [CH_W-1:0] b1 = sr_b1[gc*CH_W +: CH_W];
            wire [CH_W-1:0] b2 = sr_b2[gc*CH_W +: CH_W];

            // horizontal reflection select  (+ single-column degenerate case)
            wire [CH_W-1:0] tl = single_col ? t2 : (at_left  ? t2 : t0);
            wire [CH_W-1:0] tm = single_col ? t2 :             t1;
            wire [CH_W-1:0] tr = single_col ? t2 : (at_right ? t0 : t2);

            wire [CH_W-1:0] ml = single_col ? m2 : (at_left  ? m2 : m0);
            wire [CH_W-1:0] mm = single_col ? m2 :             m1;
            wire [CH_W-1:0] mr = single_col ? m2 : (at_right ? m0 : m2);

            wire [CH_W-1:0] bl = single_col ? b2 : (at_left  ? b2 : b0);
            wire [CH_W-1:0] bm = single_col ? b2 :             b1;
            wire [CH_W-1:0] br = single_col ? b2 : (at_right ? b0 : b2);

            // row-major packing: top(3) mid(3) bot(3)
            assign win_data[(gc*9+0)*CH_W +: CH_W] = tl;
            assign win_data[(gc*9+1)*CH_W +: CH_W] = tm;
            assign win_data[(gc*9+2)*CH_W +: CH_W] = tr;
            assign win_data[(gc*9+3)*CH_W +: CH_W] = ml;
            assign win_data[(gc*9+4)*CH_W +: CH_W] = mm;
            assign win_data[(gc*9+5)*CH_W +: CH_W] = mr;
            assign win_data[(gc*9+6)*CH_W +: CH_W] = bl;
            assign win_data[(gc*9+7)*CH_W +: CH_W] = bm;
            assign win_data[(gc*9+8)*CH_W +: CH_W] = br;
        end
    endgenerate

endmodule

`default_nettype wire
