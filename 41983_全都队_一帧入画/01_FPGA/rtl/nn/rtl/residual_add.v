//============================================================================
//  residual_add.v -- out = x + F(x)  with an int16 intermediate (R2 scheme)
//----------------------------------------------------------------------------
//  The model's residual block is  return x + self.c2(self.c1(x)).
//
//  Why this is NOT a plain int8 add
//    x and F are produced by different layers and therefore carry different
//    quantisation scales (InstanceNorm's gamma/beta are per-channel, so the
//    scale is per-channel too).  Going back to int8 would need a per-channel
//    multiply  q_out = (q_x*s_x + q_F*s_F) / s_out  -- 64 multipliers ~= 32 DSP
//    on top of the convolution's 144, which busts the 150 DSP budget.
//
//  The R2 scheme
//    The postproc stage is free to choose its output scale (A' already encodes
//    the scale), so the residual block makes c1 and c2 emit with the SAME
//    per-channel scale s.  Then
//
//        out_real = s*q_x + s*q_F = s*(q_x + q_F)
//        =>  q_out = q_x + q_F                 <- pure add, zero multipliers
//
//    and the sum (range +-254) simply needs a wider container: int16.
//    No rounding happens at all, so this is MORE accurate than an int8
//    requantisation, not less.
//
//  Structure
//    The two streams arrive as independent memories (in the real system the
//    layers are run one after another and land in external storage), so this
//    module is a simple streaming adder with a small elastic buffer.
//
//    Din  : q_x  stream  (int8 per channel, INT8_CODE_W)
//    Df   : q_F  stream  (int8 per channel)
//    Dout : q_x + q_F    (int16 per channel), saturating
//
//  Saturation
//    The natural sum is +-254 so saturation never triggers for legal inputs;
//    it is kept as a guard against malformed streams.  A separate `shift_out`
//    path (rounding right shift) is provided for closing a residual block back
//    into int8 -- that is the only place a shift is needed and it costs no
//    multiplier.
//============================================================================

`default_nettype none

module residual_add #(
    parameter integer C          = 32,      // channels
    parameter integer IN_W       = 8,       // input code width (int8)
    parameter integer OUT_W      = 16,      // output code width (int16)
    parameter integer SH         = 0        // >0: also emit a rounded, shifted
                                            // version (for closing the block)
)(
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     in_valid,
    input  wire [C*IN_W-1:0]        x_px,     // q_x
    input  wire [C*IN_W-1:0]        f_px,     // q_F

    output reg                      out_valid,
    output reg  [C*OUT_W-1:0]       out_px,   // q_x + q_F  (int16)

    // optional narrowed version (valid only when SH > 0)
    output reg                      sh_valid,
    output reg  [C*IN_W-1:0]        sh_px
);

    //------------------------------------------------------------------------
    //  Per-channel signed add with saturation
    //  Both operands are sign-extended to OUT_W, then summed.  The sum itself
    //  needs OUT_W+1 bits, so it is declared that way and only then clamped.
    //------------------------------------------------------------------------
    wire signed [OUT_W-1:0]   x_ext [0:C-1];
    wire signed [OUT_W-1:0]   f_ext [0:C-1];
    wire signed [OUT_W:0]     sum   [0:C-1];

    genvar g;
    generate
        for (g = 0; g < C; g = g + 1) begin : G_CH
            assign x_ext[g] = $signed(x_px[g*IN_W +: IN_W]);
            assign f_ext[g] = $signed(f_px[g*IN_W +: IN_W]);
            assign sum[g]   = x_ext[g] + f_ext[g];      // OUT_W+1 bits
        end
    endgenerate

    // saturating narrow from the OUT_W+1-bit sum into OUT_W bits
    function signed [OUT_W-1:0] sat16;
        input signed [OUT_W:0] v;
        localparam signed [OUT_W:0] HI =  (1 <<< (OUT_W-1)) - 1;
        localparam signed [OUT_W:0] LO = -(1 <<< (OUT_W-1));
        begin
            if (v > HI)      sat16 = HI[OUT_W-1:0];
            else if (v < LO) sat16 = LO[OUT_W-1:0];
            else             sat16 = v[OUT_W-1:0];
        end
    endfunction

    // rounded, saturating narrow to IN_W bits (only used when SH > 0)
    function signed [IN_W-1:0] narrow;
        input signed [OUT_W-1:0] v;
        input integer            sh;
        reg signed [OUT_W-1:0] t;
        localparam signed [OUT_W-1:0] HI = (1 <<< (IN_W-1)) - 1;
        localparam signed [OUT_W-1:0] LO = -(1 <<< (IN_W-1));
        begin
            if (sh > 0) t = (v + (1 <<< (sh-1))) >>> sh;   // round-half-up
            else        t = v;
            if (t > HI)      narrow = HI[IN_W-1:0];
            else if (t < LO) narrow = LO[IN_W-1:0];
            else             narrow = t[IN_W-1:0];
        end
    endfunction

    integer c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_px    <= {(C*OUT_W){1'b0}};
            sh_valid  <= 1'b0;
            sh_px     <= {(C*IN_W){1'b0}};
        end else begin
            out_valid <= in_valid;
            sh_valid  <= in_valid;
            if (in_valid) begin
                for (c = 0; c < C; c = c + 1) begin
                    out_px[c*OUT_W +: OUT_W] <= sat16(sum[c]);
                    if (SH > 0)
                        sh_px[c*IN_W +: IN_W] <= narrow(sat16(sum[c]), SH);
                end
            end
        end
    end

endmodule

`default_nettype wire
