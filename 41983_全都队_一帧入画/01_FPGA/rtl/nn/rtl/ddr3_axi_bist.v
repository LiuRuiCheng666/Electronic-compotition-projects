`timescale 1ns/1ps
`default_nettype none

// Minimal destructive DDR3 memory test for the demo controller's AXI4 port.
// After a start pulse it writes TEST_BEATS unique 128-bit words, reads them
// back, and latches pass/fail until reset.  Only one transaction is outstanding
// at a time, which keeps the board-bring-up path deliberately conservative.
module ddr3_axi_bist #(
    parameter integer AXI_ID_WIDTH   = 4,
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer TEST_BEATS     = 256,
    parameter [AXI_ADDR_WIDTH-1:0] BASE_ADDR = 32'h0080_0000,
    parameter integer TIMEOUT_WIDTH  = 24
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,

    output reg  busy,
    output reg  done,
    output reg  pass,
    output reg  fail,
    output reg  [31:0] error_count,
    output reg  [AXI_ADDR_WIDTH-1:0] first_error_addr,

    output wire [AXI_ID_WIDTH-1:0]   m_axi_awid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [7:0]                m_axi_awlen,
    output wire [2:0]                m_axi_awsize,
    output wire [1:0]                m_axi_awburst,
    output wire                      m_axi_awlock,
    output wire [3:0]                m_axi_awcache,
    output wire [2:0]                m_axi_awprot,
    output wire                      m_axi_awvalid,
    input  wire                      m_axi_awready,

    output wire [AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output wire                        m_axi_wlast,
    output wire                        m_axi_wvalid,
    input  wire                        m_axi_wready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_bid,
    input  wire [1:0]              m_axi_bresp,
    input  wire                    m_axi_bvalid,
    output wire                    m_axi_bready,

    output wire [AXI_ID_WIDTH-1:0]   m_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0]                m_axi_arlen,
    output wire [2:0]                m_axi_arsize,
    output wire [1:0]                m_axi_arburst,
    output wire                      m_axi_arlock,
    output wire [3:0]                m_axi_arcache,
    output wire [2:0]                m_axi_arprot,
    output wire                      m_axi_arvalid,
    input  wire                      m_axi_arready,

    input  wire [AXI_ID_WIDTH-1:0] m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]              m_axi_rresp,
    input  wire                    m_axi_rlast,
    input  wire                    m_axi_rvalid,
    output wire                    m_axi_rready
);
    localparam integer AXI_BYTES = AXI_DATA_WIDTH / 8;
    localparam integer AXI_SIZE_I = $clog2(AXI_BYTES);
    localparam integer IDX_W = (TEST_BEATS <= 1) ? 1 : $clog2(TEST_BEATS);

    localparam [3:0] S_IDLE = 4'd0, S_WA = 4'd1, S_WD = 4'd2,
                     S_WB   = 4'd3, S_RA = 4'd4, S_RD = 4'd5,
                     S_DONE = 4'd6;

    reg [3:0] state;
    reg [IDX_W-1:0] index;
    reg [TIMEOUT_WIDTH-1:0] watchdog;

    wire [AXI_ADDR_WIDTH-1:0] index_ext =
        {{(AXI_ADDR_WIDTH-IDX_W){1'b0}}, index};
    wire [AXI_ADDR_WIDTH-1:0] test_addr =
        BASE_ADDR + (index_ext << AXI_SIZE_I);

    function [AXI_DATA_WIDTH-1:0] test_pattern;
        input [IDX_W-1:0] idx;
        integer k;
        reg [31:0] seed;
        begin
            seed = 32'hA5C3_5A3C ^ {{(32-IDX_W){1'b0}}, idx};
            for (k = 0; k < AXI_DATA_WIDTH/32; k = k + 1)
                test_pattern[k*32 +: 32] = seed ^ (32'h9E37_79B9 * k);
        end
    endfunction

    wire progress = (m_axi_awvalid && m_axi_awready) ||
                    (m_axi_wvalid  && m_axi_wready)  ||
                    (m_axi_bvalid  && m_axi_bready)  ||
                    (m_axi_arvalid && m_axi_arready) ||
                    (m_axi_rvalid  && m_axi_rready);

    assign m_axi_awid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_awaddr  = test_addr;
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = AXI_SIZE_I[2:0];
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'd3;
    assign m_axi_awprot  = 3'd2;
    assign m_axi_awvalid = (state == S_WA);

    assign m_axi_wdata  = test_pattern(index);
    assign m_axi_wstrb  = {AXI_BYTES{1'b1}};
    assign m_axi_wlast  = 1'b1;
    assign m_axi_wvalid = (state == S_WD);
    assign m_axi_bready = (state == S_WB);

    assign m_axi_arid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_araddr  = test_addr;
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arsize  = AXI_SIZE_I[2:0];
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'd3;
    assign m_axi_arprot  = 3'd2;
    assign m_axi_arvalid = (state == S_RA);
    assign m_axi_rready  = (state == S_RD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            index            <= {IDX_W{1'b0}};
            watchdog         <= {TIMEOUT_WIDTH{1'b0}};
            busy             <= 1'b0;
            done             <= 1'b0;
            pass             <= 1'b0;
            fail             <= 1'b0;
            error_count      <= 32'd0;
            first_error_addr <= {AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (!busy || progress)
                watchdog <= {TIMEOUT_WIDTH{1'b0}};
            else
                watchdog <= watchdog + 1'b1;

            if (busy && (&watchdog)) begin
                busy <= 1'b0;
                done <= 1'b1;
                pass <= 1'b0;
                fail <= 1'b1;
                if (error_count == 0) begin
                    error_count      <= 32'd1;
                    first_error_addr <= test_addr;
                end
                state <= S_DONE;
            end else begin
                case (state)
                    S_IDLE: if (start) begin
                        index            <= {IDX_W{1'b0}};
                        busy             <= 1'b1;
                        done             <= 1'b0;
                        pass             <= 1'b0;
                        fail             <= 1'b0;
                        error_count      <= 32'd0;
                        first_error_addr <= {AXI_ADDR_WIDTH{1'b0}};
                        state            <= S_WA;
                    end

                    S_WA: if (m_axi_awready)
                        state <= S_WD;

                    S_WD: if (m_axi_wready)
                        state <= S_WB;

                    S_WB: if (m_axi_bvalid) begin
                        if (m_axi_bresp != 2'b00) begin
                            if (error_count == 0)
                                first_error_addr <= test_addr;
                            error_count <= error_count + 1'b1;
                            fail        <= 1'b1;
                        end
                        if (index == TEST_BEATS-1) begin
                            index <= {IDX_W{1'b0}};
                            state <= S_RA;
                        end else begin
                            index <= index + 1'b1;
                            state <= S_WA;
                        end
                    end

                    S_RA: if (m_axi_arready)
                        state <= S_RD;

                    S_RD: if (m_axi_rvalid) begin
                        if ((m_axi_rresp != 2'b00) || !m_axi_rlast ||
                            (m_axi_rdata !== test_pattern(index))) begin
                            if (error_count == 0)
                                first_error_addr <= test_addr;
                            error_count <= error_count + 1'b1;
                            fail        <= 1'b1;
                        end
                        if (index == TEST_BEATS-1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            pass  <= !fail && (error_count == 0) &&
                                     (m_axi_rresp == 2'b00) && m_axi_rlast &&
                                     (m_axi_rdata === test_pattern(index));
                            state <= S_DONE;
                        end else begin
                            index <= index + 1'b1;
                            state <= S_RA;
                        end
                    end

                    S_DONE: state <= S_DONE;
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
