module axi_ddr_arbiter_2 (
    input wire clk,
    input wire rst_n,
    input wire [1:0] read_urgent,
    input wire [1:0] read_critical,

    // 两个主设备的写地址
    input  wire [1:0][5:0]  m_awid,
    input  wire [1:0][31:0] m_awaddr,
    input  wire [1:0][7:0]  m_awlen,
    input  wire [1:0][2:0]  m_awsize,
    input  wire [1:0][1:0]  m_awburst,
    input  wire [1:0]       m_awlock,
    input  wire [1:0][3:0]  m_awcache,
    input  wire [1:0][2:0]  m_awprot,
    input  wire [1:0]       m_awvalid,
    output wire [1:0]       m_awready,

    input  wire [1:0][127:0] m_wdata,
    input  wire [1:0][15:0]  m_wstrb,
    input  wire [1:0]        m_wlast,
    input  wire [1:0]        m_wvalid,
    output wire [1:0]        m_wready,

    output wire [1:0][5:0] m_bid,
    output wire [1:0][1:0] m_bresp,
    output wire [1:0]      m_bvalid,
    input  wire [1:0]      m_bready,

    // 两个主设备的读地址
    input  wire [1:0][5:0]  m_arid,
    input  wire [1:0][31:0] m_araddr,
    input  wire [1:0][7:0]  m_arlen,
    input  wire [1:0][2:0]  m_arsize,
    input  wire [1:0][1:0]  m_arburst,
    input  wire [1:0]       m_arlock,
    input  wire [1:0][3:0]  m_arcache,
    input  wire [1:0][2:0]  m_arprot,
    input  wire [1:0]       m_arvalid,
    output wire [1:0]       m_arready,

    output wire [1:0][5:0]   m_rid,
    output wire [1:0][127:0] m_rdata,
    output wire [1:0][1:0]   m_rresp,
    output wire [1:0]        m_rlast,
    output wire [1:0]        m_rvalid,
    input  wire [1:0]        m_rready,

    // 唯一 DDR 控制器接口
    output wire [3:0]   s_awid,
    output wire [31:0]  s_awaddr,
    output wire [7:0]   s_awlen,
    output wire [2:0]   s_awsize,
    output wire [1:0]   s_awburst,
    output wire         s_awlock,
    output wire [3:0]   s_awcache,
    output wire [2:0]   s_awprot,
    output wire         s_awvalid,
    input  wire         s_awready,

    output wire [127:0] s_wdata,
    output wire [15:0]  s_wstrb,
    output wire         s_wlast,
    output wire         s_wvalid,
    input  wire         s_wready,

    input  wire [3:0] s_bid,
    input  wire [1:0] s_bresp,
    input  wire       s_bvalid,
    output wire       s_bready,

    output wire [3:0]  s_arid,
    output wire [31:0] s_araddr,
    output wire [7:0]  s_arlen,
    output wire [2:0]  s_arsize,
    output wire [1:0]  s_arburst,
    output wire        s_arlock,
    output wire [3:0]  s_arcache,
    output wire [2:0]  s_arprot,
    output wire        s_arvalid,
    input  wire        s_arready,

    input  wire [3:0]   s_rid,
    input  wire [127:0] s_rdata,
    input  wire [1:0]   s_rresp,
    input  wire         s_rlast,
    input  wire         s_rvalid,
    output wire         s_rready,
    input wire          debug_enable,
    output wire [2:0]   debug_write_code,
    output wire [2:0] debug_read_state
);

localparam W_IDLE = 2'd0;
localparam W_ADDR = 2'd1;
localparam W_DATA = 2'd2;
localparam W_RESP = 2'd3;

localparam R_IDLE = 2'd0;
localparam R_ADDR = 2'd1;
localparam R_DATA = 2'd2;

reg [1:0] w_state;
reg [1:0] r_state;
reg w_owner, r_owner;
assign debug_read_state={r_owner,r_state};
reg w_turn,  r_turn;

