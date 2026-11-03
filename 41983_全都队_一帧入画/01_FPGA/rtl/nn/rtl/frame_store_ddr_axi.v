`timescale 1ns/1ps
`default_nettype none

// AXI4 DDR backend for the neural-network frame store.
//
// The network-side addresses have the same meaning as frame_store.v: they are
// byte addresses within one of four compact feature-map banks.  Every read
// returns 32 consecutive bytes starting at that exact address, including when
// the window is not aligned to an AXI beat.  A 128-bit DDR interface therefore
// needs two beats for aligned reads and three beats for unaligned reads.
//
// The client must hold a request until *_ready is high.  Read data and wr_done
// are one-cycle completion pulses.  Only one AXI transaction is outstanding;
// arbitration priority is write, weights, read A, then read B.
module frame_store_ddr_axi #(
    parameter integer A4_FAST = 0,
    parameter integer A4_FIXED_WRITES = 0,
    parameter integer A4_WRITE_END_PIPE = 0,
    parameter integer A4_STREAM_REFILL = 1,
    parameter integer A4_EARLY_CACHE_READ = A4_STREAM_REFILL,
    parameter integer A4_PARALLEL_CACHE_READ = 0,
    parameter integer A4_REGISTERED_FLUSH = 0,
    parameter integer A4_PACKET_INPUT_PIPE = 0,
    parameter integer A4_PIPELINED_MASK = 0,
    parameter integer A4_SHARED_READ_CACHE = 1,
    parameter integer A4_REFILL_ALIGN_BITS = (A4_SHARED_READ_CACHE!=0)?5:10,
    parameter integer A4_FAST_MASK_SEAL = 1,
    parameter integer A4_PACKET_WORDS = 16,
    parameter integer STREAM_WR = 0,
    parameter integer AXI_ADDR_WIDTH   = 32,
    parameter integer AXI_DATA_WIDTH   = 128,
    parameter integer AXI_ID_WIDTH     = 4,
    parameter integer FRAME_ADDR_WIDTH = 15,
    parameter [AXI_ADDR_WIDTH-1:0] BASE_ADDR = 32'h0100_0000,
    parameter [AXI_ADDR_WIDTH-1:0] WEIGHT_BASE_ADDR = 32'h0180_0000,
    parameter integer WEIGHT_GROUP_WORDS = 1,
    parameter integer BANK_ADDR_SHIFT  = 20
)(
    input  wire clk,
    input  wire rst_n,
    input  wire cal_done,
    input wire flush, invalidate,

    input  wire rda_req,
    output wire rda_ready,
    input  wire [1:0] rda_bank,
    input  wire [FRAME_ADDR_WIDTH-1:0] rda_addr,
    output wire  rda_valid,
    output wire  [255:0] rda_data,

    input  wire rdb_req,
    output wire rdb_ready,
    input  wire [1:0] rdb_bank,
    input  wire [FRAME_ADDR_WIDTH-1:0] rdb_addr,
    output wire  rdb_valid,
    output wire  [255:0] rdb_data,

    input  wire wr_req,
    output wire wr_ready,
    input  wire [1:0] wr_bank,
    input  wire [FRAME_ADDR_WIDTH-1:0] wr_addr,
    input wire [FRAME_ADDR_WIDTH:0] wr_end,
    input  wire [255:0] wr_data,
    input  wire [5:0] wr_n,
    output wire  wr_done,

    // Aligned 32-byte weight read.  wt_addr is a byte offset within the
    // packed network-weight image in DDR. A group comprises consecutive
    // WEIGHT_GROUP_WORDS requests; one burst supplies ordered 32-byte replies.
    // The producer must issue every word in the group, even if replies start.
    input  wire wt_req,
    output wire wt_ready,
    input  wire [31:0] wt_addr,
    output wire  wt_valid,
    output wire  [255:0] wt_data,

    output wire busy,
    output wire  fault,

    output wire [AXI_ID_WIDTH-1:0] m_axi_awid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awlock,
    output wire [3:0] m_axi_awcache,
    output wire [2:0] m_axi_awprot,
    output wire [3:0] m_axi_awqos,
    output wire m_axi_awvalid,
    input  wire m_axi_awready,

    output wire [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output wire m_axi_wlast,
    output wire m_axi_wvalid,
    input  wire m_axi_wready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_bid,
    input  wire [1:0] m_axi_bresp,
    input  wire m_axi_bvalid,
    output wire m_axi_bready,

    output wire [AXI_ID_WIDTH-1:0] m_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arlock,
    output wire [3:0] m_axi_arcache,
    output wire [2:0] m_axi_arprot,
    output wire [3:0] m_axi_arqos,
    output wire m_axi_arvalid,
    input  wire m_axi_arready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0] m_axi_rresp,
    input  wire m_axi_rlast,
    input  wire m_axi_rvalid,
    output wire m_axi_rready
);
    generate if (A4_FAST != 0) begin : G_A4_FAST
        frame_store_ddr_axi_a4 #(
            .FIXED_WRITES(A4_FIXED_WRITES),.WRITE_END_PIPE(A4_WRITE_END_PIPE),.STREAM_WR(STREAM_WR),.STREAM_REFILL(A4_STREAM_REFILL),.EARLY_CACHE_READ(A4_EARLY_CACHE_READ),.PARALLEL_CACHE_READ(A4_PARALLEL_CACHE_READ),.REGISTERED_FLUSH(A4_REGISTERED_FLUSH),.PACKET_INPUT_PIPE(A4_PACKET_INPUT_PIPE),.PIPELINED_MASK(A4_PIPELINED_MASK),.SHARED_READ_CACHE(A4_SHARED_READ_CACHE),.REFILL_ALIGN_BITS(A4_REFILL_ALIGN_BITS),.FAST_MASK_SEAL(A4_FAST_MASK_SEAL),.PACKET_WORDS(A4_PACKET_WORDS),
            .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH), .AXI_ID_WIDTH(AXI_ID_WIDTH), .FRAME_ADDR_WIDTH(FRAME_ADDR_WIDTH), .BASE_ADDR(BASE_ADDR), .WEIGHT_BASE_ADDR(WEIGHT_BASE_ADDR), .WEIGHT_GROUP_WORDS(WEIGHT_GROUP_WORDS), .BANK_ADDR_SHIFT(BANK_ADDR_SHIFT)
        ) u_backend (
            .clk(clk), .rst_n(rst_n), .cal_done(cal_done), .rda_req(rda_req), .rda_ready(rda_ready), .rda_bank(rda_bank), .rda_addr(rda_addr), .rda_valid(rda_valid), .rda_data(rda_data), .rdb_req(rdb_req), .rdb_ready(rdb_ready), .rdb_bank(rdb_bank), .rdb_addr(rdb_addr), .rdb_valid(rdb_valid), .rdb_data(rdb_data), .wr_req(wr_req), .wr_ready(wr_ready), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_end(wr_end), .wr_data(wr_data), .wr_n(wr_n), .wr_done(wr_done), .wt_req(wt_req), .wt_ready(wt_ready), .wt_addr(wt_addr), .wt_valid(wt_valid), .wt_data(wt_data), .busy(busy), .fault(fault), .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock), .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready), .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready), .flush(flush), .invalidate(invalidate)
        );
    end else begin : G_LEGACY
        frame_store_ddr_axi_legacy #(
            .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH), .AXI_DATA_WIDTH(AXI_DATA_WIDTH), .AXI_ID_WIDTH(AXI_ID_WIDTH), .FRAME_ADDR_WIDTH(FRAME_ADDR_WIDTH), .BASE_ADDR(BASE_ADDR), .WEIGHT_BASE_ADDR(WEIGHT_BASE_ADDR), .WEIGHT_GROUP_WORDS(WEIGHT_GROUP_WORDS), .BANK_ADDR_SHIFT(BANK_ADDR_SHIFT)
        ) u_backend (
            .clk(clk), .rst_n(rst_n), .cal_done(cal_done), .rda_req(rda_req), .rda_ready(rda_ready), .rda_bank(rda_bank), .rda_addr(rda_addr), .rda_valid(rda_valid), .rda_data(rda_data), .rdb_req(rdb_req), .rdb_ready(rdb_ready), .rdb_bank(rdb_bank), .rdb_addr(rdb_addr), .rdb_valid(rdb_valid), .rdb_data(rdb_data), .wr_req(wr_req), .wr_ready(wr_ready), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data), .wr_n(wr_n), .wr_done(wr_done), .wt_req(wt_req), .wt_ready(wt_ready), .wt_addr(wt_addr), .wt_valid(wt_valid), .wt_data(wt_data), .busy(busy), .fault(fault), .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock), .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready), .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
        );
    end endgenerate
endmodule

