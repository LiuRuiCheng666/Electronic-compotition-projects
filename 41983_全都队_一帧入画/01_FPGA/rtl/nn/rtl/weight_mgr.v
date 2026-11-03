//============================================================================
//  weight_mgr.v -- weight / coefficient fetch engine for the conv core
//----------------------------------------------------------------------------
//  Fetches one (cog, cig) weight group (P_CO x P_CI x TAP bytes) from the
//  external weight store into an on-core register buffer, so the MAC array can
//  read all 288 weights combinationally for a whole pixel tile.
//
//  Why a buffer instead of using the store directly
//    The MAC array needs all NW = 288 weights at once, every cycle, for the
//    whole tile.  A store cannot deliver that; the buffer can.
//
//  Why the 4-block (32 byte/cycle) read port
//    Load time  = NW / RD_B cycles = 288 / 32 = 9 cycles
//    Tile compute = T = 32 cycles
//    So one group's load fits inside one group's compute -> with DOUBLE
//    BUFFERING the load cost disappears entirely and the layer runs at the
//    pure compute rate (8.91 M cycles ~= 35.6 ms instead of 45.1 ms).
//    With a single block (8 byte/cycle) the load would be 36 cycles > 32 and
//    would NOT fit, which is exactly the trap that the missing-load-cost
//    analysis uncovered.
//
//  Double buffering
//    Two buffers.  While the MAC array computes from buffer `sel_buf`, the FSM
//    loads the NEXT group into the other buffer.  `ld_sel` names the target,
//    `sel_buf` names the source; the controller swaps them between groups.
//
//  External store interface
//    mem_addr  byte address, advanced by RD_B each cycle
//    mem_rdata RD_B bytes returned (the store is expected to be registered, so
//              data appears one cycle after the address is issued)
//
//  Load timing (registered-read store)
//    S_IDLE  ld_req -> mem_addr = ld_base, latch base_r
//    S_ADDR  mem_addr stays ld_base during this cycle; its posedge samples it,
//            so row 0's data is valid in the next cycle.  mem_addr is also
//            advanced to ld_base+RD_B here, so that the NEXT posedge samples
//            the address of row 1.
//    S_LD    round 0 writes row 0 and advances mem_addr to base+2*RD_B ...
//            round NCY-1 completes -> ld_done pulses one cycle
//
//    NOTE: because mem_addr is a non-blocking assignment, it must be advanced
//    ONE CYCLE AHEAD of the row being written.  Setting mem_addr = ld_base and
//    then incrementing it inside S_LD would sample the OLD address on the
//    round-0 posedge, so every row after the first would fetch row 0 again.
//    (This is exactly the bug the first version of this module had.)
//    Total latency = 2 + NCY cycles.
//============================================================================

