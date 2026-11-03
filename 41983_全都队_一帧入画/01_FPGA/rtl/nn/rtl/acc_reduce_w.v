//============================================================================
//  acc_reduce_w.v -- wide statistics accumulator for whole-network use
//----------------------------------------------------------------------------
//  Same job as acc_reduce, but sized for ALL output channels of a layer
//  (COUT_MAX) instead of just one P_CO group.
//
//  Why a separate module
//    conv_fsm walks the output channels in groups of P_CO (`cog`), emitting one
//    group at a time.  Whole-layer statistics need every group's S1/S2, so the
//    incoming P_CO lanes must be steered into the right slice of a wider array.
//    `lane_base` (= cog * P_CO, driven from conv_fsm's coeff_raddr) does that.
//    acc_reduce itself is left untouched so the B-group regression keeps
//    testing exactly what it tested before.
//
//  Clear once per LAYER (before the statistics pass), not per group.
//============================================================================

`default_nettype none

module acc_reduce_w #(
    parameter integer P_CO     = 8,      // lanes arriving per cycle
    parameter integer COUT_MAX = 32,     // lanes accumulated
    parameter integer ACC_W    = 32,
    parameter integer SH       = 5,
    parameter integer S1_W     = 48,
    parameter integer S2_W     = 56,
    parameter integer LW       = 5       // $clog2(COUT_MAX)
)(
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       clear,
    input  wire                       in_valid,
    input  wire [LW-1:0]              lane_base,     // cog * P_CO

    input  wire [P_CO*ACC_W-1:0]      acc_in,

    output wire [COUT_MAX*S1_W-1:0]   s1_out,
    output wire [COUT_MAX*S2_W-1:0]   s2_out
);

    reg signed [S1_W-1:0] s1 [0:COUT_MAX-1];
    reg        [S2_W-1:0] s2 [0:COUT_MAX-1];

    // per-lane shifted sample, kept signed so the square stays signed
    // (the unsigned-context trap from the B group)
    wire signed [ACC_W-1:0]   x_sh [0:P_CO-1];
    wire signed [2*ACC_W-1:0] x_sq [0:P_CO-1];

    integer c;
    genvar  g;

    generate
        for (g = 0; g < P_CO; g = g + 1) begin : G_SQ
            assign x_sh[g] = $signed(acc_in[g*ACC_W +: ACC_W]) >>> SH;
            assign x_sq[g] = x_sh[g] * x_sh[g];
        end
        for (g = 0; g < COUT_MAX; g = g + 1) begin : G_OUT
            assign s1_out[g*S1_W +: S1_W] = s1[g];
            assign s2_out[g*S2_W +: S2_W] = s2[g];
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (c = 0; c < COUT_MAX; c = c + 1) begin
                s1[c] <= {S1_W{1'b0}};
                s2[c] <= {S2_W{1'b0}};
            end
        end else if (clear) begin
            for (c = 0; c < COUT_MAX; c = c + 1) begin
                s1[c] <= {S1_W{1'b0}};
                s2[c] <= {S2_W{1'b0}};
            end
        end else if (in_valid) begin
            for (c = 0; c < P_CO; c = c + 1) begin
                if (lane_base + c < COUT_MAX) begin
                    s1[lane_base + c] <= s1[lane_base + c] + x_sh[c];
                    s2[lane_base + c] <= s2[lane_base + c] + x_sq[c][S2_W-1:0];
                end
            end
        end
    end

endmodule

`default_nettype wire