module frame_store_ddr_axi_legacy #(
    parameter integer AXI_ADDR_WIDTH   = 32,
    parameter integer AXI_DATA_WIDTH   = 128,
    parameter integer AXI_ID_WIDTH     = 4,
    parameter integer FRAME_ADDR_WIDTH = 15,
    parameter [AXI_ADDR_WIDTH-1:0] BASE_ADDR = 32'h0100_0000,
    parameter [AXI_ADDR_WIDTH-1:0] WEIGHT_BASE_ADDR = 32'h0180_0000,
    parameter integer WEIGHT_GROUP_WORDS = 1,
    parameter integer BANK_ADDR_SHIFT  = 20
)(
    input  wire clk,
    input  wire rst_n,
    input  wire cal_done,

    input  wire rda_req,
    output wire rda_ready,
    input  wire [1:0] rda_bank,
    input  wire [FRAME_ADDR_WIDTH-1:0] rda_addr,
    output reg  rda_valid,
    output reg  [255:0] rda_data,

    input  wire rdb_req,
    output wire rdb_ready,
    input  wire [1:0] rdb_bank,
    input  wire [FRAME_ADDR_WIDTH-1:0] rdb_addr,
    output reg  rdb_valid,
    output reg  [255:0] rdb_data,

    input  wire wr_req,
    output wire wr_ready,
    input  wire [1:0] wr_bank,
    input  wire [FRAME_ADDR_WIDTH-1:0] wr_addr,
    input  wire [255:0] wr_data,
    input  wire [5:0] wr_n,
    output reg  wr_done,

    // Aligned 32-byte weight read.  wt_addr is a byte offset within the
    // packed network-weight image in DDR. A group comprises consecutive
    // WEIGHT_GROUP_WORDS requests; one burst supplies ordered 32-byte replies.
    // The producer must issue every word in the group, even if replies start.
    input  wire wt_req,
    output wire wt_ready,
    input  wire [31:0] wt_addr,
    output reg  wt_valid,
    output reg  [255:0] wt_data,

    output wire busy,
    output reg  fault,

    output wire [AXI_ID_WIDTH-1:0] m_axi_awid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awlock,
    output wire [3:0] m_axi_awcache,
    output wire [2:0] m_axi_awprot,
    output wire [3:0] m_axi_awqos,
    output wire m_axi_awvalid,
    input  wire m_axi_awready,

    output wire [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output wire m_axi_wlast,
    output wire m_axi_wvalid,
    input  wire m_axi_wready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_bid,
    input  wire [1:0] m_axi_bresp,
    input  wire m_axi_bvalid,
    output wire m_axi_bready,

    output wire [AXI_ID_WIDTH-1:0] m_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arlock,
    output wire [3:0] m_axi_arcache,
    output wire [2:0] m_axi_arprot,
    output wire [3:0] m_axi_arqos,
    output wire m_axi_arvalid,
    input  wire m_axi_arready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0] m_axi_rresp,
    input  wire m_axi_rlast,
    input  wire m_axi_rvalid,
    output wire m_axi_rready
);
    // This adapter targets the demo controller's 128-bit AXI slave exactly.
    localparam integer AXI_BYTES = 16;
    localparam [2:0] AXI_SIZE = 3'd4;
    localparam [2:0] S_IDLE  = 3'd0, S_RADDR = 3'd1, S_RDATA = 3'd2,
                     S_WADDR = 3'd3, S_WDATA = 3'd4, S_WRESP = 3'd5;

    reg [2:0] state;
    // 0: feature read A, 1: feature read B, 2: weight read.
    reg [1:0] rd_owner;
    reg [1:0] rd_beat;
    reg [1:0] rd_beats;
    reg [1:0] rd_tx_beat;
    reg [1:0] rd_tx_beats;
    reg [3:0] rd_byte_shift;
    reg [255:0] rd_buf;
    localparam integer WT_BEATS = 2*WEIGHT_GROUP_WORDS;
    localparam integer WT_BW = $clog2(WT_BEATS+1);
    localparam integer WT_WW = $clog2(WEIGHT_GROUP_WORDS+1);
    reg [WT_BW-1:0] wt_beat, wt_tx_beat, wt_tx_beats;
    reg [WT_WW-1:0] wt_accepted;
    reg [31:0] wt_group_base;
    wire wt_active = (rd_owner == 2'd2) &&
                     (state == S_RADDR || state == S_RDATA);
    wire [WT_BW:0] wt_next_beat = {1'b0,wt_beat}+1'b1;
    wire [WT_BW:0] wt_tx_next = {1'b0,wt_tx_beat}+1'b1;
    wire [31:0] wt_expected_addr = wt_group_base + ({{(32-WT_WW){1'b0}},wt_accepted} << 5);
    function [WT_BW-1:0] weight_burst_beats;
        input [11:0] aligned_low;
        input [WT_BW-1:0] remaining;
        reg [12:0] boundary_bytes;
        reg [8:0] limit_beats;
        begin
            boundary_bytes = 13'd4096 - {1'b0,aligned_low};
            limit_beats = boundary_bytes >> 4;
            weight_burst_beats = (remaining < limit_beats) ? remaining : limit_beats;
        end
    endfunction
    reg [1:0] wr_beat;
    reg [1:0] wr_beats;
    reg [1:0] wr_tx_beat;
    reg [1:0] wr_tx_beats;
    reg [AXI_ADDR_WIDTH-1:0] req_addr;
    reg [383:0] wr_shift_data;
    reg [47:0] wr_shift_strb;

    function [AXI_ADDR_WIDTH-1:0] absolute_addr;
        input [1:0] bank;
        input [FRAME_ADDR_WIDTH-1:0] byte_addr;
        reg [AXI_ADDR_WIDTH-1:0] bank_ext;
        reg [AXI_ADDR_WIDTH-1:0] addr_ext;
        begin
            bank_ext = {{(AXI_ADDR_WIDTH-2){1'b0}}, bank};
            addr_ext = {{(AXI_ADDR_WIDTH-FRAME_ADDR_WIDTH){1'b0}}, byte_addr};
            absolute_addr = BASE_ADDR + (bank_ext << BANK_ADDR_SHIFT) + addr_ext;
        end
    endfunction

    function [31:0] byte_mask;
        input [5:0] n;
        begin
            if (n == 0)       byte_mask = 32'd0;
            else if (n >= 32) byte_mask = 32'hffff_ffff;
            else              byte_mask = (32'h1 << n) - 1'b1;
        end
    endfunction

    // AXI4 bursts may not cross a 4-KiB boundary.  A transfer here is at
    // most three beats, so only starts at 0xfe0/0xff0 need shortening.
    function [1:0] first_burst_beats;
        input [11:0] aligned_low;
        input [1:0] total_beats;
        reg [1:0] boundary_limit;
        begin
            if (aligned_low == 12'hff0)
                boundary_limit = 2'd1;
            else if (aligned_low == 12'hfe0)
                boundary_limit = 2'd2;
            else
                boundary_limit = 2'd3;
            first_burst_beats = (total_beats < boundary_limit) ?
                                total_beats : boundary_limit;
        end
    endfunction

    wire [AXI_ADDR_WIDTH-1:0] rda_abs = absolute_addr(rda_bank, rda_addr);
    wire [AXI_ADDR_WIDTH-1:0] rdb_abs = absolute_addr(rdb_bank, rdb_addr);
    wire [AXI_ADDR_WIDTH-1:0] wr_abs  = absolute_addr(wr_bank, wr_addr);
    wire [AXI_ADDR_WIDTH-1:0] wt_abs = WEIGHT_BASE_ADDR + wt_addr;
    wire [AXI_ADDR_WIDTH-1:0] rda_aligned =
        {rda_abs[AXI_ADDR_WIDTH-1:4], 4'b0000};
    wire [AXI_ADDR_WIDTH-1:0] rdb_aligned =
        {rdb_abs[AXI_ADDR_WIDTH-1:4], 4'b0000};
    wire [AXI_ADDR_WIDTH-1:0] wr_aligned =
        {wr_abs[AXI_ADDR_WIDTH-1:4], 4'b0000};
    wire [AXI_ADDR_WIDTH-1:0] wt_aligned =
        {wt_abs[AXI_ADDR_WIDTH-1:4], 4'b0000};
    wire [1:0] rda_req_beats = (rda_abs[3:0] == 0) ? 2'd2 : 2'd3;
    wire [1:0] rdb_req_beats = (rdb_abs[3:0] == 0) ? 2'd2 : 2'd3;
    wire [1:0] wr_req_beats = ({1'b0, wr_abs[3:0]} + wr_n + 15) >> 4;
    // Producer holds wr_req until it observes registered wr_done. On the
    // completion cycle it has not yet dropped wr_req: do not accept it twice.
    wire idle_ok = (state == S_IDLE) && cal_done && !wr_done;
    wire [2:0] rd_next_beat = {1'b0, rd_beat} + 3'd1;
    wire [2:0] wr_next_beat = {1'b0, wr_beat} + 3'd1;
    wire [2:0] rd_tx_next_beat = {1'b0, rd_tx_beat} + 3'd1;
    wire [2:0] wr_tx_next_beat = {1'b0, wr_tx_beat} + 3'd1;
    wire [AXI_ADDR_WIDTH-1:0] rd_tx_bytes =
        {{(AXI_ADDR_WIDTH-2){1'b0}}, rd_tx_beats} << 4;
    wire [AXI_ADDR_WIDTH-1:0] wr_tx_bytes =
        {{(AXI_ADDR_WIDTH-2){1'b0}}, wr_tx_beats} << 4;

    // Assemble before shifting so the current (final) AXI beat participates
    // without waiting for another cycle.
    wire [383:0] rd_join_2 =
        {128'd0, m_axi_rdata[127:0], rd_buf[127:0]} >> (rd_byte_shift * 8);
    wire [383:0] rd_join_3 =
        {m_axi_rdata[127:0], rd_buf} >> (rd_byte_shift * 8);
    wire [255:0] rd_result = (rd_beats == 2) ?
                             rd_join_2[255:0] : rd_join_3[255:0];

    assign wr_ready  = idle_ok;
    assign wt_ready  = (idle_ok && !wr_req) ||
                      (wt_active && (wt_accepted < WEIGHT_GROUP_WORDS));
    assign rda_ready = idle_ok && !wr_req && !wt_req;
    assign rdb_ready = idle_ok && !wr_req && !wt_req && !rda_req;
    assign busy = (state != S_IDLE) || wr_done;

    assign m_axi_awid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_awaddr  = req_addr;
    assign m_axi_awlen   = {6'd0, wr_tx_beats - 1'b1};
    assign m_axi_awsize  = AXI_SIZE;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'd3;
    assign m_axi_awprot  = 3'd2;
    assign m_axi_awqos   = 4'd0;
    assign m_axi_awvalid = (state == S_WADDR);

    assign m_axi_wdata = (wr_beat == 0) ? wr_shift_data[127:0] :
                        (wr_beat == 1) ? wr_shift_data[255:128] :
                                         wr_shift_data[383:256];
    assign m_axi_wstrb = (wr_beat == 0) ? wr_shift_strb[15:0] :
                        (wr_beat == 1) ? wr_shift_strb[31:16] :
                                         wr_shift_strb[47:32];
    assign m_axi_wlast  = (wr_tx_next_beat == {1'b0, wr_tx_beats});
    assign m_axi_wvalid = (state == S_WDATA);
    assign m_axi_bready = (state == S_WRESP);

    assign m_axi_arid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_araddr  = req_addr;
    assign m_axi_arlen   = (rd_owner == 2'd2) ? (wt_tx_beats - 1'b1) :
                          {6'd0, rd_tx_beats - 1'b1};
    assign m_axi_arsize  = AXI_SIZE;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'd3;
    assign m_axi_arprot  = 3'd2;
    assign m_axi_arqos   = 4'd0;
    assign m_axi_arvalid = (state == S_RADDR);
    assign m_axi_rready  = (state == S_RDATA) &&
                          (!wt_active || (wt_accepted > (wt_beat >> 1)));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            rd_owner <= 2'd0;
            rd_beat <= 2'd0;
            rd_beats <= 2'd2;
            rd_tx_beat <= 2'd0;
            rd_tx_beats <= 2'd2;
            rd_byte_shift <= 4'd0;
            rd_buf <= 256'd0;
            wt_beat <= 0; wt_tx_beat <= 0; wt_tx_beats <= 0;
            wt_accepted <= 0; wt_group_base <= 0;
            wr_beat <= 2'd0;
            wr_beats <= 2'd1;
            wr_tx_beat <= 2'd0;
            wr_tx_beats <= 2'd1;
            req_addr <= {AXI_ADDR_WIDTH{1'b0}};
            wr_shift_data <= 384'd0;
            wr_shift_strb <= 48'd0;
            rda_valid <= 1'b0;
            rdb_valid <= 1'b0;
            wt_valid <= 1'b0;
            wr_done <= 1'b0;

            rda_data <= 256'd0;
            rdb_data <= 256'd0;
            wt_data <= 256'd0;
            fault <= 1'b0;
        end else begin
            rda_valid <= 1'b0;
            rdb_valid <= 1'b0;
            wt_valid <= 1'b0;
            wr_done <= 1'b0;

            // Accept the remaining logical 32-byte requests without issuing
            // extra ARs. Count/validate them independently of response timing.
            if (wt_active && wt_req && wt_ready) begin
                wt_accepted <= wt_accepted + 1'b1;
                if (wt_addr != wt_expected_addr) fault <= 1'b1;
            end

            case (state)
            S_IDLE: begin
                if (idle_ok && wr_req) begin
                    if ((wr_n == 0) || (wr_n > 32)) begin
                        fault <= 1'b1;
                        wr_done <= 1'b1;
                    end else begin
                        req_addr <= wr_aligned;
                        wr_shift_data <= {128'd0, wr_data} << (wr_abs[3:0] * 8);
                        wr_shift_strb <= {16'd0, byte_mask(wr_n)} << wr_abs[3:0];
                        wr_beats <= wr_req_beats;
                        wr_beat <= 2'd0;
                        wr_tx_beat <= 2'd0;
                        wr_tx_beats <= first_burst_beats(wr_aligned[11:0],
                                                        wr_req_beats);
                        state <= S_WADDR;
                    end
                end else if (idle_ok && wt_req) begin
                    // Read the complete padded group, preserving its on-DDR
                    // format. Split only at a 4-KiB AXI boundary.
                    req_addr <= wt_aligned;
                    rd_byte_shift <= 4'd0;
                    rd_beats <= 2'd2;
                    rd_owner <= 2'd2;
                    rd_beat <= 2'd0;
                    rd_tx_beat <= 2'd0;
                    rd_tx_beats <= first_burst_beats(wt_aligned[11:0], 2'd2);
                    wt_group_base <= wt_addr;
                    wt_accepted <= 1;
                    wt_beat <= 0; wt_tx_beat <= 0;
                    wt_tx_beats <= weight_burst_beats(wt_aligned[11:0],WT_BEATS);
                    state <= S_RADDR;
                end else if (idle_ok && rda_req) begin
                    req_addr <= rda_aligned;
                    rd_byte_shift <= rda_abs[3:0];
                    rd_beats <= rda_req_beats;
                    rd_owner <= 2'd0;
                    rd_beat <= 2'd0;
                    rd_tx_beat <= 2'd0;
                    rd_tx_beats <= first_burst_beats(rda_aligned[11:0],
                                                     rda_req_beats);
                    state <= S_RADDR;
                end else if (idle_ok && rdb_req) begin
                    req_addr <= rdb_aligned;
                    rd_byte_shift <= rdb_abs[3:0];
                    rd_beats <= rdb_req_beats;
                    rd_owner <= 2'd1;
                    rd_beat <= 2'd0;
                    rd_tx_beat <= 2'd0;
                    rd_tx_beats <= first_burst_beats(rdb_aligned[11:0],
                                                     rdb_req_beats);
                    state <= S_RADDR;
                end
            end

            S_RADDR: if (m_axi_arready) state <= S_RDATA;

            S_RDATA: if (m_axi_rvalid && m_axi_rready) begin
                if (rd_owner == 2'd2) begin
                    if (m_axi_rresp != 0 ||
                        m_axi_rlast != (wt_tx_next == wt_tx_beats)) fault <= 1'b1;
                    if (!wt_beat[0]) rd_buf[127:0] <= m_axi_rdata[127:0];
                    else begin
                        wt_data <= {m_axi_rdata[127:0],rd_buf[127:0]};
                        wt_valid <= 1'b1;
                    end
                    if (wt_next_beat == WT_BEATS) state <= S_IDLE;
                    else begin
                        wt_beat <= wt_beat + 1'b1;
                        if (wt_tx_next == wt_tx_beats) begin
                            req_addr <= req_addr + (wt_tx_beats * 16);
                            wt_tx_beats <= weight_burst_beats(12'd0, WT_BEATS-wt_next_beat);
                            wt_tx_beat <= 0;
                            state <= S_RADDR;
                        end else wt_tx_beat <= wt_tx_beat + 1'b1;
                    end
                end else begin
                if ((m_axi_rresp != 2'b00) ||
                    (m_axi_rlast != (rd_tx_next_beat == {1'b0, rd_tx_beats})))
                    fault <= 1'b1;
                if (rd_next_beat == {1'b0, rd_beats}) begin
                    if (rd_owner == 2'd2) begin
                        wt_data <= rd_result;
                        wt_valid <= 1'b1;
                    end else if (rd_owner == 2'd1) begin
                        rdb_data <= rd_result;
                        rdb_valid <= 1'b1;
                    end else begin
                        rda_data <= rd_result;
                        rda_valid <= 1'b1;
                    end
                    state <= S_IDLE;
                end else begin
                    if (rd_beat == 0)
                        rd_buf[127:0] <= m_axi_rdata[127:0];
                    else
                        rd_buf[255:128] <= m_axi_rdata[127:0];
                    rd_beat <= rd_beat + 1'b1;
                    if (rd_tx_next_beat == {1'b0, rd_tx_beats}) begin
                        req_addr <= req_addr + rd_tx_bytes;
                        rd_tx_beats <= rd_beats - rd_next_beat;
                        rd_tx_beat <= 2'd0;
                        state <= S_RADDR;
                    end else begin
                        rd_tx_beat <= rd_tx_beat + 1'b1;
                    end
                end
                end
            end

            S_WADDR: if (m_axi_awready) state <= S_WDATA;

            S_WDATA: if (m_axi_wready) begin
                wr_beat <= wr_beat + 1'b1;
                if (m_axi_wlast)
                    state <= S_WRESP;
                else
                    wr_tx_beat <= wr_tx_beat + 1'b1;
            end

            S_WRESP: if (m_axi_bvalid) begin
                if (m_axi_bresp != 2'b00)
                    fault <= 1'b1;
                if (wr_beat == wr_beats) begin
                    wr_done <= 1'b1;
                    state <= S_IDLE;
                end else begin
                    req_addr <= req_addr + wr_tx_bytes;
                    wr_tx_beats <= wr_beats - wr_beat;
                    wr_tx_beat <= 2'd0;
                    state <= S_WADDR;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire

`default_nettype none
module frame_store_ddr_axi_a4 #(
    parameter integer STREAM_REFILL = 1,
    parameter integer WRITE_END_PIPE = 0,
    parameter integer FIXED_WRITES = 0,
    parameter integer SHARED_READ_CACHE = 1,
    parameter integer REFILL_ALIGN_BITS = (SHARED_READ_CACHE!=0)?5:10,
    parameter integer FAST_MASK_SEAL = 1,
    parameter integer PACKET_WORDS = 16,
    parameter integer EARLY_CACHE_READ = STREAM_REFILL,
    parameter integer PARALLEL_CACHE_READ = 0,
    parameter integer REGISTERED_FLUSH = 0,
    parameter integer PACKET_INPUT_PIPE = 0,
    parameter integer PIPELINED_MASK = 0,
    parameter integer STREAM_WR = 0,
    parameter integer PACKET_OVERLAP = 1,
    parameter integer AXI_ADDR_WIDTH   = 32,
    parameter integer AXI_DATA_WIDTH   = 128,
    parameter integer AXI_ID_WIDTH     = 4,
    parameter integer FRAME_ADDR_WIDTH = 15,
    parameter [AXI_ADDR_WIDTH-1:0] BASE_ADDR = 32'h0100_0000,
    parameter [AXI_ADDR_WIDTH-1:0] WEIGHT_BASE_ADDR = 32'h0180_0000,
    parameter integer WEIGHT_GROUP_WORDS = 1,
    parameter integer BANK_ADDR_SHIFT  = 20
)(
    input  wire clk,
    input  wire rst_n,
    input  wire cal_done,
    input wire flush, invalidate,

    input  wire rda_req,
    output wire rda_ready,
    input  wire [1:0] rda_bank,
    input  wire [FRAME_ADDR_WIDTH-1:0] rda_addr,
    output wire rda_valid,
    output wire [255:0] rda_data,

    input  wire rdb_req,
    output wire rdb_ready,
    input  wire [1:0] rdb_bank,
    input  wire [FRAME_ADDR_WIDTH-1:0] rdb_addr,
    output wire rdb_valid,
    output wire [255:0] rdb_data,

    input  wire wr_req,
    output wire wr_ready,
    input  wire [1:0] wr_bank,
    input  wire [FRAME_ADDR_WIDTH-1:0] wr_addr,
    input wire [FRAME_ADDR_WIDTH:0] wr_end,
    input  wire [255:0] wr_data,
    input  wire [5:0] wr_n,
    output reg  wr_done,

    // Aligned 32-byte weight read.  wt_addr is a byte offset within the
    // packed network-weight image in DDR. A group comprises consecutive
    // WEIGHT_GROUP_WORDS requests; one burst supplies ordered 32-byte replies.
    // The producer must issue every word in the group, even if replies start.
    input  wire wt_req,
    output wire wt_ready,
    input  wire [31:0] wt_addr,
    output reg  wt_valid,
    output reg  [255:0] wt_data,

    output wire busy,
    output reg  fault,

    output wire [AXI_ID_WIDTH-1:0] m_axi_awid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awlock,
    output wire [3:0] m_axi_awcache,
    output wire [2:0] m_axi_awprot,
    output wire [3:0] m_axi_awqos,
    output wire m_axi_awvalid,
    input  wire m_axi_awready,

    output wire [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output wire m_axi_wlast,
    output wire m_axi_wvalid,
    input  wire m_axi_wready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_bid,
    input  wire [1:0] m_axi_bresp,
    input  wire m_axi_bvalid,
    output wire m_axi_bready,

    output wire [AXI_ID_WIDTH-1:0] m_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arlock,
    output wire [3:0] m_axi_arcache,
    output wire [2:0] m_axi_arprot,
    output wire [3:0] m_axi_arqos,
    output wire m_axi_arvalid,
    input  wire m_axi_arready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0] m_axi_rresp,
    input  wire m_axi_rlast,
    input  wire m_axi_rvalid,
    output wire m_axi_rready
);
    // A4 feature DMA: two logical read caches (2KiB each), physically
    // combined, and two configurable masked packets sharing eight RAM blocks. At most one external transaction is
    // outstanding in each direction; reads and writes progress independently.
    // flush/busy form a layer barrier: acknowledgement means locally queued,
    // while busy remains asserted until all external B responses complete.
    localparam [3:0] IDLE=0, READ_ADDR=1, READ_DATA=2, CACHE_READ=3,
                     CACHE_RETURN=4, WRITE_ADDR=5, WRITE_DATA=6, WRITE_RESP=7,
                     WEIGHT_ADDR=8, WEIGHT_DATA=9, CACHE_SECOND=10, CACHE_THIRD=11,
                     CACHE_WAIT_FILL=12;
    reg [3:0] state;
    reg [AXI_ADDR_WIDTH-1:0] req_addr, read_addr, cache_a_base, cache_b_base;
    reg cache_a_valid, cache_b_valid, owner_b, resume_read;
    // Client ownership and physical cache way are independent. Both readers
    // may reuse either existing 2 KiB way; no data RAM is added.
    reg response_way,replace_way;
    // Refilling uses the RAM write port while responses use its read port.
    // Exactly one AXI read burst/weight transaction remains outstanding.
    localparam [1:0] F_IDLE=0,F_ADDR=1,F_DATA=2;
    reg [1:0] fill_state;
    reg fill_owner_b,fill_keep;
    reg [AXI_ADDR_WIDTH-1:0] fill_base;
    wire fill_busy=fill_state!=F_IDLE;
    reg [8:0] read_index, read_left, read_tx_beats, read_tx_index;
    reg [127:0] read_half; // weight fetch still joins two DDR beats
    // Compact resident cache: 128-bit words, two/three sequential reads for
    // aligned/unaligned 32-byte requests. Full feature maps live in DDR.
    reg [127:0] cache_first,cache_second;
    wire [127:0] cache_word;
    wire [AXI_ADDR_WIDTH-1:0] selected_cache_base=response_way ? cache_b_base : cache_a_base;
    wire [10:0] read_offset=read_addr-selected_cache_base;
    wire [6:0] read_word=read_offset[10:4];
    wire unaligned_cache_read=|read_offset[3:0];
    wire [6:0] cache_read_word=read_word+
        ((state==CACHE_SECOND)?7'd1:(state==CACHE_THIRD)?7'd2:7'd0);
    wire cache_read_enable=state==CACHE_READ || state==CACHE_SECOND || state==CACHE_THIRD;
    wire [383:0] cache_bundle=unaligned_cache_read ?
        {cache_word,cache_second,cache_first}:{128'd0,cache_word,cache_first};
    wire [383:0] read_join=cache_bundle >> (read_offset[3:0]*8);
    wire refill=((STREAM_REFILL!=0)?(fill_state==F_DATA):(state==READ_DATA)) && m_axi_rvalid && m_axi_rready;

    localparam PW=$clog2(PACKET_WORDS),PACKET_BYTES=16*PACKET_WORDS;
    reg dirty;
    reg [AXI_ADDR_WIDTH-1:0] write_base;
    // Build masks remain registers; sealed masks use their own RAM snapshot.
    (* syn_ramstyle="logic" *) reg [15:0] write_mask[0:PACKET_WORDS-1];
    reg mask_copy;
    // Three-byte final pixels are contiguous within a packet. Intermediate
    // four-byte writes may be sparse, but always cover complete words.
    reg [PACKET_WORDS*4-1:0] compact_words;
    reg compact_rgb;
    reg [15:0] compact_first,compact_last;
    reg [PW-1:0] compact_last_beat;
    reg [PW+4:0] compact_end;
    wire fixed_shape_ok;
    reg [PW-1:0] mask_copy_index;
    wire [19:0] drain_mask_q;
    reg build_bank,drain_bank;
    reg [AXI_ADDR_WIDTH-1:0] drain_base;
    reg [PW:0] drain_beats;
    reg [PW:0] write_beats,write_index,write_tx_beats,write_tx_index;
    reg [7:0] idle_age;
    reg [1:0] wstate;
    reg [AXI_ADDR_WIDTH-1:0] write_req_addr;
    function [AXI_ADDR_WIDTH-1:0] absolute_addr;
        input [1:0] bank;
        input [FRAME_ADDR_WIDTH-1:0] addr;
        begin absolute_addr=BASE_ADDR+({{(AXI_ADDR_WIDTH-2){1'b0}},bank}<<BANK_ADDR_SHIFT)+addr;end
    endfunction
    function [8:0] burst_beats;
        input [AXI_ADDR_WIDTH-1:0] addr;
        input [8:0] remaining;
        reg [8:0] limit;
        begin
            limit=(13'd4096-{1'b0,addr[11:0]})>>4;
            burst_beats=(remaining<limit) ? remaining : limit;
        end
    endfunction
    wire [AXI_ADDR_WIDTH-1:0] a_addr=absolute_addr(rda_bank,rda_addr);
    wire [AXI_ADDR_WIDTH-1:0] b_addr=absolute_addr(rdb_bank,rdb_addr);
    wire [AXI_ADDR_WIDTH-1:0] w_addr=absolute_addr(wr_bank,wr_addr);
    // Range end is captured with the descriptor; no new pipeline cycle.
    wire [AXI_ADDR_WIDTH-1:0] w_end=(WRITE_END_PIPE!=0)?
        BASE_ADDR+({{(AXI_ADDR_WIDTH-2){1'b0}},wr_bank}<<BANK_ADDR_SHIFT)+AXI_ADDR_WIDTH'(wr_end):
        (w_addr+wr_n);
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && wr_req && WRITE_END_PIPE!=0 && w_end!=(w_addr+wr_n))
        $fatal(1,"precomputed write endpoint does not match descriptor");
`endif

    wire a_hit=cache_a_valid && a_addr>=cache_a_base && a_addr+32<=cache_a_base+2048;
    wire b_hit=cache_b_valid && b_addr>=cache_b_base && b_addr+32<=cache_b_base+2048;
    wire a_in_fill=fill_busy && fill_keep && (SHARED_READ_CACHE!=0 || !fill_owner_b) && a_addr>=fill_base && a_addr+32<=fill_base+2048;
    wire b_in_fill=fill_busy && fill_keep && (SHARED_READ_CACHE!=0 || fill_owner_b) && b_addr>=fill_base && b_addr+32<=fill_base+2048;
    wire [12:0] received_bytes={read_index,4'b0};
    // Only used after the full-address range check. The modulo-2KiB
    // subtraction is exact inside this range and keeps the comparator narrow.
    wire [10:0] selected_fill_offset=(rda_req?a_addr[10:0]:b_addr[10:0])-fill_base[10:0];
    wire [12:0] selected_fill_end={2'b0,selected_fill_offset}+13'd32;
    wire requested_prefix_ready=received_bytes>=selected_fill_end;
    wire [AXI_ADDR_WIDTH-1:0] request_address=rda_req?a_addr:b_addr;
    // Start at the requested 32-byte block rather than fetching an unused
    // prefix of up to 1 KiB. Existing burst splitting handles 4 KiB edges.
    wire [AXI_ADDR_WIDTH-1:0] request_refill_base=(request_address>>REFILL_ALIGN_BITS)<<REFILL_ALIGN_BITS;
    wire way0_hit=cache_a_valid && request_address>=cache_a_base && request_address+32<=cache_a_base+2048;
    wire way1_hit=cache_b_valid && request_address>=cache_b_base && request_address+32<=cache_b_base+2048;
    wire accepted_full_hit=(SHARED_READ_CACHE!=0)?(way0_hit || way1_hit):(rda_req?a_hit:b_hit);
    wire hit_way=(SHARED_READ_CACHE!=0)?(!way0_hit && way1_hit):!rda_req;
    wire allocation_way=(SHARED_READ_CACHE!=0)?(!cache_a_valid?1'b0:!cache_b_valid?1'b1:replace_way):!rda_req;
    wire accepted_fill_hit=rda_req?a_in_fill:b_in_fill;
    wire allow_read_during_fill=!fill_busy || accepted_full_hit || accepted_fill_hit;
    wire early_read=EARLY_CACHE_READ!=0 &&
        ((rda_req && rda_ready) || (rdb_req && rdb_ready)) &&
        (accepted_full_hit || (accepted_fill_hit && requested_prefix_ready));
    wire selected_way=accepted_full_hit?hit_way:accepted_fill_hit?fill_owner_b:allocation_way;
    wire [10:0] early_offset=request_address[10:0]-(selected_way?cache_b_base[10:0]:cache_a_base[10:0]);
    // Address selection is independent of the long ready/conflict path.
    // In IDLE the RAM can only read an accepted early hit; in the cache
    // response states it reads the held descriptor. RE still qualifies the
    // exact original transaction, so unused IDLE addresses have no effect.
    wire early_address_slot=(EARLY_CACHE_READ!=0) && state==IDLE;
    wire [6:0] early_word0=request_address[10:4]-cache_a_base[10:4];
    wire [6:0] early_word1=request_address[10:4]-cache_b_base[10:4];
    wire [7:0] early_cache_address=(REFILL_ALIGN_BITS>=4)?
        {selected_way,selected_way?early_word1:early_word0}:
        {selected_way,early_offset[10:4]};
    generate if(PARALLEL_CACHE_READ!=0)begin:G_PARALLEL_READ
        // Read both physical ways before the tag/ready decision. Only the
        // accepted descriptor may consume Q; misses and withdrawn requests
        // never publish speculative contents. The registered response_way
        // chooses the word after the RAM clock edge, removing tag and hazard
        // logic from BRAM RE/RADDR without changing hit response latency.
        wire [127:0] word0,word1;
        wire [10:0] offset0=request_address[10:0]-cache_a_base[10:0];
        wire [10:0] offset1=request_address[10:0]-cache_b_base[10:0];
        wire [6:0] index0=(REFILL_ALIGN_BITS>=4)?early_word0:offset0[10:4];
        wire [6:0] index1=(REFILL_ALIGN_BITS>=4)?early_word1:offset1[10:4];
        wire read_enable=rst_n && (cache_read_enable || early_address_slot);
        wire write_way=fill_busy?fill_owner_b:response_way;
        a4_cache_sdp #(.AW(7)) u_way0(.clk(clk),.we(refill && !write_way),
            .wa(read_index[6:0]),.wd(m_axi_rdata),.re(read_enable),
            .ra(early_address_slot?index0:cache_read_word),.q(word0));
        a4_cache_sdp #(.AW(7)) u_way1(.clk(clk),.we(refill && write_way),
            .wa(read_index[6:0]),.wd(m_axi_rdata),.re(read_enable),
            .ra(early_address_slot?index1:cache_read_word),.q(word1));
        assign cache_word=response_way?word1:word0;
    end else begin:G_SHARED_READ_PORT
    // No response reads past the stored frontier. The two logical banks
    // keep independent tags; physical read/write ports may run concurrently.
    a4_cache_sdp #(.AW(8)) u_read_cache(.clk(clk),.we(refill),
        .wa({(fill_busy?fill_owner_b:response_way),read_index[6:0]}),.wd(m_axi_rdata),
        .re(cache_read_enable || early_read),.ra(early_address_slot?early_cache_address:{response_way,cache_read_word}),.q(cache_word));
    end endgenerate
    // RAM Q and saved words remain stable through the response cycle.
    assign rda_valid=rst_n && state==CACHE_RETURN && !owner_b;
    assign rdb_valid=rst_n && state==CACHE_RETURN && owner_b;
    assign rda_data=read_join[255:0];
    assign rdb_data=read_join[255:0];
    wire write_fits=!dirty || (w_addr>=write_base && w_end<=write_base+PACKET_BYTES);
    wire write_valid_size=(wr_n!=0 && wr_n<=32) && (FIXED_WRITES==0 || fixed_shape_ok);
    wire [AXI_ADDR_WIDTH-1:0] effective_write_base=dirty ? write_base : {w_addr[AXI_ADDR_WIDTH-1:4],4'b0};
    wire [PW+4:0] write_offset=w_addr-effective_write_base;
    wire [PW+4:0] write_end=write_offset+wr_n;
    wire [PW:0] needed_write_beats=(write_end+15)>>4;
    // Align once, then use fixed byte lanes: avoid 32 independent wide write muxes.
    // Fixed A4 accepts only RGB3 or aligned word4 descriptors. Upper
    // data bytes have no strobes, so they need no 32-byte barrel shifter.
    wire [383:0] aligned_write_data=(FIXED_WRITES!=0)?
        ({352'b0,wr_data[31:0]} << (write_offset[3:0]*8)):
        ({128'b0,wr_data} << (write_offset[3:0]*8));
    wire [47:0] aligned_write_mask=((FIXED_WRITES!=0)?((wr_n==3)?48'h7:48'hf):((48'h1<<wr_n)-1'b1)) << write_offset[3:0];
    // Rotate the three byte-aligned words once into four shared lanes.
    // Every packet register consumes one fixed lane, rather than replicating
    // a three-way 128-bit data mux for all packet words.
    wire [127:0] packet_lane_data[0:3];
    wire [15:0] packet_lane_mask[0:3];
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin:G_PACKET_LANES
        localparam [1:0] L0=lane,L1=(lane+3)%4,L2=(lane+2)%4;
        assign packet_lane_data[lane]=(write_offset[5:4]==L0)?aligned_write_data[127:0]:
                                      (write_offset[5:4]==L1)?aligned_write_data[255:128]:
                                      (write_offset[5:4]==L2)?aligned_write_data[383:256]:128'b0;
        assign packet_lane_mask[lane]=(write_offset[5:4]==L0)?aligned_write_mask[15:0]:
                                      (write_offset[5:4]==L1)?aligned_write_mask[31:16]:
                                      (write_offset[5:4]==L2)?aligned_write_mask[47:32]:16'b0;
    end endgenerate
    // Two RGB bytes share one width-20 RAM; its two 10-bit write lanes
    // keep byte strobes independent. Short NN writes complete in one cycle.
    // Wider generic writes retain the 1..32-byte interface using two tail
    // cycles; sealing and new acceptance wait until those bytes are stored.
    wire packet_accept=rst_n && wr_req && wr_ready && write_valid_size;
    wire [PW:0] packet_word0={1'b0,write_offset[PW+3:4]};
    wire [PW:0] packet_word1=packet_word0+1'b1;
    wire [PW:0] packet_read_word=(wstate==2 && m_axi_wready)?write_index+1'b1:write_index;
    reg [1:0] packet_tail_phase;
    reg [255:0] packet_tail_data;
    reg [31:0] packet_tail_mask;
    reg [PW:0] packet_tail_word;
    wire packet_pending=(packet_tail_phase!=0);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            packet_tail_phase<=0;packet_tail_data<=0;
            packet_tail_mask<=0;packet_tail_word<=0;
        end else if(FIXED_WRITES==0 && packet_accept && wr_n>15) begin
            packet_tail_phase<=1;
            packet_tail_data<=aligned_write_data[383:128];
            packet_tail_mask<=aligned_write_mask[47:16];
            packet_tail_word<=packet_word1;
        end else if(packet_pending) begin
            if(packet_tail_phase==1 && |packet_tail_mask[31:16]) begin
                packet_tail_phase<=2;
                packet_tail_data<={128'b0,packet_tail_data[255:128]};
                packet_tail_mask<={16'b0,packet_tail_mask[31:16]};
                packet_tail_word<=packet_tail_word+1'b1;
            end else packet_tail_phase<=0;
        end
    end
    wire [127:0] packet_q;
    wire seal_packet;
    genvar byte_pair;
    generate for(byte_pair=0;byte_pair<8;byte_pair=byte_pair+1) begin:G_PACKET_PAIR
        wire [1:0] mask0=aligned_write_mask[byte_pair*2 +:2];
        wire [1:0] mask1=aligned_write_mask[16+byte_pair*2 +:2];
        wire select_first=(FIXED_WRITES==0 && wr_n>15) || (|mask0);
        wire [PW:0] word_sel=packet_pending?packet_tail_word:
                                   (select_first?packet_word0:packet_word1);
        wire [15:0] data_sel=packet_pending?packet_tail_data[byte_pair*16 +:16]:
                         select_first?aligned_write_data[byte_pair*16 +:16]:
                                      aligned_write_data[128+byte_pair*16 +:16];
        wire [1:0] byte_mask=packet_pending?packet_tail_mask[byte_pair*2 +:2]:
                                        select_first?mask0:mask1;
        wire [1:0] write_enable={(2){(packet_pending || packet_accept) && word_sel<PACKET_WORDS}} & byte_mask;
        wire [19:0] pair_q;
        wire [1:0] ram_write_enable;
        wire [PW:0] ram_write_word;
        wire ram_write_bank;
        wire [15:0] ram_write_data;
        if(PACKET_INPUT_PIPE!=0)begin:G_INPUT_PIPE
            // Capture payload/mask/address independently of the acceptance
            // control. RAM writes one edge later, with one write per cycle.
            // The last commit is no later than packet seal; AW and the first
            // drain-port read follow seal, so no uncommitted byte is visible.
            reg write_q;
            reg [PW:0] word_q;
            reg bank_q;
            reg [15:0] data_q;
            reg [1:0] mask_q;
            always @(posedge clk or negedge rst_n)
                if(!rst_n)write_q<=0;
                else write_q<=packet_pending || packet_accept;
            always @(posedge clk)begin
                word_q<=word_sel;bank_q<=build_bank;
                data_q<=data_sel;mask_q<=byte_mask;
            end
            assign ram_write_enable={2{write_q && word_q<PACKET_WORDS}} & mask_q;
            assign ram_write_word=word_q;
            assign ram_write_bank=bank_q;
            assign ram_write_data=data_q;
        end else begin:G_DIRECT_INPUT
            assign ram_write_enable=write_enable;
            assign ram_write_word=word_sel;
            assign ram_write_bank=build_bank;
            assign ram_write_data=data_sel;
        end
        EFX_RAM10 #(.READ_WIDTH(20),.WRITE_WIDTH(20),.OUTPUT_REG(1'b0),
                    .WRITE_MODE("READ_FIRST")) u_data(
            .WCLK(clk),.WCLKE(1'b1),.WADDREN(1'b1),.WE(ram_write_enable),
            .WADDR({{(8-PW){1'b0}},ram_write_bank,ram_write_word[PW-1:0]}),.WDATA({2'b0,ram_write_data[15:8],2'b0,ram_write_data[7:0]}),
            .RCLK(clk),.RE(1'b1),.RADDREN(1'b1),.RST(1'b0),
            .RADDR({{(8-PW){1'b0}},drain_bank,packet_read_word[PW-1:0]}),.RDATA(pair_q));
        assign packet_q[byte_pair*16 +:16]={pair_q[17:10],pair_q[7:0]};
    end endgenerate
    // Commit byte masks from the same registered descriptor that writes RAM.
    // With pipelined masks seal waits until this final commit has retired,
    // so the snapshot includes every accepted byte, including the tail word.
    wire packet_input_pending;
    generate if(PACKET_INPUT_PIPE!=0)begin:G_INPUT_PENDING
        assign packet_input_pending=G_PACKET_PAIR[0].G_INPUT_PIPE.write_q;
    end else begin assign packet_input_pending=0;end endgenerate
    wire mask_update_pending=PIPELINED_MASK!=0 && packet_input_pending;
    wire [15:0] committed_mask[0:PACKET_WORDS-1];
    genvar commit_word,commit_byte;
    generate for(commit_word=0;commit_word<PACKET_WORDS;commit_word=commit_word+1)begin:G_COMMIT_WORD
        for(commit_byte=0;commit_byte<16;commit_byte=commit_byte+1)begin:G_COMMIT_BYTE
            assign committed_mask[commit_word][commit_byte]=
                G_PACKET_PAIR[commit_byte/2].ram_write_enable[commit_byte%2] &&
                G_PACKET_PAIR[commit_byte/2].ram_write_word==commit_word &&
                G_PACKET_PAIR[commit_byte/2].ram_write_bank==build_bank;
        end
    end endgenerate
    // A packet-sized logic snapshot replaces two very shallow mask RAMs and their
    // eight-cycle copy. Data packets stay in their existing block RAM banks.
    generate if(FIXED_WRITES!=0)begin:G_COMPACT_MASK_SEAL
        // Dirty qualification hides uninitialized payload state after reset.
        // The first accepted write initializes every field before a seal.
        assign fixed_shape_ok=((wr_n==3) || (wr_n==4 && w_addr[1:0]==0)) &&
            (!dirty || ((compact_rgb==(wr_n==3)) && (wr_n!=3 || write_offset==compact_end)));
        always @(posedge clk)if(packet_accept)begin
            if(!dirty)begin
                compact_words<=0;compact_rgb<=(wr_n==3);
                compact_first<=16'hffff << write_offset[3:0];
            end
            if(wr_n==4)compact_words[write_offset[PW+3:2]]<=1'b1;
            else begin
                compact_last<=(write_end[3:0]==0)?16'hffff:((17'h1<<write_end[3:0])-1'b1);
                compact_last_beat<=needed_write_beats-1'b1;compact_end<=write_end;
            end
        end
        function [15:0] word_strobes(input [3:0] v);
            word_strobes={{4{v[3]}},{4{v[2]}},{4{v[1]}},{4{v[0]}}};
        endfunction
        function [15:0] rgb_strobes(input [PW-1:0] word_index,input [15:0] first_mask,last_mask,input [PW-1:0] last_index);
            rgb_strobes=(word_index>last_index)?16'd0:
                ((word_index==0)?first_mask:16'hffff) & ((word_index==last_index)?last_mask:16'hffff);
        endfunction
        reg [PACKET_WORDS*4-1:0] sealed_words;
        reg sealed_rgb;reg [15:0] sealed_first,sealed_last;
        reg [PW-1:0] sealed_last_beat;reg [15:0] mask_q;
        always @(posedge clk)begin
            if(rst_n && seal_packet)begin
                sealed_words<=compact_words;sealed_rgb<=compact_rgb;
                sealed_first<=compact_first;sealed_last<=compact_last;sealed_last_beat<=compact_last_beat;
            end
            mask_q<=sealed_rgb?rgb_strobes(packet_read_word[PW-1:0],sealed_first,sealed_last,sealed_last_beat):
                word_strobes(sealed_words[packet_read_word[PW-1:0]*4+:4]);
        end
        assign drain_mask_q={4'b0,mask_q};
`ifndef SYNTHESIS
        // Keep the complete original bitmap as a simulation-only oracle.
        reg [15:0] reference_sealed[0:PACKET_WORDS-1];reg [15:0] reference_q;
        integer k;reg [15:0] assembled;
        initial if(FAST_MASK_SEAL==0)$fatal(1,"compact A4 mask requires fast sealing");
        always @(posedge clk)begin
            if(rst_n && seal_packet)for(k=0;k<PACKET_WORDS;k=k+1)begin
                assembled=compact_rgb?rgb_strobes(PW'(k),compact_first,compact_last,compact_last_beat):word_strobes(compact_words[k*4+:4]);
                if(assembled!==write_mask[k])$fatal(1,"compressed packet mask differs at word %0d",k);
                reference_sealed[k]<=write_mask[k];
            end
            reference_q<=reference_sealed[packet_read_word[PW-1:0]];
            if(rst_n && m_axi_wvalid && m_axi_wstrb!==reference_q)$fatal(1,"compressed WSTRB differs from original snapshot");
        end
`endif
    end else if(FAST_MASK_SEAL!=0)begin:G_FAST_MASK_SEAL
        assign fixed_shape_ok=1'b1;
        (* syn_ramstyle="logic" *) reg [15:0] sealed_mask[0:PACKET_WORDS-1];
        reg [15:0] mask_q;
        integer mask_word;
        always @(posedge clk)begin
            if(rst_n && seal_packet)
                for(mask_word=0;mask_word<PACKET_WORDS;mask_word=mask_word+1)
                    sealed_mask[mask_word]<=write_mask[mask_word];
            mask_q<=sealed_mask[packet_read_word[PW-1:0]];
        end
        assign drain_mask_q={4'b0,mask_q};
    end else begin:G_RAM_MASK_SEAL
    assign fixed_shape_ok=1'b1;
    genvar mask_byte;
    for(mask_byte=0;mask_byte<2;mask_byte=mask_byte+1)begin:G_MASK_SNAPSHOT
        wire [7:0] mask_q;
        wire [PW:0] next_copy={1'b0,mask_copy_index}+1'b1;
        EFX_DPRAM10 #(.READ_WIDTH_A(8),.WRITE_WIDTH_A(8),.READ_WIDTH_B(8),.WRITE_WIDTH_B(8),
            .OUTPUT_REG_A(1'b0),.OUTPUT_REG_B(1'b0),.WRITE_MODE_A("READ_FIRST"),.WRITE_MODE_B("READ_FIRST")) u_mask(
            .CLKA(clk),.CLKEA(1'b1),.RSTA(1'b0),.ADDRENA(1'b1),
            .ADDRA(mask_copy?{{(10-PW){1'b0}},mask_copy_index}:{{(10-PW){1'b0}},packet_read_word[PW-1:0]}),
            .WEA(mask_copy),.WDATAA(write_mask[mask_copy_index][mask_byte*8+:8]),.RDATAA(mask_q),
            .CLKB(clk),.CLKEB(mask_copy),.RSTB(1'b0),.ADDRENB(1'b1),
            .ADDRB({{(10-PW){1'b0}},next_copy[PW-1:0]}),.WEB(mask_copy && next_copy<drain_beats),
            .WDATAB(write_mask[next_copy[PW-1:0]][mask_byte*8+:8]),.RDATAB());
        assign drain_mask_q[mask_byte*8+:8]=mask_q;
    end
    assign drain_mask_q[19:16]=0;
    end endgenerate
    // Conservatively protect the full possible refill range for every read.
    // It contains the requested 32 bytes on a hit and the complete 2 KiB
    // refill on a miss. This removes cache-hit -> extent mux -> compare from
    // the arbitration path; extra conflicts only cause an earlier safe drain.
    wire [AXI_ADDR_WIDTH-1:0] a_extent_base=(a_addr>>REFILL_ALIGN_BITS)<<REFILL_ALIGN_BITS;
    wire [AXI_ADDR_WIDTH-1:0] b_extent_base=(b_addr>>REFILL_ALIGN_BITS)<<REFILL_ALIGN_BITS;
    wire [AXI_ADDR_WIDTH-1:0] a_extent_end=a_extent_base+2048;
    wire [AXI_ADDR_WIDTH-1:0] b_extent_end=b_extent_base+2048;
    wire assembly_read_conflict=dirty &&
        ((rda_req && a_extent_base<write_base+(write_beats<<4) && a_extent_end>write_base) ||
         (!rda_req && rdb_req && b_extent_base<write_base+(write_beats<<4) && b_extent_end>write_base));
    // A queued packet remains a read hazard until its final B response,
    // even while the other physical bank accepts the following packet.
    wire drain_read_conflict=(wstate!=0) &&
        ((rda_req && a_extent_base<drain_base+(drain_beats<<4) && a_extent_end>drain_base) ||
         (!rda_req && rdb_req && b_extent_base<drain_base+(drain_beats<<4) && b_extent_end>drain_base));
    wire read_write_conflict=assembly_read_conflict || drain_read_conflict;
    wire incoming_conflict=wr_req &&
        ((rda_req && a_extent_base<w_end && a_extent_end>w_addr) ||
         (!rda_req && rdb_req && b_extent_base<w_end && b_extent_end>w_addr));
    wire active_read_conflict=((state!=IDLE && state!=WEIGHT_ADDR && state!=WEIGHT_DATA) &&
        w_addr<selected_cache_base+2048 && w_end>selected_cache_base) ||
        (fill_busy && w_addr<fill_base+2048 && w_end>fill_base);
    wire flush_due=dirty && (flush || idle_age==128 ||
                        (wr_req && !write_fits) || read_write_conflict);
    // Stall new packet updates on the current hazard, but move the drain
    // FSM/counter enable behind a register. A stale request may drain early;
    // dirty qualification prevents draining an already-completed packet.
    (* syn_preserve=1, syn_keep=1 *) reg flush_due_q;
    assign seal_packet=(wstate==0) && dirty && !packet_pending && !mask_update_pending && (flush || flush_due_q);
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)flush_due_q<=0;
        else flush_due_q<=flush_due;
    end
    // The drain bank is immutable until all its B responses return.
    // Non-overlapping reads continue during AW/W/B and packet assembly.
    // The read side still blocks a conflicting descriptor until both dirty
    // assembly and the final drained B response have retired. A read arriving
    // this cycle may let one more fitting write join that same dirty packet;
    // flush_due_q then stops acceptance before sealing on the next edge.
    // Explicit flush, active refill conflicts and packet fit remain immediate.
    // This removes the incoming read's ready path from packet-mask CE.
    assign wr_ready=(PACKET_OVERLAP!=0 || wstate==0) && !packet_pending && !mask_copy && cal_done && !flush && (REGISTERED_FLUSH!=0 || !flush_due) && !flush_due_q &&
                    !active_read_conflict && write_fits && (STREAM_WR!=0 || !wr_done);
    assign rda_ready=(state==IDLE) && cal_done && !flush && !wt_req &&
                     !read_write_conflict && !incoming_conflict && allow_read_during_fill &&
                     (STREAM_REFILL==0 || !invalidate);
    assign rdb_ready=rda_ready && !rda_req;
    assign wt_ready=(state==IDLE) && !fill_busy && cal_done && !flush;
    assign busy=(state!=IDLE)||fill_busy||(wstate!=0)||dirty||wr_done;
    assign m_axi_awid=0;assign m_axi_awaddr=write_req_addr;
    assign m_axi_awlen=write_tx_beats-1'b1;assign m_axi_awsize=4;
    assign m_axi_awburst=1;assign m_axi_awlock=0;assign m_axi_awcache=3;
    assign m_axi_awprot=2;assign m_axi_awqos=0;assign m_axi_awvalid=(wstate==1) && !mask_copy;
    assign m_axi_wdata=packet_q;
    assign m_axi_wstrb=drain_mask_q[15:0];
    assign m_axi_wlast=(write_tx_index+1'b1==write_tx_beats);
    assign m_axi_wvalid=(wstate==2);assign m_axi_bready=(wstate==3);
    assign m_axi_arid=0;assign m_axi_araddr=req_addr;
    assign m_axi_arlen=(state==WEIGHT_ADDR)?8'd1:read_tx_beats-1'b1;assign m_axi_arsize=4;
    assign m_axi_arburst=1;assign m_axi_arlock=0;assign m_axi_arcache=3;
    assign m_axi_arprot=2;assign m_axi_arqos=0;
    assign m_axi_arvalid=(state==WEIGHT_ADDR) || ((STREAM_REFILL!=0)?(fill_state==F_ADDR):(state==READ_ADDR));
    assign m_axi_rready=(state==WEIGHT_DATA) || ((STREAM_REFILL!=0)?(fill_state==F_DATA):(state==READ_DATA));
    integer j, wb, cw, cb;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;req_addr<=0;read_addr<=0;cache_a_base<=0;cache_b_base<=0;
            cache_a_valid<=0;cache_b_valid<=0;owner_b<=0;resume_read<=0;
            response_way<=0;replace_way<=0;
            fill_state<=F_IDLE;fill_owner_b<=0;fill_keep<=0;fill_base<=0;
            read_index<=0;read_left<=0;read_tx_beats<=0;read_tx_index<=0;read_half<=0;cache_first<=0;cache_second<=0;
            wstate<=0;write_req_addr<=0;
            build_bank<=0;drain_bank<=0;drain_base<=0;drain_beats<=0;
            dirty<=0;write_base<=0;write_beats<=0;write_index<=0;
            write_tx_beats<=0;write_tx_index<=0;idle_age<=0;
            wr_done<=0;
            wt_valid<=0;wt_data<=0;fault<=0;
            mask_copy<=0;mask_copy_index<=0;
            for(j=0;j<PACKET_WORDS;j=j+1) write_mask[j]<=0;
        end else begin
            wr_done<=0;wt_valid<=0;
            if(invalidate) begin cache_a_valid<=0;cache_b_valid<=0;fill_keep<=0;end

            if(fill_state==F_ADDR && m_axi_arvalid && m_axi_arready)fill_state<=F_DATA;
            if(fill_state==F_DATA && m_axi_rvalid && m_axi_rready)begin
                if(m_axi_rresp!=0 || m_axi_rlast!=(read_tx_index+1'b1==read_tx_beats))fault<=1;
                read_index<=read_index+1'b1;
                if(read_index==127)begin
                    if(fill_owner_b)cache_b_valid<=fill_keep && !invalidate;
                    else cache_a_valid<=fill_keep && !invalidate;
                    fill_state<=F_IDLE;
                end else if(read_tx_index+1'b1==read_tx_beats)begin
                    req_addr<=req_addr+(read_tx_beats<<4);
                    read_left<=read_left-read_tx_beats;
                    read_tx_beats<=burst_beats(req_addr+(read_tx_beats<<4),read_left-read_tx_beats);
                    read_tx_index<=0;fill_state<=F_ADDR;
                end else read_tx_index<=read_tx_index+1'b1;
            end

            if(mask_copy)begin
                if({1'b0,mask_copy_index}+2>=drain_beats)mask_copy<=0;
                else mask_copy_index<=mask_copy_index+2'd2;
            end
            if(dirty && idle_age<128) idle_age<=idle_age+1'b1;
            // Independent build bank: keep accepting while the sealed bank
            // waits for AW/W/B. Eight data RAM primitives hold both packets;
            // the separate mask snapshot keeps the sealed packet immutable.
            if(PIPELINED_MASK!=0)begin
                for(cw=0;cw<PACKET_WORDS;cw=cw+1)
                    for(cb=0;cb<16;cb=cb+1)
                        if(committed_mask[cw][cb])write_mask[cw][cb]<=1;
            end
            if(wr_req && wr_ready) begin
                if(!write_valid_size) begin fault<=1;wr_done<=1;end
                else begin
                    if(!dirty) begin
                        write_base<=effective_write_base;
                        for(j=0;j<PACKET_WORDS;j=j+1) write_mask[j]<=0;
                    end
                    if(PIPELINED_MASK==0)for(wb=0;wb<PACKET_WORDS;wb=wb+1) begin
                        if(write_offset[PW+4:4]==wb ||
                           ({1'b0,write_offset[PW+4:4]}+1)==wb ||
                           ({1'b0,write_offset[PW+4:4]}+2)==wb) begin
                            for(j=0;j<16;j=j+1) begin
                                if(packet_lane_mask[wb%4][j]) begin
                                    write_mask[wb][j]<=1;
                                end
                            end
                        end
                    end
                    if(!dirty || needed_write_beats>write_beats) write_beats<=needed_write_beats;
                    dirty<=1;idle_age<=0;wr_done<=1;
                    if(cache_a_valid && w_addr<cache_a_base+2048 && w_end>cache_a_base) cache_a_valid<=0;
                    if(cache_b_valid && w_addr<cache_b_base+2048 && w_end>cache_b_base) cache_b_valid<=0;
                end
            end

            case(wstate)
                0:begin
                    if(dirty && !packet_pending && !mask_update_pending && (flush || flush_due_q)) begin
                        write_req_addr<=write_base;write_index<=0;write_tx_index<=0;
                        write_tx_beats<=burst_beats(write_base,{1'b0,write_beats});
                        wstate<=1;
                        drain_bank<=build_bank;build_bank<=~build_bank;
                        drain_base<=write_base;drain_beats<=write_beats;
                        mask_copy<=(FAST_MASK_SEAL==0);mask_copy_index<=0;
                        dirty<=0;write_beats<=0;idle_age<=0;
                    end
                end
                1:if(m_axi_awvalid && m_axi_awready) wstate<=2;
                2:if(m_axi_wvalid && m_axi_wready) begin
                    write_index<=write_index+1'b1;
                    if(m_axi_wlast) wstate<=3;
                    else write_tx_index<=write_tx_index+1'b1;
                end
                3:if(m_axi_bvalid && m_axi_bready) begin
                    if(m_axi_bresp!=0) fault<=1;
                    if(write_index==drain_beats) begin wstate<=0;end
                    else begin
                        write_req_addr<=write_req_addr+(write_tx_beats<<4);
                        write_tx_beats<=burst_beats(write_req_addr+(write_tx_beats<<4),drain_beats-write_index);
                        write_tx_index<=0;wstate<=1;
                    end
                end
            endcase
            case(state)
                IDLE:if(wt_req && wt_ready) begin
                    // Weight manager requests one aligned 32-byte word. Two
                    // 128-bit beats cannot cross 4 KiB at 32-byte alignment.
                    if(wt_addr[4:0]!=0) fault<=1;
                    req_addr<=WEIGHT_BASE_ADDR+wt_addr;
                    read_tx_index<=0;state<=WEIGHT_ADDR;
                end else if((rda_req && rda_ready) || (rdb_req && rdb_ready)) begin
                    owner_b<=!rda_req;read_addr<=rda_req?a_addr:b_addr;
                    response_way<=selected_way;replace_way<=!selected_way;
                    if(accepted_full_hit || (accepted_fill_hit && requested_prefix_ready))state<=(EARLY_CACHE_READ!=0)?CACHE_SECOND:CACHE_READ;
                    else if(STREAM_REFILL!=0 && accepted_fill_hit)state<=CACHE_WAIT_FILL;
                    else begin
                        if(!allocation_way) begin
                            cache_a_base<=request_refill_base;cache_a_valid<=0;
                        end else begin
                            cache_b_base<=request_refill_base;cache_b_valid<=0;
                        end
                        read_index<=0;read_left<=128;read_tx_index<=0;
                        read_tx_beats<=burst_beats(request_refill_base,9'd128);
                        req_addr<=request_refill_base;
                        if(STREAM_REFILL!=0)begin
                            fill_owner_b<=allocation_way;fill_keep<=!invalidate;
                            fill_base<=request_refill_base;
                            fill_state<=F_ADDR;state<=CACHE_WAIT_FILL;
                        end else state<=READ_ADDR;
                    end
                end
                READ_ADDR:if(STREAM_REFILL==0 && m_axi_arvalid && m_axi_arready) state<=READ_DATA;
                READ_DATA:if(STREAM_REFILL==0 && m_axi_rvalid && m_axi_rready) begin
                    if(m_axi_rresp!=0 || m_axi_rlast!=(read_tx_index+1'b1==read_tx_beats)) fault<=1;
                    read_index<=read_index+1'b1;
                    if(read_index==127) begin
                        if(response_way) cache_b_valid<=1;else cache_a_valid<=1;
                        state<=CACHE_READ;
                    end else if(read_tx_index+1'b1==read_tx_beats) begin
                        req_addr<=req_addr+(read_tx_beats<<4);
                        read_left<=read_left-read_tx_beats;
                        read_tx_beats<=burst_beats(req_addr+(read_tx_beats<<4),read_left-read_tx_beats);
                        read_tx_index<=0;state<=READ_ADDR;
                    end else read_tx_index<=read_tx_index+1'b1;
                end
                WEIGHT_ADDR:if(m_axi_arvalid && m_axi_arready) state<=WEIGHT_DATA;
                WEIGHT_DATA:if(m_axi_rvalid && m_axi_rready) begin
                    if(m_axi_rresp!=0 || m_axi_rlast!=(read_tx_index==1)) fault<=1;
                    if(read_tx_index==0) begin read_half<=m_axi_rdata;read_tx_index<=1;end
                    else begin wt_data<={m_axi_rdata,read_half};wt_valid<=1;state<=IDLE;end
                end
                CACHE_READ:state<=CACHE_SECOND;
                CACHE_WAIT_FILL:if(received_bytes>={2'b0,read_offset}+13'd32)state<=CACHE_READ;
                CACHE_SECOND:begin
                    cache_first<=cache_word;
                    state<=unaligned_cache_read?CACHE_THIRD:CACHE_RETURN;
                end
                CACHE_THIRD:begin cache_second<=cache_word;state<=CACHE_RETURN;end
                // RAM Q was captured at the preceding clock edge. The client
                // consumes this response at the edge that retires CACHE_RETURN.
                CACHE_RETURN:state<=IDLE;
                default:begin fault<=1;state<=IDLE;end
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && STREAM_REFILL!=0)begin
        if(fill_busy && (state==WEIGHT_ADDR || state==WEIGHT_DATA))$fatal(1,"weight transaction overlaps a cache refill");
        if(cache_read_enable && fill_busy && response_way==fill_owner_b && {2'b0,cache_read_word}>=read_index)
            $fatal(1,"cache response read ahead of stored refill frontier");
        if(early_read && fill_busy && selected_way==fill_owner_b && {2'b0,early_offset[10:4]}>=read_index)
            $fatal(1,"early cache read ahead of stored refill frontier");
        if(state==CACHE_WAIT_FILL && (response_way!=fill_owner_b || selected_cache_base!=fill_base || {2'b0,read_offset}+13'd32>2048))
            $fatal(1,"pending cache response lost its refill allocation");
        if(fill_busy && !busy)$fatal(1,"refill missing from layer barrier");
    end
`endif
endmodule
`default_nettype wire

// Fixed-role RAM inference template; cache validity is tracked outside.
module a4_cache_sdp #(parameter AW=7)(input wire clk,we,re,
    input wire [AW-1:0] wa,ra,input wire [127:0] wd,
    output reg [127:0] q);
    (* syn_ramstyle="block_ram" *) reg [127:0] mem[0:(1<<AW)-1];
    always @(posedge clk) if(we) mem[wa]<=wd;
    always @(posedge clk) if(re) q<=mem[ra];
endmodule
