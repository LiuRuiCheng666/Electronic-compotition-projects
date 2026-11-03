//============================================================================
//  win_cache.v -- tile window cache (sequential write, random read)
//----------------------------------------------------------------------------
//  Holds one TILE of windows: DEPTH pixels, each carrying CING input-channel
//  groups (one 3x3 window each).  It is the bridge between
//
//    WRITE side: the line buffers emit one PIXEL BUNDLE per cycle, in the
//                order pixel0{group0..groupN}, pixel1{...}, ... (sequential)
//
//    READ  side: the controller walks the tile in the order
//                output-group -> input-group -> pixel, which is a RANDOM
//                access pattern w.r.t. the write order
//
//  Why a FIFO is NOT enough
//    A FIFO can only be read in write order.  The compute order needs, for a
//    fixed input-group, all pixels of the tile, which are strided by CING in
//    the write stream.  So the storage must accept a random read address.
//    (v1 of this idea used win_fifo; the stride mismatch is why it was
//    replaced here.)
//
//  Storage organisation
//    DEPTH*CING entries, each DW bits.  A wide input bundle is captured once
//    and written into the narrow RAM one channel group per cycle.  The read
//    address directly selects {pixel, group}, avoiding a CING-way wide RAM and
//    its large post-read mux.
//
//  Back-pressure
//    wr_ready is low while full, so the caller can freeze the line buffers
//    (stall) -- the same contract as win_fifo.
//
//  Read latency
//    rd_bundle is REGISTERED (1 cycle after rd_addr), rd_group adds the mux
//    (combinational), so rd_group is valid 1 cycle after rd_addr is presented.
//============================================================================

`default_nettype none

//----------------------------------------------------------------------------
//  Simple dual-port synchronous RAM.
//  Keep the storage primitive isolated from the serializer so Efinity sees
//  the same fixed-role RAM template already used by line_ram/frame_store_lane.
//----------------------------------------------------------------------------
module win_cache_ram #(
    parameter integer DW = 144,
    parameter integer AW = 9
)(
    input  wire             clk,
    input  wire             wr_en,
    input  wire [AW-1:0]    wr_addr,
    input  wire [DW-1:0]    wr_data,
    input  wire             rd_en,
    input  wire [AW-1:0]    rd_addr,
    output reg  [DW-1:0]    rd_data
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge clk)
        if (wr_en)
            mem[wr_addr] <= wr_data;

    always @(posedge clk)
        if (rd_en)
            rd_data <= mem[rd_addr];
endmodule

module win_cache #(
    parameter integer ACTIVE_GROUPS = 0,
    parameter integer RING = 0,
    parameter integer CING  = 2,        // input-channel groups per pixel
    parameter integer DW    = 288,      // one group's window width (bits)
    parameter integer DEPTH = 32,       // pixels per tile
    parameter integer AW    = 5,        // $clog2(DEPTH)
    parameter integer GW    = 1         // $clog2(CING)
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- sequential write: one pixel bundle per cycle ----
    input  wire [GW:0]              cfg_cing,
    input  wire                     wr_valid,
    output wire                     wr_ready,
    input  wire [CING*DW-1:0]       wr_bundle,

    // ---- flush: reset the write pointer/count so the cache can be reused
    //      for the next tile (called while idle, between tiles) ----
    input  wire                     flush,
    input  wire                     release_tile,
    input  wire [AW:0]              release_pixels,

    // ---- random read: pick any stored pixel, then any group ----
    input  wire [AW-1:0]            rd_addr,
    input  wire [GW-1:0]            cig_sel,
    output wire [DW-1:0]            rd_group,
    output wire                     rd_valid,

    // ---- status ----
    output wire [AW:0]              count,
    output wire                     full,
    output wire                     empty,
    output reg                      wr_busy
);

    localparam integer MEM_DEPTH = DEPTH * CING;
    localparam integer MAW = (MEM_DEPTH > 1) ? $clog2(MEM_DEPTH) : 1;


    reg [AW:0]   cnt;
    reg [AW-1:0] wptr;
    reg [GW-1:0] wr_group;
    reg [GW:0] groups_hold;
    wire [GW:0] groups_now = (ACTIVE_GROUPS != 0) ? cfg_cing : CING;
    reg [CING*DW-1:0] bundle_hold;

    assign count    = cnt;
    assign full     = (cnt == DEPTH);
    assign empty    = (cnt == 0);
    assign wr_ready = (cnt != DEPTH) && !wr_busy;
    assign rd_valid = 1'b1;                         // registered read, always on

    wire do_accept = wr_valid && wr_ready;
    wire finish_pixel = (do_accept && groups_now==1) ||
                        (wr_busy && ({1'b0,wr_group}+1'b1==groups_hold));
    wire [MAW-1:0] wr_group_addr = wptr * CING + wr_group;
    wire [MAW-1:0] wr_first_addr = wptr * CING;
    wire [MAW-1:0] rd_mem_addr   = rd_addr * CING + cig_sel;

    // Present exactly one fixed-width write port to the RAM.  All variable
    // slicing and address selection stay outside the inference template.
    wire             ram_wr_en   = wr_busy || do_accept;
    wire [MAW-1:0]   ram_wr_addr = do_accept ? wr_first_addr : wr_group_addr;
    wire [DW-1:0] held_group;
    // With exactly two groups the serializer can only visit group one after
    // the direct group-zero write. Avoid retaining/reselecting group zero.
    generate if(CING==2)begin:G_TWO_GROUP_HOLD
        assign held_group=bundle_hold[DW +: DW];
`ifndef SYNTHESIS
        always @(posedge clk)if(rst_n && wr_busy && wr_group!=1)
            $fatal(1,"two-group serializer attempted a non-second group");
