//======================================================================
// rsqrt_unit.v -- Fixed-point reciprocal square root unit
//                 (mantissa + exponent decomposition form)
//
// FUNCTION
//     Input  : T (positive integer)
//     Output : 1/sqrt(T) in "mantissa + exponent" decomposed form
//                 1/sqrt(T) = (v_out / 2^R) * 2^(-sh_out)
//              where v_out in [1/sqrt2, sqrt2] * 2^R  (R fractional bits)
//                    sh_out = ceil(e/2), e = position of MSB of T
//
// WHY NOT A SINGLE FIXED-POINT WORD
//     T spans a very wide range (up to 2^48 here), so 1/sqrt(T) can be
//     as small as 2^-24.  A single fixed-point representation would need
//     40+ fractional bits to avoid underflow.  After decomposition the
//     mantissa only needs R fractional bits, and the exponent is
//     compensated later by a shift when computing the A/B coefficients.
//
// ALGORITHM
//     T = m * 2^e,  m in [1,2)
//     1/sqrt(T) = (1/sqrt(m)) * 2^(-e/2)
//               = v * 2^(-sh) * (sqrt2 if e is odd)
//     1/sqrt(m) is obtained by "lookup table + linear interpolation":
//         let t = m - 1 in [0,1), use the top K bits of t as the index j
//         to look up 1/sqrt(1 + j/2^K), and interpolate with the rest.
//
// PIPELINE (3 stages)
//     S1: leading-one detection (find e)
//     S2: mantissa extraction + table index / interpolation fraction
//         + sh / odd
//     S3: table lookup + linear interpolation + sqrt2 correction
//     Latency = 3 clock cycles
//
// ACCURACY
//     Relative error about 0.009% (13.4 bit), see pc2fpga/out/report.txt
//
// NOTES
//     * Throughput demand is very low (~288 calls per frame, occupancy
//       < 2%), so a single unit time-shared across all layers/channels is
//       sufficient.  Area is prioritised over latency.
//     * All table values are non-negative; the interpolation difference
//       (y1 - y0) is negative, hence signed arithmetic is used there.
//     * Every intermediate that is "supposed to be positive" is
//       zero-extended before entering signed arithmetic, so that the MSB
//       is not mistaken for a sign bit.  This is the easiest trap to fall
//       into in this module.
//     * T = 0 is supposed to be blocked by the upstream T_min guard; this
//       module still returns v = lut[0], sh = 0 for T = 0, i.e. no
//       undefined behaviour.
//======================================================================
`timescale 1ns/1ps

module rsqrt_unit #(
    parameter integer T_W = 48,     // width of T
    parameter integer K   = 5,      // LUT index width (2^K + 1 entries)
    parameter integer R   = 18,     // fractional bits of the mantissa
    parameter integer FM  = 22      // internal mantissa fractional bits (> K)
)(
    input  wire                clk,
    input  wire                rst_n,
    // ---- input ----
    input  wire                in_valid,
    input  wire [T_W-1:0]      t_data,      // T (positive integer)
    // ---- output (valid 3 cycles later) ----
    output reg                 out_valid,
    output reg  [R:0]          v_out,       // mantissa v (R fractional bits)
    output reg  [7:0]          sh_out,      // exponent shift sh = ceil(e/2)
    output reg                 odd_out      // parity of e (already folded into v_out, debug only)
);

    //------------------------------------------------------------------
    // Derived constants
    //------------------------------------------------------------------
    localparam integer LUT_N = (1 << K);         // number of entries (excluding last)
    localparam integer FQ    = FM - K;           // interpolation fraction width
    localparam integer DW    = R + 1;            // table value width
    localparam integer EO_W  = 8;                // width of e / sh
    localparam [18:0]  SQRT2_FP = 19'd370728;    // round(sqrt2 * 2^18), 19 bits

    //------------------------------------------------------------------
    // S1: leading-one detection -- position e of the MSB of T
    //     The loop scans from LSB to MSB; the last assignment is the MSB
    //     (stays 0 when T == 0).
    //------------------------------------------------------------------
    integer i;
    reg [EO_W-1:0] e_c;
    always @* begin
        e_c = {EO_W{1'b0}};
        for (i = 0; i < T_W; i = i + 1)
            if (t_data[i]) e_c = i[EO_W-1:0];
    end

    reg [EO_W-1:0] e_r;
    reg [T_W-1:0]  t_r;
    reg            v1_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_r  <= {EO_W{1'b0}};
            t_r  <= {T_W{1'b0}};
            v1_r <= 1'b0;
        end else begin
            e_r  <= e_c;
            t_r  <= t_data;
            v1_r <= in_valid;
        end
    end

    //------------------------------------------------------------------
    // S2: mantissa extraction + table index / interpolation fraction
    //     m_fp   = T * 2^FM / 2^e,  (FM+1) bits, MSB is always 1
    //     offset = m_fp - 2^FM      in [0, 2^FM)
    //     j      = offset[FM-1:FQ]  top K bits
    //     f      = offset[FQ-1:0]   low FQ bits
    //     Note: m_fp < 2^(FM+1), so all significant bits of the shifted
    //           value fit in the low (FM+1) bits; truncating to (FM+1)
    //           bits is safe.
    //------------------------------------------------------------------
    wire [FM:0] m_c = (e_r >= FM) ? ({{(FM+1){1'b0}}, t_r} >> (e_r - FM))
                                  : ({{(FM+1){1'b0}}, t_r} << (FM - e_r));

    wire [FM-1:0]   off_c = m_c[FM-1:0];
    wire [K-1:0]    j_c   = off_c[FM-1 : FQ];
    wire [FQ-1:0]   f_c   = off_c[FQ-1 : 0];
    wire            odd_c = e_r[0];
    wire [EO_W-1:0] sh_c  = (e_r + 1'b1) >> 1;      // ceil(e/2)

    reg [K-1:0]    j_r;
    reg [FQ-1:0]   f_r;
    reg [EO_W-1:0] sh_r;
    reg            odd_r;
    reg            v2_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            j_r  <= {K{1'b0}};
            f_r  <= {FQ{1'b0}};
            sh_r <= {EO_W{1'b0}};
            odd_r <= 1'b0;
            v2_r <= 1'b0;
        end else begin
            j_r   <= j_c;
            f_r   <= f_c;
            sh_r  <= sh_c;
            odd_r <= odd_c;
            v2_r  <= v1_r;
        end
    end

    //------------------------------------------------------------------
    // S3: table lookup + linear interpolation + sqrt2 correction
    //     v0 = lut[j] + ((lut[j+1] - lut[j]) * f) >>> FQ
    //     v  = odd ? (v0 * sqrt2) >>> R : v0
    //     Note: lut[j+1] - lut[j] < 0, so the difference is signed;
    //           >>> is an arithmetic right shift, matching the
    //           round-toward-minus-infinity behaviour of the Python
    //           reference implementation.
    //------------------------------------------------------------------
    wire [DW-1:0] y0, y1;
    wire [K:0]    j_ext = {1'b0, j_r};              // zero-extend to K+1 bits
    wire [K:0]    jn    = j_ext + 1'b1;             // j+1 in [1, 2^K], needs K+1 bits
    rsqrt_lut #(.K(K), .R(R)) u_lut_cur  (.idx(j_ext), .val(y0));
    rsqrt_lut #(.K(K), .R(R)) u_lut_next (.idx(jn),    .val(y1));

    // Zero-extend to DW+2 bits before casting to signed, so the MSB is
    // not interpreted as a sign bit.
    wire signed [DW+1:0] y0_s = $signed({2'b00, y0});
    wire signed [DW+1:0] y1_s = $signed({2'b00, y1});
    wire signed [DW+1:0] diff_s = y1_s - y0_s;                    // <= 0

    wire signed [DW+1:0] f_s = $signed({2'b00, f_r});             // 18 bits -> 21 bits
    wire signed [2*DW+2:0] prod_s = diff_s * f_s;
    wire signed [DW+1:0] interp_s = prod_s >>> FQ;                // value range is small, truncation is safe

    wire signed [DW+1:0] v0_s = y0_s + interp_s;                  // > 0
    wire [DW-1:0]        v0_c = v0_s[DW-1:0];

    // sqrt2 correction: zero-extend v0_c to DW+2 bits, then cast to signed
    wire signed [DW+1:0]   v0_z = $signed({2'b00, v0_c});
    wire signed [DW+18:0]  sq2_s = $signed({13'b0, SQRT2_FP});    // 32 bits, positive
    wire signed [2*DW+20:0] sq_s = v0_z * sq2_s;
    wire [2*DW+20:0]        sq_sh = sq_s >>> R;
    wire [DW-1:0]           v_odd_c = sq_sh[DW-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            v_out     <= {(R+1){1'b0}};
            sh_out    <= 8'd0;
            odd_out   <= 1'b0;
        end else begin
            out_valid <= v2_r;
            v_out     <= odd_r ? v_odd_c : v0_c;
            sh_out    <= sh_r;
            odd_out   <= odd_r;
        end
    end

endmodule
