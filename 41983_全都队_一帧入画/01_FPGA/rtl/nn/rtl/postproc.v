//============================================================================
//  postproc.v -- merged normalisation + requantisation + ReLU + saturation
//----------------------------------------------------------------------------
//  Per lane, computes the single fused multiply-add that replaces the
//  two-step chain (normalise, then requantise):
//
//      y = clamp( requant( acc * A' + B' ) )
//
//  Derivation
//      The textbook chain is
//          t   = A * acc + B                 (instance/batch normalisation)
//          y   = t * M_mul                   (requantisation)
//      which folds into
//          y   = (A * M_mul) * acc + (B * M_mul)
//              = A' * acc + B'
//      so the hardware needs ONE multiplier and ONE adder per lane.  A' and B'
//      are recomputed once per layer (416 values for this network).
//
//  Arithmetic (all signed, exact integer semantics)
//      prod = acc * a_mul                      -> PW = ACC_W + A_W bits
//      sum  = prod + sign_extend(b_add)        -> PW bits
//      q    = sum >>> SA                       -> arithmetic shift (floor)
//      q    = (q < 0 && relu_en) ? 0 : q       -> ReLU
//      y    = min(max(q, SAT_MIN), SAT_MAX)    -> saturation
//
//  Rounding
//      The shift is a FLOOR, so a round-to-nearest offset must be folded into
//      b_add by the coefficient generator (add 1<<(SA-1) with the correct
//      sign).  This keeps the datapath free of an extra adder.
//
//  Note on the ReLU / saturation order
//      For ReLU layers the quantisation zero point is non-negative, so doing
//      ReLU before saturation does not change the result.  For non-ReLU layers
//      relu_en is 0 and only saturation applies.
//============================================================================