`endif
    end else begin:G_GENERIC_GROUP_HOLD
        assign held_group=bundle_hold[wr_group*DW +: DW];
    end endgenerate
    wire [DW-1:0] ram_wr_data=do_accept?wr_bundle[0 +: DW]:held_group;
    wire [DW-1:0]    group_r;

    win_cache_ram #(.DW(DW), .AW(MAW)) u_ram (
        .clk(clk),
        .wr_en(ram_wr_en), .wr_addr(ram_wr_addr), .wr_data(ram_wr_data),
        .rd_en(1'b1), .rd_addr(rd_mem_addr), .rd_data(group_r)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= {(AW+1){1'b0}};
            wptr        <= {AW{1'b0}};
            wr_group    <= {GW{1'b0}};
            groups_hold <= CING;
            wr_busy     <= 1'b0;
            bundle_hold <= {(CING*DW){1'b0}};
        end else if (flush) begin
            cnt      <= {(AW+1){1'b0}};
            wptr     <= {AW{1'b0}};
            wr_group <= {GW{1'b0}};
            wr_busy  <= 1'b0;
        end else begin
            if (RING!=0) begin
                case ({finish_pixel,release_tile})
                    2'b10: cnt<=cnt+1'b1;
                    2'b01: cnt<=cnt-release_pixels;
                    2'b11: cnt<=cnt+1'b1-release_pixels;
                    default: cnt<=cnt;
                endcase
            end
            if (do_accept) begin
                bundle_hold <= wr_bundle;
                groups_hold <= groups_now;
                if (groups_now == 1) begin
                    wptr <= wptr + 1'b1;
                    if (RING==0) cnt <= cnt + 1'b1;
                end else begin
                    wr_group <= 1'b1;
                    wr_busy  <= 1'b1;
                end
            end else if (wr_busy) begin
                if ({1'b0,wr_group} + 1'b1 == groups_hold) begin
                    wr_group <= {GW{1'b0}};
                    wr_busy  <= 1'b0;
                    wptr     <= wptr + 1'b1;
                    if (RING==0) cnt <= cnt + 1'b1;
                end else begin
                    wr_group <= wr_group + 1'b1;
                end
            end
        end
    end

    assign rd_group = group_r;

endmodule

`default_nettype wire
