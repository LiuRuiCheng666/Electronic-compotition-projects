//============================================================================
//  net_top.v -- whole-network integration, STAGE 1 (mini chain)
//----------------------------------------------------------------------------
//  Scope of this version
//    ? conv layers, both normalised (statistics pass + coefficient pass +
//      output pass) and un-normalised (ROM coefficients)
//    ? tanh, residual-add and nearest-neighbour upsample stages
//
//  A4_DEEP_ROW: encoder0 streams directly into independent encoder1
//  line-buffer/MAC/quantization stage; encoder2 onward retains this scheduler.
//  Architecture (route A: layer by layer, external frame store)
//
//    frame store (4 banks, 8 bit/sample, channel-inner: addr = pixel*C + ch)
//        |
//        |  reader: one pixel per cycle; all CING input-channel groups are
//        |          presented IN PARALLEL (one combinational read port per
//        |          group) so the line buffers stay in lockstep
//        v
//    line_buffer x CING -> win_cache -> mac_array -> acc_bank -+-> postproc -> write
//                                                              |      ^
//    weight_mgr <- weight bytes                                |      |
//    acc_reduce_w -> norm_coeff -> coeff_table -----------------+------+
//    conv_fsm drives one layer; the SEQUENCER here drives the layer list.
//
//  Two-pass normalisation
//    A normalised layer streams its input twice: pass 0 gathers S1/S2
//    (acc_reduce_w, which is NOT reset between passes), then the per-channel
//    coefficients are computed into coeff_table, then pass 1 produces the
//    output with postproc reading those coefficients.  A real system reuses
//    the previous frame's statistics; this is the single-frame equivalent.
//
//  Everything is driven by net_vectors/*.mem -- no layer data is hard-coded.
//============================================================================

`timescale 1ns/1ps
`default_nettype none

`ifndef NETV
  `ifdef MINI
    `define NETV "../mini_vectors"
  `else
    `define NETV "../net_vectors"
  `endif
`endif

// number of descriptor rows to execute (the vector set defines how many)
`ifndef NLX
  `define NLX 20
`endif

module net_top #(
    parameter integer USE_EXTERNAL_DDR_OUTPUT = 0,
    parameter integer USE_EXTERNAL_DDR_INPUT = 0,
    parameter integer A4_MODE  = 0,
    parameter integer A4_COMPACT_WRITES = 0,
    parameter integer RUNTIME_MODEL = 0,
    parameter integer A4_TILE_PREFETCH = A4_MODE,
    parameter integer A4_STREAM_EMIT = A4_MODE,
    parameter integer A4_FUSION = A4_MODE,
    parameter integer A4_STREAM = A4_MODE,
    parameter integer A4_RESIDUAL_REPLAY = A4_MODE,
    parameter integer A4_RESIDUAL_FAST = A4_MODE,
    parameter integer A4_RESIDUAL_PIPE = A4_MODE,
    parameter integer A4_READ_PREFETCH = A4_MODE,
    parameter integer A4_RETURN_ADVANCE = 0,
    parameter integer A4_REQUEST_TRACK = 0,
    parameter integer A4_READ_INPUT_PIPE = 0,
    parameter integer A4_WRITE_INPUT_PIPE = 0,
    parameter integer A4_STREAM_REFILL = A4_MODE,
    parameter integer A4_EARLY_CACHE_READ = A4_STREAM_REFILL,
    parameter integer A4_PARALLEL_CACHE_READ = 0,
    parameter integer A4_REGISTERED_FLUSH = 0,
    parameter integer A4_PACKET_INPUT_PIPE = 0,
    parameter integer A4_PIPELINED_MASK = 0,
    parameter integer A4_SHARED_READ_CACHE = A4_MODE,
    parameter integer A4_REFILL_ALIGN_BITS = (A4_SHARED_READ_CACHE!=0)?5:10,
    parameter integer A4_FAST_MASK_SEAL = 0,
    parameter integer A4_PACKET_WORDS = 16,
    parameter integer A4_WRITE_QUEUE_LOG2 = 4,
    parameter integer A4_WRITE_QUEUE_BRAM = 0,
    parameter integer A4_IMPLICIT_QUEUE = 1,
    parameter integer A4_ROW_OVERLAP = A4_MODE,
    parameter integer A4_DEEP_ROW = A4_MODE,
    // Reuse the encoder1 row engine for the final convolution after layer10.
    parameter integer A4_TAIL_FUSION = A4_MODE,
    parameter integer A4_ROW_FIFO_DEPTH = (A4_TAIL_FUSION!=0)?8:4,
    parameter integer A4_ROW_PCO = 2,
    parameter integer P_CI     = (A4_MODE!=0)?4:2,
    parameter integer P_CO     = 4,
    parameter integer T        = 32,          // tile pixels (win_cache depth)
    parameter integer BLOG     = 15,          // 32768 bytes per bank
    parameter integer NL       = `NLX,        // descriptor slots
    parameter integer IMAGE_SCALE = 1,
    parameter integer IMAGE_HEIGHT_SCALE = IMAGE_SCALE,       // spatial dimensions only; weights unchanged
    parameter integer COUT_MAX = (A4_MODE != 0) ? 8 : 32,
    parameter integer ACC_W    = 32,
    parameter integer A_W      = 32,
    parameter integer B_W      = 33,
    parameter integer SA       = 24,
    parameter integer CING_MAX = (A4_MODE != 0) ? (8/P_CI) : 16,
    // Diagnostic mode: write signed 32-bit acc>>SH values instead of the
    // post-normalisation int8 output.  The convolution still runs both passes.
    parameter integer DEBUG_WRITE_ACC_S = 0,
    parameter integer DEBUG_CHECK_LAYER0_STATS = 0,
    parameter integer DEBUG_CHECK_LAYER0_WEIGHTS = 0,
    parameter integer DEBUG_CHECK_LAYER0_PIXEL0 = 0,
    parameter integer DEBUG_CHECK_LAYER0_MAC = 0,
    parameter integer DEBUG_CHECK_LAYER0_MAC_INPUTS = 0,
    parameter integer USE_DDR  = 0,
    parameter integer USE_DDR_WEIGHTS = 0,
    // Overlap the next input-channel weight group with current tile MACs.
    // Set to 0 to reproduce the serial group-burst baseline.
    parameter integer WEIGHT_PREFETCH = 1,
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer AXI_ID_WIDTH   = 4,
    parameter [AXI_ADDR_WIDTH-1:0] DDR_BASE_ADDR = 32'h0100_0000,
    parameter [AXI_ADDR_WIDTH-1:0] DDR_WEIGHT_BASE_ADDR = 32'h0180_0000,
    parameter integer DDR_BANK_ADDR_SHIFT = 20
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    input wire [2:0] runtime_model,
    input wire cfg_we,cfg_tanh,
    input wire [7:0] cfg_index,
    input wire [63:0] cfg_data,
    input wire [AXI_ADDR_WIDTH-1:0] input_ddr_base,output_ddr_base,
    output reg                   done,
    output reg                   busy,
    output wire profile_compute_active,profile_memory_wait,

    input  wire [1:0]            dbg_bank,
    input  wire [BLOG-1:0]       dbg_addr,
    output wire [7:0]            dbg_data,

    input  wire                  ddr_cal_done,
    output wire                  ddr_fault,
    output reg  [2:0]            diagnostic_code,
    output wire [AXI_ID_WIDTH-1:0] m_axi_awid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [7:0]            m_axi_awlen,
    output wire [2:0]            m_axi_awsize,
    output wire [1:0]            m_axi_awburst,
    output wire                  m_axi_awlock,
    output wire [3:0]            m_axi_awcache,
    output wire [2:0]            m_axi_awprot,
    output wire [3:0]            m_axi_awqos,
    output wire                  m_axi_awvalid,
    input  wire                  m_axi_awready,
    output wire [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output wire                  m_axi_wlast,
    output wire                  m_axi_wvalid,
    input  wire                  m_axi_wready,
    input  wire [AXI_ID_WIDTH-1:0] m_axi_bid,
    input  wire [1:0]            m_axi_bresp,
    input  wire                  m_axi_bvalid,
    output wire                  m_axi_bready,
    output wire [AXI_ID_WIDTH-1:0] m_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0]            m_axi_arlen,
    output wire [2:0]            m_axi_arsize,
    output wire [1:0]            m_axi_arburst,
    output wire                  m_axi_arlock,
    output wire [3:0]            m_axi_arcache,
    output wire [2:0]            m_axi_arprot,
    output wire [3:0]            m_axi_arqos,
    output wire                  m_axi_arvalid,
    input  wire                  m_axi_arready,
    input  wire [AXI_ID_WIDTH-1:0] m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]            m_axi_rresp,
    input  wire                  m_axi_rlast,
    input  wire                  m_axi_rvalid,
    output wire                  m_axi_rready
);

    localparam integer BWM = 1 << BLOG;
    reg [4:0] li;                  // layer index
    localparam integer RUN_LAYERS = (A4_MODE != 0) ? 13 : NL;
    // High-resolution prototype. Input/display must be DDR-backed before
    // IMAGE_SCALE=20 is enabled in a board top-level. Keep scale=2 arithmetic.
    localparam integer FRAME_PIXEL_W = (IMAGE_SCALE > 8) ? 20 : 16;
    localparam integer NORM_T_W = (IMAGE_SCALE > 2) ? 80 : 48;
    localparam integer UP_ROW_W = (IMAGE_SCALE > 8) ? 16*IMAGE_SCALE : 128;
    localparam integer DWIN     = P_CI * 9 * 8;      // one group's window bits
    localparam integer PCO_W    = $clog2(P_CO);
    localparam integer CIG_W    = $clog2(CING_MAX);
    localparam integer MAXCOG   = (COUT_MAX + P_CO - 1) / P_CO;
    // Layers execute serially: a layer writes its coefficients, immediately
    // consumes them in phase 1, and only then advances to the next layer.
    // Keep one layer's channel groups instead of reserving NL copies.
    localparam integer CT_DEPTH = MAXCOG;
    localparam integer CT_AW    = (CT_DEPTH <= 1) ? 1 : $clog2(CT_DEPTH);

    //========================================================================
    //  frame store
    //========================================================================
    // write port
    wire             wr_en;
    wire             wrq_valid;
    wire [1:0]       wr_bank;
    wire [BLOG-1:0]  wr_addr;
    // 32 bytes wide to match frame_store's port; only the low P_CO*8 bits
    // carry data (one output-channel group), the rest stays 0.
    wire [255:0]     wr_data;
    wire [5:0]       wr_n;

    // read ports (one per input-channel group is served by the reader below)
    reg  [1:0]       rdA_bank;
    reg  [BLOG-1:0]  rdA_addr;
    reg  [1:0]       rdB_bank;
    reg  [BLOG-1:0]  rdB_addr;
    wire [255:0]     rdA_data;
    wire [255:0]     rdB_data;
    wire             rdA_en;
    wire             rdB_en;

    wire [255:0] bram_rda_data, bram_rdb_data;
    wire [7:0]   bram_dbg_data;
    reg          bram_rda_valid, bram_rdb_valid;

    // Keep the original instance name so the existing ModelSim testbench can
    // still preload and inspect u_store.bank when USE_DDR=0.  Constant gating
    // lets synthesis remove this complete BRAM store in a USE_DDR=1 build.
    frame_store #(.NB(4), .BLOG(BLOG), .RW(32)) u_store (
        .clk(clk),
        .rda_en((USE_DDR == 0) && rdA_en),
        .rda_bank(rdA_bank), .rda_addr(rdA_addr), .rda_data(bram_rda_data),
        .rdb_en((USE_DDR == 0) && rdB_en),
        .rdb_bank(rdB_bank), .rdb_addr(rdB_addr), .rdb_data(bram_rdb_data),
        .wr_en((USE_DDR == 0) && wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr),
        .wr_data(wr_data), .wr_n(wr_n),
        .dbg_en((USE_DDR == 0) && !busy),
        .dbg_bank(dbg_bank), .dbg_addr(dbg_addr), .dbg_data(bram_dbg_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bram_rda_valid <= 1'b0;
            bram_rdb_valid <= 1'b0;
        end else begin
            bram_rda_valid <= (USE_DDR == 0) && rdA_en;
            bram_rdb_valid <= (USE_DDR == 0) && rdB_en;
        end
    end

    wire mem_rda_ready, mem_rda_valid;
    wire mem_rdb_ready, mem_rdb_valid;
    wire mem_wr_ready, mem_wr_done;
    wire [255:0] mem_rda_data, mem_rdb_data;
    wire ddr_busy_i, ddr_fault_i;
    wire ddr_wt_ready, ddr_wt_valid;
    wire [255:0] ddr_wt_data;
    wire [31:0]  wm_addr;
    wire         wm_mem_req;
    wire         wm_mem_ready;
    wire         wm_mem_valid;
    wire [255:0] mem_rdata;

    assign rdA_data = mem_rda_data;
    assign rdB_data = mem_rdb_data;
    assign dbg_data = (USE_DDR != 0) ? 8'd0 : bram_dbg_data;
    assign ddr_fault = (USE_DDR != 0) ? ddr_fault_i : 1'b0;

    // Encoder0 -> independent encoder1 row pipeline; encoder2 reuses the main MAC.
    localparam ROW_ENABLE=(A4_DEEP_ROW!=0 && A4_MODE!=0 && P_CI==4 && P_CO==4 && USE_DDR!=0 && A4_STREAM!=0 && A4_FUSION!=0 && DEBUG_WRITE_ACC_S==0);
    localparam TAIL_ENABLE=ROW_ENABLE && A4_TAIL_FUSION!=0;
    wire row_tail=TAIL_ENABLE && li==10;
    wire row_session,row_feed,row_input_ready,row_output_valid,row_finished,row_compute1,row_compute2;
    wire row_tanh_ce;
    wire [255:0] wr_data_queue;
    wire [63:0] row_output_data;wire [31:0] row_output_index;
    wire row_wt_req,row_wt_ready,row_wt_valid;wire [255:0] row_wt_data;
    wire [31:0] row_wt_addr;
    reg row_loading,row_pending,row_active;reg [3:0] row_word;
    assign row_wt_req=ROW_ENABLE && row_loading && !row_pending;
    assign row_wt_addr=(row_tail?32'd1600:32'd160)+({28'd0,row_word}<<5);
    wire a4_store_flush;
    generate
        if (USE_DDR != 0) begin : G_DDR_STORE
            wire [AXI_ADDR_WIDTH-1:0] feature_araddr,feature_awaddr;
            wire final_output_layer=(A4_FUSION!=0) ? (li==11 || row_tail) : (li==12);
            assign m_axi_awaddr=(USE_EXTERNAL_DDR_OUTPUT!=0 && A4_MODE!=0 && final_output_layer) ?
                output_ddr_base+(feature_awaddr-DDR_BASE_ADDR) : feature_awaddr;
            // A4 layer zero alone reads the immutable picture. Cache tags
            // retain the feature-bank geometry; every session invalidates
            // them and layer barriers drain all outstanding AXI reads.
            assign m_axi_araddr=(USE_EXTERNAL_DDR_INPUT!=0 && A4_MODE!=0 && li==0 && feature_araddr>=DDR_BASE_ADDR && feature_araddr<DDR_BASE_ADDR+(32'd1<<DDR_BANK_ADDR_SHIFT)) ?
                input_ddr_base+(feature_araddr-DDR_BASE_ADDR) : feature_araddr;
            wire pipe_a_req,pipe_b_req,store_a_ready,store_b_ready,store_busy;
            wire [1:0] pipe_a_bank,pipe_b_bank;
            wire [BLOG-1:0] pipe_a_addr,pipe_b_addr;
            wire pipe_a_busy,pipe_b_busy;
            wire pipe_w_req,store_w_ready,pipe_w_busy;
            wire [1:0] pipe_w_bank;
            wire [BLOG-1:0] pipe_w_addr;
            wire [255:0] pipe_w_data;
            wire [5:0] pipe_w_n;
            wire [BLOG:0] pipe_w_end;
            wire store_flush=a4_store_flush && !pipe_w_busy;
            if(A4_WRITE_INPUT_PIPE!=0 && A4_STREAM!=0) begin:G_WRITE_INPUT_PIPE
                nn_write_descriptor_pipe #(.AW(BLOG)) qw(
                    .clk(clk),.rst_n(rst_n),.clear(start),.enable(ddr_cal_done && !a4_store_flush),
                    .in_req(wr_en),.in_ready(mem_wr_ready),.in_bank(wr_bank),.in_addr(wr_addr),.in_data(wr_data),.in_n(wr_n),
                    .out_req(pipe_w_req),.out_ready(store_w_ready),.out_bank(pipe_w_bank),.out_addr(pipe_w_addr),.out_data(pipe_w_data),.out_n(pipe_w_n),.out_end(pipe_w_end),.busy(pipe_w_busy));
            end else begin:G_WRITE_INPUT_DIRECT
                assign pipe_w_req=wr_en;assign mem_wr_ready=store_w_ready;
                assign pipe_w_bank=wr_bank;assign pipe_w_addr=wr_addr;
                assign pipe_w_data=wr_data;assign pipe_w_n=wr_n;assign pipe_w_busy=0;
                assign pipe_w_end={1'b0,wr_addr}+wr_n;
            end
            if(A4_READ_INPUT_PIPE!=0) begin:G_READ_INPUT_PIPE
                nn_read_descriptor_pipe #(.AW(BLOG)) qa(
                    .clk(clk),.rst_n(rst_n),.clear(start),.enable(ddr_cal_done && !a4_store_flush),
                    .in_req(rdA_en),.in_ready(mem_rda_ready),.in_bank(rdA_bank),.in_addr(rdA_addr),
                    .out_req(pipe_a_req),.out_ready(store_a_ready),.out_bank(pipe_a_bank),.out_addr(pipe_a_addr),
                    .returned(mem_rda_valid),.busy(pipe_a_busy));
                nn_read_descriptor_pipe #(.AW(BLOG)) qb(
                    .clk(clk),.rst_n(rst_n),.clear(start),.enable(ddr_cal_done && !a4_store_flush),
                    .in_req(rdB_en),.in_ready(mem_rdb_ready),.in_bank(rdB_bank),.in_addr(rdB_addr),
                    .out_req(pipe_b_req),.out_ready(store_b_ready),.out_bank(pipe_b_bank),.out_addr(pipe_b_addr),
                    .returned(mem_rdb_valid),.busy(pipe_b_busy));
            end else begin:G_READ_INPUT_DIRECT
                assign pipe_a_req=rdA_en;assign pipe_b_req=rdB_en;
                assign pipe_a_bank=rdA_bank;assign pipe_b_bank=rdB_bank;
                assign pipe_a_addr=rdA_addr;assign pipe_b_addr=rdB_addr;
                assign mem_rda_ready=store_a_ready;assign mem_rdb_ready=store_b_ready;
                assign pipe_a_busy=0;assign pipe_b_busy=0;
            end
            // All A4 streamed feature inputs have 4 or 8 channels. The
            // convolution reader requests 32-byte blocks; residual readers
            // request pixel*4 only at multiples of eight under residual replay.
            // Every accepted request is therefore 32-byte aligned.
            localparam WORD_ALIGNED_READS=A4_MODE!=0 && A4_STREAM!=0 && A4_FUSION!=0 && A4_RESIDUAL_REPLAY!=0;
            wire [BLOG-1:0] aligned_a=WORD_ALIGNED_READS?{pipe_a_addr[BLOG-1:5],5'b0}:pipe_a_addr;
            wire [BLOG-1:0] aligned_b=WORD_ALIGNED_READS?{pipe_b_addr[BLOG-1:5],5'b0}:pipe_b_addr;
`ifndef SYNTHESIS
            always @(posedge clk)if(rst_n && WORD_ALIGNED_READS)begin
                if(pipe_a_req && store_a_ready && |pipe_a_addr[4:0])$fatal(1,"A4 32-byte read A invariant");
                if(pipe_b_req && store_b_ready && |pipe_b_addr[4:0])$fatal(1,"A4 32-byte read B invariant");
            end