// Passive LIVE diagnostic code. Reset the age on ANY write handshake,
// owner/state change, or idle without a video request. No fault drives control.
reg [19:0] dbg_no_progress;
reg [1:0] dbg_previous_state;
reg dbg_previous_owner;
wire dbg_progress = (s_awvalid && s_awready) ||
    (s_wvalid && s_wready) || (s_bvalid && s_bready);
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dbg_no_progress <= 0;
        dbg_previous_state <= W_IDLE;
        dbg_previous_owner <= 0;
    end else begin
        dbg_previous_state <= w_state;
        dbg_previous_owner <= w_owner;
        if (!debug_enable || dbg_progress ||
            (w_state != dbg_previous_state) || (w_owner != dbg_previous_owner) ||
            ((w_state == W_IDLE) && !m_awvalid[0])) dbg_no_progress <= 0;
        else if (!(&dbg_no_progress)) dbg_no_progress <= dbg_no_progress + 1'b1;
    end
end
// Codes use D3:D2:D1 as a binary number; D0 stays the heartbeat.
// 1: video request not forwarded (idle, or selected video withdrew AW).
// 2/3/4: video-owned AW / W / B no progress.
// 5/6/7: NN-port-owned AW / W / B no progress.
assign debug_write_code = !(debug_enable && (&dbg_no_progress)) ? 3'd0 :
    (w_state == W_IDLE) ? 3'd1 :
    (w_state == W_ADDR) ? (w_owner ? 3'd5 : (s_awvalid ? 3'd2 : 3'd1)) :
    (w_state == W_DATA) ? (w_owner ? 3'd6 : 3'd3) :
    (w_state == W_RESP) ? (w_owner ? 3'd7 : 3'd4) : 3'd1;

// 请求被选中后，锁住归属直到整个事务结束。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        w_state <= W_IDLE;
        w_owner <= 1'b0;
        w_turn  <= 1'b0;
    end else begin
        case (w_state)
            W_IDLE: begin
                if (|m_awvalid) begin
                    if (&m_awvalid)
                        w_owner <= w_turn;
                    else
                        w_owner <= m_awvalid[1];

                    w_state <= W_ADDR;
                end
            end

            W_ADDR: begin
                if (s_awvalid && s_awready)
                    w_state <= W_DATA;
            end

            W_DATA: begin
                if (s_wvalid && s_wready && s_wlast)
                    w_state <= W_RESP;
            end

            W_RESP: begin
                if (s_bvalid && s_bready) begin
                    w_turn  <= ~w_owner;
                    w_state <= W_IDLE;
                end
            end

            default: w_state <= W_IDLE;
        endcase
    end
end

// Prefer an urgent reader for at most three consecutive grants when both
// readers contend. Ownership stays fixed through AR stalls and the last R beat.
// Bridge the short unpack/next-burst gap before committing a competing
// long transfer. Grace is capped; three consecutive grants also force service.
reg [1:0] read_run;
reg read_last;
reg [4:0] read_grace;
reg grace_owner,urgent_active,critical_active;
always @*begin
 grace_owner=0;urgent_active=0;critical_active=0;
 case(read_urgent)
  2'b01:begin grace_owner=0;urgent_active=1;end
  2'b10:begin grace_owner=1;urgent_active=1;end
  default:begin end
 endcase
 // Emergency video refill may exceed the normal 3:1 quota. Two endangered
 // video readers remain round-robin peers; an unconnected input is inert.
 case(read_critical)
  2'b01:begin grace_owner=0;urgent_active=1;critical_active=1;end
  2'b10:begin grace_owner=1;urgent_active=1;critical_active=1;end
  2'b11:urgent_active=0;
  default:begin end
 endcase
end
wire grace_request=urgent_active &&
                   !m_arvalid[grace_owner] && m_arvalid[!grace_owner] &&
                   (critical_active || !(read_last==grace_owner && read_run==3));
wire grace_wait=grace_request && read_grace<(critical_active?16:4);
reg read_choice;
always @* begin
 read_choice=m_arvalid[1];
 if(&m_arvalid)begin
  case(read_urgent)
   2'b01:read_choice=(read_last==0 && read_run==3)?1'b1:1'b0;
   2'b10:read_choice=(read_last==1 && read_run==3)?1'b0:1'b1;
   default:read_choice=r_turn;
  endcase
  case(read_critical)
   2'b01:read_choice=0;
   2'b10:read_choice=1;
   2'b11:read_choice=r_turn;
   default:begin end
  endcase
 end
end
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_state <= R_IDLE;
        r_owner <= 1'b0;
        r_turn  <= 1'b0;read_run<=0;read_last<=0;read_grace<=0;
    end else begin
        if(r_state==R_IDLE && grace_wait)read_grace<=read_grace+1'b1;
        else if(r_state!=R_IDLE || !grace_request)read_grace<=0;
        case (r_state)
            R_IDLE: begin
                if ((|m_arvalid) && !grace_wait) begin
                    r_owner<=read_choice;
                    read_last<=read_choice;
                    if(read_choice!=read_last)read_run<=1;
                    else if(read_run<3)read_run<=read_run+1'b1;

                    r_state <= R_ADDR;
                end
            end

            R_ADDR: begin
                if (s_arvalid && s_arready)
                    r_state <= R_DATA;
            end

            R_DATA: begin
                if (s_rvalid && s_rready && s_rlast) begin
                    r_turn  <= ~r_owner;
                    r_state <= R_IDLE;
                end
            end

            default: r_state <= R_IDLE;
        endcase
    end
end

// 当前两个主设备都使用ID=0。
// 控制器ID是4位；视频模块端口是6位。
assign s_awid    = m_awid[w_owner][3:0];
assign s_awaddr  = m_awaddr[w_owner];
assign s_awlen   = m_awlen[w_owner];
assign s_awsize  = m_awsize[w_owner];
assign s_awburst = m_awburst[w_owner];
assign s_awlock  = m_awlock[w_owner];
assign s_awcache = m_awcache[w_owner];
assign s_awprot  = m_awprot[w_owner];

assign s_awvalid =
    rst_n && (w_state == W_ADDR) && m_awvalid[w_owner];

assign s_wdata = m_wdata[w_owner];
assign s_wstrb = m_wstrb[w_owner];
assign s_wlast = m_wlast[w_owner];

assign s_wvalid =
    rst_n && (w_state == W_DATA) && m_wvalid[w_owner];

assign s_bready =
    rst_n && (w_state == W_RESP) && m_bready[w_owner];

assign s_arid    = m_arid[r_owner][3:0];
assign s_araddr  = m_araddr[r_owner];
assign s_arlen   = m_arlen[r_owner];
assign s_arsize  = m_arsize[r_owner];
assign s_arburst = m_arburst[r_owner];
assign s_arlock  = m_arlock[r_owner];
assign s_arcache = m_arcache[r_owner];
assign s_arprot  = m_arprot[r_owner];

assign s_arvalid =
    rst_n && (r_state == R_ADDR) && m_arvalid[r_owner];

assign s_rready =
    rst_n && (r_state == R_DATA) && m_rready[r_owner];

genvar i;
generate
    for (i = 0; i < 2; i = i + 1) begin : g_return
        assign m_awready[i] =
            rst_n && (w_state == W_ADDR) &&
            (w_owner == i) && s_awready;

        assign m_wready[i] =
            rst_n && (w_state == W_DATA) &&
            (w_owner == i) && s_wready;

        assign m_bid[i]   = {2'b00, s_bid};
        assign m_bresp[i] = s_bresp;
        assign m_bvalid[i] =
            rst_n && (w_state == W_RESP) &&
            (w_owner == i) && s_bvalid;

        assign m_arready[i] =
            rst_n && (r_state == R_ADDR) &&
            (r_owner == i) && s_arready;

        assign m_rid[i]   = {2'b00, s_rid};
        assign m_rdata[i] = s_rdata;
        assign m_rresp[i] = s_rresp;
        assign m_rlast[i] = s_rlast;
        assign m_rvalid[i] =
            rst_n && (r_state == R_DATA) &&
            (r_owner == i) && s_rvalid;
    end
endgenerate

endmodule
