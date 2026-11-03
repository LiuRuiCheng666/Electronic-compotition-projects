//============================================================================
//  upsample.v -- nearest-neighbour x2 upsampling
//----------------------------------------------------------------------------
//  Matches  nn.Upsample(scale_factor=2, mode="nearest") : every input pixel
//  becomes a 2x2 block, so the output is (2H) x (2W) with
//
//      out[2i  ][2j  ] = out[2i  ][2j+1]
//                      = out[2i+1][2j  ]
//                      = out[2i+1][2j+1] = in[i][j]
//
//  Structure: one row buffer, then the row is emitted TWICE, each pass
//  doubling every pixel horizontally.
//
//      S_FILL : accept W pixels of one input row          (W cycles)
//      S_ROW1 : emit 2W pixels (output row 2i)            (2W cycles)
//      S_ROW2 : emit the same 2W pixels (output row 2i+1) (2W cycles)
//      -> 5W cycles per input row
//
//  Why a row buffer is needed
//    The vertical duplication requires the row to be available twice.  For the
//    largest case in this network the row is 128 px x 32 ch x 8 bit = 4 KB,
//    which fits in a few ESRAM blocks (swap the array for a primitive later).
//
//  Handshake
//    in_ready  is high only during S_FILL
//    out_valid is a REGISTERED function of the state, so it is high for exactly
//    the 4W cycles that produce one input row's 2x2 expansion and drops on the
//    cycle the FSM leaves S_ROW2.
//
//    Trap found while writing this: if out_valid is simply set in S_ROW1/2 and
//    cleared when returning to S_FILL, the very LAST output of the frame is
//    lost (it is overwritten by the clear in the same cycle).  Deriving it from
//    the state removes that class of bug entirely.
//============================================================================

`default_nettype none

module upsample #(
    parameter integer C      = 32,      // channels carried per pixel
    parameter integer CH_W   = 8,       // bits per channel
    parameter integer MAX_W  = 128,     // max input row width
    parameter integer AW     = 7        // $clog2(MAX_W)
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- configuration (idle-time update) ----
    input  wire [15:0]              cfg_w,      // input row width
    input  wire [15:0]              cfg_h,      // input row count

    // ---- input stream (row scan) ----
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire [C*CH_W-1:0]        in_px,

    // ---- output stream ----
    output reg                      out_valid,
    input  wire                     out_ready,
    output reg  [C*CH_W-1:0]        out_px,
    output reg  [15:0]              out_row,
    output reg  [15:0]              out_col,

    output wire                     busy,
    output wire                     done
);

    localparam integer PW = C * CH_W;
    localparam integer S_IDLE = 2'd0, S_FILL = 2'd1,
                       S_ROW1 = 2'd2, S_ROW2 = 2'd3;
    reg [1:0] st;

    reg [PW-1:0] rb [0:MAX_W-1];         // one input row

    reg [15:0] ph;                       // phase counter
    reg [15:0] row;                      // input row index
    reg [15:0] w_r, h_r;

    wire [15:0] ph_last_fill = w_r - 16'd1;
    wire [15:0] ph_last_row  = (w_r << 1) - 16'd1;
    wire [15:0] src_idx      = ph >> 1;   // which pixel to repeat
    wire        emit         = (st == S_ROW1) || (st == S_ROW2);
    wire        last_in_row  = (row + 16'd1 >= h_r);

    assign in_ready = (st == S_FILL);
    assign busy     = (st != S_IDLE);
    assign done     = (st == S_IDLE) && (row != 16'd0);

    // The row buffer has a synchronous write port and deliberately has no
    // reset.  Every row is completely filled before either output pass reads
    // it, so clearing the memory is unnecessary and prevents RAM inference.
    always @(posedge clk) begin
        if ((st == S_FILL) && in_valid)
            rb[ph[AW-1:0]] <= in_px;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            ph        <= 16'd0;
            row       <= 16'd0;
            w_r       <= 16'd0;
            h_r       <= 16'd0;
            out_valid <= 1'b0;
            out_px    <= {PW{1'b0}};
            out_row   <= 16'd0;
            out_col   <= 16'd0;
        end else begin
            // -----------------------------------------------------------
            //  Output side: registered, driven purely by the state so it is
            //  asserted for exactly the emitting cycles.
            // -----------------------------------------------------------
            out_valid <= emit && out_ready;
            if (emit && out_ready) begin
                out_px  <= rb[src_idx[AW-1:0]];
                out_row <= (st == S_ROW1) ? (row << 1) : ((row << 1) + 16'd1);
                out_col <= ph;
            end

            case (st)
            //------------------------------------------------------------
            S_IDLE: begin
                w_r <= cfg_w;
                h_r <= cfg_h;
                ph  <= 16'd0;
                row <= 16'd0;
                st  <= S_FILL;
            end

            //------------------------------------------------------------
            //  S_FILL: capture one input row
            //------------------------------------------------------------
            S_FILL: begin
                if (in_valid) begin
                    if (ph == ph_last_fill) begin
                        ph <= 16'd0;
                        st <= S_ROW1;
                    end else begin
                        ph <= ph + 16'd1;
                    end
                end
            end

            //------------------------------------------------------------
            //  S_ROW1 / S_ROW2: emit the doubled row twice
            //------------------------------------------------------------
            S_ROW1, S_ROW2: begin
                // Keep the source index and state fixed while the DDR write
                // slot is occupied.  A value is emitted only when accepted.
                if (out_ready) begin
                    if (ph == ph_last_row) begin
                        ph <= 16'd0;
                        if (st == S_ROW1) begin
                            st <= S_ROW2;
                        end else if (last_in_row) begin
                            st <= S_IDLE;
                        end else begin
                            row <= row + 16'd1;
                            st  <= S_FILL;
                        end
                    end else begin
                        ph <= ph + 16'd1;
                    end
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