`default_nettype none

module weight_mgr #(
    parameter integer P_CO  = 8,
    parameter integer P_CI  = 4,
    parameter integer TAP   = 9,
    parameter integer CH_W  = 8,
    parameter integer RD_B  = 32,          // bytes fetched per cycle
    parameter integer BRAM_PREFIX_BYTES=0,
    parameter integer CNT_W = 4            // wide enough for NCY
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // ---- external weight store (wide, registered read) ----
    output reg  [31:0]                   mem_addr,
    output wire                          mem_req,
    input  wire                          mem_ready,
    input  wire                          mem_valid,
    input  wire [RD_B*CH_W-1:0]          mem_rdata,

    // ---- load control ----
    input  wire                          ld_req,
    input  wire [31:0]                   ld_base,
    input  wire                          ld_sel,      // target buffer 0/1
    output wire                          ld_busy,
    output wire                          ld_done,

    // ---- output to the MAC array ----
    input  wire                          sel_buf_early,
    input  wire                          sel_buf,     // source buffer 0/1
    output wire [P_CO*P_CI*TAP*CH_W-1:0] w_data
);

    localparam integer NW  = P_CO * P_CI * TAP;                  // 288
    localparam integer NCY = (NW + RD_B - 1) / RD_B;             // 9
    localparam integer DW  = P_CO * P_CI * TAP * CH_W;           // 2304

    reg [CH_W-1:0] buf0 [0:NW-1];
    reg [CH_W-1:0] buf1 [0:NW-1];

    localparam integer S_IDLE = 1'b0, S_LOAD = 1'b1;

    reg                st;
    reg [CNT_W-1:0]    issue_cnt;
    reg [CNT_W-1:0]    recv_cnt;
    reg                tgt;
    reg                done_r;
    reg [31:0]         base_r;

    assign ld_busy = (st != S_IDLE);
    assign ld_done = done_r;
    assign mem_req = (st == S_LOAD) &&
                     (issue_cnt < NCY[CNT_W-1:0]);

    integer j;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            issue_cnt <= {CNT_W{1'b0}};
            recv_cnt  <= {CNT_W{1'b0}};
            tgt      <= 1'b0;
            done_r   <= 1'b0;
            mem_addr <= 32'd0;
            base_r   <= 32'd0;
        end else begin
            done_r <= 1'b0;

            case (st)
                S_IDLE: if (ld_req) begin
                            mem_addr <= ld_base;     // issue the first address
                            base_r   <= ld_base;
                            tgt      <= ld_sel;
                            issue_cnt <= {CNT_W{1'b0}};
                            recv_cnt  <= {CNT_W{1'b0}};
                            st       <= S_LOAD;
                        end

                S_LOAD: begin
                    // Requests may be pipelined when the backing store stays
                    // ready (local ROM), but also tolerate arbitrary DDR
                    // backpressure and response latency.
                    if (mem_req && mem_ready) begin
                        issue_cnt <= issue_cnt + 1'b1;
                        if (issue_cnt + 1'b1 < NCY[CNT_W-1:0])
                            mem_addr <= base_r + (issue_cnt + 1'b1) * RD_B;
                    end

                    if (mem_valid) begin
                            // Constant destination and lane; one beat-select decoder
                            // per word replaces dynamic byte-array write indexing.
                            if (recv_cnt == NCY[CNT_W-1:0] - 1'b1) begin
                                st     <= S_IDLE;
                                done_r <= 1'b1;
                            end else begin
                                recv_cnt <= recv_cnt + 1'b1;
                            end
                        end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // Data is not reset: conv_fsm clears resident_valid on reset and waits
    // for ld_done before issuing MACs. Both banks remain independently loaded.
    // Keeping reset off this wide data path reduces reset routing fanout.
    always @(posedge clk) begin
        if (rst_n && st == S_LOAD && mem_valid) begin
            for (j = BRAM_PREFIX_BYTES; j < NW; j = j + 1) begin
                if (recv_cnt == j / RD_B) begin
                    if (tgt) buf1[j] <= mem_rdata[(j % RD_B)*CH_W +: CH_W];
                    else buf0[j] <= mem_rdata[(j % RD_B)*CH_W +: CH_W];
                end
            end
        end
    end

    generate if(BRAM_PREFIX_BYTES!=0)begin:G_PREFIX_RAM
        localparam PBITS=BRAM_PREFIX_BYTES*CH_W;
        localparam PARTS=(PBITS+19)/20;
        wire [PARTS*20-1:0] loaded={{(PARTS*20-PBITS){1'b0}},mem_rdata[PBITS-1:0]};
        wire [PARTS*20-1:0] selected;
        wire we=rst_n && st==S_LOAD && mem_valid && recv_cnt==0;
        for(genvar part=0;part<PARTS;part=part+1)begin:G_PART
            EFX_RAM10 #(.READ_WIDTH(20),.WRITE_WIDTH(20),.OUTPUT_REG(1'b0),.WRITE_MODE("READ_FIRST")) storage(
                .WCLK(clk),.WCLKE(1'b1),.WADDREN(1'b1),.WE({2{we}}),
                .WADDR({8'd0,tgt}),.WDATA(loaded[part*20+:20]),
                .RCLK(clk),.RE(1'b1),.RADDREN(1'b1),.RST(1'b0),.RADDR({8'd0,sel_buf_early}),
                .RDATA(selected[part*20+:20]));
        end
        assign w_data[PBITS-1:0]=selected[PBITS-1:0];
        initial if(BRAM_PREFIX_BYTES>RD_B || BRAM_PREFIX_BYTES>NW)$fatal(1,"invalid weight prefix");
    end endgenerate

    // ---- output mux: the MAC array sees all NW weights combinationally ----
    genvar g;
    generate
        for (g = BRAM_PREFIX_BYTES; g < NW; g = g + 1) begin : G_OUT
            assign w_data[g*CH_W +: CH_W] = sel_buf ? buf1[g] : buf0[g];
        end
    endgenerate

endmodule

`default_nettype wire