`default_nettype none

module postproc #(
    parameter integer P_RD    = 8,      // lanes (channels processed per cycle)
    parameter integer ACC_W   = 32,     // accumulator width
    parameter integer A_W     = 32,     // multiplicative coefficient width
    parameter integer B_W     = A_W,    // additive coefficient width
    parameter integer SA      = 20,     // fractional bits of A'
    parameter integer SAT_MIN = -127,   // symmetric int8 clamp
    parameter integer SAT_MAX = 127,
    parameter integer ROUND_EVEN = 0,
    parameter integer SHIFT_ONLY = 0,
    parameter integer SHIFT_ACC_W = ACC_W, // optional proved A4 input bound
    parameter integer PIPE    = 1       // 0=combinational, 1=output register, 3=three-stage
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       in_valid,

    input  wire [P_RD*ACC_W-1:0]      acc_in,
    input  wire [P_RD*A_W-1:0]        a_mul,
    input  wire [P_RD*B_W-1:0]        b_add,
    input  wire                       relu_en,

    output reg                        out_valid,
    output reg  [P_RD*8-1:0]          out_data
);

    localparam integer PW = ACC_W + A_W;

    //------------------------------------------------------------------------
    //  Per-lane fused multiply-add + requantise + ReLU + saturate
    //------------------------------------------------------------------------
    wire [P_RD*8-1:0] y_comb;

    genvar g;
    generate
        for (g = 0; g < P_RD; g = g + 1) begin : G_LANE

            if (SHIFT_ONLY != 0) begin : G_FIXED_SHIFT
                // A4: A is exactly 2^15, 2^16, 2^17 or 2^18; B=bias_q*A.
                // Preserve the same three-stage latency and signed ties-to-even.
                reg signed [SHIFT_ACC_W-1:0] acc_r;
                reg signed [B_W-15-1:0] bias_r;
                reg signed [SHIFT_ACC_W:0] sum_r;
                reg [1:0] shift_r, shift_sum;
                reg relu_r, relu_sum;
                wire [A_W-1:0] coeff = a_mul[g*A_W +: A_W];
                wire signed [B_W-1:0] bias = b_add[g*B_W +: B_W];
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        acc_r<=0;bias_r<=0;sum_r<=0;shift_r<=0;shift_sum<=0;relu_r<=0;relu_sum<=0;
                    end else begin
                        acc_r<=(coeff==0) ? 0 : acc_in[g*ACC_W +: SHIFT_ACC_W];
                        case (coeff)
                            32'd32768: begin bias_r<=bias>>>15;shift_r<=3;end
                            32'd262144: begin bias_r<=bias>>>18;shift_r<=2;end
                            32'd131072: begin bias_r<=bias>>>17;shift_r<=1;end
                            default: begin bias_r<=bias>>>16;shift_r<=0;end
                        endcase
                        relu_r<=relu_en;
                        sum_r<=$signed({acc_r[SHIFT_ACC_W-1],acc_r})+$signed({{(SHIFT_ACC_W+1-(B_W-15)){bias_r[B_W-16]}},bias_r});
                        shift_sum<=shift_r;relu_sum<=relu_r;
                    end
                end
                wire signed [SHIFT_ACC_W:0] floor_q = (shift_sum==3) ? (sum_r>>>9) : (shift_sum==2) ? (sum_r>>>6) :
                                                (shift_sum==1) ? (sum_r>>>7) : (sum_r>>>8);
                wire greater_half = (shift_sum==3) ? (sum_r[8:0]>9'd256) : (shift_sum==2) ? (sum_r[5:0]>6'd32) :
                                    (shift_sum==1) ? (sum_r[6:0]>7'd64) : (sum_r[7:0]>8'd128);
                wire equal_half = (shift_sum==3) ? (sum_r[8:0]==9'd256) : (shift_sum==2) ? (sum_r[5:0]==6'd32) :
                                  (shift_sum==1) ? (sum_r[6:0]==7'd64) : (sum_r[7:0]==8'd128);
                wire signed [SHIFT_ACC_W:0] rounded_q = floor_q + ((greater_half || (equal_half && floor_q[0])) ? 1'b1 : 1'b0);
                wire signed [SHIFT_ACC_W:0] relu_q = (relu_sum && rounded_q<0) ? 0 : rounded_q;
                wire signed [SHIFT_ACC_W:0] saturated_q = (relu_q>SAT_MAX) ? SAT_MAX : (relu_q<SAT_MIN) ? SAT_MIN : relu_q;
                if(SAT_MIN==-127 && SAT_MAX==127)begin:G_NARROW_ROUND
                    // Rounding adds only 0 or 1. Values outside this interval
                    // saturate identically before or after rounding; inside it
                    // an 8-bit addition cannot overflow. Negative ReLU rounds
                    // to either a negative value or zero, both yielding zero.
                    wire [7:0] narrow_q=floor_q[7:0]+(greater_half || (equal_half && floor_q[0]));
                    assign y_comb[g*8+:8]=(relu_sum && floor_q<0)?8'd0:
                        (floor_q>=127)?8'd127:(floor_q < -127)?8'h81:narrow_q;
`ifndef SYNTHESIS
                    always @(posedge clk)if(rst_n && y_comb[g*8+:8]!==saturated_q[7:0])
                        $fatal(1,"compact postproc differs from original signed rounding/saturation");
`endif
                end else begin:G_GENERIC_SATURATION
                    assign y_comb[g*8 +: 8] = saturated_q[7:0];
                end
`ifndef SYNTHESIS
                always @(posedge clk) if (rst_n && in_valid) begin
                    if (coeff!=0 && $signed(acc_in[g*ACC_W +: ACC_W]) != $signed(acc_in[g*ACC_W +: SHIFT_ACC_W]))
                        $fatal(1,"A4 accumulator input exceeds proved width");
                    if (PIPE!=3 || SA!=24 || (coeff!=0 && coeff!=32768 && coeff!=65536 && coeff!=131072 && coeff!=262144))
                        $fatal(1,"invalid A4 fixed-shift coefficients/latency");
                    if ((coeff==0 && bias!=0) || (coeff==32768 && bias[14:0]!=0) || (coeff==65536 && bias[15:0]!=0) || (coeff==131072 && bias[16:0]!=0) || (coeff==262144 && bias[17:0]!=0))
                        $fatal(1,"A4 bias is not an exact integer multiple of A");
                end
