`timescale 1ns/1ps
`default_nettype none
// Global boot lifetime: local per-frame NN reset never reloads weights.
module camera_nn_weight_boot_mux #(parameter integer TWO_MODELS=0, MODEL_COUNT=(TWO_MODELS!=0)?2:1, CORE_HZ=100000000, parameter integer WEIGHT_BYTES=1760, SPI_CLK_DIV=4, parameter [23:0] FLASH_ADDR=24'h400000, parameter [31:0] DDR_ADDR=32'h01800000)(
input wire clk,rst_n,cal_done,
input wire [2:0] select_model,
input wire inference_idle,
output wire [2:0] active_model,
output wire cfg_we,cfg_tanh,
output wire [7:0] cfg_index,
output wire [63:0] cfg_data,
output wire ready,failed,
output wire [2:0] fault_code,
output wire flash_sclk,flash_mosi,flash_cs_n,
input wire flash_miso,
input wire [3:0] n_axi_awid,
output wire [3:0] m_axi_awid,
input wire [31:0] n_axi_awaddr,
output wire [31:0] m_axi_awaddr,
input wire [7:0] n_axi_awlen,
output wire [7:0] m_axi_awlen,
input wire [2:0] n_axi_awsize,
output wire [2:0] m_axi_awsize,
input wire [1:0] n_axi_awburst,
output wire [1:0] m_axi_awburst,
input wire n_axi_awlock,
output wire m_axi_awlock,
input wire [3:0] n_axi_awcache,
output wire [3:0] m_axi_awcache,
input wire [2:0] n_axi_awprot,
output wire [2:0] m_axi_awprot,
input wire n_axi_awvalid,
output wire m_axi_awvalid,
output wire n_axi_awready,
input wire m_axi_awready,
input wire [127:0] n_axi_wdata,
output wire [127:0] m_axi_wdata,
input wire [15:0] n_axi_wstrb,
output wire [15:0] m_axi_wstrb,
input wire n_axi_wlast,
output wire m_axi_wlast,
input wire n_axi_wvalid,
output wire m_axi_wvalid,
output wire n_axi_wready,
input wire m_axi_wready,
output wire [3:0] n_axi_bid,
input wire [3:0] m_axi_bid,
output wire [1:0] n_axi_bresp,
input wire [1:0] m_axi_bresp,
output wire n_axi_bvalid,
input wire m_axi_bvalid,
input wire n_axi_bready,
output wire m_axi_bready,
input wire [3:0] n_axi_arid,
output wire [3:0] m_axi_arid,
input wire [31:0] n_axi_araddr,
output wire [31:0] m_axi_araddr,
input wire [7:0] n_axi_arlen,
output wire [7:0] m_axi_arlen,
input wire [2:0] n_axi_arsize,
output wire [2:0] m_axi_arsize,
input wire [1:0] n_axi_arburst,
output wire [1:0] m_axi_arburst,
input wire n_axi_arlock,
output wire m_axi_arlock,
input wire [3:0] n_axi_arcache,
output wire [3:0] m_axi_arcache,
input wire [2:0] n_axi_arprot,
output wire [2:0] m_axi_arprot,
input wire n_axi_arvalid,
output wire m_axi_arvalid,
output wire n_axi_arready,
input wire m_axi_arready,
output wire [3:0] n_axi_rid,
input wire [3:0] m_axi_rid,
output wire [127:0] n_axi_rdata,
input wire [127:0] m_axi_rdata,
output wire [1:0] n_axi_rresp,
input wire [1:0] m_axi_rresp,
output wire n_axi_rlast,
input wire m_axi_rlast,
output wire n_axi_rvalid,
input wire m_axi_rvalid,
input wire n_axi_rready,
output wire m_axi_rready
);
reg launched,start;wire done,passed,boot_failed;wire [2:0] boot_fault;
wire meta_ready,meta_failed,meta_busy,meta_arvalid,meta_arready,meta_rready;
wire [31:0] meta_araddr;
reg meta_start;
wire boot_ok=done && passed && !boot_failed;
assign failed=boot_failed || meta_failed;
assign fault_code=boot_failed?boot_fault:(meta_failed?3'd5:3'd0);
// New inference admission follows the requested model, but AXI for an
// already-running inference must continue until it becomes idle.
wire nn_bus_enabled=boot_ok && !failed && meta_ready && !meta_busy;
assign ready=boot_ok && !meta_failed && meta_ready && (MODEL_COUNT==1 || select_model==active_model);
generate if(MODEL_COUNT>1)begin:G_DUAL
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)meta_start<=0;
  else begin meta_start<=0;
   if(boot_ok && inference_idle && !meta_busy && !meta_start && !meta_failed && (!meta_ready || select_model!=active_model)) meta_start<=1;
  end
 end
 a4_model_parameters #(.DDR_BASE(DDR_ADDR),.MODEL_COUNT(MODEL_COUNT)) u_params(.clk(clk),.rst_n(rst_n),.start(meta_start),.model(select_model),
  .busy(meta_busy),.ready(meta_ready),.failed(meta_failed),.active_model(active_model),
  .cfg_we(cfg_we),.cfg_tanh(cfg_tanh),.cfg_index(cfg_index),.cfg_data(cfg_data),
  .araddr(meta_araddr),.arvalid(meta_arvalid),.arready(meta_arready),
  .rdata(m_axi_rdata),.rresp((m_axi_rid!=0)?2'b10:m_axi_rresp),.rlast(m_axi_rlast),.rvalid(m_axi_rvalid && meta_busy),.rready(meta_rready));
end else begin:G_SINGLE
 assign meta_ready=1;assign meta_failed=0;assign meta_busy=0;assign meta_arvalid=0;assign meta_rready=0;assign meta_araddr=0;
 assign active_model=0;assign cfg_we=0;assign cfg_tanh=0;assign cfg_index=0;assign cfg_data=0;
end endgenerate
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin launched<=0;start<=0;end
 else begin start<=0;if(cal_done && !launched)begin launched<=1;start<=1;end end
end
wire [3:0] boot_awid;
wire [31:0] boot_awaddr;
wire [7:0] boot_awlen;
wire [2:0] boot_awsize;
wire [1:0] boot_awburst;
wire boot_awlock;
wire [3:0] boot_awcache;
wire [2:0] boot_awprot;
wire boot_awvalid;
wire boot_awready;
wire [127:0] boot_wdata;
wire [15:0] boot_wstrb;
wire boot_wlast;
wire boot_wvalid;
wire boot_wready;
wire [3:0] boot_bid;
wire [1:0] boot_bresp;
wire boot_bvalid;
wire boot_bready;
spi_flash_weight_loader #(.FLASH_BASE_ADDR(FLASH_ADDR),.DDR_BASE_ADDR(DDR_ADDR),.PAYLOAD_BYTES(WEIGHT_BYTES),.SPI_CLK_DIV(SPI_CLK_DIV),.WAKE_WAIT_CYCLES(CORE_HZ/5000+1)) u_loader(.clk(clk),
.rst_n(rst_n),
.start(start),
.runtime_flash_addr(24'd0),
.done(done),
.pass(passed),
.fail(boot_failed),
.fault_code(boot_fault),
.flash_sclk(flash_sclk),
.flash_mosi(flash_mosi),
.flash_cs_n(flash_cs_n),
.flash_miso(flash_miso),
.m_axi_awid(boot_awid),
.m_axi_awaddr(boot_awaddr),
.m_axi_awlen(boot_awlen),
.m_axi_awsize(boot_awsize),
.m_axi_awburst(boot_awburst),
.m_axi_awlock(boot_awlock),
.m_axi_awcache(boot_awcache),
.m_axi_awprot(boot_awprot),
.m_axi_awvalid(boot_awvalid),
.m_axi_awready(boot_awready),
.m_axi_wdata(boot_wdata),
.m_axi_wstrb(boot_wstrb),
.m_axi_wlast(boot_wlast),
.m_axi_wvalid(boot_wvalid),
.m_axi_wready(boot_wready),
.m_axi_bid(boot_bid),
.m_axi_bresp(boot_bresp),
.m_axi_bvalid(boot_bvalid),
.m_axi_bready(boot_bready));
assign m_axi_awid=nn_bus_enabled?n_axi_awid:boot_awid;
assign m_axi_awaddr=nn_bus_enabled?n_axi_awaddr:boot_awaddr;
assign m_axi_awlen=nn_bus_enabled?n_axi_awlen:boot_awlen;
assign m_axi_awsize=nn_bus_enabled?n_axi_awsize:boot_awsize;
assign m_axi_awburst=nn_bus_enabled?n_axi_awburst:boot_awburst;
assign m_axi_awlock=nn_bus_enabled?n_axi_awlock:boot_awlock;
assign m_axi_awcache=nn_bus_enabled?n_axi_awcache:boot_awcache;
assign m_axi_awprot=nn_bus_enabled?n_axi_awprot:boot_awprot;
assign m_axi_awvalid=nn_bus_enabled?n_axi_awvalid:boot_awvalid;
assign n_axi_awready=nn_bus_enabled && m_axi_awready;
assign boot_awready=!nn_bus_enabled && m_axi_awready;
assign m_axi_wdata=nn_bus_enabled?n_axi_wdata:boot_wdata;
assign m_axi_wstrb=nn_bus_enabled?n_axi_wstrb:boot_wstrb;
assign m_axi_wlast=nn_bus_enabled?n_axi_wlast:boot_wlast;
assign m_axi_wvalid=nn_bus_enabled?n_axi_wvalid:boot_wvalid;
assign n_axi_wready=nn_bus_enabled && m_axi_wready;
assign boot_wready=!nn_bus_enabled && m_axi_wready;
assign n_axi_bid=m_axi_bid;
assign boot_bid=m_axi_bid;
assign n_axi_bresp=m_axi_bresp;
assign boot_bresp=m_axi_bresp;
assign n_axi_bvalid=nn_bus_enabled && m_axi_bvalid;
assign boot_bvalid=!nn_bus_enabled && m_axi_bvalid;
assign m_axi_bready=nn_bus_enabled?n_axi_bready:boot_bready;
assign m_axi_arid=meta_busy?4'd0:n_axi_arid;
assign m_axi_araddr=meta_busy?meta_araddr:n_axi_araddr;
assign m_axi_arlen=meta_busy?8'd0:n_axi_arlen;
assign m_axi_arsize=meta_busy?3'd4:n_axi_arsize;
assign m_axi_arburst=meta_busy?2'd1:n_axi_arburst;
assign m_axi_arlock=meta_busy?1'b0:n_axi_arlock;
assign m_axi_arcache=meta_busy?4'd0:n_axi_arcache;
assign m_axi_arprot=meta_busy?3'd0:n_axi_arprot;
assign m_axi_arvalid=meta_busy?meta_arvalid:(nn_bus_enabled && n_axi_arvalid);
assign meta_arready=meta_busy && m_axi_arready;
assign n_axi_arready=nn_bus_enabled && m_axi_arready;
assign n_axi_rid=m_axi_rid;
assign n_axi_rdata=m_axi_rdata;
assign n_axi_rresp=m_axi_rresp;
assign n_axi_rlast=m_axi_rlast;
assign n_axi_rvalid=nn_bus_enabled && m_axi_rvalid;
assign m_axi_rready=meta_busy?meta_rready:(nn_bus_enabled && n_axi_rready);
endmodule
`default_nettype wire

`timescale 1ns/1ps
`default_nettype none
// Read only the selected model's small metadata from DDR between inferences.
// Kernels stay in DDR. No full-model block RAM is allocated here.
module a4_model_parameters #(
 parameter [31:0] DDR_BASE=32'h01800000,
 parameter integer TIMEOUT_BITS=24, MODEL_COUNT=2
)(
 input wire clk,rst_n,start,
 input wire [2:0] model,
 output reg busy,ready,failed,
 output reg [2:0] active_model,
 output reg cfg_we,cfg_tanh,
 output reg [7:0] cfg_index,
 output wire [63:0] cfg_data,
 output wire [31:0] araddr,
 output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [1:0] rresp,
 input wire rlast,rvalid,output wire rready
);
 localparam IDLE=0,ADDR=1,READ=2,EMIT=3,FINISH=4,FAIL=5;
 reg [2:0] state;
 reg kind;
 reg [5:0] beat;
 reg [4:0] lane;
 reg [127:0] hold_data;
 reg [TIMEOUT_BITS-1:0] timeout_count;
 // Present the existing beat buffer directly. Shift only when the consumer
 // samples cfg_we, preserving the original write cycles without a second 64-bit bank.
 assign cfg_data=cfg_tanh?{56'd0,hold_data[7:0]}:hold_data[63:0];
 assign araddr=DDR_BASE+{17'd0,active_model,12'd0}+(kind?32'ha00:32'h800)+({26'd0,beat}<<4);
 assign arvalid=(state==ADDR);
 assign rready=(state==READ);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;busy<=0;ready<=0;failed<=0;active_model<=1;
   cfg_we<=0;cfg_tanh<=0;cfg_index<=0;
   kind<=0;beat<=0;lane<=0;hold_data<=0;timeout_count<=0;
  end else begin
   cfg_we<=0;
   if(cfg_we)hold_data<=cfg_tanh?(hold_data>>8):(hold_data>>64);
   if(state==ADDR || state==READ)begin
    timeout_count<=timeout_count+1'b1;
    if(&timeout_count)begin failed<=1;ready<=0;busy<=0;state<=FAIL;end
   end else timeout_count<=0;
   if(!((state==ADDR || state==READ) && &timeout_count)) case(state)
    IDLE:if(start && !failed)begin
     if(model>=MODEL_COUNT)begin failed<=1;ready<=0;busy<=0;state<=FAIL;end
     else begin active_model<=model;kind<=0;beat<=0;lane<=0;busy<=1;ready<=0;state<=ADDR;end
    end
    ADDR:if(arready)begin state<=READ;timeout_count<=0;end
    READ:if(rvalid)begin
     if(rresp!=0 || !rlast)begin failed<=1;ready<=0;busy<=0;state<=FAIL;end
     else begin hold_data<=rdata;lane<=0;state<=EMIT;end
    end
    EMIT:begin
     cfg_we<=1;cfg_tanh<=kind;
     if(kind)begin cfg_index<={beat[3:0],4'd0}+lane[3:0];end
     else begin cfg_index<={beat[4:0],1'b0}+lane[0];end
     if(lane==(kind?15:1))begin
      lane<=0;
      if(beat==(kind?15:19))begin
       if(!kind)begin kind<=1;beat<=0;state<=ADDR;end
       else state<=FINISH;
      end else begin beat<=beat+1'b1;state<=ADDR;end
     end else lane<=lane+1'b1;
    end
    FINISH:begin ready<=1;busy<=0;state<=IDLE;end
    FAIL:begin busy<=0;ready<=0;end
    default:;
   endcase
  end
 end
endmodule
`default_nettype wire
