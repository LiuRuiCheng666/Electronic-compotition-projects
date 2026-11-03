//============================================================================
//  win_fifo.v -- elastic window buffer (first-word fall-through)
//----------------------------------------------------------------------------
//  Decouples a free-running producer from a slower consumer.
//
//  Why it exists
//    line_buffer_v2 emits one 3x3 window per cycle.  With CIN > P_CI the MAC
//    array must be time-shared over CING = CIN/P_CI input-channel groups, so
//    it consumes one window every CING*COG cycles.  The rate gap is
//    CING*COG (up to 32 for this network), i.e. the backlog is LAYER-sized --
//    far too large to buffer internally (enc.1 would need ~150k windows).
//
//    So the FIFO is deliberately SMALL (just enough to hide the response
//    latency of the back-pressure loop and to absorb burstiness).  The real
//    rate matching is done by asserting `stall` on the line buffers whenever
//    this FIFO cannot accept (see wr_ready).
//
//  Handshake
//    write : accepts when wr_valid && wr_ready
//    read  : FIRST-WORD FALL-THROUGH -- rd_data always shows the head entry
//            and rd_valid is high while non-empty, so the consumer may pop
//            with rd_valid && rd_ready
//
//  Note on the FPGA mapping
//    The combinational head read suits a small distributed-RAM / register
//    implementation.  If this is later mapped to an ESRAM with a registered
//    read, rd_valid must be delayed by one cycle accordingly.
//============================================================================

`default_nettype none

module win_fifo #(
    parameter integer DW    = 592,      // entry width
    parameter integer DEPTH = 16,       // entries; MUST be a power of two
    parameter integer AW    = 4         // = $clog2(DEPTH)
)(
    input  wire            clk,
    input  wire            rst_n,

    // ---- write side ----
    input  wire            wr_valid,
    output wire            wr_ready,
    input  wire [DW-1:0]   wr_data,

    // ---- read side (first-word fall-through) ----
    output wire            rd_valid,
    input  wire            rd_ready,
    output wire [DW-1:0]   rd_data,

    // ---- status ----
    output wire            full,
    output wire            empty,
    output wire [AW:0]     level
);

    reg [DW-1:0] mem [0:DEPTH-1];
    reg [AW:0]   count;
    reg [AW-1:0] wptr, rptr;

    assign empty    = (count == 0);
    assign full     = (count == DEPTH);
    assign wr_ready = (count < DEPTH);
    assign rd_valid = (count != 0);
    assign rd_data  = mem[rptr];        // first-word fall-through
    assign level    = count;

    wire do_wr = wr_valid && wr_ready;
    wire do_rd = rd_valid && rd_ready;

    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= {(AW+1){1'b0}};
            wptr  <= {AW{1'b0}};
            rptr  <= {AW{1'b0}};
            for (k = 0; k < DEPTH; k = k + 1) mem[k] <= {DW{1'b0}};
        end else begin
            if (do_wr) begin
                mem[wptr] <= wr_data;
                wptr      <= wptr + 1'b1;
            end
            if (do_rd)
                rptr <= rptr + 1'b1;

            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule

`default_nettype wire