`endif
            end else begin : G_MULTIPLY
            wire signed [ACC_W-1:0] acc;
            wire signed [A_W-1:0] a;
            wire signed [B_W-1:0] b;
            wire lane_relu;
            wire signed [PW-1:0] prod;
            wire signed [PW-1:0] b_ext;
            if (PIPE == 3) begin : G_SPLIT
                reg signed [ACC_W-1:0] acc_r;
                reg signed [A_W-1:0] a_r;
                reg signed [B_W-1:0] b_r;
                reg relu_r, relu_product;
                reg signed [PW-1:0] product_r, bias_r;
                // Stage 1 terminates the accumulator RAM/shift/coeff paths.
                // Stage 2 terminates the exact signed product before add/clamp.
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        acc_r<=0; a_r<=0; b_r<=0; relu_r<=0;
                        product_r<=0; bias_r<=0; relu_product<=0;
                    end else begin
                        acc_r<=acc_in[g*ACC_W +: ACC_W];
                        a_r<=a_mul[g*A_W +: A_W];
                        b_r<=b_add[g*B_W +: B_W];
                        relu_r<=relu_en;
                        product_r<=acc_r*a_r;
                        bias_r<={{(PW-B_W){b_r[B_W-1]}},b_r};
                        relu_product<=relu_r;
                    end
                end
                assign prod=product_r;
                assign b_ext=bias_r;
                assign lane_relu=relu_product;
                assign acc=acc_r;
                assign a=a_r;
                assign b=b_r;
            end else begin : G_DIRECT
                assign acc=acc_in[g*ACC_W +: ACC_W];
                assign a=a_mul[g*A_W +: A_W];
                assign b=b_add[g*B_W +: B_W];
                assign prod=acc*a;
                assign b_ext={{(PW-B_W){b[B_W-1]}},b};
                assign lane_relu=relu_en;
            end

            // exact product, zero/sign extended to PW

            // sign-extend b to PW and add
            wire signed [PW-1:0] sum = prod + b_ext;

            // arithmetic shift right (floor) -- rounding is folded into b_add
            wire signed [PW-1:0] q_floor = sum >>> SA;
            localparam [SA-1:0] HALF = {1'b1, {(SA-1){1'b0}}};
            wire round_up = (sum[SA-1:0] > HALF) ||
                            ((sum[SA-1:0] == HALF) && q_floor[0]);
            wire signed [PW-1:0] q_raw = q_floor +
                (((ROUND_EVEN != 0) && round_up) ? {{(PW-1){1'b0}},1'b1} : {PW{1'b0}});

            // ReLU then symmetric saturation (comparison constants sign-extended
            // to PW so the part-selects stay in range)
            wire signed [PW-1:0] sat_max_ext = SAT_MAX;
            wire signed [PW-1:0] sat_min_ext = SAT_MIN;

            wire signed [PW-1:0] q_relu =
                (lane_relu && (q_raw < 0)) ? {PW{1'b0}} : q_raw;

            wire signed [PW-1:0] q_sat =
                (q_relu > sat_max_ext) ? sat_max_ext :
                (q_relu < sat_min_ext) ? sat_min_ext : q_relu;

            assign y_comb[g*8 +: 8] = q_sat[7:0];

            end
        end
    endgenerate

    //------------------------------------------------------------------------
    //  Optional output register
    //------------------------------------------------------------------------
    generate
        if (PIPE != 0) begin : G_PIPE
            reg [1:0] valid_delay;
            wire result_valid=(PIPE==3) ? valid_delay[1] : in_valid;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    valid_delay <= 0;
                    out_valid <= 1'b0;
                    out_data  <= {(P_RD*8){1'b0}};
                end else begin
                    valid_delay <= {valid_delay[0],in_valid};
                    out_valid <= result_valid;
                    if (result_valid)
                        out_data <= y_comb;
                end
            end
        end else begin : G_COMB
            always @* begin
                out_valid = in_valid;
                out_data  = y_comb;
            end
        end
    endgenerate

endmodule

`default_nettype wire
