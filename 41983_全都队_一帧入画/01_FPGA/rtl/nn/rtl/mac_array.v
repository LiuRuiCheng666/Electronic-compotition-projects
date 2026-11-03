//============================================================================
//  mac_array.v -- fully parallel 3x3 convolution MAC array
//----------------------------------------------------------------------------
//  Computes, for one pixel, the dot product of a 3x3 window against the
//  weights of P_CO output channels:
//
//      out_sum[co] = SUM over (ci, k) of  win[ci][k] * w[co][ci][k]
//
//  where ci indexes P_CI parallel input channels and k indexes the TAP (=9)
//  window positions in row-major order.
//
//  Data layout (both buses little-endian, int8 lanes)
//      win_data[(ci*TAP + k)*CH_W +: CH_W]
//      w_data  [((co*P_CI + ci)*TAP + k)*CH_W +: CH_W]
//      out_sum [ co*ACC_W +: ACC_W]                       (signed)
//
//  Physical size
//      MACs per cycle = P_CO * P_CI * TAP
//      With P_CO=4, P_CI=4, TAP=9 -> 144 MACs -> 72 DSP when DUAL_DSP=1.
//      DUAL_DSP=0 retains inferred multipliers for the legacy path.
//      P_CI is the time-multiplexing knob: the surrounding logic feeds
//      CIN/P_CI input-channel groups sequentially and accumulates the
//      partial sums in acc_bank.
//
//  Structure
//      Stage 1 : P_CO * P_CI * TAP int8 x int8 multipliers (-> signed ACC_W)
//      Stage 2 : per output channel, a BALANCED adder tree over all
//                P_CI*TAP products (ceil-half reduction, depth = ceil(log2))
//      Stage 3 : optional output register (PIPE = 0 or 1)
//
//  No overflow can occur for TAP=9, P_CI<=4: the largest partial sum is
//  36 * 128 * 128 = 589,824 < 2^20, and ACC_W is 32.
//
//  Limitations
//      * P_CI * TAP must be <= 64 (bounds the generated reduction to 6 levels)
//============================================================================

`default_nettype none

module mac_array #(
    parameter integer DUAL_DSP = 0,
    // Two DSPs form a short combinational cascade, adding matching lanes
    // internally. No extra DSPs, clock cycles, or changes to the public latency.
    parameter integer DSP_CASCADE = 1,
    parameter integer DSP_CASCADE_PAIRS = 2,
    // Contract: weights settle at least one clock before a valid MAC and
    // remain stable throughout a group. A4 schedulers satisfy this contract.
    // B registers prime during invalid cycles without changing pixel latency.
    parameter integer STABLE_WEIGHTS = 0,
    parameter integer P_CO  = 8,        // output channels computed in parallel
    parameter integer P_CI  = 4,        // input channels applied in parallel
    parameter integer TAP   = 9,        // 3x3
    parameter integer CH_W  = 8,        // operand width (int8)
    parameter integer ACC_W = 32,       // accumulator width
    parameter integer PIPE  = 1         // 1 = register the output
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          in_valid,

    input  wire [P_CI*TAP*CH_W-1:0]      win_data,
    input  wire [P_CO*P_CI*TAP*CH_W-1:0] w_data,

    output reg                           out_valid,
    output reg  [P_CO*ACC_W-1:0]         out_sum
);

    //------------------------------------------------------------------------
    //  Reduction geometry
    //------------------------------------------------------------------------
    localparam integer N0 = P_CI * TAP;
    localparam integer N1 = (N0 + 1) / 2;
    localparam integer N2 = (N1 + 1) / 2;
    localparam integer N3 = (N2 + 1) / 2;
    localparam integer N4 = (N3 + 1) / 2;
    localparam integer N5 = (N4 + 1) / 2;
    localparam integer N6 = (N5 + 1) / 2;
    // Move the existing one-cycle register inside each DSP cascade. Later
    // operands are registered on the same edge as the earlier partial sum.
    localparam integer DSP_RETIME = PIPE!=0 && DUAL_DSP!=0 && DSP_CASCADE!=0 &&
        CH_W==8 && N0%4==0 && (DSP_CASCADE_PAIRS==2 || DSP_CASCADE_PAIRS==4);
`ifndef SYNTHESIS
    reg [P_CO*P_CI*TAP*CH_W-1:0] previous_weights;
    always @(posedge clk)begin
        previous_weights<=w_data;
        if(rst_n && DSP_RETIME && STABLE_WEIGHTS!=0 && in_valid && w_data!==previous_weights)
            $fatal(1,"DSP weight priming contract violated");
    end
