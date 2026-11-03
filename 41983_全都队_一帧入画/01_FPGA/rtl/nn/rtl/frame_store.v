//============================================================================
//  frame_store.v -- banked, synchronous frame buffer
//----------------------------------------------------------------------------
//  Byte layout is unchanged:
//      address = pixel_index * channels_per_pixel + channel
//
//  The store is striped over 32 byte lanes.  A 32-byte request reads one byte
//  from every lane, then rotates the lane vector by address[4:0].  Each lane is
//  a small true-dual-port RAM, so the implementation maps to embedded memory
//  instead of a million-bit asynchronous mux network.
//
//  Both read ports have one-cycle latency and an enable.  Debug reads reuse
//  port A while the network is idle (dbg_en=1).
//============================================================================

`timescale 1ns/1ps
`default_nettype none

module frame_store_lane #(
    parameter integer AW = 10
)(
    input  wire          clk,
    input  wire          wr_en,
    input  wire [AW-1:0] wr_addr,
    input  wire [7:0]    wr_data,
    input  wire          rd_en,
    input  wire [AW-1:0] rd_addr,
    output reg  [7:0]    rd_data
);
    reg [7:0] mem [0:(1<<AW)-1];

    always @(posedge clk)
        if (wr_en)
            mem[wr_addr] <= wr_data;

    always @(posedge clk)
        if (rd_en)
            rd_data <= mem[rd_addr];
endmodule


module frame_store #(
    parameter integer NB   = 4,
    parameter integer BLOG = 15,
    parameter integer RW   = 32
)(
    input  wire                 clk,

    input  wire                 rda_en,
    input  wire [1:0]           rda_bank,
    input  wire [BLOG-1:0]      rda_addr,
    output wire [RW*8-1:0]      rda_data,

    input  wire                 rdb_en,
    input  wire [1:0]           rdb_bank,
    input  wire [BLOG-1:0]      rdb_addr,
    output wire [RW*8-1:0]      rdb_data,

    input  wire                 wr_en,
    input  wire [1:0]           wr_bank,
    input  wire [BLOG-1:0]      wr_addr,
    input  wire [RW*8-1:0]      wr_data,
    input  wire [5:0]           wr_n,

    input  wire                 dbg_en,
    input  wire [1:0]           dbg_bank,
    input  wire [BLOG-1:0]      dbg_addr,
    output wire [7:0]           dbg_data
);

    localparam integer LSHIFT = 5;
    localparam integer RAW    = BLOG-LSHIFT;

    // Debug access borrows read port A only while the sequencer is idle.
    wire                 a_en   = dbg_en || rda_en;
    wire [1:0]           a_bank = dbg_en ? dbg_bank : rda_bank;
    wire [BLOG-1:0]      a_addr = dbg_en ? dbg_addr : rda_addr;

    reg [1:0] a_bank_q, b_bank_q;
    reg [LSHIFT-1:0] a_low_q, b_low_q;

    always @(posedge clk) begin
        if (a_en) begin
            a_bank_q <= a_bank;
            a_low_q  <= a_addr[LSHIFT-1:0];
        end
        if (rdb_en) begin
            b_bank_q <= rdb_bank;
            b_low_q  <= rdb_addr[LSHIFT-1:0];
        end
    end

    wire [RW*8-1:0] bank_a_q [0:NB-1];
    wire [RW*8-1:0] bank_b_q [0:NB-1];

    genvar gb, gl;
    generate
        for (gb = 0; gb < NB; gb = gb + 1) begin : G_BANK
            localparam [1:0] BANK_ID = gb;
            for (gl = 0; gl < RW; gl = gl + 1) begin : G_LANE
                localparam [LSHIFT-1:0] LANE_ID = gl;

                // Lanes below the byte offset come from the following row.
                wire [RAW-1:0] a_row = a_addr[BLOG-1:LSHIFT] +
                                       ((LANE_ID < a_addr[LSHIFT-1:0]) ? 1'b1 : 1'b0);
                wire [RAW-1:0] b_row = rdb_addr[BLOG-1:LSHIFT] +
                                       ((LANE_ID < rdb_addr[LSHIFT-1:0]) ? 1'b1 : 1'b0);

                // Exactly one byte of a <=32-byte write maps to each lane.
                wire [5:0] w_delta =
                    ({1'b0, LANE_ID} - {1'b0, wr_addr[LSHIFT-1:0]}) & 6'h1f;
                wire       lane_we = wr_en && (wr_bank == BANK_ID) &&
                                     (w_delta < wr_n);
                wire [RAW-1:0] w_row = wr_addr[BLOG-1:LSHIFT] +
                                       ((LANE_ID < wr_addr[LSHIFT-1:0]) ? 1'b1 : 1'b0);
                wire [7:0] w_byte = wr_data[w_delta*8 +: 8];

                wire a_read = a_en && (a_bank == BANK_ID);
                wire b_read = rdb_en && (rdb_bank == BANK_ID);
                wire [7:0] q;

                frame_store_lane #(.AW(RAW)) u_lane (
                    .clk(clk),
                    .wr_en(lane_we), .wr_addr(w_row), .wr_data(w_byte),
                    .rd_en(a_read || b_read),
                    .rd_addr(a_read ? a_row : b_row), .rd_data(q)
                );

                assign bank_a_q[gb][gl*8 +: 8] = q;
                assign bank_b_q[gb][gl*8 +: 8] = q;
            end
        end
    endgenerate

    reg [RW*8-1:0] a_lanes, b_lanes;
    always @(*) begin
        a_lanes = {RW*8{1'b0}};
        b_lanes = {RW*8{1'b0}};
        case (a_bank_q)
            2'd0: a_lanes = bank_a_q[0];
            2'd1: a_lanes = bank_a_q[1];
            2'd2: a_lanes = bank_a_q[2];
            2'd3: a_lanes = bank_a_q[3];
        endcase
        case (b_bank_q)
            2'd0: b_lanes = bank_b_q[0];
            2'd1: b_lanes = bank_b_q[1];
            2'd2: b_lanes = bank_b_q[2];
            2'd3: b_lanes = bank_b_q[3];
        endcase
    end

    // Duplicate before shifting so an unaligned window wraps lane 31 -> 0.
    wire [RW*16-1:0] a_twice = {a_lanes, a_lanes};
    wire [RW*16-1:0] b_twice = {b_lanes, b_lanes};
    assign rda_data = a_twice >> (a_low_q * 8);
    assign rdb_data = b_twice >> (b_low_q * 8);
    assign dbg_data = rda_data[7:0];

endmodule

`default_nettype wire