`timescale 1ns/1ps
`default_nettype none

// Board-level end-to-end test:
//   input ROM -> DDR bank 0 -> net_top -> DDR bank 0 -> CRC32 checker.
// The module owns the controller AXI port during preload and verification and
// gives it to net_top only while inference is running.
module nn_ddr_selftest #(
    parameter integer USE_EXTERNAL_DDR_OUTPUT = 0,
    parameter integer BYPASS_VERIFIED_INPUT = 0,
    parameter integer USE_EXTERNAL_DDR_INPUT = 0,
    parameter integer A4_MODE = 0,
    parameter integer A4_COMPACT_WRITES = 0,
    parameter integer A4_DEEP_ROW = A4_MODE,
    parameter integer RUNTIME_MODEL = 0,
    parameter integer AXI_ID_WIDTH   = 4,
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer AXI_DATA_WIDTH = 128,
    parameter [AXI_ADDR_WIDTH-1:0] FRAME_BASE_ADDR = 32'h0100_0000,
    parameter integer BANK_ADDR_SHIFT = 20,
    parameter integer NETWORK_LAYERS = 20,
    parameter integer IMAGE_SCALE = 1,
    parameter integer IMAGE_HEIGHT_SCALE = IMAGE_SCALE,
    parameter integer FRAME_ADDR_BITS = 15,
    parameter integer CAMERA_ADDR_WIDTH = 10,
    parameter integer INPUT_PRELOAD_ONLY = 0,
    parameter integer PRELOAD_DDR_INPUT = 1,
    parameter integer USE_CAMERA_INPUT = 0,
    // Diagnostic completion check only; no final-output CRC comparison.
    parameter integer INFERENCE_COMPLETION_ONLY = 0,
    parameter integer VERIFY_OUTPUT_REPEAT = 0,
    parameter integer ENABLE_OUTPUT_PREVIEW = 0,
    // Live camera output has no fixed golden CRC. AXI faults remain checked.
    parameter integer CHECK_OUTPUT_CRC = 1,
    // Enable only after the packed weight image has been loaded at
    // WEIGHT_BASE_ADDR in DDR; this self-test currently preloads input only.
    parameter integer USE_DDR_WEIGHTS = 0,
    // Set to zero when an external loader has already copied the packed
    // weight image to WEIGHT_BASE_ADDR.  This removes the large temporary
    // on-chip weight ROM while retaining the proven self-test sequence.
    parameter integer PRELOAD_DDR_WEIGHTS = 1,
    parameter [AXI_ADDR_WIDTH-1:0] WEIGHT_BASE_ADDR = 32'h0180_0000,
    parameter integer WEIGHT_WORDS = 3072,
    parameter WEIGHT_MEM_FILE = "net_w3072.mem",
    parameter integer DEBUG_WRITE_ACC_S = 0,
    parameter integer DEBUG_CHECK_LAYER0_STATS = 0,
    parameter integer DEBUG_CHECK_LAYER0_WEIGHTS = 0,
    parameter integer DEBUG_CHECK_LAYER0_PIXEL0 = 0,
    parameter integer DEBUG_CHECK_LAYER0_MAC = 0,
    parameter integer DEBUG_CHECK_LAYER0_MAC_INPUTS = 0,
    parameter integer OUTPUT_BANK = 0,
    parameter integer INPUT_BEATS  = 192, // 32*24*4 / 16
    parameter integer OUTPUT_BEATS = 144, // 32*24*3 / 16
    parameter [31:0] INPUT_CRC32    = 32'hFD64_7557,
    parameter [31:0] EXPECTED_CRC32 = 32'hC5B9_A402,
    parameter integer RUNTIME_CRC = 0,
    parameter INPUT_MEM_FILE = "net_in32.mem",
    parameter integer A4_PACKET_WORDS = 16,
    parameter integer A4_RETURN_ADVANCE = 0,
    parameter integer A4_REQUEST_TRACK = 0,
    parameter integer A4_READ_INPUT_PIPE = 0,
    parameter integer A4_WRITE_INPUT_PIPE = 0,
    parameter integer A4_PARALLEL_CACHE_READ = 0,
    parameter integer A4_REGISTERED_FLUSH = 0,
    parameter integer A4_PACKET_INPUT_PIPE = 0,
    parameter integer A4_WRITE_QUEUE_BRAM = 0,
    parameter integer A4_PIPELINED_MASK = 0,
    parameter integer A4_ROW_PCO = 2,
    parameter integer A4_FAST_MASK_SEAL = 0,
    parameter integer TIMEOUT_WIDTH = 28
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input wire [2:0] runtime_model,
    input wire cfg_we,cfg_tanh,
    input wire [7:0] cfg_index,
    input wire [63:0] cfg_data,
    input  wire ddr_cal_done,
    input wire [31:0] runtime_input_crc32,runtime_output_crc32,
    input wire [AXI_ADDR_WIDTH-1:0] runtime_input_ddr_base,runtime_output_ddr_base,
    input wire runtime_input_verified,
    output wire [CAMERA_ADDR_WIDTH-1:0] camera_read_addr,
    input wire [31:0] camera_read_data,

    output reg  busy,
    output reg  done,
    output reg  pass,
    output reg [31:0] output_crc32,
    output reg [31:0] output_nonzero_bytes,
    output reg [7:0] output_byte_min,
    output reg [7:0] output_byte_max,
    output wire preview_byte_valid,
    output wire [7:0] preview_byte_data,
    output reg  fail,
    output reg  [31:0] error_count,
    // 0:none, 1:timeout, 2:preload write response,
    // 3:net diagnostic, 4:net DDR/AXI or verify-read response fault,
    // 5:output CRC mismatch,
    // 6:preloaded input CRC mismatch, 7:layer-0 S1/S2 mismatch.
    output reg  [2:0] fault_code,
    output reg  [2:0] debug_phase,
    output reg debug_timeout,
    output wire profile_compute_active,profile_memory_wait,

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
    localparam integer IDX_W = (INPUT_BEATS > OUTPUT_BEATS) ?
                               $clog2(INPUT_BEATS) : $clog2(OUTPUT_BEATS);

    localparam integer INPUT_WORDS = INPUT_BEATS * 4;
    localparam integer ROM_AW = $clog2(INPUT_WORDS);

    localparam [4:0] S_IDLE    = 4'd0,  S_P_PRIME = 4'd1,
                     S_P_FILL  = 4'd2,  S_P_WA    = 4'd3,
                     S_P_WD    = 4'd4,  S_P_WB    = 4'd5,
                     S_NSTART  = 4'd6,  S_NWAIT   = 4'd7,
                     S_V_RA    = 4'd8,  S_V_RD    = 4'd9,
                     S_V_CRC   = 4'd10, S_DONE    = 4'd11,
                     S_W_PRIME = 4'd12, S_W_WA    = 4'd13,
                     S_W_WD    = 4'd14, S_W_WB    = 4'd15,
                     S_INPUT_CRC = 5'd16;
    wire skip_input_check=(BYPASS_VERIFIED_INPUT!=0) && runtime_input_verified;
    reg [4:0] state;
    reg [IDX_W-1:0] beat_index;
    reg [31:0] crc_reg;
    reg [127:0] verify_data;
    reg [3:0] crc_byte_index;
    reg verify_resp_bad;
    reg verify_input;
    reg output_second_pass;
    // Reuse the first verification pass; no additional DDR transactions.
    assign preview_byte_valid = (ENABLE_OUTPUT_PREVIEW != 0) &&
        (state == S_V_CRC) && !verify_input && !output_second_pass;
    reg [TIMEOUT_WIDTH-1:0] watchdog;
    reg [ROM_AW-1:0] rom_addr;
    reg [1:0] rom_word_index;
    localparam integer WEIGHT_AW = $clog2(WEIGHT_WORDS);
    reg [WEIGHT_AW-1:0] weight_rom_addr;
    reg [WEIGHT_AW-1:0] weight_word_index;
    reg weight_half;

    // Keep the preload image in a narrow ROM.  A 192x128 declaration wastes
    // six physical RAM blocks on this device because of the wide read port;
    // 768x32 stores the same 24 Kbit efficiently.  Four ROM words are
    // assembled before issuing each 128-bit AXI write.
    wire [31:0] rom_q;
    reg [AXI_DATA_WIDTH-1:0] input_beat;
    assign camera_read_addr = rom_addr;
    generate if (USE_CAMERA_INPUT != 0) begin : g_camera_input
        assign rom_q = camera_read_data;
    end else if (PRELOAD_DDR_INPUT != 0) begin : g_fixed_input
        (* syn_ramstyle = "block_ram" *) reg [31:0] input_rom [0:INPUT_WORDS-1];
        reg [31:0] rom_q_reg;
        initial $readmemh(INPUT_MEM_FILE, input_rom);
        always @(posedge clk) rom_q_reg <= input_rom[rom_addr];
        assign rom_q = rom_q_reg;
    end else begin : g_external_input
        assign rom_q = 32'd0;
    end endgenerate
    reg [31:0] captured_crc;
    reg [3:0] input_crc_byte;
    wire [31:0] expected_input_crc = (USE_CAMERA_INPUT != 0) ?
        (captured_crc ^ 32'hFFFFFFFF) : (RUNTIME_CRC ? runtime_input_crc32 : INPUT_CRC32);

    // Temporary board-validation source.  In DDR-weight mode this ROM is
    // copied once to external DDR before inference.  It is intentionally kept
    // only until a flash/host boot loader replaces the preload path.
    wire [255:0] weight_rom_q;
    generate
        if (PRELOAD_DDR_WEIGHTS != 0) begin : G_WEIGHT_PRELOAD_ROM
            (* syn_ramstyle = "block_ram" *) reg [255:0] weight_rom [0:WEIGHT_WORDS-1];
            reg [255:0] weight_rom_q_reg;
            initial $readmemh(WEIGHT_MEM_FILE, weight_rom);
            always @(posedge clk)
                weight_rom_q_reg <= weight_rom[weight_rom_addr];
            assign weight_rom_q = weight_rom_q_reg;
        end else begin : G_NO_WEIGHT_PRELOAD_ROM
            assign weight_rom_q = 256'd0;
        end
    endgenerate

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

    // One byte per cycle keeps the CRC checker off the 100 MHz critical path.
    wire [7:0] crc_data_byte = verify_data[crc_byte_index*8 +: 8];
    assign preview_byte_data = crc_data_byte;
    wire [31:0] crc_after_byte = crc32_byte(crc_reg, crc_data_byte);
    wire [AXI_ADDR_WIDTH-1:0] beat_ext =
        {{(AXI_ADDR_WIDTH-IDX_W){1'b0}}, beat_index};
    wire input_preload_owner =
                         (state == S_P_PRIME) || (state == S_P_FILL) ||
                         (state == S_P_WA) || (state == S_P_WD) ||
                         (state == S_P_WB) || (state == S_INPUT_CRC);
    wire weight_preload_owner =
                         (state == S_W_PRIME) || (state == S_W_WA) ||
                         (state == S_W_WD) || (state == S_W_WB);
    wire preload_owner = input_preload_owner || weight_preload_owner;
    wire verify_owner  = (state == S_V_RA) || (state == S_V_RD) ||
                         (state == S_V_CRC);
    wire local_owner   = preload_owner || verify_owner;
    reg net_write_pending;
    // Preserve NN ownership through every accepted AW -> B transaction.
    // Backend is serialized; a split write starts its next AW only after B.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) net_write_pending <= 1'b0;
        else if (!local_owner) begin
            if (m_axi_awvalid && m_axi_awready) net_write_pending <= 1'b1;
            if (m_axi_bvalid && m_axi_bready) net_write_pending <= 1'b0;
        end
    end
    wire [AXI_ADDR_WIDTH-1:0] output_bank_offset =
        OUTPUT_BANK << BANK_ADDR_SHIFT;
    wire [AXI_ADDR_WIDTH-1:0] local_bank_offset =
        (verify_owner && !verify_input) ? output_bank_offset :
                                          {AXI_ADDR_WIDTH{1'b0}};
    wire [AXI_ADDR_WIDTH-1:0] weight_word_ext = weight_word_index;
    wire [AXI_ADDR_WIDTH-1:0] weight_preload_addr =
        WEIGHT_BASE_ADDR + (weight_word_ext << 5) +
        (weight_half ? AXI_BYTES : 0);
    wire [AXI_ADDR_WIDTH-1:0] frame_local_addr =
        ((USE_EXTERNAL_DDR_INPUT!=0 && verify_owner && verify_input) ? runtime_input_ddr_base : ((USE_EXTERNAL_DDR_OUTPUT!=0 && verify_owner && !verify_input) ? runtime_output_ddr_base : FRAME_BASE_ADDR)) + local_bank_offset + (beat_ext << AXI_SIZE_I);
    wire [AXI_ADDR_WIDTH-1:0] local_addr =
        weight_preload_owner ? weight_preload_addr : frame_local_addr;
    wire [AXI_DATA_WIDTH-1:0] local_write_data =
        weight_preload_owner ?
        (weight_half ? weight_rom_q[255:128] : weight_rom_q[127:0]) :
        input_beat;

    wire net_done, net_busy, net_fault;
    wire [2:0] net_diagnostic_code;
    wire net_start = (state == S_NSTART);
    wire [AXI_ID_WIDTH-1:0] n_awid, n_arid;
    wire [AXI_ADDR_WIDTH-1:0] n_awaddr, n_araddr;
    wire [7:0] n_awlen, n_arlen;
    wire [2:0] n_awsize, n_ar_size;
    wire [1:0] n_awburst, n_arburst;
    wire n_awlock, n_arlock;
    wire [3:0] n_awcache, n_arcache;
    wire [2:0] n_awprot, n_arprot;
    wire [3:0] n_awqos, n_arqos;
    wire n_awvalid, n_wlast, n_wvalid, n_bready;
    wire [AXI_DATA_WIDTH-1:0] n_wdata;
    wire [AXI_DATA_WIDTH/8-1:0] n_wstrb;
    wire n_arvalid, n_rready;

    // Eliminate the inference hardware explicitly in the input-only diagnostic.
    // The normal build still instantiates the original net_top unchanged.
    generate if (INPUT_PRELOAD_ONLY == 0) begin : g_inference
    net_top #(
        // Fixed A4 layers have at most 8 input channels: the exact signed
        // convolution bound is 8*9*128*128=1179648, within signed 22 bits.
        // Keep the legacy 32-bit diagnostic accumulator output unchanged.
        .ACC_W((A4_MODE!=0 && DEBUG_WRITE_ACC_S==0)?22:32),
        .USE_EXTERNAL_DDR_INPUT(USE_EXTERNAL_DDR_INPUT), .USE_EXTERNAL_DDR_OUTPUT(USE_EXTERNAL_DDR_OUTPUT),
        .A4_COMPACT_WRITES(A4_COMPACT_WRITES),.A4_MODE(A4_MODE),.RUNTIME_MODEL(RUNTIME_MODEL),.A4_DEEP_ROW(A4_DEEP_ROW),
        .A4_RETURN_ADVANCE(A4_RETURN_ADVANCE),.A4_REQUEST_TRACK(A4_REQUEST_TRACK),.A4_READ_INPUT_PIPE(A4_READ_INPUT_PIPE),.A4_WRITE_INPUT_PIPE(A4_WRITE_INPUT_PIPE),.A4_PARALLEL_CACHE_READ(A4_PARALLEL_CACHE_READ),.A4_REGISTERED_FLUSH(A4_REGISTERED_FLUSH),.A4_PACKET_INPUT_PIPE(A4_PACKET_INPUT_PIPE),.A4_WRITE_QUEUE_BRAM(A4_WRITE_QUEUE_BRAM),.A4_PIPELINED_MASK(A4_PIPELINED_MASK),.A4_PACKET_WORDS(A4_PACKET_WORDS),.A4_ROW_PCO(A4_ROW_PCO),.A4_FAST_MASK_SEAL(A4_FAST_MASK_SEAL),
        .NL(NETWORK_LAYERS),
        .DEBUG_WRITE_ACC_S(DEBUG_WRITE_ACC_S),
        .DEBUG_CHECK_LAYER0_STATS(DEBUG_CHECK_LAYER0_STATS),
        .DEBUG_CHECK_LAYER0_WEIGHTS(DEBUG_CHECK_LAYER0_WEIGHTS),
        .DEBUG_CHECK_LAYER0_PIXEL0(DEBUG_CHECK_LAYER0_PIXEL0),
        .DEBUG_CHECK_LAYER0_MAC(DEBUG_CHECK_LAYER0_MAC),
        .DEBUG_CHECK_LAYER0_MAC_INPUTS(DEBUG_CHECK_LAYER0_MAC_INPUTS),
        .USE_DDR(1),
        .IMAGE_SCALE(IMAGE_SCALE),.IMAGE_HEIGHT_SCALE(IMAGE_HEIGHT_SCALE),
        .BLOG(FRAME_ADDR_BITS),
        .USE_DDR_WEIGHTS(USE_DDR_WEIGHTS),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .DDR_BASE_ADDR(FRAME_BASE_ADDR),
        .DDR_WEIGHT_BASE_ADDR(WEIGHT_BASE_ADDR),
        .DDR_BANK_ADDR_SHIFT(BANK_ADDR_SHIFT)
    ) u_net_top (
        .clk(clk), .rst_n(rst_n), .start(net_start),
        .runtime_model(runtime_model),.cfg_we(cfg_we),.cfg_tanh(cfg_tanh),.cfg_index(cfg_index),.cfg_data(cfg_data),
        .input_ddr_base(runtime_input_ddr_base), .output_ddr_base(runtime_output_ddr_base),
        .done(net_done), .busy(net_busy),
        .profile_compute_active(profile_compute_active),.profile_memory_wait(profile_memory_wait),
        .dbg_bank(2'd0), .dbg_addr({FRAME_ADDR_BITS{1'b0}}), .dbg_data(),
        .ddr_cal_done(ddr_cal_done), .ddr_fault(net_fault),
        .diagnostic_code(net_diagnostic_code),
        .m_axi_awid(n_awid), .m_axi_awaddr(n_awaddr),
        .m_axi_awlen(n_awlen), .m_axi_awsize(n_awsize),
        .m_axi_awburst(n_awburst), .m_axi_awlock(n_awlock),
        .m_axi_awcache(n_awcache), .m_axi_awprot(n_awprot),
        .m_axi_awqos(n_awqos), .m_axi_awvalid(n_awvalid),
        .m_axi_awready(m_axi_awready), .m_axi_wdata(n_wdata),
        .m_axi_wstrb(n_wstrb), .m_axi_wlast(n_wlast),
        .m_axi_wvalid(n_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(n_bready),
        .m_axi_arid(n_arid), .m_axi_araddr(n_araddr),
        .m_axi_arlen(n_arlen), .m_axi_arsize(n_ar_size),
        .m_axi_arburst(n_arburst), .m_axi_arlock(n_arlock),
        .m_axi_arcache(n_arcache), .m_axi_arprot(n_arprot),
        .m_axi_arqos(n_arqos), .m_axi_arvalid(n_arvalid),
        .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(n_rready)
    );
    end else begin : g_no_inference
        assign net_done = 1'b0;
        assign net_busy = 1'b0;
        assign profile_compute_active=1'b0;assign profile_memory_wait=1'b0;
        assign net_fault = 1'b0;
        assign net_diagnostic_code = 3'd0;
        assign n_awid = {AXI_ID_WIDTH{1'b0}};
        assign n_arid = {AXI_ID_WIDTH{1'b0}};
        assign n_awaddr = {AXI_ADDR_WIDTH{1'b0}};
        assign n_araddr = {AXI_ADDR_WIDTH{1'b0}};
        assign n_awlen = 8'd0;
        assign n_arlen = 8'd0;
        assign n_awsize = AXI_SIZE_I[2:0];
        assign n_ar_size = AXI_SIZE_I[2:0];
        assign n_awburst = 2'b01;
        assign n_arburst = 2'b01;
        assign n_awlock = 1'b0;
        assign n_arlock = 1'b0;
        assign n_awcache = 4'd0;
        assign n_arcache = 4'd0;
        assign n_awprot = 3'd0;
        assign n_arprot = 3'd0;
        assign n_awqos = 4'd0;
        assign n_arqos = 4'd0;
        assign n_awvalid = 1'b0;
        assign n_wvalid = 1'b0;
        assign n_wlast = 1'b0;
        assign n_wdata = {AXI_DATA_WIDTH{1'b0}};
        assign n_wstrb = {AXI_BYTES{1'b0}};
        assign n_bready = 1'b0;
        assign n_arvalid = 1'b0;
        assign n_rready = 1'b0;
    end endgenerate

    assign m_axi_awid    = local_owner ? {AXI_ID_WIDTH{1'b0}} : n_awid;
    assign m_axi_awaddr  = local_owner ? local_addr : n_awaddr;
    assign m_axi_awlen   = local_owner ? 8'd0 : n_awlen;
    assign m_axi_awsize  = local_owner ? AXI_SIZE_I[2:0] : n_awsize;
    assign m_axi_awburst = local_owner ? 2'b01 : n_awburst;
    assign m_axi_awlock  = local_owner ? 1'b0 : n_awlock;
    assign m_axi_awcache = local_owner ? 4'd3 : n_awcache;
    assign m_axi_awprot  = local_owner ? 3'd2 : n_awprot;
    assign m_axi_awvalid = preload_owner &&
                           ((state == S_P_WA) || (state == S_W_WA)) ? 1'b1 :
                           (local_owner ? 1'b0 : n_awvalid);
    assign m_axi_wdata   = local_owner ? local_write_data : n_wdata;
    assign m_axi_wstrb   = local_owner ? {AXI_BYTES{1'b1}} : n_wstrb;
    assign m_axi_wlast   = local_owner ? 1'b1 : n_wlast;
    assign m_axi_wvalid  = preload_owner &&
                           ((state == S_P_WD) || (state == S_W_WD)) ? 1'b1 :
                           (local_owner ? 1'b0 : n_wvalid);
    assign m_axi_bready  = preload_owner &&
                           ((state == S_P_WB) || (state == S_W_WB)) ? 1'b1 :
                           (local_owner ? 1'b0 : n_bready);

    assign m_axi_arid    = local_owner ? {AXI_ID_WIDTH{1'b0}} : n_arid;
    assign m_axi_araddr  = local_owner ? local_addr : n_araddr;
    assign m_axi_arlen   = local_owner ? 8'd0 : n_arlen;
    assign m_axi_arsize  = local_owner ? AXI_SIZE_I[2:0] : n_ar_size;
    assign m_axi_arburst = local_owner ? 2'b01 : n_arburst;
    assign m_axi_arlock  = local_owner ? 1'b0 : n_arlock;
    assign m_axi_arcache = local_owner ? 4'd3 : n_arcache;
    assign m_axi_arprot  = local_owner ? 3'd2 : n_arprot;
    assign m_axi_arvalid = verify_owner && (state == S_V_RA) ? 1'b1 :
                           (local_owner ? 1'b0 : n_arvalid);
    assign m_axi_rready  = verify_owner && (state == S_V_RD) ? 1'b1 :
                           (local_owner ? 1'b0 : n_rready);

    wire progress = (m_axi_awvalid && m_axi_awready) ||
                    (m_axi_wvalid  && m_axi_wready)  ||
                    (m_axi_bvalid  && m_axi_bready)  ||
                    (m_axi_arvalid && m_axi_arready) ||
                    (m_axi_rvalid  && m_axi_rready)  || net_done;

    // Diagnostic only: retain the phase at the first failure, including timeout.
    // 1:preload, 2:input CRC, 3:NN AR, 4:NN R, 5:NN write,
    // 6:NN internal compute/drain, 7:output CRC readback.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin debug_phase <= 0; debug_timeout <= 0; end
        else if (!fail && state != S_DONE) begin
            if (busy && (&watchdog)) debug_timeout <= 1;
            if (state == S_NWAIT)
                debug_phase <= (n_awvalid || n_wvalid || n_bready) ? 3'd5 :
                               n_arvalid ? 3'd3 : n_rready ? 3'd4 : 3'd6;
            else if (state == S_NSTART) debug_phase <= 6;
            else if (state == S_V_RA || state == S_V_RD || state == S_V_CRC)
                debug_phase <= verify_input ? 3'd2 : 3'd7;
            else if (state == S_INPUT_CRC) debug_phase <= 2;
            else if (state == S_IDLE) debug_phase <= 0;
            else debug_phase <= 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            beat_index  <= {IDX_W{1'b0}};
            crc_reg     <= 32'hFFFF_FFFF;
            captured_crc <= 32'hFFFF_FFFF;
            input_crc_byte <= 4'd0;
            verify_data <= 128'd0;
            crc_byte_index <= 4'd0;
            verify_resp_bad <= 1'b0;
            verify_input <= 1'b0;
            output_second_pass <= 1'b0;
            output_crc32 <= 0;
            output_nonzero_bytes <= 0;
            output_byte_min <= 8'hff;
            output_byte_max <= 0;
            watchdog    <= {TIMEOUT_WIDTH{1'b0}};
            rom_addr    <= {ROM_AW{1'b0}};
            rom_word_index <= 2'd0;
            weight_rom_addr <= {WEIGHT_AW{1'b0}};
            weight_word_index <= {WEIGHT_AW{1'b0}};
            weight_half <= 1'b0;
            input_beat  <= {AXI_DATA_WIDTH{1'b0}};
            busy        <= 1'b0;
            done        <= 1'b0;
            pass        <= 1'b0;
            fail        <= 1'b0;
            error_count <= 32'd0;
            fault_code  <= 3'd0;
        end else begin
            if (!busy || progress)
                watchdog <= {TIMEOUT_WIDTH{1'b0}};
            else
                watchdog <= watchdog + 1'b1;

            if (busy && (&watchdog)) begin
                busy        <= 1'b0;
                done        <= 1'b1;
                pass        <= 1'b0;
                fail        <= 1'b1;
                error_count <= error_count + 1'b1;
                if (fault_code == 3'd0)
                    fault_code <= 3'd1;
                state       <= S_DONE;
            end else begin
                case (state)
                    S_IDLE: if (start && ddr_cal_done) begin
                        output_second_pass <= 1'b0;
                        output_crc32 <= 0;
                        output_nonzero_bytes <= 0;
                        output_byte_min <= 8'hff;
                        output_byte_max <= 0;
                        captured_crc <= 32'hFFFF_FFFF;
                        beat_index  <= {IDX_W{1'b0}};
                        busy        <= 1'b1;
                        done        <= 1'b0;
                        pass        <= 1'b0;
                        fail        <= 1'b0;
                        error_count <= 32'd0;
                        fault_code  <= 3'd0;
                        rom_addr    <= {ROM_AW{1'b0}};
                        weight_rom_addr <= {WEIGHT_AW{1'b0}};
                        weight_word_index <= {WEIGHT_AW{1'b0}};
                        weight_half <= 1'b0;
                        verify_input <= 1'b1;
                        crc_reg <= 32'hFFFF_FFFF;
                        state       <= ((USE_DDR_WEIGHTS != 0) &&
                                        (PRELOAD_DDR_WEIGHTS != 0)) ?
                                       S_W_PRIME : ((PRELOAD_DDR_INPUT != 0) ? S_P_PRIME : (skip_input_check ? S_NSTART : S_V_RA));
                    end

                    // Copy the packed 256-bit weight image to DDR as two
                    // 128-bit AXI writes per ROM word.
                    S_W_PRIME: state <= S_W_WA;
                    S_W_WA: if (m_axi_awready) state <= S_W_WD;
                    S_W_WD: if (m_axi_wready)  state <= S_W_WB;
                    S_W_WB: if (m_axi_bvalid) begin
                        if (m_axi_bresp != 2'b00) begin
                            fail        <= 1'b1;
                            error_count <= error_count + 1'b1;
                            if (fault_code == 3'd0)
                                fault_code <= 3'd2;
                        end
                        if (!weight_half) begin
                            weight_half <= 1'b1;
                            state <= S_W_WA;
                        end else if (weight_word_index == WEIGHT_WORDS-1) begin
                            weight_half <= 1'b0;
                            beat_index <= {IDX_W{1'b0}};
                            rom_addr <= {ROM_AW{1'b0}};
                            verify_input <= 1'b1;
                            crc_reg <= 32'hFFFF_FFFF;
                            state <= (PRELOAD_DDR_INPUT != 0) ? S_P_PRIME : (skip_input_check ? S_NSTART : S_V_RA);
                        end else begin
                            weight_half <= 1'b0;
                            weight_word_index <= weight_word_index + 1'b1;
                            weight_rom_addr <= weight_rom_addr + 1'b1;
                            state <= S_W_PRIME;
                        end
                    end

                    // Prime the synchronous ROM, then collect four 32-bit
                    // words.  Word 0 occupies AXI bits [31:0].
                    S_P_PRIME: begin
                        rom_word_index <= 2'd0;
                        rom_addr <= rom_addr + 1'b1;
                        state <= S_P_FILL;
                    end
                    S_P_FILL: begin
                        input_beat[rom_word_index*32 +: 32] <= rom_q;
                        if (rom_word_index == 2'd3) begin
                            input_crc_byte <= 4'd0;
                            state <= (USE_CAMERA_INPUT != 0) ? S_INPUT_CRC : S_P_WA;
                        end else begin
                            rom_word_index <= rom_word_index + 1'b1;
                            rom_addr <= rom_addr + 1'b1;
                        end
                    end

                    S_INPUT_CRC: begin
                        captured_crc <= crc32_byte(captured_crc,
                            input_beat[input_crc_byte*8 +: 8]);
                        if (input_crc_byte == 4'd15) state <= S_P_WA;
                        else input_crc_byte <= input_crc_byte + 1'b1;
                    end
                    S_P_WA: if (m_axi_awready) state <= S_P_WD;
                    S_P_WD: if (m_axi_wready)  state <= S_P_WB;
                    S_P_WB: if (m_axi_bvalid) begin
                        if (m_axi_bresp != 2'b00) begin
                            fail        <= 1'b1;
                            error_count <= error_count + 1'b1;
                            if (fault_code == 3'd0)
                                fault_code <= 3'd2;
                        end
                        if (beat_index == INPUT_BEATS-1) begin
                            beat_index <= {IDX_W{1'b0}};
                            crc_reg    <= 32'hFFFF_FFFF;
                            verify_input <= 1'b1;
                            state      <= S_V_RA;
                        end else begin
                            beat_index <= beat_index + 1'b1;
                            // rom_addr already points at the first word of
                            // the next beat after the four-word fill above.
                            state      <= S_P_PRIME;
                        end
                    end

                    S_NSTART: state <= S_NWAIT;
                    S_NWAIT: begin
                        if (net_diagnostic_code != 3'd0) begin
                            busy        <= 1'b0;
                            done        <= 1'b1;
                            pass        <= 1'b0;
                            fail        <= 1'b1;
                            error_count <= error_count + 1'b1;
                            if (fault_code == 3'd0)
                                fault_code <= net_diagnostic_code;
                            state       <= S_DONE;
                        end else if (net_fault) begin
                            busy        <= 1'b0;
                            done        <= 1'b1;
                            pass        <= 1'b0;
                            fail        <= 1'b1;
                            error_count <= error_count + 1'b1;
                            if (fault_code == 3'd0)
                                fault_code <= 3'd4;
                            state       <= S_DONE;
                        end else if (net_done && !net_write_pending &&
                                     !n_awvalid && !n_wvalid) begin
                            if (INFERENCE_COMPLETION_ONLY != 0) begin
                                busy <= 1'b0;
                                done <= 1'b1;
                                pass <= !fail && (error_count == 0);
                                state <= S_DONE;
                            end else begin
                            beat_index <= {IDX_W{1'b0}};
                            crc_reg    <= 32'hFFFF_FFFF;
                            verify_input <= 1'b0;
                            state      <= S_V_RA;
                            end
                        end
                    end

                    S_V_RA: if (m_axi_arready) state <= S_V_RD;
                    S_V_RD: if (m_axi_rvalid) begin
                        verify_data     <= m_axi_rdata;
                        crc_byte_index  <= 4'd0;
                        verify_resp_bad <= (m_axi_rresp != 2'b00) || !m_axi_rlast;
                        if ((m_axi_rresp != 2'b00) || !m_axi_rlast) begin
                            fail        <= 1'b1;
                            error_count <= error_count + 1'b1;
                            if (fault_code == 3'd0)
                                fault_code <= 3'd4;
                        end
                        state <= S_V_CRC;
                    end

                    S_V_CRC: begin
                        crc_reg <= crc_after_byte;
                        if (!verify_input && !output_second_pass) begin
                            if (crc_data_byte != 0)
                                output_nonzero_bytes <= output_nonzero_bytes + 1'b1;
                            if (crc_data_byte < output_byte_min) output_byte_min <= crc_data_byte;
                            if (crc_data_byte > output_byte_max) output_byte_max <= crc_data_byte;
                        end
                        if (crc_byte_index == 4'd15) begin
                            if (beat_index == (verify_input ? INPUT_BEATS-1 :
                                                              OUTPUT_BEATS-1)) begin
                                if (verify_input) begin
                                    if (!fail && (error_count == 0) &&
                                        !verify_resp_bad &&
                                        ((crc_after_byte ^ 32'hFFFF_FFFF) == expected_input_crc)) begin
                                        beat_index   <= {IDX_W{1'b0}};
                                        verify_input <= 1'b0;
                                        if (INPUT_PRELOAD_ONLY != 0) begin
                                            busy <= 1'b0;
                                            done <= 1'b1;
                                            pass <= 1'b1;
                                            state <= S_DONE;
                                        end else begin
                                            state <= S_NSTART;
                                        end
                                    end else begin
                                        busy <= 1'b0;
                                        done <= 1'b1;
                                        pass <= 1'b0;
                                        fail <= 1'b1;
                                        if ((crc_after_byte ^ 32'hFFFF_FFFF) != expected_input_crc) begin
                                            error_count <= error_count + 1'b1;
                                            if (fault_code == 3'd0)
                                                fault_code <= 3'd6;
                                        end
                                        state <= S_DONE;
                                    end
                                end else if ((VERIFY_OUTPUT_REPEAT != 0) && !output_second_pass) begin
                                    // No NN rerun: read the same frozen output region again.
                                    output_crc32 <= crc_after_byte ^ 32'hFFFF_FFFF;
                                    output_second_pass <= 1'b1;
                                    beat_index <= {IDX_W{1'b0}};
                                    crc_reg <= 32'hFFFF_FFFF;
                                    state <= S_V_RA;
                                end else begin
                                    busy <= 1'b0;
                                    done <= 1'b1;
                                    if (VERIFY_OUTPUT_REPEAT == 0)
                                        output_crc32 <= crc_after_byte ^ 32'hFFFF_FFFF;
                                    if (!fail && (error_count == 0) &&
                                        !verify_resp_bad &&
                                        ((VERIFY_OUTPUT_REPEAT == 0) ||
                                         ((crc_after_byte ^ 32'hFFFF_FFFF) == output_crc32)) &&
                                        ((CHECK_OUTPUT_CRC == 0) ||
                                         ((crc_after_byte ^ 32'hFFFF_FFFF) == (RUNTIME_CRC ? runtime_output_crc32 : EXPECTED_CRC32)))) begin
                                        pass <= 1'b1;
                                    end else begin
                                        pass <= 1'b0;
                                        fail <= 1'b1;
                                        if (((CHECK_OUTPUT_CRC != 0) &&
                                            ((crc_after_byte ^ 32'hFFFF_FFFF) != (RUNTIME_CRC ? runtime_output_crc32 : EXPECTED_CRC32))) ||
                                            ((VERIFY_OUTPUT_REPEAT != 0) &&
                                            ((crc_after_byte ^ 32'hFFFF_FFFF) != output_crc32))) begin
                                            error_count <= error_count + 1'b1;
                                            if (fault_code == 3'd0)
                                                fault_code <= 3'd5;
                                        end
                                    end
                                    state <= S_DONE;
                                end
                            end else begin
                                beat_index <= beat_index + 1'b1;
                                state      <= S_V_RA;
                            end
                        end else begin
                            crc_byte_index <= crc_byte_index + 1'b1;
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
