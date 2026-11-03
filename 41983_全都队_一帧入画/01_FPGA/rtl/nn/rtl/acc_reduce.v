//============================================================================
//  acc_reduce.v -- statistics accumulator (S1 / S2) for normalisation
//----------------------------------------------------------------------------
//  Accumulates, per output channel, the two sums InstanceNorm needs:
//
//      S1[co] = SUM_pixels  x          where x = (acc >> SH)
//      S2[co] = SUM_pixels  x^2
//
//  from which  T = N*S2 - S1^2  (== N^2 * variance, exact in integers).
//
//  Where the data comes from
//    acc_bank's WIDE READ already presents all P_CO accumulators of one pixel
//    during EMIT, which is exactly the pre-normalisation accumulator the
//    statistics must be measured on.  So acc_reduce simply taps that bus with
//    `in_valid` (= the EMIT strobe) -- no extra memory traffic.
//
//  Why SH appears at all
//    The raw accumulator is wide; shifting it right by SH keeps the squaring
//    multiplier and S2 narrow.  SH cancels out of the final A/B (see the
//    derivation in norm_coeff.v), so it does not bias the result -- but SH
//    must match the actual magnitude of acc, or precision is lost.
//
//  Clear semantics (the contract that bit us before)
//    CLEAR once per LAYER (not per tile): a channel's statistics span every
//    tile, so the accumulators persist across the whole layer and are only
//    reset at the start of the next layer.
//============================================================================

`default_nettype none

module acc_reduce #(
    parameter integer P_CO  = 8,        // channels in parallel
    parameter integer ACC_W = 32,       // accumulator width
    parameter integer SH    = 4,        // statistics right-shift
    parameter integer S1_W  = 48,       // signed
    parameter integer S2_W  = 56        // unsigned
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- control ----
    input  wire                       clear,        // start of a layer
    input  wire                       in_valid,     // one pixel's accumulators

    // ---- input: the wide accumulator read ----
    input  wire [P_CO*ACC_W-1:0]      acc_in,

    // ---- results ----
    output wire [P_CO*S1_W-1:0]       s1_out,
    output wire [P_CO*S2_W-1:0]       s2_out
);

    reg signed [S1_W-1:0] s1 [0:P_CO-1];
    reg        [S2_W-1:0] s2 [0:P_CO-1];

    integer c;
    genvar  g;

    //------------------------------------------------------------------------
    //  TRAP: the squaring multiply must be done in a SIGNED context.
    //  s2 is an UNSIGNED reg, so writing
    //      s2[c] <= s2[c] + ($signed(x) >>> SH) * ($signed(x) >>> SH);
    //  makes the whole right-hand side unsigned, the $signed() casts are
    //  discarded, and a negative sample is squared as its raw 32-bit pattern
    //  (e.g. -936 becomes 4294966360).  The result wrapped to ~2^56.
    //  Declaring the product wire as `signed` keeps the multiply signed; the
    //  product of two x values is always >= 0, so zero-extending it into the
    //  unsigned S2 accumulator is exact.
    //------------------------------------------------------------------------
    wire signed [ACC_W-1:0]   x_sh [0:P_CO-1];
    wire signed [2*ACC_W-1:0] x_sq [0:P_CO-1];

    generate
        for (g = 0; g < P_CO; g = g + 1) begin : G_SQ
            assign x_sh[g] = $signed(acc_in[g*ACC_W +: ACC_W]) >>> SH;
            assign x_sq[g] = x_sh[g] * x_sh[g];
        end
    endgenerate

    generate
        for (g = 0; g < P_CO; g = g + 1) begin : G_OUT
            assign s1_out[g*S1_W +: S1_W] = s1[g];
            assign s2_out[g*S2_W +: S2_W] = s2[g];
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (c = 0; c < P_CO; c = c + 1) begin
                s1[c] <= {S1_W{1'b0}};
                s2[c] <= {S2_W{1'b0}};
            end
        end else if (clear) begin
            for (c = 0; c < P_CO; c = c + 1) begin
                s1[c] <= {S1_W{1'b0}};
                s2[c] <= {S2_W{1'b0}};
            end
        end else if (in_valid) begin
            for (c = 0; c < P_CO; c = c + 1) begin
                s1[c] <= s1[c] + x_sh[c];
                s2[c] <= s2[c] + x_sq[c][S2_W-1:0];
            end
        end
    end

endmodule

`default_nettype wire
