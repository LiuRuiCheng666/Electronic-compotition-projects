`timescale 1ns/1ps
`default_nettype none

// Read a packed neural-network weight image from the board configuration
// SPI flash and copy the payload to DDR through single-beat AXI writes.
//
// Flash image (all 32-bit fields little endian):
//   0x00  "NNW1"
//   0x04  format version (1)
//   0x08  payload byte count
//   0x0c  CRC32 of payload
//   0x10..0x1f reserved
//   0x20  packed weight payload
//
// The SPI reader uses command 0x03 and mode 0.  SCLK therefore remains low
// while idle, MOSI changes on falling edges and MISO is sampled on rising
// edges.  SPI_CLK_DIV is the number of system-clock cycles per half SCLK.
module spi_flash_weight_loader #(
    parameter integer AXI_ID_WIDTH   = 4,
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer AXI_DATA_WIDTH = 128,
    parameter [23:0] FLASH_BASE_ADDR = 24'h40_0000,
    parameter integer RUNTIME_FLASH_ADDR = 0,
    parameter [AXI_ADDR_WIDTH-1:0] DDR_BASE_ADDR = 32'h0180_0000,
    parameter integer PAYLOAD_BYTES  = 98304,
    parameter integer HEADER_BYTES   = 32,
    parameter integer SPI_CLK_DIV    = 4,
    parameter integer WAKE_WAIT_CYCLES = 20000,
    parameter integer TIMEOUT_WIDTH  = 28
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input wire [23:0] runtime_flash_addr,

    output reg  busy,
    output reg  done,
    output reg  pass,
    output reg  fail,
    output reg  [2:0] fault_code,
    output reg  [2:0] debug_phase,

    output reg  flash_sclk,
    output reg  flash_mosi,
    input  wire flash_miso,
    output reg  flash_cs_n,

    output wire [AXI_ID_WIDTH-1:0]     m_axi_awid,
    output reg  [AXI_ADDR_WIDTH-1:0]   m_axi_awaddr,
    output wire [7:0]                  m_axi_awlen,
    output wire [2:0]                  m_axi_awsize,
    output wire [1:0]                  m_axi_awburst,
    output wire                        m_axi_awlock,
    output wire [3:0]                  m_axi_awcache,
    output wire [2:0]                  m_axi_awprot,
    output reg                         m_axi_awvalid,
    input  wire                        m_axi_awready,
    output reg  [AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output wire                        m_axi_wlast,
    output reg                         m_axi_wvalid,
    input  wire                        m_axi_wready,
    input  wire [AXI_ID_WIDTH-1:0]     m_axi_bid,
    input  wire [1:0]                  m_axi_bresp,
    input  wire                        m_axi_bvalid,
    output reg                         m_axi_bready
);
    localparam integer AXI_BYTES = AXI_DATA_WIDTH / 8;
    localparam integer AXI_SIZE  = $clog2(AXI_BYTES);
    localparam integer DIV_W = (SPI_CLK_DIV <= 1) ? 1 : $clog2(SPI_CLK_DIV);
    localparam [7:0] READ_COMMAND = 8'h03, WAKE_COMMAND=8'hAB;
    reg [15:0] wake_wait;

    localparam [3:0] S_IDLE   = 4'd0,
                     S_CMD    = 4'd1,
                     S_ADDR   = 4'd2,
                     S_HEADER = 4'd3,
                     S_DATA   = 4'd4,
                     S_AW     = 4'd5,
                     S_W      = 4'd6,
                     S_B      = 4'd7,
                     S_CHECK  = 4'd8,
                     S_DONE   = 4'd9, S_WAKE=4'd10, S_WAKE_WAIT=4'd11, S_SETTLE=4'd12;

    reg [3:0] state;
    // Freeze the last active phase before the fault moves state to S_DONE.
    // 1:SPI, 2:AW, 3:W, 4:B, 5:CRC/header check.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) debug_phase <= 0;
        else if (!fail && state != S_DONE) begin
            case (state)
                S_CMD,S_ADDR,S_HEADER,S_DATA,S_WAKE,S_WAKE_WAIT,S_SETTLE: debug_phase <= 1;
                S_AW: debug_phase <= 2;
                S_W: debug_phase <= 3;
                S_B: debug_phase <= 4;
                S_CHECK: debug_phase <= 5;
                default: debug_phase <= 0;
            endcase
        end
    end
    reg [DIV_W-1:0] div_count;
    reg [5:0] tx_bit_count;
    reg [23:0] flash_addr_latched;
    reg [7:0] rx_shift;
    reg [5:0] header_index;
    // Check constant header fields as bytes arrive, rather than retaining
    // three 32-bit words only to compare them once at the end of the header.
    reg header_bad;
    localparam [31:0] EXPECTED_LENGTH=PAYLOAD_BYTES;
    reg [7:0] expected_header_byte;
    always @* begin
        case(header_index)
            0,1:expected_header_byte=8'h4e;
            2:expected_header_byte=8'h57;
            3:expected_header_byte=8'h31;
            4:expected_header_byte=8'h01;
            8:expected_header_byte=EXPECTED_LENGTH[7:0];
            9:expected_header_byte=EXPECTED_LENGTH[15:8];
            10:expected_header_byte=EXPECTED_LENGTH[23:16];
            11:expected_header_byte=EXPECTED_LENGTH[31:24];
            default:expected_header_byte=0;
        endcase
    end
    reg [31:0] header_crc;
    reg [31:0] payload_index;
    reg [7:0] beat_byte_index;
    reg [31:0] crc_reg;
    reg [TIMEOUT_WIDTH-1:0] watchdog;

    wire spi_tick = (div_count == SPI_CLK_DIV-1);
    wire [7:0] rx_byte = {rx_shift[6:0], flash_miso};
    wire [31:0] payload_crc_final = ~crc_reg;

    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0] data;
        integer b;
        reg [31:0] c;
        begin
            c = crc_in ^ data;
            for (b = 0; b < 8; b = b + 1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
            crc32_byte = c;
        end
    endfunction

    assign m_axi_awid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = AXI_SIZE[2:0];
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'd3;
    assign m_axi_awprot  = 3'd2;
    assign m_axi_wstrb   = {AXI_BYTES{1'b1}};
    assign m_axi_wlast   = 1'b1;

    wire progress = spi_tick ||
                    (m_axi_awvalid && m_axi_awready) ||
                    (m_axi_wvalid && m_axi_wready) ||
                    (m_axi_bvalid && m_axi_bready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            wake_wait<=0;
            busy           <= 1'b0;
            done           <= 1'b0;
            pass           <= 1'b0;
            fail           <= 1'b0;
            fault_code     <= 3'd0;
            flash_sclk     <= 1'b0;
            flash_mosi     <= 1'b0;
            flash_cs_n     <= 1'b1;
            div_count      <= {DIV_W{1'b0}};
            tx_bit_count   <= 6'd0;
            flash_addr_latched <= FLASH_BASE_ADDR;
            rx_shift       <= 8'd0;
            header_index   <= 6'd0;
            header_bad     <= 1'b0;
            header_crc     <= 32'd0;
            payload_index  <= 32'd0;
            beat_byte_index <= 8'd0;
            crc_reg        <= 32'hFFFF_FFFF;
            watchdog       <= {TIMEOUT_WIDTH{1'b0}};
            m_axi_awaddr   <= DDR_BASE_ADDR;
            m_axi_awvalid  <= 1'b0;
            m_axi_wdata    <= {AXI_DATA_WIDTH{1'b0}};
            m_axi_wvalid   <= 1'b0;
            m_axi_bready   <= 1'b0;
        end else begin
            done <= 1'b0;
            if (progress)
                watchdog <= {TIMEOUT_WIDTH{1'b0}};
            else if (busy)
                watchdog <= watchdog + 1'b1;

            if (busy && &watchdog) begin
                busy       <= 1'b0;
                fail       <= 1'b1;
                fault_code <= 3'd1;
                flash_cs_n <= 1'b1;
                flash_sclk <= 1'b0;
                state      <= S_DONE;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (start) begin
                            flash_addr_latched <= RUNTIME_FLASH_ADDR ? runtime_flash_addr : FLASH_BASE_ADDR;
                            busy            <= 1'b1;
                            pass            <= 1'b0;
                            fail            <= 1'b0;
                            fault_code      <= 3'd0;
                            flash_cs_n      <= 1'b1;
                            wake_wait       <= 0;
                            flash_sclk      <= 1'b0;
                            flash_mosi      <= 1'b0; // command bit 7 of 0x03
                            div_count       <= {DIV_W{1'b0}};
                            tx_bit_count    <= 6'd0;
                            header_index    <= 6'd0;
                            header_bad      <= 1'b0;
                            payload_index   <= 32'd0;
                            beat_byte_index <= 8'd0;
                            crc_reg         <= 32'hFFFF_FFFF;
                            m_axi_awaddr    <= DDR_BASE_ADDR;
                            state           <= S_SETTLE;
                        end
                    end

                    // Start with CS high to allow configuration-port handover.
                    // AB is non-destructive release from deep power-down.
                    S_SETTLE:begin
                        if(wake_wait==WAKE_WAIT_CYCLES-1)begin
                            wake_wait<=0;flash_cs_n<=0;flash_mosi<=WAKE_COMMAND[7];
                            div_count<=0;tx_bit_count<=0;state<=S_WAKE;
                        end else wake_wait<=wake_wait+1'b1;
                    end
                    S_WAKE:if(spi_tick)begin
                        div_count<=0;
                        if(!flash_sclk)flash_sclk<=1;
                        else begin
                            flash_sclk<=0;
                            if(tx_bit_count==7)begin
                                flash_cs_n<=1;wake_wait<=0;state<=S_WAKE_WAIT;
                            end else begin
                                tx_bit_count<=tx_bit_count+1'b1;flash_mosi<=WAKE_COMMAND[6-tx_bit_count];
                            end
                        end
                    end else div_count<=div_count+1'b1;
                    S_WAKE_WAIT:begin
                        if(wake_wait==WAKE_WAIT_CYCLES-1)begin
                            flash_cs_n<=0;flash_mosi<=READ_COMMAND[7];
                            div_count<=0;tx_bit_count<=0;state<=S_CMD;
                        end else wake_wait<=wake_wait+1'b1;
                    end
                    // Send 0x03, MSB first.  The first bit is placed on MOSI
                    // when entering S_CMD; every complete SCLK advances it.
                    S_CMD: if (spi_tick) begin
                        div_count <= {DIV_W{1'b0}};
                        if (!flash_sclk) begin
                            flash_sclk <= 1'b1;
                        end else begin
                            flash_sclk <= 1'b0;
                            if (tx_bit_count == 6'd7) begin
                                tx_bit_count <= 6'd0;
                                flash_mosi <= flash_addr_latched[23];
                                state <= S_ADDR;
                            end else begin
                                tx_bit_count <= tx_bit_count + 1'b1;
                                flash_mosi <= READ_COMMAND[6-tx_bit_count];
                            end
                        end
                    end else div_count <= div_count + 1'b1;

                    S_ADDR: if (spi_tick) begin
                        div_count <= {DIV_W{1'b0}};
                        if (!flash_sclk) begin
                            flash_sclk <= 1'b1;
                        end else begin
                            flash_sclk <= 1'b0;
                            if (tx_bit_count == 6'd23) begin
                                tx_bit_count <= 6'd0;
                                flash_mosi <= 1'b0;
                                state <= S_HEADER;
                            end else begin
                                tx_bit_count <= tx_bit_count + 1'b1;
                                flash_mosi <= flash_addr_latched[22-tx_bit_count];
                            end
                        end
                    end else div_count <= div_count + 1'b1;

                    S_HEADER: if (spi_tick) begin
                        div_count <= {DIV_W{1'b0}};
                        if (!flash_sclk) begin
                            flash_sclk <= 1'b1;
                            rx_shift <= rx_byte;
                        end else begin
                            flash_sclk <= 1'b0;
                            if (tx_bit_count == 6'd7) begin
                                tx_bit_count <= 6'd0;
                                if(header_index<12 && rx_shift!=expected_header_byte)header_bad<=1'b1;
                                case (header_index)
                                    12:header_crc[7:0]      <= rx_shift;
                                    13:header_crc[15:8]     <= rx_shift;
                                    14:header_crc[23:16]    <= rx_shift;
                                    15:header_crc[31:24]    <= rx_shift;
                                    default: ;
                                endcase
                                if (header_index == HEADER_BYTES-1) begin
                                    if (header_bad) begin
                                        busy       <= 1'b0;
                                        fail       <= 1'b1;
                                        fault_code <= 3'd2;
                                        flash_cs_n <= 1'b1;
                                        state      <= S_DONE;
                                    end else begin
                                        state <= S_DATA;
                                    end
                                end else header_index <= header_index + 1'b1;
                            end else tx_bit_count <= tx_bit_count + 1'b1;
                        end
                    end else div_count <= div_count + 1'b1;

                    S_DATA: if (spi_tick) begin
                        div_count <= {DIV_W{1'b0}};
                        if (!flash_sclk) begin
                            flash_sclk <= 1'b1;
                            rx_shift <= rx_byte;
                        end else begin
                            flash_sclk <= 1'b0;
                            if (tx_bit_count == 6'd7) begin
                                tx_bit_count <= 6'd0;
                                m_axi_wdata[beat_byte_index*8 +: 8] <= rx_shift;
                                crc_reg <= crc32_byte(crc_reg, rx_shift);
                                payload_index <= payload_index + 1'b1;
                                if (beat_byte_index == AXI_BYTES-1) begin
                                    beat_byte_index <= 8'd0;
                                    state <= S_AW;
                                end else beat_byte_index <= beat_byte_index + 1'b1;
                            end else tx_bit_count <= tx_bit_count + 1'b1;
                        end
                    end else div_count <= div_count + 1'b1;

                    S_AW: begin
                        m_axi_awvalid <= 1'b1;
                        if (m_axi_awvalid && m_axi_awready) begin
                            m_axi_awvalid <= 1'b0;
                            state <= S_W;
                        end
                    end
                    S_W: begin
                        m_axi_wvalid <= 1'b1;
                        if (m_axi_wvalid && m_axi_wready) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_bready <= 1'b1;
                            state <= S_B;
                        end
                    end
                    S_B: if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        if (m_axi_bresp != 2'b00) begin
                            busy       <= 1'b0;
                            fail       <= 1'b1;
                            fault_code <= 3'd3;
                            flash_cs_n <= 1'b1;
                            state      <= S_DONE;
                        end else if (payload_index == PAYLOAD_BYTES) begin
                            flash_cs_n <= 1'b1;
                            flash_sclk <= 1'b0;
                            state <= S_CHECK;
                        end else begin
                            m_axi_awaddr <= m_axi_awaddr + AXI_BYTES;
                            state <= S_DATA;
                        end
                    end
                    S_CHECK: begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        if (payload_crc_final == header_crc) begin
                            pass <= 1'b1;
                        end else begin
                            fail       <= 1'b1;
                            fault_code <= 3'd4;
                        end
                        state <= S_DONE;
                    end
                    S_DONE: begin
                        // Keep completion asserted so the AXI owner mux never
                        // hands the port back to this one-shot boot loader.
                        done  <= 1'b1;
                        state <= S_DONE;
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
