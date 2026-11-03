//============================================================================
//  coeff_table.v -- A'/B' coefficient store for the postproc stage
//----------------------------------------------------------------------------
//  The InstanceNorm coefficients are computed one channel at a time (a divide
//  free reciprocal square root is far too slow to do per pixel), so they must
//  be stored and then read back P_CO at a time while the layer streams.
//
//  This is also what makes the FRAME-REUSE schedule possible: the coefficients
//  for layer L are produced at the end of frame N and read back during frame
//  N+1, so no layer ever has to make a second pass over its own data.
//
//  Organisation
//    DEPTH entries (one per output-channel group of the current layer).
//    The network sequencer overwrites the table only after the previous layer
//    has consumed all of its coefficients.
//    Each entry holds TWO vectors of P_CO words:
//        A'[0..P_CO-1]   and   B'[0..P_CO-1]
//    Writes are PER CHANNEL (that is the rate norm_coeff produces them);
//    reads are WHOLE-VECTOR (that is the rate postproc consumes them).
//
//  Both ports are registered, so a read address presented in cycle t yields
//  data in cycle t+1 -- the same convention as acc_bank's wide read.
//============================================================================

`default_nettype none

module coeff_table #(
    parameter integer P_CO  = 8,
    parameter integer A_W   = 32,
    parameter integer B_W   = A_W,
    parameter integer AW    = 6,        // $clog2(DEPTH)
    parameter integer CW    = 3,        // $clog2(P_CO)
    parameter integer DEPTH = 64
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- write: one channel at a time ----
    input  wire                       we,
    input  wire [AW-1:0]              waddr,     // entry (layer / cog)
    input  wire [CW-1:0]              wch,       // channel within the group
    input  wire signed [A_W-1:0]      wa,
    input  wire signed [B_W-1:0]      wb,

    // ---- read: the whole vector at once ----
    input  wire [AW-1:0]              raddr,
    output reg  [P_CO*A_W-1:0]        a_vec,
    output reg  [P_CO*B_W-1:0]        b_vec
);

    // With current-layer-only depth this store is only about 2 Kbit.  Mapping
    // it to logic avoids width/parallel-read fragmentation into 17 RAM10s.
    (* syn_ramstyle = "logic" *) reg signed [A_W-1:0] a_mem [0:DEPTH*P_CO-1];
    (* syn_ramstyle = "logic" *) reg signed [B_W-1:0] b_mem [0:DEPTH*P_CO-1];

    integer i;

    // Keep the memories themselves free of an asynchronous clear.  Clearing
    // every entry through rst_n turns the inferred RAM write port asynchronous
    // in Efinity; coefficients are written before their scheduled use anyway.
    always @(posedge clk) begin
        if (we) begin
            a_mem[waddr*P_CO + wch] <= wa;
            b_mem[waddr*P_CO + wch] <= wb;
        end
    end

    // The externally visible read vectors remain resettable and registered.
    // Separate nonblocking read/write blocks preserve the old-data-on-write
    // behavior when read and write addresses coincide in the same cycle.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_vec <= {(P_CO*A_W){1'b0}};
            b_vec <= {(P_CO*B_W){1'b0}};
        end else begin
            for (i = 0; i < P_CO; i = i + 1) begin
                a_vec[i*A_W +: A_W] <= a_mem[raddr*P_CO + i];
                b_vec[i*B_W +: B_W] <= b_mem[raddr*P_CO + i];
            end
        end
    end

endmodule

`default_nettype wire