`endif

    // All supported geometries fit comfortably in signed 24 bits
    // (36 * 128 * 128 < 2^20).  Keeping the DSP reduction at this native
    // width avoids device-specific garbage in bits [31:24]; the final result
    // is explicitly sign-extended to the public ACC_W interface below.
    // An int8 product is at most 2^14; any partial sum has at most N0
    // terms. This width includes the positive all-minus-128 extreme too.
    localparam integer MAC_W = 2*CH_W+$clog2(N0+1)-1;

    //------------------------------------------------------------------------
    //  Products + balanced adder tree, one replica per output channel
    //------------------------------------------------------------------------
    wire signed [MAC_W-1:0] dot [0:P_CO-1];

    genvar gco, gn;
    generate
        for (gco = 0; gco < P_CO; gco = gco + 1) begin : G_CO

            // ---- stage 1: the P_CI*TAP products -------------------------
            wire signed [MAC_W-1:0] p [0:N0-1];
            if (DUAL_DSP!=0 && DSP_CASCADE!=0 && CH_W==8 && N0%4==0) begin : G_CASCADE
                // Each signed 24-bit lane sums up to four int8 products.
                // The DSP count and public one-cycle latency stay unchanged.
                for(gn=0;gn<(N0/2+DSP_CASCADE_PAIRS-1)/DSP_CASCADE_PAIRS;gn=gn+1)begin:G_CHAIN
                    localparam BASE=gn*DSP_CASCADE_PAIRS*2;
                    localparam COUNT=((N0-BASE)/2<DSP_CASCADE_PAIRS)?(N0-BASE)/2:DSP_CASCADE_PAIRS;
                    wire [47:0] chain[0:COUNT],result[0:COUNT];
                    assign chain[0]=0;
                    for(genvar step=0;step<COUNT;step=step+1)begin:G_PAIR
                        localparam IX=BASE+2*step;
                        // Keep the public one-cycle latency, but balance the
                        // fabric reduction against the short DSP cascade.
                        // Later input products use A/B registers on the same
                        // edge as this earlier partial-sum W register.
                        localparam CUT=(COUNT<3)?COUNT:3;
                        localparam REG_ACTIVE=DSP_RETIME && (STABLE_WEIGHTS!=0 || step>=CUT-1);
                        wire [7:0] a0=win_data[IX*8+:8],a1=win_data[(IX+1)*8+:8];
                        wire [7:0] b0=w_data[(gco*N0+IX)*8+:8],b1=w_data[(gco*N0+IX+1)*8+:8];
                        EFX_DSP48 #(.MODE("DUAL"),.SIGNED(1),.P_EXT("ALIGN_RIGHT"),
                            .A_REG(DSP_RETIME && step>=CUT),.B_REG(DSP_RETIME && (STABLE_WEIGHTS!=0 || step>=CUT)),
                            .W_REG(DSP_RETIME && step==CUT-1),
                            .M_SEL("P"),.N_SEL(step==0?"CONST0":"CASCIN"),.W_SEL(step==0?"P":"X"),.CASCOUT_SEL(step==0?"P":"W")) u_dsp(
                            .A({{3{a1[7]}},a1,a0}),.B({{2{b1[7]}},b1,b0}),.C(18'd0),
                            .CASCIN(chain[step]),.OP(2'b00),.SHIFT_ENA(1'b0),
                            .CLK(REG_ACTIVE?clk:1'b0),.CE(REG_ACTIVE?((STABLE_WEIGHTS!=0)?1'b1:in_valid):1'b0),.RST(REG_ACTIVE?!rst_n:1'b0),.O(result[step+1]),.CASCOUT(chain[step+1]),.OVFL());
                    end
                    assign p[BASE]=$signed(result[COUNT][23:0]);
                    assign p[BASE+1]=$signed(result[COUNT][47:24]);
                    for(genvar zero=2;zero<COUNT*2;zero=zero+1)begin:G_ZERO
                        assign p[BASE+zero]=0;
                    end
                end
            end else if (DUAL_DSP!=0 && CH_W==8 && N0%2==0) begin : G_DUAL
                for (gn=0; gn<N0/2; gn=gn+1) begin : G_PAIR
                    wire [7:0] a0=win_data[(2*gn)*8 +: 8];
                    wire [7:0] a1=win_data[(2*gn+1)*8 +: 8];
                    wire [7:0] b0=w_data[(gco*N0+2*gn)*8 +: 8];
                    wire [7:0] b1=w_data[(gco*N0+2*gn+1)*8 +: 8];
                    wire [47:0] pair_product;
                    // Titanium DUAL: high 11x10 and low 8x8 signed lanes.
                    // Sign-extend high operands; ALIGN_RIGHT yields two
                    // independent signed 24-bit products without latency.
                    EFX_DSP48 #(.MODE("DUAL"), .SIGNED(1),
                        .P_EXT("ALIGN_RIGHT"), .W_SEL("P"),
                        .N_SEL("CONST0")) u_dsp (
                        .A({{3{a1[7]}},a1,a0}),
                        .B({{2{b1[7]}},b1,b0}), .C(18'd0),
                        .CASCIN(48'd0), .OP(2'b00), .SHIFT_ENA(1'b0),
                        // No internal registers: disable their control ports
                        // as required by the Efinity primitive checker.
                        .CLK(1'b0), .CE(1'b0), .RST(1'b0),
                        .O(pair_product), .CASCOUT(), .OVFL());
                    assign p[2*gn]=$signed(pair_product[23:0]);
                    assign p[2*gn+1]=$signed(pair_product[47:24]);
                end
            end else begin : G_SINGLE
            for (gn = 0; gn < N0; gn = gn + 1) begin : G_PROD
                // Keep the multiply width explicit.  Some synthesis tools
                // otherwise evaluate an 8x8 expression at operand width and
                // only then extend it to ACC_W, silently discarding the upper
                // half of the signed product.  A named 2*CH_W product also
                // makes the intended signed DSP mapping unambiguous.
                wire signed [CH_W-1:0] win_s;
                wire signed [CH_W-1:0] weight_s;
                wire signed [2*CH_W-1:0] product_s;
                assign win_s = win_data[(gn)*CH_W +: CH_W];
                assign weight_s = w_data[(gco*N0 + gn)*CH_W +: CH_W];
                assign product_s = win_s * weight_s;
                assign p[gn] = {{(MAC_W-2*CH_W){product_s[2*CH_W-1]}},
                                product_s};
            end
            end

            // ---- stage 2: balanced tree --------------------------------
            wire signed [MAC_W-1:0] l1 [0:N1-1];
            for (gn = 0; gn < N1; gn = gn + 1) begin : G_L1
                if ((2*gn + 1) < N0) assign l1[gn] = p[2*gn] + p[2*gn+1];
                else                 assign l1[gn] = p[2*gn];
            end

            wire signed [MAC_W-1:0] l2 [0:N2-1];
            for (gn = 0; gn < N2; gn = gn + 1) begin : G_L2
                if ((2*gn + 1) < N1) assign l2[gn] = l1[2*gn] + l1[2*gn+1];
                else                 assign l2[gn] = l1[2*gn];
            end

            wire signed [MAC_W-1:0] l3 [0:N3-1];
            for (gn = 0; gn < N3; gn = gn + 1) begin : G_L3
                if ((2*gn + 1) < N2) assign l3[gn] = l2[2*gn] + l2[2*gn+1];
                else                 assign l3[gn] = l2[2*gn];
            end

            wire signed [MAC_W-1:0] l4 [0:N4-1];
            for (gn = 0; gn < N4; gn = gn + 1) begin : G_L4
                if ((2*gn + 1) < N3) assign l4[gn] = l3[2*gn] + l3[2*gn+1];
                else                 assign l4[gn] = l3[2*gn];
            end

            wire signed [MAC_W-1:0] l5 [0:N5-1];
            for (gn = 0; gn < N5; gn = gn + 1) begin : G_L5
                if ((2*gn + 1) < N4) assign l5[gn] = l4[2*gn] + l4[2*gn+1];
                else                 assign l5[gn] = l4[2*gn];
            end

            wire signed [MAC_W-1:0] l6 [0:N6-1];
            for (gn = 0; gn < N6; gn = gn + 1) begin : G_L6
                if ((2*gn + 1) < N5) assign l6[gn] = l5[2*gn] + l5[2*gn+1];
                else                 assign l6[gn] = l5[2*gn];
            end

            assign dot[gco] = l6[0];

        end
    endgenerate

    //------------------------------------------------------------------------
    //  Stage 3: optional output register
    //------------------------------------------------------------------------
    generate
        if (DSP_RETIME) begin : G_DSP_PIPE
            integer k;
            always @(posedge clk or negedge rst_n)
                if(!rst_n)out_valid<=0;else out_valid<=in_valid;
            always @* for(k=0;k<P_CO;k=k+1)
                out_sum[k*ACC_W+:ACC_W]={{(ACC_W-MAC_W){dot[k][MAC_W-1]}},dot[k]};
        end else if (PIPE != 0) begin : G_PIPE
            integer k;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    out_valid <= 1'b0;
                    out_sum   <= {(P_CO*ACC_W){1'b0}};
                end else begin
                    out_valid <= in_valid;
                    if (in_valid) begin
                        for (k = 0; k < P_CO; k = k + 1)
                            out_sum[k*ACC_W +: ACC_W] <=
                                {{(ACC_W-MAC_W){dot[k][MAC_W-1]}}, dot[k]};
                    end
                end
            end
        end else begin : G_COMB
            integer k;
            always @* begin
                out_valid = in_valid;
                for (k = 0; k < P_CO; k = k + 1)
                    out_sum[k*ACC_W +: ACC_W] =
                        {{(ACC_W-MAC_W){dot[k][MAC_W-1]}}, dot[k]};
            end
        end
    endgenerate

endmodule

`default_nettype wire