`endif
            assign ddr_busy_i=store_busy || pipe_a_busy || pipe_b_busy || pipe_w_busy;
            frame_store_ddr_axi #(
                .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
                .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
                .AXI_ID_WIDTH(AXI_ID_WIDTH),
                .FRAME_ADDR_WIDTH(BLOG),
                .BASE_ADDR(DDR_BASE_ADDR),
                .WEIGHT_BASE_ADDR(DDR_WEIGHT_BASE_ADDR),
                .WEIGHT_GROUP_WORDS((P_CO*P_CI*9+31)/32),
                .BANK_ADDR_SHIFT(DDR_BANK_ADDR_SHIFT), .A4_FAST(A4_MODE), .STREAM_WR(A4_STREAM),
                .A4_FIXED_WRITES(A4_COMPACT_WRITES!=0 && A4_MODE!=0 && A4_STREAM!=0 && DEBUG_WRITE_ACC_S==0),.A4_WRITE_END_PIPE(A4_WRITE_INPUT_PIPE!=0 && A4_STREAM!=0),.A4_STREAM_REFILL(A4_STREAM_REFILL),.A4_EARLY_CACHE_READ(A4_EARLY_CACHE_READ),.A4_PARALLEL_CACHE_READ(A4_PARALLEL_CACHE_READ),.A4_REGISTERED_FLUSH(A4_REGISTERED_FLUSH),.A4_PACKET_INPUT_PIPE(A4_PACKET_INPUT_PIPE),.A4_PIPELINED_MASK(A4_PIPELINED_MASK),.A4_SHARED_READ_CACHE(A4_SHARED_READ_CACHE),.A4_REFILL_ALIGN_BITS(A4_REFILL_ALIGN_BITS),.A4_FAST_MASK_SEAL(A4_FAST_MASK_SEAL),.A4_PACKET_WORDS(A4_PACKET_WORDS)
            ) u_ddr_store (
                .clk(clk), .rst_n(rst_n), .cal_done(ddr_cal_done),
                .flush(store_flush), .invalidate(start),
                .rda_req(pipe_a_req), .rda_ready(store_a_ready),
                .rda_bank(pipe_a_bank), .rda_addr(aligned_a),
                .rda_valid(mem_rda_valid), .rda_data(mem_rda_data),
                .rdb_req(pipe_b_req), .rdb_ready(store_b_ready),
                .rdb_bank(pipe_b_bank), .rdb_addr(aligned_b),
                .rdb_valid(mem_rdb_valid), .rdb_data(mem_rdb_data),
                .wr_req(pipe_w_req), .wr_ready(store_w_ready),
                .wr_bank(pipe_w_bank), .wr_addr(pipe_w_addr), .wr_end(pipe_w_end),
                .wr_data(pipe_w_data), .wr_n(pipe_w_n), .wr_done(mem_wr_done),
                .wt_req((USE_DDR_WEIGHTS != 0) && (row_loading?row_wt_req:wm_mem_req)),
                .wt_ready(ddr_wt_ready), .wt_addr((row_loading?row_wt_addr:wm_addr) + ((RUNTIME_MODEL!=0)?{17'd0,runtime_model,12'd0}:32'd0)),
                .wt_valid(ddr_wt_valid), .wt_data(ddr_wt_data),
                .busy(store_busy), .fault(ddr_fault_i),
                .m_axi_awid(m_axi_awid), .m_axi_awaddr(feature_awaddr),
                .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
                .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
                .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
                .m_axi_awqos(m_axi_awqos), .m_axi_awvalid(m_axi_awvalid),
                .m_axi_awready(m_axi_awready),
                .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
                .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
                .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid),
                .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
                .m_axi_bready(m_axi_bready),
                .m_axi_arid(m_axi_arid), .m_axi_araddr(feature_araddr),
                .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
                .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
                .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
                .m_axi_arqos(m_axi_arqos), .m_axi_arvalid(m_axi_arvalid),
                .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid),
                .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
                .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
                .m_axi_rready(m_axi_rready)
            );
        end else begin : G_BRAM_STORE
            assign mem_rda_ready = 1'b1;
            assign mem_rda_valid = bram_rda_valid;
            assign mem_rda_data  = bram_rda_data;
            assign mem_rdb_ready = 1'b1;
            assign mem_rdb_valid = bram_rdb_valid;
            assign mem_rdb_data  = bram_rdb_data;
            assign mem_wr_ready  = 1'b1;
            assign mem_wr_done   = wr_en;
            assign ddr_busy_i    = 1'b0;
            assign ddr_fault_i   = 1'b0;
            assign ddr_wt_ready  = 1'b0;
            assign ddr_wt_valid  = 1'b0;
            assign ddr_wt_data   = 256'd0;
            assign m_axi_awid = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_awaddr = {AXI_ADDR_WIDTH{1'b0}};
            assign m_axi_awlen = 8'd0; assign m_axi_awsize = 3'd0;
            assign m_axi_awburst = 2'd0; assign m_axi_awlock = 1'b0;
            assign m_axi_awcache = 4'd0; assign m_axi_awprot = 3'd0;
            assign m_axi_awqos = 4'd0; assign m_axi_awvalid = 1'b0;
            assign m_axi_wdata = {AXI_DATA_WIDTH{1'b0}};
            assign m_axi_wstrb = {(AXI_DATA_WIDTH/8){1'b0}};
            assign m_axi_wlast = 1'b0; assign m_axi_wvalid = 1'b0;
            assign m_axi_bready = 1'b0;
            assign m_axi_arid = {AXI_ID_WIDTH{1'b0}};
            assign m_axi_araddr = {AXI_ADDR_WIDTH{1'b0}};
            assign m_axi_arlen = 8'd0; assign m_axi_arsize = 3'd0;
            assign m_axi_arburst = 2'd0; assign m_axi_arlock = 1'b0;
            assign m_axi_arcache = 4'd0; assign m_axi_arprot = 3'd0;
            assign m_axi_arqos = 4'd0; assign m_axi_arvalid = 1'b0;
            assign m_axi_rready = 1'b0;
        end
    endgenerate

    //========================================================================
    //  descriptor tables
    //========================================================================

    // The network descriptor is fixed for this generated model.  Keep all
    // fields in one combinational case ROM so Efinity does not try to
    // decompose eight independently initialized asynchronous RAMs.
    function [207:0] desc_rom;
        input [4:0] idx;
        begin
            if (A4_MODE != 0) begin
                case (idx)
                    5'd0: desc_rom = 208'h0000180020000400040002000100000100000000000000000004;
                    5'd1: desc_rom = 208'h0000180020000400040002000100010200000000c00000000404;
                    5'd2: desc_rom = 208'h0000180020000800040002000200020300000001800000000808;
                    5'd3: desc_rom = 208'h00000c0010000400080002000200030000000003000000001004;
                    5'd4: desc_rom = 208'h0000060008000400040002000100000100000004800000001404;
                    5'd5: desc_rom = 208'h0000060008000400040000000100010200000005400000001804;
                    5'd6: desc_rom = 208'h0200060008000400040000000100020300000006000000001c04;
                    5'd7: desc_rom = 208'h0100060008000400040000000100030100000006000000001c04;
                    5'd8: desc_rom = 208'h00000c0010000400040002000100010200000006000000001c04;
                    5'd9: desc_rom = 208'h01000c0010000400040000000100020300000006c00000002004;
                    5'd10: desc_rom = 208'h0000180020000400040002000100030100000006c00000002004;
                    5'd11: desc_rom = 208'h0000180020000400040000000100010200000007800000002403;
                    5'd12: desc_rom = 208'h0300180020000300030000000100020000000008400000002803;
                    default: desc_rom = 208'd0;
                endcase
            end else begin
            case (idx)
                 5'd0: desc_rom = 208'h000018002000080004000305010000010f000000000000000008;
                 5'd1: desc_rom = 208'h000018002000080008000305010001020f000001800000000808;
                 5'd2: desc_rom = 208'h000018002000100008000305020002030f000004800000001010;
                 5'd3: desc_rom = 208'h00000c001000200010000304020003000f00000a800000002020;
                 5'd4: desc_rom = 208'h0000060008002000200003040100000100000022800000004020;
                 5'd5: desc_rom = 208'h0000060008002000200001050100010200000052800000006020;
                 5'd6: desc_rom = 208'h0200060008002000200000010100020300000000000000000020;
                 5'd7: desc_rom = 208'h0000060008002000200003060100030003000082800000008020;
                 5'd8: desc_rom = 208'h00000600080020002000010601000001030000b280000000a020;
                 5'd9: desc_rom = 208'h0200060008002000200000000100010203000000000000000020;
                5'd10: desc_rom = 208'h00000600080020002000030501000203020000e280000000c020;
                5'd11: desc_rom = 208'h000006000800200020000105010003000200011280000000e020;
                5'd12: desc_rom = 208'h0200060008002000200000000100000102000000000000000020;
                5'd13: desc_rom = 208'h010006000800200020000000010001020f000000000000000020;
                5'd14: desc_rom = 208'h00000c001000100020000306010002030f000142800000010010;
                5'd15: desc_rom = 208'h01000c001000100010000000010003000f000000000000000010;
                5'd16: desc_rom = 208'h000018002000080010000305010000010f00015a800000011008;
                5'd17: desc_rom = 208'h000018002000080008000304010001020f000160800000011808;
                5'd18: desc_rom = 208'h000018002000040008000000010002030f000163800000012003;
                5'd19: desc_rom = 208'h030018002000030003000000010003000f000000000000000003;
                default: desc_rom = 208'd0;
            endcase
            end
            if(A4_MODE!=0 && P_CI==4) begin
                case(idx)
                    5'd0: desc_rom[71:40]=32'd0;
                    5'd1: desc_rom[71:40]=32'd160;
                    5'd2: desc_rom[71:40]=32'd320;
                    5'd3: desc_rom[71:40]=32'd640;
                    5'd4: desc_rom[71:40]=32'd960;
                    5'd5: desc_rom[71:40]=32'd1120;
                    5'd6: desc_rom[71:40]=32'd1280;
                    5'd7: desc_rom[71:40]=32'd1280;
                    5'd8: desc_rom[71:40]=32'd1280;
                    5'd9: desc_rom[71:40]=32'd1440;
                    5'd10: desc_rom[71:40]=32'd1440;
                    5'd11: desc_rom[71:40]=32'd1600;
                    5'd12: desc_rom[71:40]=32'd1760;
                endcase
            end
            desc_rom[199:184] = desc_rom[199:184] * IMAGE_HEIGHT_SCALE;
            desc_rom[183:168] = desc_rom[183:168] * IMAGE_SCALE;
        end
    endfunction

    wire [207:0] d_cur  = desc_rom(li);
    wire [7:0]   d_op   = d_cur[207:200];
    wire [31:0]  d_dim  = d_cur[199:168];
    wire [31:0]  d_ch   = d_cur[167:136];
    wire [31:0]  d_flag = d_cur[135:104];
    wire [31:0]  d_bank = d_cur[103:72];
    wire [31:0]  d_wb   = d_cur[71:40];
    wire [31:0]  d_gb   = d_cur[39:8];
    wire [7:0]   d_rc   = d_cur[7:0];
    // The generated network currently contains 296 gamma/beta entries.
    // Keep a power-of-two depth so later decoder layers do not read past
    // entry 255 (dec.1 starts at gbase 256).
    localparam integer GROM_WORDS = (A4_MODE != 0) ? 64 : 512;
    (* syn_ramstyle="logic" *) reg [63:0] grom [0:GROM_WORDS-1];
    // A4 coefficients are exact bias codes plus one of four power-of-two shifts.
    // Store that compact representation in logic, rather than a full 40x64 RAM.
    (* syn_ramstyle="logic" *) reg [16:0] runtime_bias[0:39];
    (* syn_ramstyle="logic" *) reg [2:0] runtime_factor[0:39];
    always @(posedge clk) if(RUNTIME_MODEL!=0 && cfg_we && !cfg_tanh && cfg_index<40) begin
        case(cfg_data[31:0])
            32'd32768: begin runtime_bias[cfg_index]<=$signed(cfg_data[63:32])>>>15;runtime_factor[cfg_index]<=4;end
            32'd65536: begin runtime_bias[cfg_index]<=$signed(cfg_data[63:32])>>>16;runtime_factor[cfg_index]<=1;end
            32'd131072:begin runtime_bias[cfg_index]<=$signed(cfg_data[63:32])>>>17;runtime_factor[cfg_index]<=2;end
            32'd262144:begin runtime_bias[cfg_index]<=$signed(cfg_data[63:32])>>>18;runtime_factor[cfg_index]<=3;end
            default:begin runtime_bias[cfg_index]<=0;runtime_factor[cfg_index]<=0;end
        endcase
    end
    // Weight manager always requests one aligned 32-byte beat.  Store that
    // beat as one RAM word so synthesis infers one ROM instead of replicating
    // a byte-wide ROM for 32 simultaneous read addresses.
    // The generated network occupies 2,856 words (91,392 bytes).  Reserve
    // 3,072 words so the ROM maps to six 512-row RAM segments instead of the
    // eight segments implied by a 4,096-word declaration.
    localparam integer WMEM_WORDS = (A4_MODE != 0) ? ((P_CI==4)?55:66) : 3072;
    reg [255:0] wmem [0:WMEM_WORDS-1];

    integer k;
    initial begin

        if(RUNTIME_MODEL==0) for (k = 0; k < GROM_WORDS; k = k + 1) grom[k] = 64'd0;
        //initialize the ram contents, innecessary because of the values in ram 
        //has been initialize below
        // The source file contains 4096 words; only the implemented ROM range
        // is loaded.  All referenced weight addresses are below word 2856.
        /*
        $readmemh({`NETV, "/net_op.mem"},    d_op);
        $readmemh({`NETV, "/net_dim.mem"},   d_dim);
        $readmemh({`NETV, "/net_ch.mem"},    d_ch);
        $readmemh({`NETV, "/net_flags.mem"}, d_flag);
        $readmemh({`NETV, "/net_bank.mem"},  d_bank);
        $readmemh({`NETV, "/net_wbase.mem"}, d_wb);
        $readmemh({`NETV, "/net_gbase.mem"}, d_gb);
        $readmemh({`NETV, "/net_realc.mem"}, d_rc);
        $readmemh({`NETV, "/net_gb.mem"},    grom);
        $readmemh({`NETV, "/net_w256.mem"},  wmem);
        $readmemh({`NETV, "/net_in.mem"},    u_store.bank);  // ???? bank 0*/

        if (A4_MODE != 0) begin
            if(RUNTIME_MODEL==0) $readmemh("a4_coeff.mem", grom);
            if(USE_DDR_WEIGHTS==0) begin
                if(P_CI==4) $readmemh("a4_weights_pci4.mem", wmem);
                else $readmemh("a4_weights.mem", wmem);
            end
        end else begin
            $readmemh("net_gb.mem", grom);
            $readmemh("net_w3072.mem", wmem);
        end
        //only modelsim simulation needs the verilog content below
        //$readmemh("net_in.mem", u_store.bank);
    end

    // 256-bit synchronous ROM port for weight_mgr.  wm_addr is a byte
    // address and is always 32-byte aligned, hence bits [16:5] select a word.
    reg           weight_check_active;
    reg           weight_check_prime;
    reg  [3:0]    weight_check_addr;
    reg  [3:0]    weight_check_count;
    reg  [31:0]   weight_check_sig;
    wire [11:0]   wmem_read_addr = weight_check_active ?
                    {8'd0, weight_check_addr} : wm_addr[16:5];
    wire [31:0] weight_check_fold =
        mem_rdata[31:0]    ^ mem_rdata[63:32]   ^
        mem_rdata[95:64]   ^ mem_rdata[127:96]  ^
        mem_rdata[159:128] ^ mem_rdata[191:160] ^
        mem_rdata[223:192] ^ mem_rdata[255:224];
    wire [31:0] weight_check_sig_next =
        {weight_check_sig[30:0], weight_check_sig[31]} ^
        weight_check_fold ^ {28'd0, weight_check_count};
    generate
        if (USE_DDR_WEIGHTS != 0) begin : G_DDR_WEIGHTS
            assign wm_mem_ready = ddr_wt_ready && !row_loading;
            assign row_wt_ready=ddr_wt_ready;assign row_wt_valid=ddr_wt_valid;assign row_wt_data=ddr_wt_data;
            assign wm_mem_valid = ddr_wt_valid && !row_loading;
            assign mem_rdata    = ddr_wt_data;
        end else begin : G_ROM_WEIGHTS
            reg [255:0] rom_rdata;
            reg         rom_valid;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rom_rdata <= 256'd0;
                    rom_valid <= 1'b0;
                end else begin
                    rom_valid <= wm_mem_req && !row_loading;
                    if (wm_mem_req || weight_check_active)
                        rom_rdata <= wmem[wmem_read_addr];
                end
            end
            reg [255:0] row_rom_data;reg row_rom_valid;
            always @(posedge clk or negedge rst_n)begin
                if(!rst_n)row_rom_valid<=0;
                else begin row_rom_valid<=row_wt_req;if(row_wt_req)row_rom_data<=wmem[row_wt_addr>>5];end
            end
            assign row_wt_ready=1'b1;assign row_wt_valid=row_rom_valid;assign row_wt_data=row_rom_data;
            assign wm_mem_ready = !row_loading;
            assign wm_mem_valid = rom_valid;
            assign mem_rdata    = rom_rdata;
        end
    endgenerate

    //========================================================================
    //  per-layer latched configuration
    //========================================================================
    reg [1:0]  phase;             // 0 = statistics, 1 = output
    reg [15:0] l_h, l_w, l_cin, l_cout;
    reg [31:0] l_pixels; // calculate once at descriptor load, away from DDR request enables
    function [31:0] descriptor_pixels;
        input [31:0] dim;
        begin
            if(A4_MODE!=0)begin
                case(dim)
                    {16'(24*IMAGE_HEIGHT_SCALE),16'(32*IMAGE_SCALE)}:
                        descriptor_pixels=(24*IMAGE_HEIGHT_SCALE)*(32*IMAGE_SCALE);
                    {16'(12*IMAGE_HEIGHT_SCALE),16'(16*IMAGE_SCALE)}:
                        descriptor_pixels=(12*IMAGE_HEIGHT_SCALE)*(16*IMAGE_SCALE);
                    {16'(6*IMAGE_HEIGHT_SCALE),16'(8*IMAGE_SCALE)}:
                        descriptor_pixels=(6*IMAGE_HEIGHT_SCALE)*(8*IMAGE_SCALE);
                    default:descriptor_pixels=0;
                endcase
            end else descriptor_pixels={16'd0,dim[31:16]}*{16'd0,dim[15:0]};
        end
    endfunction
    reg [7:0]  l_sh, l_rc;
    // A4 descriptors use only RGB(3), four or eight channels. Avoid a
    // variable multiply feeding packet RAM address and write enables.
    function [31:0] channel_byte_address;
        input [31:0] pixel;
        input [7:0] channels;
        begin
            if(A4_MODE!=0) begin
                case(channels)
                    3: channel_byte_address=(pixel<<1)+pixel;
                    4: channel_byte_address=pixel<<2;
                    8: channel_byte_address=pixel<<3;
                    default: channel_byte_address=0;
                endcase
            end else channel_byte_address=pixel*channels;
        end
    endfunction

    reg [1:0]  l_st;
    reg        l_nrm, l_relu;
    reg [31:0] l_wb, l_gb;
    reg [1:0]  l_src, l_dst, l_xb;
    reg [4:0]  l_op;
    // Sequencer state declarations are placed before the read-port muxes,
    // because `default_nettype none requires declarations before use.
    localparam S_IDLE   = 5'd0,  S_LD    = 5'd1,
               S_DPRST  = 5'd2,  S_CFGP  = 5'd3,  S_CFWAIT = 5'd4,
               S_COEF   = 5'd5,  S_COEFW = 5'd6,
               S_THGO   = 5'd7,  S_THRUN = 5'd8,
               S_NEXT   = 5'd9,  S_DONE  = 5'd10,
               S_RAGO   = 5'd11, S_RARUN = 5'd12,
               S_UPGO   = 5'd13, S_UPRUN = 5'd14,
               S_WCHK   = 5'd15, S_ROMPRIME = 5'd16;
    reg [4:0] st;
    assign row_session=(ROW_ENABLE && st==S_IDLE && start) || (TAIL_ENABLE && st==S_LD && li==10);
    assign row_feed=(ROW_ENABLE && li==0) || row_tail;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin row_loading<=0;row_pending<=0;row_active<=0;row_word<=0;end
        else if(row_session)begin row_loading<=1;row_pending<=0;row_active<=0;row_word<=0;end
        else if(row_loading)begin
            if(row_wt_req && row_wt_ready)row_pending<=1;
            if(row_pending && row_wt_valid)begin
                row_pending<=0;
                if(row_word==4)begin row_loading<=0;row_active<=1;end
                else row_word<=row_word+1'b1;
            end
        end
    end
    generate if(ROW_ENABLE)begin : G_DEEP_ROWS
        wire row_reset_n=rst_n && row_active;
        wire [31:0] result_data;
        wire result_valid;wire [31:0] result_index;
        reg tail_valid;reg [31:0] tail_index;
        wire tail_ready=!tail_valid || mem_wr_ready;
        // Elastic one-entry stage: the existing tanh RAM output is its data
        // register. Freeze the lookup and index together under DDR backpressure.
        always @(posedge clk or negedge row_reset_n)begin
            if(!row_reset_n)begin tail_valid<=0;tail_index<=0;end
            else if(row_tail && tail_ready)begin
                tail_valid<=result_valid;
                if(result_valid)tail_index<=result_index;
            end
        end
        assign row_output_valid=row_tail?tail_valid:result_valid;
        assign row_output_index=row_tail?tail_index:result_index;
        assign row_tanh_ce=!row_tail || (result_valid && tail_ready);
        a4_row_conv #(.FIFO_BRAM(1),.SINGLE_GROUP_SHARED_WEIGHTS(1),.W(32*IMAGE_SCALE),.H(24*IMAGE_HEIGHT_SCALE),.CO(4),.PCO(A4_ROW_PCO),.WINDOW_HOLD(A4_ROW_OVERLAP),.GBASE(4),.WORDS(5),.RUNTIME_MODEL(RUNTIME_MODEL),.TAIL_REUSE(TAIL_ENABLE),.FIFO_DEPTH(A4_ROW_FIFO_DEPTH)) u_encoder1(
            .clk(clk),.rst_n(row_reset_n),.cfg_we(cfg_we && !cfg_tanh),.cfg_index(cfg_index),.cfg_data(cfg_data),
            .tail_mode(row_tail),
            .weight_we(row_loading && row_pending && row_wt_valid),.weight_word(row_word),.weight_data(row_wt_data),
            .in_valid(wrq_valid && row_feed && row_active),.in_ready(row_input_ready),.in_data(wr_data_queue[31:0]),
            .out_valid(result_valid),.out_ready(row_feed && (row_tail?tail_ready:mem_wr_ready)),.out_data(result_data),.out_index(result_index),.finished(row_finished),.compute_active(row_compute1));
        assign row_output_data={32'd0,result_data};assign row_compute2=0;
    end else begin : G_NO_DEEP_ROWS
        assign row_tanh_ce=1;assign row_compute1=0;assign row_compute2=0;assign row_input_ready=0;assign row_output_valid=0;assign row_output_data=0;assign row_output_index=0;assign row_finished=1;
    end endgenerate
    assign a4_store_flush = (A4_MODE != 0) && (st == S_NEXT || st == S_DONE);

    // variable statistics / postproc shift
    reg [4:0]  sh_r;
    // acc_bank ???????????? generate ?????
    // ?? Verilog ?????? 1 ? wire?????????
    wire [P_CO*ACC_W-1:0] acc_rd_data;
    wire [P_CO*ACC_W-1:0] acc_committed_sum;
    wire acc_commit_valid,cf_mac_emit,cf_pp_valid;
    wire [FRAME_PIXEL_W-1:0] cf_mac_global;
    wire [7:0] cf_mac_cog;
    reg [FRAME_PIXEL_W-1:0] stream_px1,stream_px2,stream_px3,stream_px4;
    reg [7:0] stream_cog1,stream_cog2,stream_cog3,stream_cog4;
    reg [3:0] stream_emit_valid;
    wire stream_emit=(A4_STREAM_EMIT!=0);

    wire [P_CO*ACC_W-1:0] acc_s;
    genvar gsh;
    generate
        for (gsh = 0; gsh < P_CO; gsh = gsh + 1) begin : G_SH
            wire signed [ACC_W-1:0] t =
                $signed(stream_emit ? acc_committed_sum[gsh*ACC_W +: ACC_W] : acc_rd_data[gsh*ACC_W +: ACC_W]) >>> sh_r;
            assign acc_s[gsh*ACC_W +: ACC_W] = t;
        end
    endgenerate

    //========================================================================
    //  datapath reset (acc_reduce_w and coeff_table are exempt)
    //========================================================================
    reg  dp_rst_n;

    //========================================================================
    //  reader + line buffers
    //========================================================================
    reg  [31:0] rdr_pix;
    reg [15:0] rdr_col, rdr_row;
    wire virtual_up = (A4_FUSION!=0) && (li==8 || li==10);
    reg  [CIG_W:0] rdr_cing;
    reg         rdr_en;
    reg  [15:0] rdr_cin;
    reg  [31:0] rdr_npix;


    wire [CING_MAX-1:0] lb_inrdy;
    wire                lb_stall;
    wire [15:0]         lb_cfg_w, lb_cfg_h;
    wire [1:0]          lb_cfg_stride;
    wire [DWIN-1:0]     lb_wdata [0:CING_MAX-1];
    wire                lb_wvalid[0:CING_MAX-1];

    reg  [31:0]  th_pix, th_cnt;  // tanh read/write pixel counters
    reg  [31:0]  ra_pix, ra_cnt;  // residual read/write pixel counters
    reg  [31:0]  up_pix, up_cnt;  // upsample read/write pixel counters
    reg          rdr_data_valid;
    reg          ra_data_valid;
    reg          up_data_valid;
    reg          rdr_pending;
    reg          th_pending;
    reg          up_pending;
    reg  [2:0]   ra_phase;
    reg  [255:0] ra_x_hold, ra_f_hold;

    wire rdr_consume = rdr_data_valid && lb_inrdy[0];
    reg rdr_block_valid;
    reg [BLOG-6:0] rdr_block_base, rdr_request_base;
    reg [4:0] rdr_request_offset;
    reg [255:0] rdr_block, rdr_block1, rdr_pixel_hold;
    reg rdr_active_bank;
    reg [BLOG-1:0] rdr_source_addr,rdr_row_base;
    reg [BLOG-1:0] rdr_row_bytes;
    // Incremental byte addresses eliminate the chained virtual-up multipliers.
    always @(posedge clk) if(st==S_LD) begin
        if(A4_MODE!=0) rdr_row_bytes <= (d_ch[15:0]==8) ? ({1'b0,d_dim[15:1]}<<3) : ({1'b0,d_dim[15:1]}<<2);
        else rdr_row_bytes <= (d_dim[15:0]>>1)*d_ch[15:0];
    end
    // A second 32-byte word hides cache-read latency behind pixel consumption.
    // Upsampled walks prefetch only inside the current source row.
    reg rdr_prefetch_valid,rdr_pending_prefetch,rdr_prefetch_eligible,rdr_prefetch_armed;
    reg [BLOG-6:0] rdr_prefetch_next;
    reg [BLOG-6:0] rdr_prefetch_tag;
    wire rdr_prefetch_mode=A4_READ_PREFETCH!=0 && A4_STREAM!=0 && USE_DDR!=0 &&
                           (rdr_cin==4 || rdr_cin==8);
    wire rdr_prefetch_hit=rdr_prefetch_mode && rdr_prefetch_valid &&
                         rdr_prefetch_tag==rdr_source_addr[BLOG-1:5];
    wire [255:0] rdr_selected_block=(rdr_active_bank ^ rdr_prefetch_hit)?rdr_block1:rdr_block;
    wire rdr_block_hit=rdr_block_valid && (rdr_block_base==rdr_source_addr[BLOG-1:5]);
    wire rdr_can_issue = rdr_en && (rdr_pix < rdr_npix) &&
                   (!rdr_pending || (rdr_prefetch_mode && rdr_pending_prefetch)) &&
                   (!rdr_data_valid || rdr_consume);
    // Nearest-neighbour horizontal copies reuse the retained read result.
    wire rdr_replay = rdr_can_issue && ((A4_STREAM!=0)?(rdr_block_hit || rdr_prefetch_hit):(virtual_up && rdr_col[0]));
    wire rdr_demand_req = rdr_can_issue && !rdr_pending &&
                          ((A4_STREAM!=0)?!(rdr_block_hit || rdr_prefetch_hit):(!virtual_up || !rdr_col[0]));
    wire [5:0] rdr_pixels_to_boundary=(6'd32-{1'b0,rdr_source_addr[4:0]}) >> ((rdr_cin==8)?3:2);
    wire [BLOG-6:0] rdr_next_block=rdr_prefetch_next;
    wire rdr_prefetch_req=rdr_prefetch_mode && rdr_en && rdr_block_hit &&
                         !rdr_pending && !rdr_prefetch_valid && rdr_prefetch_armed && rdr_prefetch_eligible;
    wire rdr_req=rdr_demand_req || rdr_prefetch_req;
    wire rdr_mem_issue;
    wire th_req = (A4_FUSION==0) && (st == S_THRUN) && (th_pix < l_pixels) &&
                  (th_pix == th_cnt) && !th_pending && !wr_en;
    // Each A4 residual pixel has four channels. Reuse all eight pixels in
    // a returned 32-byte word; the existing hold registers shift by one pixel.
    wire ra_replay = A4_RESIDUAL_REPLAY!=0 && USE_DDR!=0 && l_rc==4 && ra_pix[2:0]!=0;
    wire ra_a_req = (st == S_RARUN) && (ra_pix < l_pixels) &&
                    (ra_phase == 3'd0) && !ra_replay;
    wire ra_b_req = (st == S_RARUN) && (ra_phase == 3'd2) && !ra_replay;
    wire up_consume;
    wire up_req;
    wire rdr_issue;
    wire th_issue;
    wire ra_issue;
    wire up_issue;
    wire rdr_mem_return = mem_rda_valid && (st != S_RARUN) && (st != S_UPRUN);
    wire rdr_demand_return=rdr_mem_return && !rdr_pending_prefetch;
    wire rdr_return = rdr_demand_return || rdr_replay;

    // ---- read port A: convolution reader, or residual skip input ----
    always @(*) begin
        if (st == S_RARUN) begin
            rdA_bank = l_xb;
            rdA_addr = channel_byte_address(ra_pix,l_rc);
        end else if (A4_FUSION==0 && st == S_UPRUN) begin
            rdA_bank = l_src;
            rdA_addr = channel_byte_address(up_pix,l_rc);
        end else begin
            rdA_bank = l_src;
            rdA_addr = rdr_prefetch_req?{rdr_next_block,5'd0}:
                       (A4_STREAM!=0)?{rdr_source_addr[BLOG-1:5],5'd0}:rdr_source_addr;
        end
    end

    // ---- read port B: tanh input, or residual F input ----
    // th_pix is declared here because the read address depends on it
    // (it used to be declared with the tanh engine, further down)
    always @(*) begin
        rdB_bank = l_src;
        rdB_addr = (st == S_RARUN) ? (channel_byte_address(ra_pix,l_rc)) : ((A4_FUSION==0)?(th_pix * 3):32'd0);
    end

    // The frame store is synchronous; rdr_data_valid identifies the returned pixel.
    genvar gc;
    generate
        for (gc = 0; gc < CING_MAX; gc = gc + 1) begin : G_LB
            // group gc occupies bytes [gc*P_CI*8 +: P_CI*8] of the 32-byte read
            wire [P_CI*8-1:0] g_px = (A4_STREAM!=0)?rdr_pixel_hold[gc*P_CI*8 +: P_CI*8]:rdA_data[gc*P_CI*8 +: P_CI*8];

            wire in_ok = rdr_data_valid && (gc < rdr_cing);
            // The second input group is active only in enc.3, at half width.
            localparam LB_MAX_WIDTH=(A4_MODE!=0)?((gc==0)?32*IMAGE_SCALE:16*IMAGE_SCALE):1024;
            localparam LB_ADDR_WIDTH=$clog2(LB_MAX_WIDTH);
            line_buffer_v2 #(.P_CI(P_CI), .CH_W(8), .MAX_W(LB_MAX_WIDTH), .ADDR_W(LB_ADDR_WIDTH)) u_lb (
                .clk(clk), .rst_n(dp_rst_n), .stall(lb_stall),
                .cfg_w(lb_cfg_w), .cfg_h(lb_cfg_h), .cfg_stride(lb_cfg_stride),
                .in_valid(in_ok), .in_ready(lb_inrdy[gc]), .in_px(g_px),
                .win_valid(lb_wvalid[gc]), .win_row(), .win_col(),
                .win_data(lb_wdata[gc])
            );
        end
    endgenerate

    always @(posedge clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            rdr_pix        <= 32'd0;
            rdr_col<=0;rdr_row<=0;rdr_source_addr<=0;rdr_row_base<=0;
            rdr_block_valid<=0;rdr_block_base<=0;rdr_request_base<=0;
            rdr_request_offset<=0;rdr_block<=0;rdr_block1<=0;rdr_active_bank<=0;rdr_pixel_hold<=0;
            rdr_data_valid <= 1'b0;
            rdr_pending    <= 1'b0;
            rdr_prefetch_valid<=0;rdr_pending_prefetch<=0;rdr_prefetch_tag<=0;
            rdr_prefetch_next<=0;rdr_prefetch_eligible<=0;rdr_prefetch_armed<=0;
        end else begin
            if(A4_STREAM!=0) begin
                // Keep boundary addition/comparison out of the read-address mux.
                // Eligibility becomes usable only after a new resident tag settles.
                rdr_prefetch_eligible<=virtual_up ? ({rdr_next_block,5'd0}<rdr_row_base+rdr_row_bytes) :
                                          (rdr_pix+rdr_pixels_to_boundary<rdr_npix);
                rdr_prefetch_armed<=1;
                // A descriptor may track a presented request before ready.
                // Once accepted, pending blocks every following demand and
                // prefetch, so these fields stay held until the owned return.
                // A withdrawn unaccepted request has no response to consume.
                // This keeps ready/hazard logic out of the metadata CE path.
                if((A4_REQUEST_TRACK!=0)?rdr_req:rdr_mem_issue) begin
                    rdr_request_base<=rdr_prefetch_req?rdr_next_block:rdr_source_addr[BLOG-1:5];
                    rdr_request_offset<=rdr_source_addr[4:0];rdr_pending_prefetch<=rdr_prefetch_req;
                end
                if(rdr_replay) begin
                    rdr_pixel_hold<=rdr_selected_block>>(rdr_source_addr[4:0]*8);
                    if(rdr_prefetch_hit) begin
                        rdr_active_bank<=~rdr_active_bank;rdr_block_base<=rdr_prefetch_tag;rdr_block_valid<=1;
                        rdr_prefetch_next<=rdr_prefetch_tag+1'b1;rdr_prefetch_armed<=0;
                        rdr_prefetch_valid<=0;
                    end
                end
                if(rdr_mem_return) begin
                    if(rdr_active_bank ^ rdr_pending_prefetch) rdr_block1<=mem_rda_data;
                    else rdr_block<=mem_rda_data;
                end
                if(rdr_mem_return && rdr_pending_prefetch) begin
                    rdr_prefetch_tag<=rdr_request_base;rdr_prefetch_valid<=1;
                end
                if(rdr_demand_return) begin
                    rdr_block_base<=rdr_request_base;rdr_block_valid<=1;
                    rdr_prefetch_next<=rdr_request_base+1'b1;rdr_prefetch_armed<=0;
                    rdr_pixel_hold<=mem_rda_data>>(rdr_request_offset*8);
                end
            end
            if (rdr_issue) begin
                rdr_pix <= rdr_pix + 32'd1;
                if(!virtual_up) rdr_source_addr<=rdr_source_addr+rdr_cin;
                else if(rdr_col+1==l_w) begin
                    if(rdr_row[0]) begin rdr_row_base<=rdr_row_base+rdr_row_bytes;rdr_source_addr<=rdr_row_base+rdr_row_bytes;end
                    else rdr_source_addr<=rdr_row_base;
                end else if(rdr_col[0]) rdr_source_addr<=rdr_source_addr+rdr_cin;
                if(rdr_col+1==l_w) begin rdr_col<=0;rdr_row<=rdr_row+1'b1;end
                else rdr_col<=rdr_col+1'b1;
            end
            case ({rdr_mem_issue, rdr_mem_return})
                2'b10: rdr_pending <= 1'b1;
                2'b01: rdr_pending <= 1'b0;
                2'b11: rdr_pending <= 1'b1;
                default: rdr_pending <= rdr_pending;
            endcase
            case ({rdr_return, rdr_consume})
                2'b10: rdr_data_valid <= 1'b1;
                2'b01: rdr_data_valid <= 1'b0;
                2'b11: rdr_data_valid <= 1'b1;
                default: rdr_data_valid <= rdr_data_valid;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) if(rst_n && A4_FUSION!=0 && (st==S_UPGO || st==S_UPRUN || st==S_THGO || st==S_THRUN))
        $fatal(1,"fused profile entered standalone upsample/tanh state");
    always @(posedge clk) if(dp_rst_n && rdr_en) begin
        if(rdr_mem_issue && rdr_pending) $fatal(1,"reader issued over an outstanding request");
        if(rdr_mem_return && !rdr_pending) $fatal(1,"reader received an unowned response");
        if(rdr_demand_return && rdr_replay) $fatal(1,"two pixels returned into one reader slot");
        if(rdr_mem_issue && rdr_prefetch_req && virtual_up &&
           rdA_addr>=rdr_row_base+rdr_row_bytes) $fatal(1,"prefetch crossed an upsample source row");
    end
`endif

    //========================================================================
    //  window cache (inactive groups forced to 0 so no X leaks in)
    //========================================================================
    wire [CING_MAX*DWIN-1:0] wc_wr_bundle;
    wire             wc_wr_valid, wc_wr_ready, wc_wr_busy, wc_flush;
    wire wc_release,wc_read_bank;
    localparam integer WC_AW=(A4_TILE_PREFETCH!=0)?6:5;
    wire [WC_AW:0] wc_count;

    wire [FRAME_PIXEL_W-1:0] wc_rd_addr;
    wire [WC_AW-1:0] wc_read_pixel=wc_rd_addr[WC_AW-1:0]+((wc_read_bank)?T:0);
    wire [FRAME_PIXEL_W-1:0] wc_cig_sel;
    wire [DWIN-1:0]  wc_rd_group;

    generate
        for (gc = 0; gc < CING_MAX; gc = gc + 1) begin : G_PACK
            assign wc_wr_bundle[gc*DWIN +: DWIN] =
                (gc < rdr_cing) ? lb_wdata[gc] : {DWIN{1'b0}};
        end
    endgenerate

    win_cache #(.ACTIVE_GROUPS(A4_MODE), .CING(CING_MAX), .DW(DWIN), .DEPTH((A4_TILE_PREFETCH!=0)?2*T:T), .AW(WC_AW), .GW(CIG_W), .RING(A4_TILE_PREFETCH)) u_wc (
        .clk(clk), .rst_n(dp_rst_n),
        .wr_valid(wc_wr_valid), .wr_ready(wc_wr_ready), .wr_bundle(wc_wr_bundle),
        .cfg_cing(rdr_cing[CIG_W:0]),
        .flush(wc_flush), .release_tile(wc_release), .release_pixels((WC_AW+1)'(T)),
        .rd_addr(wc_read_pixel), .cig_sel(wc_cig_sel[CIG_W-1:0]),
        .rd_group(wc_rd_group), .rd_valid(),
        .count(wc_count), .full(), .empty(), .wr_busy(wc_wr_busy)
    );

    //========================================================================
    //  weights / mac / acc
    //========================================================================
    wire              wm_ld_req, wm_ld_sel, wm_ld_busy, wm_ld_done, wm_sel_buf;
    wire [31:0]       wm_ld_base;
    wire [P_CO*P_CI*9*8-1:0] wm_wdata;
    wire mac_valid;
    localparam MAIN_MAC_INPUT_PIPE=(A4_MODE!=0 && A4_STREAM!=0);
    reg wm_sel_delayed;
    always @(posedge clk or negedge dp_rst_n)
        if(!dp_rst_n)wm_sel_delayed<=0;else wm_sel_delayed<=wm_sel_buf;
    wire main_mac_valid;
    wire [DWIN-1:0] main_mac_window;
    generate if(MAIN_MAC_INPUT_PIPE)begin:G_MAC_WINDOW_PIPE
        reg valid_q;reg [DWIN-1:0] window_q;
        always @(posedge clk)window_q<=wc_rd_group;
        always @(posedge clk or negedge dp_rst_n)
            if(!dp_rst_n)valid_q<=0;else valid_q<=mac_valid;
        assign main_mac_valid=valid_q;assign main_mac_window=window_q;
    end else begin:G_MAC_WINDOW_DIRECT
        assign main_mac_valid=mac_valid;assign main_mac_window=wc_rd_group;
    end endgenerate

    weight_mgr #(.BRAM_PREFIX_BYTES(MAIN_MAC_INPUT_PIPE?32:0),.P_CO(P_CO), .P_CI(P_CI), .TAP(9), .CH_W(8), .RD_B(32)) u_wm (
        .clk(clk), .rst_n(dp_rst_n),
        .mem_addr(wm_addr), .mem_req(wm_mem_req),
        .mem_ready(wm_mem_ready), .mem_valid(wm_mem_valid),
        .mem_rdata(mem_rdata),
        .ld_req(wm_ld_req), .ld_base(wm_ld_base), .ld_sel(wm_ld_sel),
        .ld_busy(wm_ld_busy), .ld_done(wm_ld_done),
        .sel_buf_early(wm_sel_buf),.sel_buf(MAIN_MAC_INPUT_PIPE?wm_sel_delayed:wm_sel_buf), .w_data(wm_wdata)
    );


    wire                  mac_out_valid;
    wire [P_CO*ACC_W-1:0] mac_out_sum;
    // Layer 0 issues 3072 MAC transactions in one statistics pass.  Keep the
    // diagnostic counters wide enough that they cannot wrap at 256 and make a
    // later tile look like the first-pixel events 0/32/64/96 again.
    reg  [15:0]           debug_mac_event;
    reg  [15:0]           debug_mac_input_event;

    // Optional one-shot capture for the Efinity VIO debugger. Reading these
    // five registers does not require a Logic Analyzer trace buffer (and
    // therefore avoids consuming another block RAM).  syn_preserve/syn_keep
    // retain the names when MAC diagnostics are explicitly enabled. Default
    // builds may prune unused snapshots to leave logic for packet coalescing.
    (* syn_preserve = DEBUG_CHECK_LAYER0_MAC, syn_keep = DEBUG_CHECK_LAYER0_MAC *) reg        dbg_mac0_captured;
    (* syn_preserve = DEBUG_CHECK_LAYER0_MAC, syn_keep = DEBUG_CHECK_LAYER0_MAC *) reg signed [31:0] dbg_mac0_sum0;
    (* syn_preserve = DEBUG_CHECK_LAYER0_MAC, syn_keep = DEBUG_CHECK_LAYER0_MAC *) reg signed [31:0] dbg_mac0_sum1;
    (* syn_preserve = DEBUG_CHECK_LAYER0_MAC, syn_keep = DEBUG_CHECK_LAYER0_MAC *) reg signed [31:0] dbg_mac0_sum2;
    (* syn_preserve = DEBUG_CHECK_LAYER0_MAC, syn_keep = DEBUG_CHECK_LAYER0_MAC *) reg signed [31:0] dbg_mac0_sum3;
    (* syn_preserve = DEBUG_CHECK_LAYER0_MAC, syn_keep = DEBUG_CHECK_LAYER0_MAC *) reg        dbg_mac_fail_captured;
    (* syn_preserve = DEBUG_CHECK_LAYER0_MAC, syn_keep = DEBUG_CHECK_LAYER0_MAC *) reg [7:0]  dbg_mac_fail_event;

    always @(posedge clk or negedge dp_rst_n) begin
        if(!dp_rst_n) begin
            stream_px1<=0;stream_px2<=0;stream_px3<=0;stream_px4<=0;
            stream_cog1<=0;stream_cog2<=0;stream_cog3<=0;stream_cog4<=0;stream_emit_valid<=0;
        end else begin
            stream_emit_valid<={stream_emit_valid[2:0],mac_valid && cf_mac_emit};
            if(mac_valid) begin stream_px1<=cf_mac_global;stream_cog1<=cf_mac_cog;end
            stream_px2<=stream_px1;stream_px3<=stream_px2;stream_px4<=stream_px3;
            stream_cog2<=stream_cog1;stream_cog3<=stream_cog2;stream_cog4<=stream_cog3;
        end
    end
    mac_array #(.DUAL_DSP(A4_MODE), .STABLE_WEIGHTS(A4_MODE), .DSP_CASCADE_PAIRS(4), .P_CO(P_CO), .P_CI(P_CI), .TAP(9), .CH_W(8), .ACC_W(ACC_W),
                .PIPE(1)) u_mac (
        .clk(clk), .rst_n(dp_rst_n), .in_valid(main_mac_valid),
        .win_data(main_mac_window), .w_data(wm_wdata),
        .out_valid(mac_out_valid), .out_sum(mac_out_sum)
    );

    wire                  acc_clr;
    wire [FRAME_PIXEL_W-1:0] clr_px, mac_px, rd_px;
    reg  [4:0]            mac_px_d,mac_px_dd;
    wire mac_first;reg mac_first_d,mac_first_dd;

    always @(posedge clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin mac_px_d<=0;mac_px_dd<=0;mac_first_d<=0;mac_first_dd<=0;end
        else begin mac_px_d<=mac_px[4:0];mac_px_dd<=mac_px_d;mac_first_d<=mac_first;mac_first_dd<=mac_first_d;end
    end

    acc_bank #(.OVERWRITE(A4_STREAM),.STORE_W((A4_MODE!=0)?24:ACC_W), .P_PX(T), .P_CO(P_CO), .ACC_W(ACC_W), .PXW(5), .COW(PCO_W)) u_acc (
        .clk(clk), .rst_n(dp_rst_n),
        .clr_valid(acc_clr), .clr_px(clr_px[4:0]),
        .acc_valid(mac_out_valid), .acc_overwrite(MAIN_MAC_INPUT_PIPE?mac_first_dd:mac_first_d), .acc_px(MAIN_MAC_INPUT_PIPE?mac_px_dd:mac_px_d), .acc_sum(mac_out_sum),
        .rd_px(rd_px[4:0]), .rd_data(acc_rd_data),
        .commit_valid(acc_commit_valid),.committed_sum(acc_committed_sum)
    );

    //========================================================================
    //  emit synchronisation pipeline (1 cycle)
    //
    //  Measured facts (DBG_PH probe):
    //    ? conv_fsm asserts pp_valid in the SAME cycle as rd_px
    //    ? acc_bank's wide read is REGISTERED, so acc_rd_data lags rd_px by
    //      1 cycle
    //  Therefore both the statistics tap and the frame write must use the
    //  emit strobe and the pixel index DELAYED BY ONE CYCLE, otherwise every
    //  value is read/written one pixel early.
    //
    //  This also removes the need for the old pp_cnt restart-on-cog-change
    //  logic, which was found to restart spuriously (the write pixel index now
    //  comes straight from rd_px, which conv_fsm already provides).
    //========================================================================
    wire              pp_in_valid;      // conv_fsm emit strobe (same cycle as rd_px)
    // the emit strobe is COMBINATIONAL (assigned in the sequencer section,
    // where the state encoding is visible); only the pixel index and the cog
    // are delayed by one cycle
    wire              em_v;
    // NOTE: the pixel index must hold a WHOLE FRAME's index (up to W*H), not
    // just a tile index.  Declaring these 5 bits silently wrapped every 32
    // pixels and corrupted the frame.
    reg  [31:0]       em_px;            // frame-global pixel index, delayed 1 cycle
    reg  [7:0]        em_cog;           // cog delayed 1 cycle
    // Original tag stage, followed by two extra stages for postproc PIPE=3.
    reg               em_vd;            // em_v delayed 1 cycle
    reg  [31:0]       em_px2;           // rd_px delayed 2 cycles
    reg  [7:0]        em_cog2;          // cog delayed 2 cycles
    reg [31:0] em_px3, em_px4;
    reg [7:0] em_cog3, em_cog4;
    reg [2:0] pp_inflight;
    reg final_pp_valid;reg [31:0] final_pixel;reg [7:0] final_cog;
    wire              pp_valid;
    wire pp_pending = final_pp_valid || pp_in_valid || (|pp_inflight) || pp_valid || (stream_emit && ((|stream_emit_valid) || (mac_valid && cf_mac_emit)));
    assign pp_in_valid=stream_emit ? (acc_commit_valid && stream_emit_valid[MAIN_MAC_INPUT_PIPE?3:2]) : cf_pp_valid;
    // Tags advance with the three postproc registers, not with AXI ready.
    always @(posedge clk or negedge dp_rst_n) begin
        if (!dp_rst_n) begin
            em_px3<=0; em_px4<=0; em_cog3<=0; em_cog4<=0;
            pp_inflight<=0;
        end else begin
            em_px3<=em_px2; em_px4<=em_px3;
            em_cog3<=em_cog2; em_cog4<=em_cog3;
            pp_inflight<={pp_inflight[1:0],pp_in_valid};
        end
    end
    reg               pp_relu;
    wire [P_CO*8-1:0] pp_out_data;
    wire [P_CO*A_W-1:0] ct_a_vec;
    wire [P_CO*B_W-1:0] ct_b_vec;
    reg  [P_CO*ACC_W-1:0] acc_s_d;

    postproc #(.P_RD(P_CO), .ACC_W(ACC_W), .A_W(A_W), .B_W(B_W), .SA(SA),
               .SAT_MIN(-127), .SAT_MAX(127), .ROUND_EVEN(A4_MODE), .SHIFT_ONLY(A4_MODE), .SHIFT_ACC_W(A4_MODE!=0?22:ACC_W), .PIPE(3)) u_pp (
        .clk(clk), .rst_n(dp_rst_n), .in_valid(pp_in_valid),
        .acc_in(acc_s), .a_mul(ct_a_vec), .b_add(ct_b_vec), .relu_en(pp_relu),
        .out_valid(pp_valid), .out_data(pp_out_data)
    );

    //========================================================================
    //  statistics
    //========================================================================
    reg  ar_clr;
    wire [COUT_MAX*48-1:0] ar_s1;
    wire [COUT_MAX*56-1:0] ar_s2;
    wire [7:0] cf_cog;
    // lane_base = output-channel-group index * P_CO.
    // P_CO is a power of two, so this stays a constant shift rather than a multiplier.
    wire [4:0] ar_lane = em_cog[4:0] << PCO_W;

    // Bit-exact layer-0 statistics from net_vectors/net_stat.txt.  Checking
    // these after pass 0 avoids involving coefficient generation, postproc,
    // ReLU, DDR write ordering, or the diagnostic acc_s stream itself.
    wire layer0_stats_match =
        ($signed(ar_s1[0*48 +: 48]) ==  48'sd5995)   &&
        ($signed(ar_s1[1*48 +: 48]) == -48'sd115973) &&
        ($signed(ar_s1[2*48 +: 48]) == -48'sd20978)  &&
        ($signed(ar_s1[3*48 +: 48]) == -48'sd112899) &&
        ($signed(ar_s1[4*48 +: 48]) == -48'sd52037)  &&
        ($signed(ar_s1[5*48 +: 48]) ==  48'sd165883) &&
        ($signed(ar_s1[6*48 +: 48]) == -48'sd8173)   &&
        ($signed(ar_s1[7*48 +: 48]) == -48'sd20756)  &&
        (ar_s2[0*56 +: 56] == 56'd106642801) &&
        (ar_s2[1*56 +: 56] == 56'd150866475) &&
        (ar_s2[2*56 +: 56] == 56'd105689370) &&
        (ar_s2[3*56 +: 56] == 56'd76543039)  &&
        (ar_s2[4*56 +: 56] == 56'd70913247)  &&
        (ar_s2[5*56 +: 56] == 56'd125487371) &&
        (ar_s2[6*56 +: 56] == 56'd95275569)  &&
        (ar_s2[7*56 +: 56] == 56'd141153564);

    wire layer0_px0_acc_match =
        (em_cog == 8'd0) ?
          (($signed(acc_rd_data[0*ACC_W +: ACC_W]) ==  32'sd5088) &&
           ($signed(acc_rd_data[1*ACC_W +: ACC_W]) == -32'sd657)  &&
           ($signed(acc_rd_data[2*ACC_W +: ACC_W]) ==  32'sd7681) &&
           ($signed(acc_rd_data[3*ACC_W +: ACC_W]) == -32'sd8276)) :
        (em_cog == 8'd1) ?
          (($signed(acc_rd_data[0*ACC_W +: ACC_W]) == -32'sd9399) &&
           ($signed(acc_rd_data[1*ACC_W +: ACC_W]) == -32'sd6540) &&
           ($signed(acc_rd_data[2*ACC_W +: ACC_W]) ==  32'sd8045) &&
           ($signed(acc_rd_data[3*ACC_W +: ACC_W]) ==  32'sd13535)) : 1'b1;

    wire layer0_px0_shift_match =
        (em_cog == 8'd0) ?
          (($signed(acc_s[0*ACC_W +: ACC_W]) ==  32'sd159) &&
           ($signed(acc_s[1*ACC_W +: ACC_W]) == -32'sd21)  &&
           ($signed(acc_s[2*ACC_W +: ACC_W]) ==  32'sd240) &&
           ($signed(acc_s[3*ACC_W +: ACC_W]) == -32'sd259)) :
        (em_cog == 8'd1) ?
          (($signed(acc_s[0*ACC_W +: ACC_W]) == -32'sd294) &&
           ($signed(acc_s[1*ACC_W +: ACC_W]) == -32'sd205) &&
           ($signed(acc_s[2*ACC_W +: ACC_W]) ==  32'sd251) &&
           ($signed(acc_s[3*ACC_W +: ACC_W]) ==  32'sd422)) : 1'b1;

    // acc_s has already been arithmetically shifted by this layer's sh_r.
    // Keep acc_reduce_w's internal shift at zero to avoid a second shift and
    // make statistics use the same per-layer scaling as post-processing.
    generate if (A4_MODE == 0) begin : G_LEGACY_STATS
    acc_reduce_w #(.P_CO(P_CO), .COUT_MAX(COUT_MAX), .ACC_W(ACC_W), .SH(0),
                   .S1_W(48), .S2_W(56), .LW(5)) u_ar (
        .clk(clk), .rst_n(rst_n),
        .clear(ar_clr), .in_valid(em_v),
        .lane_base(ar_lane),
        .acc_in(acc_s),
        .s1_out(ar_s1), .s2_out(ar_s2)
    );
    end else begin : G_NO_STATS
        assign ar_s1 = 0; assign ar_s2 = 0;
    end endgenerate

    //========================================================================
    //  coefficients
    //========================================================================
    reg                   nc_start;
    reg  [47:0]           nc_s1;
    reg  [55:0]           nc_s2;
    reg  [19:0]           nc_n;
    reg  signed [A_W-1:0] nc_ga, nc_be;
    wire                  nc_out_valid;
    wire signed [A_W-1:0] nc_a;
    wire signed [B_W-1:0] nc_b;

    generate if (A4_MODE == 0) begin : G_LEGACY_NORM
    norm_coeff #(.SA(SA), .R(18), .K(5), .FM(22), .T_W(NORM_T_W), .S1_W(48),
                 .S2_W(56), .NW(20), .A_W(A_W), .B_W(B_W), .T_MIN(1)) u_nc (
        .clk(clk), .rst_n(rst_n),
        .start(nc_start), .s1_in(nc_s1), .s2_in(nc_s2), .n_in(nc_n),
        .gamma_fp(nc_ga), .beta_fp(nc_be),
        .out_valid(nc_out_valid), .a_out(nc_a), .b_out(nc_b), .busy(),
        .t_out(), .sh_out()
    );
    end else begin : G_NO_NORM
        assign nc_out_valid = 1'b0; assign nc_a = 0; assign nc_b = 0;
    end endgenerate

    reg                   ct_we;
    reg  [CT_AW-1:0]      ct_waddr;
    reg  [PCO_W-1:0]      ct_wch;
    reg  signed [A_W-1:0] ct_wa;
    reg  signed [B_W-1:0] ct_wb;
    reg  [CT_AW-1:0]      ct_raddr;

    coeff_table #(.P_CO(P_CO), .A_W(A_W), .B_W(B_W),
                  .AW(CT_AW), .CW(PCO_W), .DEPTH(CT_DEPTH)) u_ct (
        .clk(clk), .rst_n(rst_n),
        .we(ct_we), .waddr(ct_waddr), .wch(ct_wch), .wa(ct_wa), .wb(ct_wb),
        .raddr(ct_raddr), .a_vec(ct_a_vec), .b_vec(ct_b_vec)
    );

    //========================================================================
    //  conv_fsm
    //========================================================================
    reg          cf_start;
    reg  [15:0]  cf_cin, cf_cout, cf_h, cf_w;
    reg  [1:0]   cf_stride;
    reg  [31:0]  cf_wbase;
    wire         cf_busy, cf_done;
    wire         cf_pp_ready;
    wire [7:0]   cf_coeff_raddr;
    wire [FRAME_PIXEL_W-1:0] cf_pxglobal;
    wire         cf_stat_valid;

    conv_fsm #(.P_CI(P_CI), .P_CO(P_CO), .TAP(9), .CH_W(8), .RD_B(32), .T(T),
               .A4_FIXED_GEOMETRY((A4_MODE!=0 && P_CI==4 && P_CO==4)?1:0),
               .A4_FULL_W(32*IMAGE_SCALE),.A4_FULL_H(24*IMAGE_HEIGHT_SCALE),.ELASTIC_WINDOW_INPUT(A4_MODE),
               .PREFETCH(WEIGHT_PREFETCH), .TILE_PREFETCH(A4_TILE_PREFETCH), .CLEAR_ELIDE(A4_STREAM), .STREAM_EMIT(A4_STREAM_EMIT), .RESIDENT_WEIGHTS(A4_MODE), .REGISTER_BOUNDARY_FLAGS(A4_MODE),.GW(FRAME_PIXEL_W)) u_cf (
        .clk(clk), .rst_n(dp_rst_n), .start(cf_start),
        .cfg_cin(cf_cin), .cfg_cout(cf_cout), .cfg_h(cf_h), .cfg_w(cf_w),
        .cfg_stride(cf_stride), .cfg_wbase(cf_wbase),
        .busy(cf_busy), .done(cf_done),
        .lb_win_valid(lb_wvalid[0]), .lb_stall(lb_stall),
        .lb_cfg_w(lb_cfg_w), .lb_cfg_h(lb_cfg_h), .lb_cfg_stride(lb_cfg_stride),
        .wc_wr_valid(wc_wr_valid), .wc_wr_ready(wc_wr_ready), .wc_wr_busy(wc_wr_busy), .wc_flush(wc_flush),
        .wc_rd_addr(wc_rd_addr), .wc_cig_sel(wc_cig_sel),
        .wc_count({{(FRAME_PIXEL_W-WC_AW){1'b0}},wc_count}), .wc_release(wc_release), .wc_read_bank(wc_read_bank),
        .wm_ld_req(wm_ld_req), .wm_ld_base(wm_ld_base), .wm_ld_sel(wm_ld_sel),
        .wm_ld_done(wm_ld_done), .wm_ld_busy(wm_ld_busy), .wm_sel_buf(wm_sel_buf),
        .acc_clr(acc_clr), .clr_px(clr_px), .mac_px(mac_px), .rd_px(rd_px),
        .px_global(cf_pxglobal),
        .mac_valid(mac_valid), .mac_first(mac_first),.mac_emit(cf_mac_emit),.mac_global(cf_mac_global),.mac_cog(cf_mac_cog), .pp_valid(cf_pp_valid), .pp_ready(cf_pp_ready),
        .out_row(), .out_col(),
        .stat_valid(cf_stat_valid), .coeff_raddr(cf_coeff_raddr)
    );
    assign cf_cog = cf_coeff_raddr;

    //========================================================================
    //  tanh engine
    //========================================================================
    wire         th_valid_i;   // asserted with the one-cycle synchronous read result
    wire         th_valid_o;
    wire [63:0]  th_px_o;
    // NOTE: read port B, not A.  Port A belongs to the tile reader
    // (`rdA_addr = rdr_pix * rdr_cin`); using it here made the tanh engine read
    // whatever the reader happened to be addressing instead of its own pixel.
    wire [63:0]  rdB_th;

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : G_TH
            assign rdB_th[b*8 +: 8] =
                (b < 3) ? rdB_data[b*8 +: 8] : 8'd0;
        end
    endgenerate

    generate if(A4_FUSION==0) begin : G_STANDALONE_TANH
    tanh #(.A4_MODE(A4_MODE), .C(8), .IW(8), .OW(8)) u_th (
        .clk(clk), .rst_n(dp_rst_n),
        .in_valid(th_valid_i), .in_px(rdB_th),
        .out_valid(th_valid_o), .out_px(th_px_o)
    );

    end else begin : G_NO_STANDALONE_TANH
        assign th_valid_o=0; assign th_px_o=0;
    end endgenerate

    //========================================================================
    //  residual add engine: 32 int8 channels -> int16 sum -> int8 requantise
    //========================================================================
    wire        ra_valid_o;
    wire        ra_pipe_ready;
    wire        ra_pipe_mode=A4_RESIDUAL_PIPE!=0 && A4_MODE!=0 && A4_RESIDUAL_FAST!=0 &&
                            A4_RESIDUAL_REPLAY!=0 && USE_DDR!=0 && l_rc==4;
    wire        ra_pipe_next=ra_pipe_mode && ra_phase==5 && ra_valid_o &&
                            ra_pix[2:0]!=7 && ra_pix+1<l_pixels && ra_pipe_ready;
    wire        ra_valid_i = ra_pipe_mode ? ((ra_phase==4 && ra_pipe_ready) || ra_pipe_next) : ra_data_valid;
    wire        ra_queue_ready;
    localparam integer AUX_C = (A4_MODE != 0) ? 4 : 32;
    wire [AUX_C*16-1:0] ra_sum;
    wire [32*8-1:0]  ra_q;
    wire [AUX_C*8-1:0] ra_x_input,ra_f_input;
    generate if(AUX_C==4)begin:G_RA_REPLAY_INPUT
        assign ra_x_input=ra_pipe_next?ra_x_hold[63:32]:ra_x_hold[31:0];
        assign ra_f_input=ra_pipe_next?ra_f_hold[63:32]:ra_f_hold[31:0];
    end else begin:G_RA_LEGACY_INPUT
        assign ra_x_input=ra_x_hold[AUX_C*8-1:0];assign ra_f_input=ra_f_hold[AUX_C*8-1:0];
    end endgenerate

    residual_add #(.C(AUX_C), .IN_W(8), .OUT_W(16), .SH(0)) u_ra (
        .clk(clk), .rst_n(dp_rst_n),
        .in_valid(ra_valid_i), .x_px(ra_x_input), .f_px(ra_f_input),
        .out_valid(ra_valid_o), .out_px(ra_sum),
        .sh_valid(), .sh_px()
    );

    function signed [7:0] ra_narrow;
        input signed [15:0] v;
        input        [7:0]  sh;
        reg signed [16:0] t;
        begin
            t = v;
            if (sh != 0)
                t = ($signed(v) + (17'sd1 <<< (sh - 1))) >>> sh;
            if (t > 17'sd127)       ra_narrow = 8'sd127;
            else if (t < -17'sd127) ra_narrow = -8'sd127;
            else                    ra_narrow = t[7:0];
        end
    endfunction

    genvar rch;
    generate
        for (rch = 0; rch < AUX_C; rch = rch + 1) begin : G_RA_Q
            assign ra_q[rch*8 +: 8] =
                ra_narrow($signed(ra_sum[rch*16 +: 16]), l_sh);
        end
        if (AUX_C < 32) assign ra_q[255:AUX_C*8] = 0;
    endgenerate


    //========================================================================
    //  nearest-neighbour x2 upsample engine
    //========================================================================
    wire up_rst_n = rst_n && ((st == S_UPGO) || (st == S_UPRUN));
    wire up_in_ready, up_valid_o, up_out_ready;
    wire [32*8-1:0] up_px_o;
    wire [AUX_C*8-1:0] up_px_small;
    assign up_px_o = {{(256-AUX_C*8){1'b0}}, up_px_small};
    wire up_valid_i = up_data_valid;
    assign up_consume = up_data_valid && up_in_ready;
    assign up_req = (A4_FUSION==0) && (st == S_UPRUN) && (up_pix < l_pixels) &&
                    !up_pending && (!up_data_valid || up_consume);

    assign rdA_en = (st == S_RARUN) ? ra_a_req :
                    (A4_FUSION==0 && st == S_UPRUN) ? up_req : rdr_req;
    assign rdB_en = (st == S_RARUN) ? ra_b_req :
                    (A4_FUSION==0 && st == S_THRUN) ? th_req : 1'b0;
    wire rdA_fire = rdA_en && mem_rda_ready;
    wire rdB_fire = rdB_en && mem_rdb_ready;
    assign rdr_mem_issue = rdr_req && mem_rda_ready;
    // The pending demand descriptor holds source coordinates until its
    // data returns. No following demand can issue while it is pending.
    // Advancing both the byte address and pixel count on return therefore
    // preserves the next replay address, without a cache-ready path to CE.
    assign rdr_issue = (A4_RETURN_ADVANCE!=0 && A4_MODE!=0 && USE_DDR!=0)?
        rdr_return:((rdr_mem_issue && !rdr_prefetch_req) || rdr_replay);
    assign th_issue  = th_req && mem_rdb_ready;
    assign ra_issue  = ra_a_req && mem_rda_ready;
    assign up_issue  = up_req && mem_rda_ready;
    wire th_data_valid = (st == S_THRUN) && mem_rdb_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            th_pending <= 1'b0;
            ra_data_valid <= 1'b0;
            up_data_valid <= 1'b0;
            up_pending <= 1'b0;
            ra_phase <= 3'd0;
            ra_x_hold <= 256'd0;
            ra_f_hold <= 256'd0;
        end else begin
            ra_data_valid <= 1'b0;

            if (st != S_THRUN) begin
                th_pending <= 1'b0;
            end else begin
                case ({th_issue, mem_rdb_valid})
                    2'b10: th_pending <= 1'b1;
                    2'b01: th_pending <= 1'b0;
                    2'b11: th_pending <= 1'b1;
                    default: th_pending <= th_pending;
                endcase
            end

            if (st != S_UPRUN)
            begin
                up_data_valid <= 1'b0;
                up_pending <= 1'b0;
            end
            else begin
                case ({up_issue, mem_rda_valid})
                    2'b10: up_pending <= 1'b1;
                    2'b01: up_pending <= 1'b0;
                    2'b11: up_pending <= 1'b1;
                    default: up_pending <= up_pending;
                endcase
                case ({mem_rda_valid, up_consume})
                    2'b10: up_data_valid <= 1'b1;
                    2'b01: up_data_valid <= 1'b0;
                    2'b11: up_data_valid <= 1'b1;
                    default: up_data_valid <= up_data_valid;
                endcase
            end

            if (st != S_RARUN) begin
                ra_phase <= 3'd0;
            end else begin
                case (ra_phase)
                    3'd0: if (ra_pix < l_pixels) begin
                        if (ra_replay) begin
                            ra_x_hold <= ra_x_hold >> 32;
                            ra_phase <= 3'd2;
                        end else if (rdA_fire) ra_phase <= 3'd1;
                    end
                    3'd1: if (mem_rda_valid) begin
                        ra_x_hold <= mem_rda_data;
                        ra_phase <= 3'd2;
                    end
                    3'd2: if (ra_replay) begin
                        ra_f_hold <= ra_f_hold >> 32;
                        ra_phase <= 3'd4;
                    end else if (rdB_fire) ra_phase <= 3'd3;
                    3'd3: if (mem_rdb_valid) begin
                        ra_f_hold <= mem_rdb_data;
                        ra_phase <= 3'd4;
                    end
                    3'd4: if(ra_pipe_mode)begin
                        if(ra_pipe_ready)ra_phase<=3'd5;
                    end else if (((A4_RESIDUAL_FAST!=0)?ra_queue_ready:!wr_en) && !ra_valid_o) begin
                        ra_data_valid<=1'b1;ra_phase<=3'd5;
                    end
                    3'd5: if (ra_valid_o) begin
                        if(A4_RESIDUAL_FAST!=0 && A4_RESIDUAL_REPLAY!=0 &&
                           USE_DDR!=0 && l_rc==4 && ra_pix[2:0]!=7 && ra_pix+1<l_pixels) begin
                            // The current registered sum is already retired.
                            // Prepare the next cached pair together; no DDR read
                            // or separate X/F shift phases are needed within it.
                            ra_x_hold<=ra_x_hold>>32;ra_f_hold<=ra_f_hold>>32;
                            ra_phase<=ra_pipe_next?3'd5:3'd4;
                        end else ra_phase<=3'd0;
                    end
                    default: ra_phase <= 3'd0;
                endcase
            end
        end
    end

    generate if(A4_FUSION==0) begin : G_STANDALONE_UP
    upsample #(.C(AUX_C), .CH_W(8), .MAX_W(UP_ROW_W), .AW($clog2(UP_ROW_W))) u_up (
        .clk(clk), .rst_n(up_rst_n),
        .cfg_w(l_w), .cfg_h(l_h),
        .in_valid(up_valid_i), .in_ready(up_in_ready), .in_px(rdA_data[AUX_C*8-1:0]),
        .out_valid(up_valid_o), .out_ready(up_out_ready), .out_px(up_px_small),
        .out_row(), .out_col(), .busy(), .done()
    );

    end else begin : G_NO_STANDALONE_UP
        assign up_in_ready=0; assign up_valid_o=0; assign up_px_small=0;
    end endgenerate


    //========================================================================
    //  Data-only A4 / 8-entry legacy queue; reservations throttle the producer
    //========================================================================
    localparam integer WRQ_AW=(A4_STREAM!=0)?A4_WRITE_QUEUE_LOG2:3;
    localparam integer WRQ_DEPTH=1<<WRQ_AW;
    localparam integer WRQ_DATA_W=(A4_STREAM!=0 && DEBUG_WRITE_ACC_S==0)?32:256;
    localparam integer WRQ_COMPACT=TAIL_ENABLE && A4_STREAM!=0 && DEBUG_WRITE_ACC_S==0;
    localparam integer WRQ_ADDR_W=WRQ_COMPACT?BLOG-2:BLOG;
    // Full tiles permit an exact address permutation for eight-channel layers:
    // each tile emits 32 pixels of group0, then 32 pixels of group1.
    // Keep the stored-address fallback for other geometries/configurations.
    localparam integer WRQ_LINEAR=WRQ_COMPACT && A4_IMPLICIT_QUEUE!=0 &&
        A4_MODE!=0 && P_CO==4 && T==32 && BLOG>8 &&
        ((8*IMAGE_SCALE)*(6*IMAGE_HEIGHT_SCALE))%32==0;
    wire [BLOG-3:0] wrq_read_word;
    reg [WRQ_AW-1:0] wrq_head,wrq_tail;
    reg [WRQ_AW:0] wrq_count,wrq_reserved;
    (* syn_ramstyle="logic" *) reg [1:0] wrq_bank_mem[0:WRQ_DEPTH-1];
    (* syn_ramstyle="logic" *) reg [WRQ_ADDR_W-1:0] wrq_addr_mem[0:WRQ_DEPTH-1];
    wire [WRQ_DATA_W-1:0] wrq_payload;
    (* syn_ramstyle="logic" *) reg [5:0] wrq_n_mem[0:WRQ_DEPTH-1];
    reg [1:0] push_bank;
    reg [BLOG-1:0] push_addr;
    reg [255:0] push_data;
    reg [5:0] push_n;
    wire [23:0] fused_rgb;
    genvar fc;
    generate for(fc=0;fc<3;fc=fc+1) begin : G_OUTPUT_TANH
        if(A4_FUSION!=0) begin : G_FUSED
            tanh_lut #(.A4_MODE(1), .RUNTIME_MODEL(RUNTIME_MODEL), .CLOCKED(1), .CLOCK_ENABLE(TAIL_ENABLE), .CH_ID(fc)) u_lut(
                .clk(clk),.cfg_we(cfg_we && cfg_tanh),.cfg_index(cfg_index),.cfg_data(cfg_data[7:0]),
                .ce(row_tanh_ce),
                .idx((row_tail?row_output_data[fc*8 +: 8]:pp_out_data[fc*8 +: 8])+8'd128), .val(fused_rgb[fc*8 +: 8]));
        end else assign fused_rgb[fc*8 +: 8]=0;
    end endgenerate
    wire final_conv=(A4_FUSION!=0) && (li==11);
    always @(posedge clk or negedge dp_rst_n)begin
        if(!dp_rst_n)begin final_pp_valid<=0;final_pixel<=0;final_cog<=0;end
        else begin final_pp_valid<=pp_valid && final_conv;final_pixel<=em_px4;final_cog<=em_cog4;end
    end
    wire conv_write_result = (st == S_CFWAIT) && (phase == 2'd1) && (final_conv?final_pp_valid:pp_valid);
    wire th_write_result = (st == S_THRUN) && th_valid_o;
    wire ra_write_result = (st == S_RARUN) && ra_valid_o;
    wire up_write_result = (st == S_UPRUN) && up_valid_o;
    wire wrq_push=conv_write_result || th_write_result || ra_write_result || up_write_result;
    wire wrq_pop=wrq_valid && (row_feed?(row_active && row_input_ready):((A4_STREAM!=0)?mem_wr_ready:mem_wr_done));
`ifndef SYNTHESIS
    always @(posedge clk)if(rst_n && WRQ_COMPACT)begin
        if(wrq_push && (push_n!=4 || push_addr[1:0]!=0 || push_bank!=l_dst))
            $fatal(1,"compact feature queue received non-word payload");
        if(wrq_count!=0 && st==S_LD)$fatal(1,"layer changed with queued feature words");
    end
`endif
    // Compact feature words follow the fixed tiled/channel schedule per layer.
    // Keep only the read cursor in hardware; producer ordering is checked in
    // simulation. S_LD is reached only after the preceding queue has drained.
    generate if(WRQ_LINEAR)begin:G_LINEAR_QUEUE_CURSOR
        reg [BLOG-3:0] read_word;
        assign wrq_read_word=read_word;
        always @(posedge clk or negedge rst_n)begin
            if(!rst_n)read_word<=0;
            else if(st==S_LD)read_word<=0;
            else if(wrq_pop)read_word<=read_word+1'b1;
        end
`ifndef SYNTHESIS
        reg [BLOG-3:0] expected_write_word;
        wire [BLOG-1:0] expected_address=(l_rc==8)?
            {expected_write_word[BLOG-3:6],expected_write_word[4:0],expected_write_word[5],2'b0}:
            {expected_write_word,2'b0};
        always @(posedge clk or negedge rst_n)begin
            if(!rst_n)expected_write_word<=0;
            else if(st==S_LD)expected_write_word<=0;
            else if(wrq_push)begin
                if(push_addr!=expected_address)
                    $fatal(1,"implicit feature address mismatch got=%h expected=%h layer=%0d",push_addr,expected_address,li);
                expected_write_word<=expected_write_word+1'b1;
            end
        end
`endif
    end else begin:G_NO_LINEAR_QUEUE_CURSOR
        assign wrq_read_word=0;
    end endgenerate
    // pp_valid in conv_fsm is REGISTERED after pp_ready. Count its current
    // emission explicitly, as it has not yet entered wrq_reserved this edge.
    wire reserve_launch=(st == S_CFWAIT) && (phase == 2'd1) && (stream_emit ? (mac_valid && cf_mac_emit) : pp_in_valid);
    wire [WRQ_AW+1:0] wrq_used={1'b0,wrq_count}+{1'b0,wrq_reserved}+reserve_launch;
    generate if(A4_WRITE_QUEUE_BRAM!=0 && WRQ_DATA_W==32)begin:G_BRAM_WRITE_PAYLOAD
        sync_fwft_payload #(.WIDTH(32),.ADDR_WIDTH(WRQ_AW)) u_payload(.clk(clk),.rst_n(rst_n),
         .push(wrq_push),.pop(wrq_pop),.head(wrq_head),.tail(wrq_tail),.count(wrq_count),.push_data(push_data[31:0]),.head_data(wrq_payload));
    end else begin:G_LOGIC_WRITE_PAYLOAD
        (* syn_ramstyle="logic" *)reg [WRQ_DATA_W-1:0] data_mem[0:WRQ_DEPTH-1];
        always @(posedge clk)if(rst_n&&wrq_push)data_mem[wrq_tail]<=push_data;
        assign wrq_payload=data_mem[wrq_head];
    end endgenerate
    assign wrq_valid=(wrq_count!=0);
    assign wr_en=row_feed?row_output_valid:wrq_valid;
    wire [BLOG-1:0] queued_address;
    generate if(WRQ_LINEAR)begin:G_LINEAR_WRITE_ADDRESS
        assign queued_address=(l_rc==8)?
            {wrq_read_word[BLOG-3:6],wrq_read_word[4:0],wrq_read_word[5],2'b0}:
            {wrq_read_word,2'b0};
    end else if(WRQ_COMPACT)begin:G_COMPACT_WRITE_ADDRESS
        assign queued_address={wrq_addr_mem[wrq_head],2'b0};
    end else assign queued_address=wrq_addr_mem[wrq_head];endgenerate
    assign wr_bank=row_feed?(row_tail?2'd0:2'd2):WRQ_COMPACT?l_dst:wrq_bank_mem[wrq_head];
    assign wr_addr=row_feed?(row_tail?((row_output_index<<1)+row_output_index):(row_output_index<<2)):queued_address;
    assign wr_data_queue={{(256-WRQ_DATA_W){1'b0}},wrq_payload};
    assign wr_data=row_feed?(row_tail?{232'd0,fused_rgb}:{192'd0,row_output_data}):wr_data_queue;
    assign wr_n=row_feed?(row_tail?6'd3:6'd4):WRQ_COMPACT?6'd4:wrq_n_mem[wrq_head];
    assign ra_queue_ready=(wrq_count<WRQ_DEPTH);
    // Reserve space for both the result retiring now and the one being
    // launched. The existing one-cycle adder can then accept each cached pair.
    assign ra_pipe_ready=ra_valid_o?(wrq_count<WRQ_DEPTH-1):(wrq_count<WRQ_DEPTH);
    assign cf_pp_ready=(phase == 2'd0) ? 1'b1 : (wrq_used < WRQ_DEPTH);
    // Other engines retain the previously verified single-outstanding policy.
    assign up_out_ready=!wrq_valid && !up_valid_o;
    always @* begin
        push_bank=0;push_addr=0;push_data=0;push_n=0;
                if (conv_write_result) begin
                    push_bank = l_dst;
                    if (DEBUG_WRITE_ACC_S != 0) begin
                        // Pixel-major, channel-inner signed 32-bit words.
                        // Each output-channel group remains contiguous.
                        push_addr = ((channel_byte_address(em_px4,l_rc)) +
                                    (em_cog4 * P_CO)) << 2;
                        push_data = {{(256-P_CO*ACC_W){1'b0}}, acc_s_d};
                        if (l_rc > (em_cog4 * P_CO)) begin
                            if ((l_rc - em_cog4 * P_CO) > P_CO)
                                push_n = P_CO * 4;
                            else
                                push_n = (l_rc - em_cog4 * P_CO) << 2;
                        end else begin
                            push_n = 6'd0;
                        end
                    end else begin
                        push_addr = channel_byte_address(final_conv?final_pixel:em_px4,l_rc) + ((final_conv?final_cog:em_cog4)*P_CO);
                        push_data = final_conv ? {232'd0,fused_rgb} : {{(256-P_CO*8){1'b0}}, pp_out_data};
                        if (l_rc > (em_cog4 * P_CO)) begin
                            if ((l_rc - em_cog4 * P_CO) > P_CO)
                                push_n = P_CO[5:0];
                            else
                                push_n = l_rc - em_cog4 * P_CO;
                        end else begin
                            push_n = 6'd0;
                        end
                    end
                end else if (th_write_result) begin
                    push_bank = l_dst;
                    push_addr = channel_byte_address(th_cnt,l_rc);
                    push_data = {{(256-P_CO*8){1'b0}},
                                th_px_o[P_CO*8-1:0]};
                    push_n = l_rc;
                end else if (ra_write_result) begin
                    push_bank = l_dst;
                    push_addr = channel_byte_address(ra_cnt,l_rc);
                    push_data = ra_q;
                    push_n = l_rc;
                end else if (up_write_result) begin
                    push_bank = l_dst;
                    push_addr = channel_byte_address(up_cnt,l_rc);
                    push_data = up_px_o;
                    push_n = l_rc;
                end

    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            wrq_head<=0;wrq_tail<=0;wrq_count<=0;wrq_reserved<=0;
        end else begin
            if(wrq_push) begin
                if(!WRQ_COMPACT)wrq_bank_mem[wrq_tail]<=push_bank;
                if(!WRQ_LINEAR)wrq_addr_mem[wrq_tail]<=WRQ_COMPACT?(push_addr>>2):push_addr;
                if(!WRQ_COMPACT)wrq_n_mem[wrq_tail]<=push_n;
                wrq_tail<=wrq_tail+1'b1;
            end
            if(wrq_pop) wrq_head<=wrq_head+1'b1;
            case({wrq_push,wrq_pop})
                2'b10:wrq_count<=wrq_count+1'b1;
                2'b01:wrq_count<=wrq_count-1'b1;
                default:wrq_count<=wrq_count;
            endcase
            case({reserve_launch,conv_write_result})
                2'b10:wrq_reserved<=wrq_reserved+1'b1;
                2'b01:wrq_reserved<=wrq_reserved-1'b1;
                default:wrq_reserved<=wrq_reserved;
            endcase
        end
    end
    //========================================================================
    //  sequencer
    //========================================================================

    reg [3:0]  rst_cnt;
    reg [5:0]  ch_i;      // coefficient channel counters
    reg [5:0]  req_ch, done_ch;
    reg [31:0] pp_cnt, pp_cnt_r;
    reg [7:0]  cog_prev;
    reg        cf_done_seen;
    reg [5:0]  rom_i;

    // emit strobe: combinational, so it lines up with the acc_rd_data that the
    // registered wide read is presenting in the same cycle
    assign em_v = (st == S_CFWAIT) && pp_in_valid;

    // The synchronous frame-store read is returned one cycle after th_issue.
    assign th_valid_i = th_data_valid;

    // Synchronous single-port coefficient ROM read.  S_COEF launches channels
    // far enough apart that req_ch can be addressed directly.  S_COEFW writes
    // one channel per cycle, so after its entry-0 prefetch it addresses the
    // following channel while the current grom_q value is being consumed.
    wire [8:0] grom_chan = (st == S_COEFW) ?
                           ({3'b000, rom_i} + 9'd1) : {3'b000, req_ch};
    wire [8:0] grom_addr = l_gb[8:0] + grom_chan;
    wire [63:0] grom_q;
    generate if(RUNTIME_MODEL!=0)begin:G_RUNTIME_COEFF
        reg [16:0] bias_q;reg [2:0] factor_q;
        always @(posedge clk) begin
            bias_q<=runtime_bias[grom_addr];factor_q<=runtime_factor[grom_addr];
        end
        wire [31:0] full_bias={{15{bias_q[16]}},bias_q};
        wire [31:0] encoded_bias=(factor_q==4)?(full_bias<<15):(factor_q==3)?(full_bias<<18):
                                 (factor_q==2)?(full_bias<<17):(factor_q==1)?(full_bias<<16):32'd0;
        wire [31:0] encoded_factor=(factor_q==4)?32'd32768:(factor_q==3)?32'd262144:
                                   (factor_q==2)?32'd131072:(factor_q==1)?32'd65536:32'd0;
        assign grom_q={encoded_bias,encoded_factor};
    end else begin:G_STATIC_COEFF
        reg [63:0] q;
        always @(posedge clk) q<=grom[grom_addr];
        assign grom_q=q;
    end endgenerate

    wire [63:0] gv_coef = grom_q;
    wire [63:0] gv_rom  = grom_q;

    // Activity accounting, not a claim that every outstanding DDR request stalls MACs.
    // The outer profiler gives arithmetic activity priority over memory wait.
    assign profile_compute_active = busy && (row_compute1 || row_compute2 || mac_valid || pp_in_valid || pp_valid ||
        nc_out_valid || th_valid_o || ra_valid_o || up_valid_o);
    assign profile_memory_wait = busy && ((rdr_pending && !rdr_mem_return) ||
        (th_pending && !mem_rdb_valid) || (up_pending && !mem_rda_valid) ||
        (ra_phase==1 && !mem_rda_valid) || (ra_phase==3 && !mem_rdb_valid) ||
        (rdA_en && !mem_rda_ready) || (rdB_en && !mem_rdb_ready) ||
        (wm_ld_busy && !wm_mem_valid) || (wrq_valid && (row_feed?!row_input_ready:!mem_wr_ready)) || (row_output_valid && !mem_wr_ready) ||
        ((st==S_NEXT || st==S_DONE) && ddr_busy_i));

    // output pixel count for the current layer
    wire [31:0] npix_out = (A4_MODE!=0)?((l_st==2)?(l_pixels>>2):l_pixels):
        ((l_st == 2'd2) ? ((((l_w - 16'd1) >> 1) + 16'd1) * (((l_h - 16'd1) >> 1) + 16'd1)) : l_pixels);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; done <= 1'b0; busy <= 1'b0; dp_rst_n <= 1'b1;
            diagnostic_code <= 3'd0;
            weight_check_active <= 1'b0;
            weight_check_prime <= 1'b0;
            weight_check_addr <= 4'd0;
            weight_check_count <= 4'd0;
            weight_check_sig <= 32'h6D5A_56A9;
            debug_mac_event <= 16'd0;
            debug_mac_input_event <= 16'd0;
            dbg_mac0_captured <= 1'b0;
            dbg_mac0_sum0 <= 32'sd0;
            dbg_mac0_sum1 <= 32'sd0;
            dbg_mac0_sum2 <= 32'sd0;
            dbg_mac0_sum3 <= 32'sd0;
            dbg_mac_fail_captured <= 1'b0;
            dbg_mac_fail_event <= 8'd0;
            rst_cnt <= 4'd0; cf_start <= 1'b0; rdr_en <= 1'b0; ar_clr <= 1'b0;
            nc_start <= 1'b0; ct_we <= 1'b0; pp_relu <= 1'b1;
            ct_raddr <= {CT_AW{1'b0}}; th_pix <= 32'd0; th_cnt <= 32'd0;
            ra_pix <= 32'd0; ra_cnt <= 32'd0;
            up_pix <= 32'd0; up_cnt <= 32'd0;
            li <= 5'd0; phase <= 2'd0; ch_i <= 6'd0;
            sh_r <= 5'd5; pp_cnt <= 32'd0; pp_cnt_r <= 32'd0; cog_prev <= 8'hFF;
            req_ch <= 6'd0; done_ch <= 6'd0;
            cf_done_seen <= 1'b0;
            rom_i <= 6'd0;
            l_h<=0; l_w<=0; l_pixels<=0; l_cin<=0; l_cout<=0; l_sh<=0; l_rc<=0; l_st<=0;
            l_nrm<=0; l_relu<=0; l_wb<=0; l_gb<=0; l_src<=0; l_dst<=0; l_xb<=0; l_op<=0;
            //rdr_pix<=0; 
            rdr_cing<=0; rdr_cin<=16'd4; rdr_npix<=32'd0;
            cf_cin<=0; cf_cout<=0; cf_h<=0; cf_w<=0; cf_stride<=0; cf_wbase<=0;
            //mac_px_d <= 5'd0;
        end else begin
            cf_start   <= 1'b0;
            ar_clr     <= 1'b0;
            nc_start   <= 1'b0;
            ct_we      <= 1'b0;
            // ---- emit synchronisation ----
            //  stage 1 (statistics side) : strobe = em_v (combinational),
            //                              index = rd_px delayed 1 cycle
            //  Write side: em_px2/cog2 begin a three-register tag pipeline.
            // em_px4/cog4 align with PIPE=3 output. wrq_reserved protects
            // FIFO capacity; pp_pending prevents phase changes before drain.
            em_px   <= cf_pxglobal;
            em_cog  <= cf_cog;
            em_vd   <= em_v;
            em_px2  <= stream_emit ? (MAIN_MAC_INPUT_PIPE?stream_px4:stream_px3) : em_px;
            em_cog2 <= stream_emit ? (MAIN_MAC_INPUT_PIPE?stream_cog4:stream_cog3) : em_cog;
            if (pp_in_valid)
                acc_s_d <= acc_s;

            // First pixel, both output-channel groups, statistics pass.
            // Code 3 identifies convolution/accumulation mismatch; code 4
            // means raw acc is correct but the arithmetic shift differs.
            if ((DEBUG_CHECK_LAYER0_PIXEL0 != 0) &&
                (li == 5'd0) &&
                (st == S_CFWAIT) && (phase == 2'd0) && em_v &&
                (em_px == 32'd0) && (diagnostic_code == 3'd0)) begin
                if (!layer0_px0_acc_match)
                    diagnostic_code <= 3'd3;
                else if (!layer0_px0_shift_match)
                    diagnostic_code <= 3'd4;
            end

            // Check the exact operands presented to mac_array before checking
            // its registered result.  Code 5 identifies window-cache data;
            // code 6 identifies weight_mgr selection/packing.  Event numbers
            // match the output-side checker because mac_array has PIPE=1.
            if ((DEBUG_CHECK_LAYER0_MAC_INPUTS != 0) && (li == 5'd0) &&
                (phase == 2'd0) && mac_valid) begin
                if (diagnostic_code == 3'd0) begin
                    case (debug_mac_input_event)
                        16'd0: begin
                            if (wc_rd_group != 144'h1B611B3577351B611B4C5B4C0217024C5B4C) begin
                                diagnostic_code <= 3'd5;
                                dbg_mac_fail_captured <= 1'b1;
                                dbg_mac_fail_event <= debug_mac_input_event;
                            end else if (wm_wdata != 576'hD6ECE7B981D50CE8CE0F4E0C14152CC13738AAC17FEE1330A61321D5424FCCDBDF07CE40FEA91BC9D8261E2DCD9F90D08913E1C7AEE06D7941DAD2B4C0AEF3037E220EEED4811AF9) begin
                                diagnostic_code <= 3'd6;
                                dbg_mac_fail_captured <= 1'b1;
                                dbg_mac_fail_event <= debug_mac_input_event;
                            end
                        end
                        16'd32: begin
                            if (wc_rd_group != 144'h000000000000000000396939705470396939) begin
                                diagnostic_code <= 3'd5;
                                dbg_mac_fail_captured <= 1'b1;
                                dbg_mac_fail_event <= debug_mac_input_event;
                            end else if (wm_wdata != 576'h000000000000000000F0E40CE116043A52E000000000000000000098CA0C9214642339290000000000000000007F55756B03E94F48FB0000000000000000004A17F523E056F2B4BC) begin
                                diagnostic_code <= 3'd6;
                                dbg_mac_fail_captured <= 1'b1;
                                dbg_mac_fail_event <= debug_mac_input_event;
                            end
                        end
                        16'd64: begin
                            if (wc_rd_group != 144'h1B611B3577351B611B4C5B4C0217024C5B4C) begin
                                diagnostic_code <= 3'd5;
                                dbg_mac_fail_captured <= 1'b1;
                                dbg_mac_fail_event <= debug_mac_input_event;
                            end else if (wm_wdata != 576'h9BFF81B9C1784B72241C8AA5B90CB66B7D52ED36A92B3488394BBD7F16BA48EF0101C4B606D7CCE6F4105CF3C8167F517A65260F2206D6BE29ACEA2BDC000DF3B0FE59D817274306) begin
                                diagnostic_code <= 3'd6;
                                dbg_mac_fail_captured <= 1'b1;
                                dbg_mac_fail_event <= debug_mac_input_event;
                            end
                        end
                        16'd96: begin
                            if (wc_rd_group != 144'h000000000000000000396939705470396939) begin
                                diagnostic_code <= 3'd5;
                                dbg_mac_fail_captured <= 1'b1;
                                dbg_mac_fail_event <= debug_mac_input_event;
                            end else if (wm_wdata != 576'h000000000000000000E8D5CB01E90103345F000000000000000000C9E6E72B210839E7FA000000000000000000C6CEE2D89215AE06FE0000000000000000007F43F4220AD6D3CBC5) begin
                                diagnostic_code <= 3'd6;
                                dbg_mac_fail_captured <= 1'b1;
                                dbg_mac_fail_event <= debug_mac_input_event;
                            end
                        end
                        default: ;
                    endcase
                end
                debug_mac_input_event <= debug_mac_input_event + 1'b1;
            end

            // Capture the first registered MAC result and hold it for JTAG
            // VIO inspection.  This is deliberately independent of the LED
            // diagnostic comparisons so it records the actual hardware value.
            if ((DEBUG_CHECK_LAYER0_MAC != 0) && (li == 5'd0) &&
                (phase == 2'd0) && mac_out_valid &&
                (debug_mac_event == 16'd0) && !dbg_mac0_captured) begin
                dbg_mac0_sum0 <= $signed(mac_out_sum[0*ACC_W +: ACC_W]);
                dbg_mac0_sum1 <= $signed(mac_out_sum[1*ACC_W +: ACC_W]);
                dbg_mac0_sum2 <= $signed(mac_out_sum[2*ACC_W +: ACC_W]);
                dbg_mac0_sum3 <= $signed(mac_out_sum[3*ACC_W +: ACC_W]);
                dbg_mac0_captured <= 1'b1;
            end

            // For layer 0 / tile 0 the MAC event order is:
            //   0,32  = COG0 pixel0, CIG0/1
            //   64,96 = COG1 pixel0, CIG0/1.
            // Code 1 means at least one partial sum is already wrong.
            if ((DEBUG_CHECK_LAYER0_MAC != 0) && (li == 5'd0) &&
                (phase == 2'd0) && mac_out_valid) begin
                if (diagnostic_code == 3'd0) begin
                    case (debug_mac_event)
                        16'd0: if (!(($signed(mac_out_sum[0*ACC_W +: ACC_W]) ==  32'sd872)   &&
                                    ($signed(mac_out_sum[1*ACC_W +: ACC_W]) == -32'sd44928) &&
                                    ($signed(mac_out_sum[2*ACC_W +: ACC_W]) ==  32'sd7718)  &&
                                    ($signed(mac_out_sum[3*ACC_W +: ACC_W]) == -32'sd14024))) begin
                                  // If all four values equal the unsigned-weight
                                  // interpretation, synthesis lost the int8 sign
                                  // at the DSP multiplier inputs.  Distinguish
                                  // that exact failure from any other MAC error.
                                  if (($signed(mac_out_sum[0*ACC_W +: ACC_W]) == 32'sd142440) &&
                                      ($signed(mac_out_sum[1*ACC_W +: ACC_W]) == 32'sd163200) &&
                                      ($signed(mac_out_sum[2*ACC_W +: ACC_W]) == 32'sd109606) &&
                                      ($signed(mac_out_sum[3*ACC_W +: ACC_W]) == 32'sd133432))
                                      diagnostic_code <= 3'd2;
                                  else
                                      diagnostic_code <= 3'd1;
                              end
                        16'd32: if (!(($signed(mac_out_sum[0*ACC_W +: ACC_W]) ==  32'sd4216)  &&
                                     ($signed(mac_out_sum[1*ACC_W +: ACC_W]) ==  32'sd44271) &&
                                     ($signed(mac_out_sum[2*ACC_W +: ACC_W]) == -32'sd37)    &&
                                     ($signed(mac_out_sum[3*ACC_W +: ACC_W]) ==  32'sd5748)))
                                   diagnostic_code <= 3'd1;
                        16'd64: if (!(($signed(mac_out_sum[0*ACC_W +: ACC_W]) == -32'sd11440) &&
                                     ($signed(mac_out_sum[1*ACC_W +: ACC_W]) ==  32'sd19252) &&
                                     ($signed(mac_out_sum[2*ACC_W +: ACC_W]) ==  32'sd6569)  &&
                                     ($signed(mac_out_sum[3*ACC_W +: ACC_W]) ==  32'sd13101)))
                                   diagnostic_code <= 3'd1;
                        16'd96: if (!(($signed(mac_out_sum[0*ACC_W +: ACC_W]) ==  32'sd2041)   &&
                                     ($signed(mac_out_sum[1*ACC_W +: ACC_W]) == -32'sd25792) &&
                                     ($signed(mac_out_sum[2*ACC_W +: ACC_W]) ==  32'sd1476)  &&
                                     ($signed(mac_out_sum[3*ACC_W +: ACC_W]) ==  32'sd434)))
                                   diagnostic_code <= 3'd1;
                        default: ;
                    endcase
                end
                debug_mac_event <= debug_mac_event + 1'b1;
            end

            case (st)
            //----------------------------------------------------------------
            S_IDLE: if (start) begin
                        li <= 5'd0; done <= 1'b0; busy <= 1'b1;
                        diagnostic_code <= 3'd0;
                        dbg_mac0_captured <= 1'b0;
                        dbg_mac_fail_captured <= 1'b0;
                        dbg_mac_fail_event <= 8'd0;
                        if ((DEBUG_CHECK_LAYER0_WEIGHTS != 0) &&
                            (USE_DDR_WEIGHTS == 0) && (A4_MODE == 0)) begin
                            weight_check_active <= 1'b1;
                            weight_check_prime <= 1'b0;
                            weight_check_addr <= 4'd0;
                            weight_check_count <= 4'd0;
                            weight_check_sig <= 32'h6D5A_56A9;
                            st <= S_WCHK;
                        end else begin
                            st <= S_LD;
                        end
                    end

            //----------------------------------------------------------------
            // Sequential signature over the first 12 x 256-bit ROM words,
            // which are exactly the complete layer-0 weight payload.
            S_WCHK: begin
                if (!weight_check_prime) begin
                    // Prime the synchronous ROM with word 0 and launch word 1.
                    weight_check_prime <= 1'b1;
                    weight_check_addr <= 4'd1;
                end else begin
                    weight_check_sig <= weight_check_sig_next;
                    if (weight_check_count == 4'd11) begin
                        weight_check_active <= 1'b0;
                        if (weight_check_sig_next != 32'h4BED_C132)
                            diagnostic_code <= 3'd2;
                        st <= S_LD;
                    end else begin
                        weight_check_count <= weight_check_count + 1'b1;
                        weight_check_addr <= weight_check_addr + 1'b1;
                    end
                end
            end

            //----------------------------------------------------------------
            S_LD: begin
                if(A4_FUSION!=0 && d_op==1) begin
                    // Virtual nearest-neighbour reads in the following convolution.
                    li<=li+1'b1;st<=S_LD;
                end else begin
                l_op    <= d_op;
                l_h     <= d_dim[31:16];
                l_pixels<= descriptor_pixels(d_dim);
                l_w     <= d_dim[15:0];
                l_cout  <= d_ch[31:16];
                l_cin   <= d_ch[15:0];
                l_st    <= d_flag[1:0];
                l_sh    <= d_flag[15:8];
                l_nrm   <= d_flag[16];
                l_relu  <= d_flag[17];
                l_xb    <= d_bank[1:0];
                l_dst   <= (A4_FUSION!=0 && li==11) ? 0 : d_bank[9:8];
                l_src   <= (A4_FUSION!=0 && li==8) ? 3 :
                           (A4_FUSION!=0 && li==10) ? 2 : d_bank[17:16];
                l_wb    <= d_wb;
                l_gb    <= d_gb;
                l_rc    <= d_rc;
                sh_r    <= d_flag[15:8];
                // The reader parameters MUST be set here, not in S_CFGP:
                // S_FILL runs BEFORE S_CFGP, so setting them later left the
                // PREVIOUS layer's values in place during the fill.  With
                // CIN=16 that fed only 2 of the 4 input-channel groups and the
                // accumulation came out exactly half.
                rdr_cin  <= d_ch[15:0];
                rdr_cing <= (d_ch[15:0] + P_CI - 1) / P_CI;
                rdr_npix <= descriptor_pixels(d_dim);
                phase   <= 2'd0;
                ch_i    <= 6'd0;
                req_ch  <= 6'd0;
                done_ch <= 6'd0;
                rom_i   <= 6'd0;
                pp_cnt_r<= 32'd0;
                th_pix  <= 32'd0;
                th_cnt  <= 32'd0;
                ra_pix  <= 32'd0;
                ra_cnt  <= 32'd0;
                up_pix  <= 32'd0;
                up_cnt  <= 32'd0;
                if (d_op == 8'd0) begin
                    st <= (A4_MODE != 0) ? S_ROMPRIME : S_DPRST;
                end else if (d_op == 8'd1) begin
                    st <= S_UPGO;
                end else if (d_op == 8'd2) begin
                    st <= S_RAGO;
                end else begin
                    st <= S_THGO;
                end
                end
            end

            //----------------------------------------------------------------
            S_ROMPRIME: begin
                // One synchronous ROM cycle with the NEW layer gbase before
                // loading entry 0. This avoids stale coefficients on single pass.
                st <= S_COEFW;
            end

            S_DPRST: begin
                dp_rst_n <= 1'b0;
                if (rst_cnt == 4'd7) begin
                    dp_rst_n <= 1'b1;
                    rst_cnt  <= 4'd0;
                    if (phase == 2'd0) ar_clr <= 1'b1;
                    st <= S_CFGP;
                end else begin
                    rst_cnt <= rst_cnt + 4'd1;
                end
            end

            //----------------------------------------------------------------
            S_CFGP: begin
                if ((DEBUG_CHECK_LAYER0_MAC != 0) && (li == 5'd0) &&
                    (phase == 2'd0))
                    debug_mac_event <= 16'd0;
                if ((DEBUG_CHECK_LAYER0_MAC_INPUTS != 0) && (li == 5'd0) &&
                    (phase == 2'd0))
                    debug_mac_input_event <= 16'd0;
                cf_h <= l_h; cf_w <= l_w;
                cf_cin <= l_cin; cf_cout <= l_cout;
                cf_stride <= l_st; cf_wbase <= l_wb;
                pp_relu <= (phase == 2'd1) && l_relu;
                rdr_en  <= 1'b1;
                cf_start<= 1'b1;
                cf_done_seen <= 1'b0;
                st <= S_CFWAIT;
            end

            //----------------------------------------------------------------
            S_CFWAIT: begin
                // Current-layer coefficient entry for this output group.
                ct_raddr <= stream_emit ? (MAIN_MAC_INPUT_PIPE?stream_cog2:stream_cog1) : cf_cog;

                if (cf_done) begin
                    rdr_en <= 1'b0;
                    cf_done_seen <= 1'b1;
                end
                if (cf_done || cf_done_seen) begin
                    if (l_op == 8'd0 && phase == 2'd0 && !pp_pending) begin
                        st <= (l_nrm) ? S_COEF : S_COEFW;
                    end else if (phase == 2'd1 && !wrq_valid && !pp_pending && (!row_feed || (row_finished && !row_output_valid))) begin
                        st <= S_NEXT;
                    end
                end
            end

            //----------------------------------------------------------------
            //  S_COEF: per-channel coefficients from the statistics
            //    req_ch  = channels launched, done_ch = channels whose result
            //              has been stored.  The loop ends only when done_ch
            //              reaches COUT -- launching the last channel is NOT
            //              enough (that was the original bug: the last channel's
            //              coefficient was never written to coeff_table).
            //----------------------------------------------------------------
            S_COEF: begin
                if ((DEBUG_CHECK_LAYER0_STATS != 0) && (li == 5'd0) &&
                    (req_ch == 6'd0) && (done_ch == 6'd0) &&
                    !layer0_stats_match && (diagnostic_code == 3'd0))
                    diagnostic_code <= 3'd7;
                // store a completed channel
                if (nc_out_valid) begin
                    ct_we    <= 1'b1;
                    ct_waddr <= done_ch >> PCO_W;
                    ct_wch   <= done_ch[PCO_W-1:0];
                    ct_wa    <= nc_a;
                    ct_wb    <= nc_b;
                    done_ch  <= done_ch + 6'd1;
                end
                // launch the next channel if none is in flight
                if ((req_ch < l_cout[5:0]) && (req_ch == done_ch)) begin
                    nc_s1    <= ar_s1[req_ch*48 +: 48];
                    nc_s2    <= ar_s2[req_ch*56 +: 56];
                    nc_n     <= npix_out[19:0];
                    nc_ga    <= gv_coef[A_W-1:0];
                    nc_be    <= gv_coef[2*A_W-1:A_W];
                    nc_start <= 1'b1;
                    req_ch   <= req_ch + 6'd1;
                end
                // all channels stored -> run the output pass
                if ((done_ch == l_cout[5:0]) && !nc_out_valid) begin
                    phase <= 2'd1;
                    st    <= S_DPRST;
                end
            end

            //----------------------------------------------------------------
            //  S_COEFW: load ROM coefficients (un-normalised layers)
            //----------------------------------------------------------------
            S_COEFW: begin
                if (rom_i < l_cout[5:0]) begin
                    ct_we    <= 1'b1;
                    ct_waddr <= rom_i >> PCO_W;
                    ct_wch   <= rom_i[PCO_W-1:0];
                    ct_wa    <= gv_rom[A_W-1:0];
                    ct_wb    <= $signed(gv_rom[2*A_W-1:A_W]);
                    rom_i    <= rom_i + 6'd1;
                end else begin
                    phase <= 2'd1;
                    st    <= S_DPRST;
                end
            end

            //----------------------------------------------------------------
            S_THGO: begin
                th_pix <= 32'd0;
                th_cnt <= 32'd0;
                st <= S_THRUN;
            end

            S_THRUN: begin
                if (th_issue)
                    th_pix <= th_pix + 32'd1;
                if (th_write_result)
                    th_cnt  <= th_cnt + 32'd1;
                if ((th_cnt == l_pixels) && !wrq_valid &&
                    !th_pending && !th_valid_o)
                    st <= S_NEXT;
            end

            //----------------------------------------------------------------
            S_RAGO: begin
                ra_pix <= 32'd0;
                ra_cnt <= 32'd0;
                st <= S_RARUN;
            end

            S_RARUN: begin
                if (ra_write_result) begin
                    ra_pix <= ra_pix + 32'd1;
                    ra_cnt  <= ra_cnt + 32'd1;
                end
                if ((ra_cnt == l_pixels) && !wrq_valid &&
                    (ra_phase == 3'd0) && !ra_valid_o)
                    st <= S_NEXT;
            end
            //----------------------------------------------------------------
            S_UPGO: begin
                up_pix <= 32'd0;
                up_cnt <= 32'd0;
                st <= S_UPRUN;
            end

            S_UPRUN: begin
                if (up_issue)
                    up_pix <= up_pix + 32'd1;
                if (up_write_result)
                    up_cnt  <= up_cnt + 32'd1;
                if ((up_cnt == (l_pixels << 2)) && !wrq_valid &&
                    !up_pending && !up_data_valid && !up_valid_o)
                    st <= S_NEXT;
            end
            //----------------------------------------------------------------
            S_NEXT: begin
                if ((A4_MODE == 0) || !ddr_busy_i) begin
                if (final_conv || row_tail) begin
                    st<=S_DONE;
                end else if (li + 5'd1 < RUN_LAYERS) begin
                    li <= row_feed ? 5'd2 : li + 5'd1;
                    st <= S_LD;
                end else begin
                    st <= S_DONE;
                end
                end
            end

            S_DONE: begin
                // Completion includes the backend's final B response and
                // registered completion cycle, not just arithmetic/queue drain.
                if (!wrq_valid && !ddr_busy_i) begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    if (!start) st <= S_IDLE;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire

// Consecutive START-to-START epochs. Four exclusive bins; compute wins overlap.
// Snapshot persists across the NN's per-frame reset; reset with global video reset only.
module nn_cycle_profile(input wire clk,rst_n,start,active,compute_active,memory_wait,
 output reg valid,output reg [31:0] last_total,last_compute,last_memory,last_control,last_gap);
 // Sample the entire event tuple together. START epochs and all four bins
 // retain their exact counts; completed snapshots appear one clock later.
 // This separates long NN readiness logic from the counter CE/carry path.
 (* syn_preserve=1, syn_keep=1 *) reg start_q,active_q,compute_q,memory_q;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin start_q<=0;active_q<=0;compute_q<=0;memory_q<=0;end
  else begin start_q<=start;active_q<=active;compute_q<=compute_active;memory_q<=memory_wait;end
 end
 reg armed;
 reg [31:0] total,comp,mem,ctrl,gap;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   armed<=0;valid<=0;total<=0;comp<=0;mem<=0;ctrl<=0;gap<=0;
   last_total<=0;last_compute<=0;last_memory<=0;last_control<=0;last_gap<=0;
  end else if(start_q)begin
   if(armed)begin valid<=1;last_total<=total;last_compute<=comp;
    last_memory<=mem;last_control<=ctrl;last_gap<=gap;end
   armed<=1;total<=1;comp<=active_q&&compute_q;mem<=active_q&&!compute_q&&memory_q;
   ctrl<=active_q&&!compute_q&&!memory_q;gap<=!active_q;
  end else if(armed)begin
   total<=total+1'b1;
   if(!active_q)gap<=gap+1'b1;
   else if(compute_q)comp<=comp+1'b1;
   else if(memory_q)mem<=mem+1'b1;
   else ctrl<=ctrl+1'b1;
  end
 end
endmodule

// Independent A4 encoder row stages, included in this registered source.
`timescale 1ns/1ps
`default_nettype none
// Independent streamed3x3 convolution. Full pixels, reflection borders,
// fixed trained requantization and ready/valid at both layer boundaries.
module a4_row_conv #(parameter W=640,H=480,STRIDE=1,CO=4,PCO=2,GBASE=4,WORDS=5,RUNTIME_MODEL=0,WINDOW_HOLD=1,WEIGHT_BRAM_PREFIX=80,WEIGHT_BRAM_LANES=3,TAIL_REUSE=0,FIFO_DEPTH=4,SINGLE_GROUP_SHARED_WEIGHTS=0,FIFO_BRAM=0)(
 input wire clk,rst_n,
 input wire tail_mode,
 input wire cfg_we,input wire [7:0] cfg_index,input wire [63:0] cfg_data,
 input wire weight_we,input wire [3:0] weight_word,input wire [255:0] weight_data,
 input wire in_valid,output wire in_ready,input wire [31:0] in_data,
 output wire out_valid,input wire out_ready,output wire [CO*8-1:0] out_data,
 output wire [31:0] out_index,output reg finished,output wire compute_active
);
 localparam GROUPS=(CO+PCO-1)/PCO,GW=(GROUPS>1)?$clog2(GROUPS):1,PW=$clog2((W/STRIDE)*(H/STRIDE)+1),TOTAL=(W/STRIDE)*(H/STRIDE);
 wire [GW-1:0] last_group=(TAIL_REUSE!=0 && tail_mode)?((3+PCO-1)/PCO-1):(GROUPS-1);
 // Partially BRAM-backed banked cache, fetched once from DDR; no wide barrel mux.
 // One lane prefix uses eight RAM10s; the remaining weights stay in logic.
 reg [255:0] previous_word;
 wire [3:0] relative_word=weight_word<5?weight_word:weight_word-5;
 wire [$clog2(CO)-1:0] load_channel=(weight_word<5?0:4)+relative_word-1;
 reg [287:0] assembled_weight;
 always @*case(relative_word)
  1:assembled_weight={weight_data[31:0],previous_word};
  2:assembled_weight={weight_data[63:0],previous_word[255:32]};
  3:assembled_weight={weight_data[95:0],previous_word[255:64]};
  default:assembled_weight={weight_data[127:0],previous_word[255:96]};
 endcase
 always @(posedge clk)if(weight_we)begin
  previous_word<=weight_data;
 end
 //20-bit code: valid, signed17-bit bias, two-bit power-of-two shift.
 function [19:0] encode_coeff(input [63:0] ab);
  reg signed [31:0] bias;reg [1:0] shift;reg valid;
  begin valid=1;
   case(ab[31:0])
    32768:begin bias=$signed(ab[63:32])>>>15;shift=3;end
    65536:begin bias=$signed(ab[63:32])>>>16;shift=0;end
    131072:begin bias=$signed(ab[63:32])>>>17;shift=1;end
    262144:begin bias=$signed(ab[63:32])>>>18;shift=2;end
    default:begin valid=0;bias=0;shift=0;end
   endcase
   encode_coeff={valid,bias[16:0],shift};
  end
 endfunction
 reg [1:0] state;reg [GW-1:0] group,read_group,mac_group,tags[0:2];
 wire [287:0] live_window;wire live_valid,lb_ready;
 reg [287:0] compute_window;
 reg [PW-1:0] issued,consumed;
 localparam FAW=$clog2(FIFO_DEPTH);
 assign out_index=consumed;reg [FAW:0] used,count;reg [FAW-1:0] head,tail;

 reg [CO*8-1:0] assembly;
 wire capture=state==0 && live_valid && used<FIFO_DEPTH && issued<TOTAL;
 // Capture one complete window and advance the producer on that edge.
 // MAC reads the held window; the last group may overlap the next capture.
 wire stall=WINDOW_HOLD!=0 ? (state==1 || (live_valid && !capture) || used==FIFO_DEPTH || issued==TOTAL) :
                                      (state==1 || capture || used==FIFO_DEPTH || issued==TOTAL);
 assign out_valid=count!=0;
 wire pop=out_valid && out_ready;
 assign in_ready=lb_ready && !stall;
 line_buffer_v2 #(.P_CI(4),.MAX_W(W),.ADDR_W($clog2(W))) u_rows(
 .clk(clk),.rst_n(rst_n),.stall(stall),.cfg_w(16'(W)),.cfg_h(16'(H)),.cfg_stride(2'(STRIDE)),
 .in_valid(in_valid),.in_ready(lb_ready),.in_px(in_data),.win_valid(live_valid),.win_data(live_window),.win_row(),.win_col());
 wire issue=state==1 || capture;
 wire [GW-1:0] issue_group=capture?{GW{1'b0}}:group;
 reg read_valid;
 wire [PCO*288-1:0] selected_weights;
 reg [PCO*20-1:0] code;
 genvar lane;
 generate for(lane=0;lane<PCO;lane=lane+1)begin: G_PARAMETER_BANK
  // Store a 160-bit prefix per enabled lane in eight 20-bit RAM10s.
  // The sync read has the same latency as weight_q; no MAC schedule change.
  localparam SHARED=(SINGLE_GROUP_SHARED_WEIGHTS!=0 && GROUPS==1);
  localparam BW=(!SHARED && WEIGHT_BRAM_PREFIX!=0 && CO==4 && (PCO==2 || PCO==3 || PCO==4) && lane<WEIGHT_BRAM_LANES)?WEIGHT_BRAM_PREFIX:0;
  wire load=weight_we && relative_word!=0 && load_channel%PCO==lane;
  if(BW!=0)begin:G_BRAM_PREFIX
   genvar part;
   for(part=0;part<BW/20;part=part+1)begin:G_WORD
    EFX_RAM10 #(.READ_WIDTH(20),.WRITE_WIDTH(20),.OUTPUT_REG(1'b0),.WRITE_MODE("READ_FIRST")) u_weight(
     .WCLK(clk),.WCLKE(1'b1),.WADDREN(1'b1),.WE({2{load}}),
     .WADDR({8'b0,(load_channel/PCO!=0)}),.WDATA(assembled_weight[part*20+:20]),
     .RCLK(clk),.RE(issue),.RADDREN(1'b1),.RST(1'b0),.RADDR({8'b0,issue_group[0]}),
     .RDATA(selected_weights[lane*288+part*20+:20]));
   end
  end
  (* syn_ramstyle="logic" *) reg [287-BW:0] weight_ram[0:GROUPS-1];
  wire [287-BW:0] weight_q;
  if(SHARED)begin:G_SINGLE_GROUP_SHARED
   // The parent loads only while row_active is low and holds the weights
   // throughout a complete session. One group has no read-address selection,
   // so another full weight copy and its sparse BRAM prefix are unnecessary.
   // read_valid and the pixel/MAC schedule retain their existing latency.
   assign weight_q=weight_ram[0];
  end else begin:G_GROUP_READ_REGISTER
   reg [287-BW:0] read_q;
   always @(posedge clk)if(issue)read_q<=weight_ram[issue_group];
   assign weight_q=read_q;
  end
  assign selected_weights[lane*288+BW+:288-BW]=weight_q;
  (* syn_ramstyle="logic" *) reg [19:0] coefficient_ram[0:GROUPS-1];
  wire [19:0] selected_code;
  if(TAIL_REUSE!=0)begin:G_TAIL_COEFFICIENTS
   // Only a second compact coefficient bank; weights, DSPs and row RAMs
   // are overwritten/reused between the front and tail sessions.
   localparam TAIL_GROUPS=(3+PCO-1)/PCO;
   (* syn_ramstyle="logic" *) reg [19:0] tail_coeff[0:TAIL_GROUPS-1];
   wire [19:0] tail_code;
   if(TAIL_GROUPS==1)assign tail_code=tail_coeff[0];
   else assign tail_code=tail_coeff[read_group];
   assign selected_code=(read_group*PCO+lane>=CO)?20'd0:
                        tail_mode?((read_group*PCO+lane>=3)?20'd0:tail_code):coefficient_ram[read_group];
   if(RUNTIME_MODEL==0)begin:G_STATIC
    reg [63:0] table_data[0:63];integer c;
    initial begin
     $readmemh("a4_coeff.mem",table_data);
     for(c=0;c<TAIL_GROUPS;c=c+1)tail_coeff[c]=(c*PCO+lane<3)?encode_coeff(table_data[36+c*PCO+lane]):20'd0;
    end
   end else begin:G_RUNTIME
    always @(posedge clk)if(cfg_we && cfg_index>=36 && cfg_index<39 && (cfg_index-36)%PCO==lane)
     tail_coeff[(cfg_index-36)/PCO]<=encode_coeff(cfg_data);
   end
  end else begin:G_FRONT_COEFFICIENTS
   assign selected_code=(read_group*PCO+lane>=CO)?20'd0:coefficient_ram[read_group];
  end
  always @(posedge clk)begin
   if(load)weight_ram[load_channel/PCO]<=assembled_weight[287:BW];
   if(read_valid)code[lane*20+:20]<=selected_code;
  end
  if(RUNTIME_MODEL==0)begin: G_ROM_COEFFICIENTS
   reg [63:0] table_data[0:63];integer c;
   initial begin $readmemh("a4_coeff.mem",table_data);for(c=0;c<GROUPS;c=c+1)coefficient_ram[c]=(c*PCO+lane<CO)?encode_coeff(table_data[GBASE+c*PCO+lane]):20'd0;end
  end else begin: G_RUNTIME_COEFFICIENTS
   always @(posedge clk)if(cfg_we && cfg_index>=GBASE && cfg_index<GBASE+CO && (cfg_index-GBASE)%PCO==lane)
    coefficient_ram[(cfg_index-GBASE)/PCO]<=encode_coeff(cfg_data);
  end
 end endgenerate
 wire mv;wire [PCO*32-1:0] sums;
 mac_array #(.DUAL_DSP(1),.STABLE_WEIGHTS(1),.DSP_CASCADE_PAIRS(4),.P_CO(PCO),.P_CI(4),.PIPE(1)) u_mac(
 .clk(clk),.rst_n(rst_n),.in_valid(read_valid),.win_data((WINDOW_HOLD!=0)?compute_window:live_window),.w_data(selected_weights),.out_valid(mv),.out_sum(sums));
 // Same exact signed ties-to-even arithmetic as A4 postproc, directly from
 // the compact coefficient; avoid reconstructing A/B then decoding them again.
 reg [2:0] quant_valid;
 wire [PCO*8-1:0] px;wire pv=quant_valid[2];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)quant_valid<=0;else quant_valid<={quant_valid[1:0],mv};
 end
 generate for(lane=0;lane<PCO;lane=lane+1)begin: G_QUANT
  reg signed [20:0] acc_q;reg signed [16:0] bias_q;
  reg signed [21:0] sum_q;reg [1:0] shift_q,shift_qq;reg [7:0] pixel;
  wire [19:0] lane_code=code[lane*20+:20];
  wire signed [21:0] floor_q=shift_qq==3?(sum_q>>>9):shift_qq==2?(sum_q>>>6):shift_qq==1?(sum_q>>>7):(sum_q>>>8);
  wire greater_half=shift_qq==3?(sum_q[8:0]>256):shift_qq==2?(sum_q[5:0]>32):shift_qq==1?(sum_q[6:0]>64):(sum_q[7:0]>128);
  wire equal_half=shift_qq==3?(sum_q[8:0]==256):shift_qq==2?(sum_q[5:0]==32):shift_qq==1?(sum_q[6:0]==64):(sum_q[7:0]==128);
  wire signed [21:0] rounded_q=floor_q+((greater_half || (equal_half && floor_q[0]))?1'b1:1'b0);
  wire [7:0] narrow_q=floor_q[7:0]+(greater_half || (equal_half && floor_q[0]));
  wire [7:0] signed_pixel=(floor_q>=127)?8'd127:(floor_q < -127)?8'h81:narrow_q;
  wire [7:0] relu_pixel=(floor_q<0)?8'd0:(floor_q>=127)?8'd127:narrow_q;
`ifndef SYNTHESIS
  always @(posedge clk)if(rst_n)begin
   if(signed_pixel!==(rounded_q < -127 ? -8'sd127 : rounded_q > 127 ? 8'd127 : rounded_q[7:0]))
    $fatal(1,"compact signed row quantizer differs from reference");
   if(relu_pixel!==(rounded_q<0?8'd0:rounded_q>127?8'd127:rounded_q[7:0]))
    $fatal(1,"compact ReLU row quantizer differs from reference");
  end
`endif
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin acc_q<=0;bias_q<=0;sum_q<=0;shift_q<=0;shift_qq<=0;pixel<=0;end
   else begin
    acc_q<=lane_code[19]?sums[lane*32+:21]:0;bias_q<=lane_code[18:2];shift_q<=lane_code[1:0];
    sum_q<=$signed({acc_q[20],acc_q})+$signed({{5{bias_q[16]}},bias_q});shift_qq<=shift_q;
    if(TAIL_REUSE!=0 && tail_mode)
     pixel<=signed_pixel;
    else pixel<=relu_pixel;
   end
  end
  assign px[lane*8+:8]=pixel;
 end endgenerate
 assign compute_active=issue || read_valid || mv || pv;
 wire push=pv && tags[2]==last_group;
 reg [CO*8-1:0] completed_pixel;
 integer pack_lane;
 always @*begin
  completed_pixel=assembly;
  if(CO==4 && PCO==4)begin
   completed_pixel=px;
  end else if(CO==4 && PCO==3)begin
   if(tags[2]==0)completed_pixel[23:0]=px;
   else completed_pixel[31:24]=px[7:0];
  end else begin
   for(pack_lane=0;pack_lane<PCO;pack_lane=pack_lane+1)
    if(tags[2]*PCO+pack_lane<CO)
     completed_pixel[(tags[2]*PCO+pack_lane)*8+:8]=px[pack_lane*8+:8];
  end
 end

 // Read the next head on an accepted pop. Forward a simultaneous write
 // to that address, preserving first-word availability and zero bubbles.
 generate if(FIFO_BRAM!=0)begin:G_OUTPUT_BRAM
  (* syn_ramstyle="block_ram" *)reg[CO*8-1:0]memory[0:FIFO_DEPTH-1];
  reg[CO*8-1:0]memory_q,forwarded;reg forward_valid;
  wire[FAW-1:0]read_ahead=head+pop;
  wire write_enable=rst_n&&push;
  always @(posedge clk)begin
   if(write_enable)memory[tail]<=completed_pixel;
   memory_q<=memory[read_ahead];
   forward_valid<=write_enable&&(tail==read_ahead);
   if(write_enable&&(tail==read_ahead))forwarded<=completed_pixel;
  end
  assign out_data=forward_valid?forwarded:memory_q;
 end else begin:G_OUTPUT_LOGIC
  (* syn_ramstyle="logic" *)reg[CO*8-1:0]memory[0:FIFO_DEPTH-1];
  always @(posedge clk)if(rst_n&&push)memory[tail]<=completed_pixel;
  assign out_data=memory[head];
 end endgenerate
 integer t;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=0;group<=0;read_group<=0;read_valid<=0;mac_group<=0;consumed<=0;finished<=0;
   issued<=0;used<=0;count<=0;head<=0;tail<=0;assembly<=0;compute_window<=0;
   for(t=0;t<3;t=t+1)tags[t]<=0;
  end else begin
   read_valid<=issue;if(issue)read_group<=issue_group;if(read_valid)mac_group<=read_group;
   tags[0]<=mac_group;tags[1]<=tags[0];tags[2]<=tags[1];
   if(capture)begin
    compute_window<=live_window;group<=1;
    state<=(last_group==0)?((WINDOW_HOLD!=0)?0:2):1;issued<=issued+1'b1;
   end
   if(state==1)begin if(group==last_group)state<=(WINDOW_HOLD!=0)?0:2;else group<=group+1'b1;end
   if(state==2 && !stall)state<=0;
   if(pv)assembly<=completed_pixel;
   if(push)tail<=tail+1'b1;
   if(pop)begin head<=head+1'b1;consumed<=consumed+1'b1;if(out_index==TOTAL-1)finished<=1;end
   case({capture,pop})2'b10:used<=used+1'b1;2'b01:used<=used-1'b1;default:used<=used;endcase
   case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:count<=count;endcase
  end
 end
`ifndef SYNTHESIS
 initial if((PCO!=1 && PCO!=2 && PCO!=3 && PCO!=4) || CO<2 || (CO!=4 && CO!=8) || (TAIL_REUSE!=0 && CO!=4))$fatal(1,"unsupported compact row geometry");
 initial if(FIFO_DEPTH<4 || (FIFO_DEPTH & (FIFO_DEPTH-1))!=0)$fatal(1,"row FIFO depth must be a power of two >=4");
 always @(posedge clk)if(rst_n)begin
  if(used>FIFO_DEPTH || count>used || (push && count==FIFO_DEPTH && !pop))$fatal(1,"row-stage FIFO reservation overflow");
  if(finished && out_index!=TOTAL)$fatal(1,"row-stage incomplete frame");
 end
`endif
endmodule
`default_nettype wire

// One descriptor and one owned return per reader. The descriptor remains held
// through arbitrary cache hazards and DDR stalls. Busy includes queued work,
// so a layer barrier cannot overtake an accepted request.
module nn_read_descriptor_pipe #(parameter integer AW=24)(
 input wire clk,rst_n,clear,enable,in_req,
 output wire in_ready,input wire [1:0] in_bank,input wire [AW-1:0] in_addr,
 output wire out_req,input wire out_ready,
 output reg [1:0] out_bank,output reg [AW-1:0] out_addr,
 input wire returned,output wire busy);
 reg occupied,issued;
 assign in_ready=!occupied && enable && !clear;
 assign out_req=occupied && !issued;
 assign busy=occupied;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin occupied<=0;issued<=0;out_bank<=0;out_addr<=0;end
  else if(clear)begin occupied<=0;issued<=0;end
  else begin
   if(in_req && in_ready)begin occupied<=1;issued<=0;out_bank<=in_bank;out_addr<=in_addr;end
   if(out_req && out_ready)issued<=1;
   if(returned)begin occupied<=0;issued<=0;end
  end
 end
endmodule

// One elastic write beat. Address, length and bytes are held together until
// accepted. A last queued beat drains before the layer flush is asserted.
module nn_write_descriptor_pipe #(parameter integer AW=24)(
 input wire clk,rst_n,clear,enable,in_req,output wire in_ready,
 input wire [1:0] in_bank,input wire [AW-1:0] in_addr,
 input wire [255:0] in_data,input wire [5:0] in_n,
 output wire out_req,input wire out_ready,
 output reg [1:0] out_bank,output reg [AW-1:0] out_addr,
 output reg [255:0] out_data,output reg [5:0] out_n,output wire busy,
 output reg [AW:0] out_end);
 reg valid;
 assign in_ready=(!valid || out_ready) && enable && !clear;
 assign out_req=valid;
 assign busy=valid;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin valid<=0;out_bank<=0;out_addr<=0;out_data<=0;out_n<=0;out_end<=0;end
  else if(clear)valid<=0;
  else begin
   if(out_req && out_ready)valid<=0;
   if(in_req && in_ready)begin valid<=1;out_bank<=in_bank;out_addr<=in_addr;out_data<=in_data;out_n<=in_n;out_end<={1'b0,in_addr}+in_n;end
  end
 end
endmodule
