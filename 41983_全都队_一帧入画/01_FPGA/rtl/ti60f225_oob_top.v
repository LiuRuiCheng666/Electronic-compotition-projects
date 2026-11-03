
        /////////////////////////////////////////////////////////////////////////////
        //
        // Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
        //
        // Description:
        // Example top file for ti60f225 dev kit OOB design
        //
        // Language:  Verilog 2001
        //Ti60f225_sc431hai2hdmi_v6：
        //使用了最新版本的framebuffer_v3;
        // ------------------------------------------------------------------------------

        /////////////////////////////////////////////////////////////////////////////////
        //`define SOFT_TAP 1
        `include "ddr3_controller/ddr3_parameter.vh"
        // `include "define.v"

        module ti60f225_oob_top #(

            parameter integer               NN_CYCLE_PROFILE_ENABLE = 0,
            parameter integer               HDMI_LATEST_FRAME = 1,
            parameter integer               AUTO_LIGHT_ENABLE = 0,
            parameter                       RANK_RATIO         = 1,       // # of unique CS outputs per rank
            parameter                       ASYN_AXI_CLK       = `ASYN_AXI_CLK, 
            parameter                       RANKS              = `RANKS,
            parameter                       CK_WIDTH           = `CK_WIDTH,       // # of CK/CK# outputs to memory   
            parameter                       CKE_WIDTH          = `CKE_WIDTH,       // # of cke outputs
            parameter                       CS_WIDTH           = `CS_WIDTH,       // # of unique CS outputs
            parameter                       BANK_WIDTH         = `BANK_WIDTH,       // # of bank bits
            parameter                       ROW_WIDTH          = `ROW_WIDTH,       // DRAM address bus width
            parameter                       COL_WIDTH          = `COL_WIDTH,      // column address width
            parameter                       DM_WIDTH           = `DM_WIDTH,       // # of DM (data mask)
            parameter                       DQS_WIDTH          = `DQS_WIDTH,       // # of DQS (strobe)
            parameter                       DQ_WIDTH           = `DQ_WIDTH,      // # of DQ (data)
            parameter                       ODT_WIDTH          = `ODT_WIDTH,
            parameter                       DQ_CNT_WIDTH       = `DQ_CNT_WIDTH,       // = ceil(log2(DQ_WIDTH))
            parameter                       DQS_CNT_WIDTH      = `DQS_CNT_WIDTH,       // = ceil(log2(DQS_WIDTH))  
            parameter                       DRAM_WIDTH         = `DRAM_WIDTH,       // # of DQ per DQS   
            parameter                       DATA_WIDTH         = `DATA_WIDTH,
            parameter                       ADDR_WIDTH         = `ADDR_WIDTH,    
            parameter                       AXI_ID_WIDTH       = `AXI_ID_WIDTH,
            parameter                       AXI_ADDR_WIDTH     = `AXI_ADDR_WIDTH,
            parameter                       AXI_DATA_WIDTH     = `AXI_DATA_WIDTH
        )
        (


          input osc_inst1_CLKOUT,rxc,mdio_i,input[3:0]rxd_hi_i,rxd_lo_i,input rx_dv_HI,rx_dv_LO,
          output osc_inst1_ENA,phy_rst_n,mdc_o,mdio_o,mdio_oe,
          output[3:0]txd_hi_o,txd_lo_o,output tx_en_o_HI,tx_en_o_LO,txc_hi_o,txc_lo_o,
          input jtag_inst2_CAPTURE,jtag_inst2_RESET,jtag_inst2_SEL,
          input jtag_inst2_SHIFT,jtag_inst2_TCK,jtag_inst2_TDI,jtag_inst2_UPDATE,
          output jtag_inst2_TDO,
          input system_uart_0_io_rxd,output system_uart_0_io_txd,

           //Clocks 
            input	wire	i_arstn,
            input wire display_sw1_n,
            input wire style_sw2_n,
            input wire fisheye_sw3_n,
            input wire i_mipi_rx_pclk,vid_clk_dvi2,
            //CSI Interface
            input	 wire		io_cam_sda_IN,
            output wire   io_cam_sda_OUT,
            output wire		io_cam_sda_OE,

            output io_cam_scl_OUT,
            input io_cam_scl_IN,
            output io_cam_scl_OE,

            output	wire		o_cam_rst_p,
            
            input	wire		i_cam_ck_LP_P_IN,
            input	wire		i_cam_ck_LP_N_IN,
            output	wire		o_cam_ck_HS_TERM,
            output	wire		o_cam_ck_HS_ENA,
            input	wire		i_cam_ck_CLKOUT,
            
            input	wire	[7:0]			cam_d0_HS_IN,
            input	  wire		      cam_d0_LP_P_IN,
            input	  wire		      cam_d0_LP_N_IN,
            output	wire		      cam_d0_HS_TERM,
            output	wire		      cam_d0_HS_ENA,
            output	wire		      cam_d0_RST,
            output	wire		      cam_d0_FIFO_RD,
            input	  wire		      cam_d0_FIFO_EMPTY,
            
            input 	wire	[7:0]			cam_d1_HS_IN,
            input	  wire		        cam_d1_LP_P_IN,
            input	  wire		        cam_d1_LP_N_IN,
            output	wire		        cam_d1_HS_TERM,
            output	wire		        cam_d1_HS_ENA,
            output	wire		        cam_d1_RST,
            output	wire		        cam_d1_FIFO_RD,
            input	  wire		        cam_d1_FIFO_EMPTY,
            
            input 	wire	[7:0]			cam_d2_HS_IN,
            input	  wire		        cam_d2_LP_P_IN,
            input	  wire		        cam_d2_LP_N_IN,
            output	wire		        cam_d2_HS_TERM,
            output	wire		        cam_d2_HS_ENA,
            output	wire		        cam_d2_RST,
            output	wire		        cam_d2_FIFO_RD,
            input	  wire		        cam_d2_FIFO_EMPTY,  
           
            input 	wire	[7:0]			cam_d3_HS_IN,
            input	  wire		        cam_d3_LP_P_IN,
            input	  wire		        cam_d3_LP_N_IN,
            output	wire		        cam_d3_HS_TERM,
            output	wire		        cam_d3_HS_ENA,
            output	wire		        cam_d3_RST,
            output	wire		        cam_d3_FIFO_RD,
            input	  wire		        cam_d3_FIFO_EMPTY,

            

            input wire mipi_tx_feedback100,
            input wire core_clk, // NN/AXI160MHz; CPU and DDR control stay100MHz

            input wire hdmi_tx_slow_clk,
            input  wire CLK_25M,
            output  wire    pll_inst1_RSTN,
            input	wire	i_pll_locked,
            input 	wire  	pll_locked,
            output  wire  	USER_PLL_RSTN,
            output 	wire 	DDR3_PLL_RSTN,
            input 	wire  	user_pll_locked,
            input 					tx_cal_clk_90edge,
            input 					rx_cal_clk,
            input 					tx_cal_clk,

            input                              sdram_clk,    // SDRAM CK @ 400MHz
            // PLL status flags  
            output [2:0]                       pll_shift,  
            output [4:0]                       pll_shift_sel,
            output                             pll_shift_ena,  
            // memory interface ports
            output                             ddr_ck_hi,
            output                             ddr_ck_lo,
            output                             ddr_reset_n,
            output [CKE_WIDTH-1:0]             ddr_cke,     
            output [ROW_WIDTH-1:0]             ddr_addr,
            output [BANK_WIDTH-1:0]            ddr_ba,
            output                             ddr_cas_n,
         
            output [CS_WIDTH*RANK_RATIO-1:0]   ddr_cs_n,
            output                             ddr_ras_n,
            output                             ddr_we_n,
            
            input  [DQS_WIDTH-1:0]             ddr_dqs_in_hi,
            input  [DQS_WIDTH-1:0]             ddr_dqs_in_lo,
            input  [DQ_WIDTH-1:0]              ddr_dq_in_hi,
            input  [DQ_WIDTH-1:0]              ddr_dq_in_lo,
            
            output [DQS_WIDTH-1:0]             ddr_dqs_oe,
            output [DQS_WIDTH-1:0]             ddr_dqs_oe_n,
            output [DQ_WIDTH-1:0]              ddr_dq_oe,  
            output [DQS_WIDTH-1:0]             ddr_dqs_out_hi,
            output [DQS_WIDTH-1:0]             ddr_dqs_out_lo,
            output [DQ_WIDTH-1:0]              ddr_dq_out_hi,
            output [DQ_WIDTH-1:0]              ddr_dq_out_lo,
            output [DM_WIDTH-1:0]              ddr_dm_hi,
            output [DM_WIDTH-1:0]              ddr_dm_lo,
            output [ODT_WIDTH-1:0]             ddr_odt,

               output spi_flash_SCLK_OUT,spi_flash_MOSI_OUT,spi_flash_CS_N_OUT,
               input spi_flash_MISO_IN,
               //LED
               output [3:0] led,

            input hdmi_rx_slow_clk,hdmi_rx_clk_RX_DATA,hdmi_rx_pll_LOCKED,
            input [9:0] hdmi_rx_d0_RX_DATA,hdmi_rx_d1_RX_DATA,hdmi_rx_d2_RX_DATA,
            output hdmi_rx_pll_RSTN,hdmi_rx_clk_RX_ENA,
            output hdmi_rx_d0_RX_RST,hdmi_rx_d1_RX_RST,hdmi_rx_d2_RX_RST,
            output hdmi_rx_d0_RX_ENA,hdmi_rx_d1_RX_ENA,hdmi_rx_d2_RX_ENA,
            output hdmi_rx_clk_RX_DLY_INC,hdmi_rx_clk_RX_DLY_ENA,hdmi_rx_clk_RX_DLY_RST,
            output HPD_N,input HDMI_5V_N,
            input FPGA_HDMI_SCL_IN,FPGA_HDMI_SDA_IN,
            output FPGA_HDMI_SCL_OUT,FPGA_HDMI_SCL_OE,FPGA_HDMI_SDA_OUT,FPGA_HDMI_SDA_OE,
               // hdmi interface

            output tmds_tx_clk_TX_OE,
            output [9:0] tmds_tx_clk_TX_DATA,
            output tmds_tx_clk_TX_RST,
            output tmds_tx_data0_TX_OE,
            output [9:0] tmds_tx_data0_TX_DATA,
            output tmds_tx_data0_TX_RST,
            output tmds_tx_data1_TX_OE,
            output [9:0] tmds_tx_data1_TX_DATA,
            output tmds_tx_data1_TX_RST,
            output tmds_tx_data2_TX_OE,
            output [9:0] tmds_tx_data2_TX_DATA,
            output tmds_tx_data2_TX_RST


        );

        function integer log2;
            input	integer	val;
            integer	i;
            begin
                log2 = 0;
                for (i=0; 2**i<val; i=i+1)
                    log2 = i+1;
            end
        endfunction


        //===============================================================================
        //localparam
        //===============================================================================
        localparam WR_FIFO_DEPTH  = 1024;
        localparam RD_FIFO_DEPTH  = 1024;

        // localparam	MAX_HRES		= 12'd1920;
        // localparam	MAX_VRES		= 12'd1080;
        // localparam	HSP			= 8'd2;
        // localparam	HBP			= 8'd88;
        // localparam	HFP			= 8'd120;
        // localparam	VSP			= 8'd2;
        // localparam	VBP			= 8'd20;
        // localparam	VFP			= 8'd20;

        localparam MAX_HRES = 1920;
        localparam HFP      = 88;
        localparam HSP      = 44;
        localparam HBP      = 148;

        localparam MAX_VRES = 1080;
        localparam VFP      = 4;
        localparam VSP      = 5;
        localparam VBP      = 36;
        //===============================================================================
        //signal
        //===============================================================================
           
        wire                              app_sr_active;
        wire                              app_ref_ack;
        wire                              app_zq_ack;
        wire                              w_arstn;
        wire weights_boot_ready,weights_boot_failed;wire [2:0] weights_boot_fault;
        // Independent application clock supplied by MIPI_TX_PLL output1.
        wire                              cal_done;
        wire                              ddr_cal_done_100m;
        // DDR controller uses the original MIPI_TX 100 MHz GCLK (formerly core_clk).
        // DDR3_PLL.CLKOUT4 is peripheral RCLK and must not feed core logic.
        // Application AXI and NN remain at 150 MHz through ASYN_AXI_CLK=1.
        (* async_reg="true", syn_preserve=1 *) reg [1:0] ddr_cal_done_sync;
        always @(posedge core_clk or negedge w_arstn) begin
            if(!w_arstn) ddr_cal_done_sync<=2'b00;
            else ddr_cal_done_sync<={ddr_cal_done_sync[0],ddr_cal_done_100m};
        end
        assign cal_done=ddr_cal_done_sync[1];

        // Slave Interface Write Address Ports
        wire [AXI_ID_WIDTH-1:0]           s_axi_awid;
        wire [AXI_ADDR_WIDTH-1:0]         s_axi_awaddr;
        wire [7:0]                        s_axi_awlen;
        wire [2:0]                        s_axi_awsize;
        wire [1:0]                        s_axi_awburst;
        wire [0:0]                        s_axi_awlock;
        wire [3:0]                        s_axi_awcache;
        wire [2:0]                        s_axi_awprot;
        wire                              s_axi_awvalid;
        wire                              s_axi_awready;
        // Slave Interface Write Data Ports
        wire [AXI_DATA_WIDTH-1:0]         s_axi_wdata;
        wire [(AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb;
        wire                              s_axi_wlast;
        wire                              s_axi_wvalid;
        wire                              s_axi_wready;
        // Slave Interface Write Response Ports
        wire                              s_axi_bready;
        wire [AXI_ID_WIDTH-1:0]           s_axi_bid;
        wire [1:0]                        s_axi_bresp;
        wire                              s_axi_bvalid;
        // Slave Interface Read Address Ports
        wire [AXI_ID_WIDTH-1:0]           s_axi_arid;
        wire [AXI_ADDR_WIDTH-1:0]         s_axi_araddr;
        wire [7:0]                        s_axi_arlen;
        wire [2:0]                        s_axi_arsize;
        wire [1:0]                        s_axi_arburst;
        wire [0:0]                        s_axi_arlock;
        wire [3:0]                        s_axi_arcache;
        wire [2:0]                        s_axi_arprot;
        wire                              s_axi_arvalid;
        wire                              s_axi_arready;
        // Slave Interface Read Data Ports
        wire                              s_axi_rready;
        wire [AXI_ID_WIDTH-1:0]           s_axi_rid;
        wire [AXI_DATA_WIDTH-1:0]         s_axi_rdata;
        wire [1:0]                        s_axi_rresp;
        wire                              s_axi_rlast;
        wire                              s_axi_rvalid;
// ============================================================
// Two AXI masters before DDR arbiter
// [0] = camera frame_buffer (checker0)
// [1] = RGBX DDR capture, or legacy test when disabled
localparam RGBX_DDR_CAPTURE_EN = 1'b1;
// ============================================================

wire [1:0][5:0]  m_awid, m_bid, m_arid, m_rid;
wire [1:0][31:0] m_awaddr, m_araddr;
wire [1:0][7:0]  m_awlen, m_arlen;
wire [1:0][2:0]  m_awsize, m_arsize;
wire [1:0][1:0]  m_awburst, m_arburst;

wire [1:0]       m_awlock, m_arlock;
wire [1:0][3:0]  m_awcache, m_arcache;
wire [1:0][2:0]  m_awprot, m_arprot;


// Image task ownership is independent of CPU-local reset. Only the shared
// DDR/system reset may clear live AXI transactions and lease generation.
wire image_hold,image_hold_ack,image_capture_idle,image_pause,image_axi_owner,image_active;
wire image_nn_owner,image_job_valid,image_job_ready,image_job_done,image_job_drained,image_job_error;
wire image_nn_start,image_local_reset_n,image_actual_busy,image_actual_done,image_actual_pass,image_actual_fail;
wire [2:0] image_style;wire [31:0] image_input_base,image_output_base,image_generation;
wire [3:0] image_phase;wire [7:0] image_terminal;
wire image_dma_busy,image_control_busy;
wire [31:0] image_awaddr,image_araddr,cap_awaddr,cap_araddr;
wire [7:0] image_awlen,image_arlen,cap_awlen,cap_arlen;
wire [127:0] image_wdata,cap_wdata;wire [15:0] image_wstrb;
wire image_awvalid,image_awready,image_wlast,image_wvalid,image_wready,image_bvalid,image_bready;
wire image_arvalid,image_arready,image_rvalid,image_rready;
wire cap_awvalid,cap_awready,cap_wlast,cap_wvalid,cap_wready,cap_bvalid,cap_bready;
wire cap_arvalid,cap_arready,cap_rvalid,cap_rready;
reg image_nn_write_pending,image_nn_read_pending,image_completion_mask;
wire image_nn_quiet;
wire [31:0] image_apb_data;wire image_apb_ready,image_apb_error;
wire image_sel;
wire video_scheduler_req_ready;

wire [1:0] m_awvalid, m_awready;
wire [1:0] m_wlast,   m_wvalid, m_wready;
wire [1:0] m_bvalid,  m_bready;

wire [1:0] m_arvalid, m_arready;
wire [1:0] m_rlast,   m_rvalid, m_rready;

wire [1:0][127:0] m_wdata, m_rdata;
wire [1:0][15:0]  m_wstrb;
wire [1:0][1:0]   m_bresp, m_rresp;



        ////////////////////////////////////////////////////////////////
        // System & Debugger
        wire vid_rst_n,tx_vid_rst_n,rx_vid_rst_n;
        hdmi_reset_release u_tx_release(.clk(hdmi_tx_slow_clk),.rst_n(vid_rst_n),.released_n(tx_vid_rst_n));
        hdmi_reset_release u_rx_release(.clk(hdmi_rx_slow_clk),.rst_n(vid_rst_n),.released_n(rx_vid_rst_n));

        assign w_arstn=i_arstn & i_pll_locked & pll_locked & user_pll_locked;
        assign pll_inst1_RSTN=i_arstn;
        assign USER_PLL_RSTN=i_arstn;
        assign DDR3_PLL_RSTN=i_arstn;

        wire w_mipi_rx_vs,w_mipi_rx_hs,w_mipi_rx_de;wire [63:0] w_mipi_rx_data;
        wire w_mipi_rx_pclk_arstn;wire [15:0] mipi_debug_out;
        wire i_mipi_clk=mipi_tx_feedback100;
        hdmi_reset_release u_camera_release(.clk(i_mipi_rx_pclk),.rst_n(w_arstn),.released_n(w_mipi_rx_pclk_arstn));
        assign cam_d0_RST=0;assign cam_d1_RST=0;assign cam_d2_RST=0;assign cam_d3_RST=0;
                csi_rx_controller inst_efx_csi2_rx
                (
                      .reset_n			(i_arstn),
                      .clk				(i_mipi_clk),
                      .reset_byte_HS_n	(i_arstn),
                      .clk_byte_HS		  (i_cam_ck_CLKOUT),
                      .reset_pixel_n		(w_mipi_rx_pclk_arstn),
                      .clk_pixel			  (i_mipi_rx_pclk),
                      
                      .Rx_LP_CLK_P		  (i_cam_ck_LP_P_IN),
                      .Rx_LP_CLK_N		  (i_cam_ck_LP_N_IN),
                      .Rx_HS_enable_C		(o_cam_ck_HS_ENA),
                      .LVDS_termen_C		(o_cam_ck_HS_TERM),
                      
                      .Rx_LP_D_P			({cam_d3_LP_P_IN, cam_d2_LP_P_IN, cam_d1_LP_P_IN, cam_d0_LP_P_IN}),//(r_mipi_rx_data_LP_P_IN_2P),
                      .Rx_LP_D_N			({cam_d3_LP_N_IN, cam_d2_LP_N_IN, cam_d1_LP_N_IN, cam_d0_LP_N_IN}),//(r_mipi_rx_data_LP_N_IN_2P),
                      .Rx_HS_D_0			(cam_d0_HS_IN),//(r_mipi_rx_data_HS_IN_2P[0*8+:8]),
                      .Rx_HS_D_1			(cam_d1_HS_IN),//(r_mipi_rx_data_HS_IN_2P[1*8+:8]),
                      .Rx_HS_D_2			(cam_d2_HS_IN),
                      .Rx_HS_D_3			(cam_d3_HS_IN),
                      .Rx_HS_D_4			(),
                      .Rx_HS_D_5			(),
                      .Rx_HS_D_6			(),
                      .Rx_HS_D_7			(),
                      .Rx_HS_enable_D		({cam_d3_HS_ENA    ,cam_d2_HS_ENA    ,cam_d1_HS_ENA    ,cam_d0_HS_ENA    }),//( w_cam_d_HS_ENA),
                      .LVDS_termen_D		({cam_d3_HS_TERM   ,cam_d2_HS_TERM   ,cam_d1_HS_TERM   ,cam_d0_HS_TERM   }),
                      .fifo_rd_enable		({cam_d3_FIFO_RD   ,cam_d2_FIFO_RD   ,cam_d1_FIFO_RD   ,cam_d0_FIFO_RD   }),
                      .fifo_rd_empty		({cam_d3_FIFO_EMPTY,cam_d2_FIFO_EMPTY,cam_d1_FIFO_EMPTY,cam_d0_FIFO_EMPTY}),
                      .DLY_enable_D		       (),
                      .DLY_inc_D			(),
                      .u_dly_enable_D		(),
                      .u_dly_inc_D		       (),
                      
                      .axi_clk			(1'b0),
                      .axi_reset_n		       (1'b0),
                      .axi_awaddr			(6'b0),
                      .axi_awvalid		       (1'b0),
                      .axi_awready		       (),
                      .axi_wdata			(32'b0),
                      .axi_wvalid			(1'b0),
                      .axi_wready			(),
                      
                      .axi_bvalid			(),
                      .axi_bready			(1'b0),
                      .axi_araddr			(6'b0),
                      .axi_arvalid		       (1'b0),
                      .axi_arready		       (),
                      .axi_rdata			(),
                      .axi_rvalid			(),
                      .axi_rready			(1'b1),
                      
                      .hsync_vc0			(w_mipi_rx_hs),
                      .hsync_vc1			(),
                      .hsync_vc2			(),
                      .hsync_vc3			(),
                      .vsync_vc0			(w_mipi_rx_vs),
                      .vsync_vc1			(),
                      .vsync_vc2			(),
                      .vsync_vc3			(),
                      .vc				(),
                      .word_count			(),
                      .shortpkt_data_field        (),
                      .datatype			(),
                      .pixel_per_clk		(),
                      .pixel_data			(w_mipi_rx_data),
                      .pixel_data_valid	       (w_mipi_rx_de),
                      .irq				(),
                      .mipi_debug_out(mipi_debug_out)
                );
        // Camera Wishbone and CPU share100MHz. I2C prescale0x0293
        // preserves the original5MHz/prescale0x0020 SCL frequency exactly.
        wire scl_padoen_o,sda_padoen_o;
        reg [12:0] i2c_rst_cnt = '0;

        always @( posedge mipi_tx_feedback100 or negedge w_arstn )
        begin
            if( !w_arstn )
               i2c_rst_cnt <= 'd0;
            else 
               i2c_rst_cnt <= i2c_rst_cnt[12] ? i2c_rst_cnt : i2c_rst_cnt + 1'b1;
        end
        wire i2c_rst_n = i2c_rst_cnt[12];

        wire [2:0] c_cam_wb_addr;wire [7:0]c_cam_wb_wdata,c_cam_wb_rdata;
        wire c_cam_wb_write,c_cam_wb_stb,c_cam_wb_ack;
        i2c_master_top u_c_camera_i2c(.arst_i(1'b1),.wb_rst_i(!i2c_rst_n),.wb_clk_i(mipi_tx_feedback100),
          .wb_adr_i(c_cam_wb_addr),.wb_dat_i(c_cam_wb_wdata),.wb_dat_o(c_cam_wb_rdata),
          .wb_stb_i(c_cam_wb_stb),.wb_we_i(c_cam_wb_write),.wb_ack_o(c_cam_wb_ack),.wb_inta_o(),
          .scl_pad_i(io_cam_scl_IN),.scl_pad_o(io_cam_scl_OUT),.scl_padoen_o(scl_padoen_o),
          .sda_pad_i(io_cam_sda_IN),.sda_pad_o(io_cam_sda_OUT),.sda_padoen_o(sda_padoen_o));
        assign o_cam_rst_p = ~w_arstn;
        assign io_cam_scl_OE = ~scl_padoen_o;
        assign io_cam_sda_OE = ~sda_padoen_o;



        reg [25:0] cnt = 'd0;
        always @( posedge core_clk)
        begin 
               cnt <= cnt + 1'b1;
        end
        assign led[0]  = cal_done ? cnt[24] : 1'b0;
        assign led[1]  = weights_boot_ready;
        assign led[2]  = weights_boot_failed;
        assign led[3]  = cnt[24]; // raw core heartbeat, independent of DDR calibration

        //========================================================================================================
        //MIPI RX
        //========================================================================================================
        wire i_mipi_clk ;
        wire i2c_rst_n=w_arstn;
 wire ddr_test_done;
 wire ddr_test_error;
 wire [3:0] ddr_test_error_code;
 wire [31:0] ddr_test_error_addr;

// ============================================================
// Shared DDR arbitration test control
// ============================================================

// 上电后延迟启动 DDR Test
reg [25:0] shared_start_count = 26'd0;

// Test 完成后等待一段时间，再重新测试
reg [25:0] shared_repeat_count = 26'd0;

reg test_restart = 1'b0;


// ------------------------------------------------------------
// 第一次测试延迟启动
// 100MHz 下约 0.67 秒
// ------------------------------------------------------------
always @(posedge core_clk or negedge w_arstn) begin
    if (!w_arstn)
        shared_start_count <= 26'd0;
    else if (!vid_rst_n)
        shared_start_count <= 26'd0;
    else if (!(&shared_start_count))
        shared_start_count <= shared_start_count + 1'b1;
end


// ------------------------------------------------------------
// 一次测试完成后，等待约 0.67 秒重新启动测试
// ------------------------------------------------------------
always @(posedge core_clk or negedge w_arstn) begin
    if (!w_arstn) begin
        shared_repeat_count <= 26'd0;
        test_restart <= 1'b0;
    end
    else begin
        test_restart <= 1'b0;

        if (!ddr_test_done || ddr_test_error)
            shared_repeat_count <= 26'd0;

        else if (&shared_repeat_count) begin
            shared_repeat_count <= 26'd0;
            test_restart <= 1'b1;
        end

        else
            shared_repeat_count <= shared_repeat_count + 1'b1;
    end
end


wire shared_test_rst_n;
wire live_nn_start,live_nn_reset_n,live_nn_busy,live_nn_done,live_nn_pass,live_nn_fail;
wire [2:0] live_nn_fault;
wire [31:0] live_nn_input_base,live_nn_output_base,live_nn_display_base;
wire [31:0] live_nn_display_input_base;
wire live_display_read_pending;
wire live_nn_display_enable,live_nn_shown,live_nn_quiet,live_nn_display_fault;
wire [1:0] live_nn_display_buffer;
wire [1:0] live_nn_display_detail;
wire [31:0] live_nn_display_frame_id;
wire [7:0] live_nn_r,live_nn_g,live_nn_b;
wire live_nn_hs,live_nn_vs,live_nn_de;
wire [3:0] live_nn_awid,live_nn_arid;
wire live_nn_scheduler_fault;

wire shared_test_start;

assign shared_test_rst_n = w_arstn & ~test_restart;
assign shared_test_start = cal_done & (&shared_start_count);


reg [31:0] shared_aw_overlap_cycles = 32'd0;


reg [31:0] shared_ar_overlap_cycles = 32'd0;

always @(posedge core_clk or negedge w_arstn) begin
    if (!w_arstn) begin
        shared_aw_overlap_cycles <= 32'd0;
        shared_ar_overlap_cycles <= 32'd0;
    end
    else begin
        // 两个 Master 同时请求写
        if (&m_awvalid)
            shared_aw_overlap_cycles <= shared_aw_overlap_cycles + 1'b1;

        // 两个 Master 同时请求读
        if (&m_arvalid)
            shared_ar_overlap_cycles <= shared_ar_overlap_cycles + 1'b1;
    end
end

        wire camera_capture_commit=rgbx_ddr_commit;
        wire raw_video_read_urgent=1'b0,raw_video_read_critical=1'b0;
        wire live_display_read_critical,live_display_publication_window;
        assign m_awid[0]=0;assign m_awaddr[0]=0;assign m_awlen[0]=0;
        assign m_awsize[0]=4;assign m_awburst[0]=1;assign m_awlock[0]=0;
        assign m_awcache[0]=0;assign m_awprot[0]=0;assign m_awvalid[0]=0;
        assign m_wdata[0]=0;assign m_wstrb[0]=0;assign m_wlast[0]=0;assign m_wvalid[0]=0;assign m_bready[0]=1;
        assign m_arid[0]=0;assign m_araddr[0]=0;assign m_arlen[0]=0;
        assign m_arsize[0]=4;assign m_arburst[0]=1;assign m_arlock[0]=0;
        assign m_arcache[0]=0;assign m_arprot[0]=0;assign m_arvalid[0]=0;assign m_rready[0]=1;
    // DDR test master = m_*[1]
        assign m_awid[1]    = 6'd0;
        assign m_awsize[1]  = 3'd4;
        assign m_awburst[1] = 2'b01;
        assign m_awlock[1]  = 1'b0;
        assign m_awcache[1] = 4'd0;
        assign m_awprot[1]  = 3'd0;

        assign m_wstrb[1]   = 16'hFFFF;

        assign m_arid[1]    = 6'd0;
        assign m_arsize[1]  = 3'd4;
        assign m_arburst[1] = 2'b01;
        assign m_arlock[1]  = 1'b0;
        assign m_arcache[1] = 4'd0;
        assign m_arprot[1]  = 3'd0;
generate if (!RGBX_DDR_CAPTURE_EN) begin : g_legacy_ddr_test
ddr_addr_test u_ddr_addr_test (
    .awlen      (cap_awlen),
    .arlen      (cap_arlen),
    .wlast      (cap_wlast),

    .clk        (core_clk),
    .rst_n      (shared_test_rst_n),
    .cal_done   (shared_test_start),
    .awaddr     (cap_awaddr),
    .awvalid    (cap_awvalid),
    .awready    (cap_awready),

    .wdata      (cap_wdata),
    .wvalid     (cap_wvalid),
    .wready     (cap_wready),

    .bid        (m_bid[1][3:0]),
    .bresp      (m_bresp[1]),
    .bvalid     (cap_bvalid),
    .bready     (cap_bready),

    .araddr     (cap_araddr),
    .arvalid    (cap_arvalid),
    .arready    (cap_arready),

    .rid        (m_rid[1][3:0]),
    .rdata      (m_rdata[1]),
    .rresp      (m_rresp[1]),
    .rlast      (m_rlast[1]),
    .rvalid     (cap_rvalid),
    .rready     (cap_rready),

    .test_done  (ddr_test_done),
    .test_error (ddr_test_error),
    .error_code (ddr_test_error_code),
    .error_addr (ddr_test_error_addr)
);
end else begin : g_legacy_test_disabled
    assign ddr_test_done = live_nn_pass;
    assign ddr_test_error = live_nn_fail | live_nn_scheduler_fault | live_nn_display_fault;
    assign ddr_test_error_code = {1'b0,live_nn_fault};
    assign ddr_test_error_addr = 32'd0;
end endgenerate


// Four masters: RAW video, quantized input capture, NN, result display.
wire [1:0][5:0] n_awid;
wire [1:0][31:0] n_awaddr;
wire [1:0][7:0] n_awlen;
wire [1:0][2:0] n_awsize;
wire [1:0][1:0] n_awburst;
wire [1:0] n_awlock;
wire [1:0][3:0] n_awcache;
wire [1:0][2:0] n_awprot;
wire [1:0] n_awvalid;
wire [1:0] n_awready;
wire [1:0][127:0] n_wdata;
wire [1:0][15:0] n_wstrb;
wire [1:0] n_wlast;
wire [1:0] n_wvalid;
wire [1:0] n_wready;
wire [1:0][5:0] n_bid;
wire [1:0][1:0] n_bresp;
wire [1:0] n_bvalid;
wire [1:0] n_bready;
wire [1:0][5:0] n_arid;
wire [1:0][31:0] n_araddr;
wire [1:0][7:0] n_arlen;
wire [1:0][2:0] n_arsize;
wire [1:0][1:0] n_arburst;
wire [1:0] n_arlock;
wire [1:0][3:0] n_arcache;
wire [1:0][2:0] n_arprot;
wire [1:0] n_arvalid;
wire [1:0] n_arready;
wire [1:0][5:0] n_rid;
wire [1:0][127:0] n_rdata;
wire [1:0][1:0] n_rresp;
wire [1:0] n_rlast;
wire [1:0] n_rvalid;
wire [1:0] n_rready;
wire [1:0][5:0] g_awid;
wire [1:0][31:0] g_awaddr;
wire [1:0][7:0] g_awlen;
wire [1:0][2:0] g_awsize;
wire [1:0][1:0] g_awburst;
wire [1:0] g_awlock;
wire [1:0][3:0] g_awcache;
wire [1:0][2:0] g_awprot;
wire [1:0] g_awvalid;
wire [1:0] g_awready;
wire [1:0][127:0] g_wdata;
wire [1:0][15:0] g_wstrb;
wire [1:0] g_wlast;
wire [1:0] g_wvalid;
wire [1:0] g_wready;
wire [1:0][5:0] g_bid;
wire [1:0][1:0] g_bresp;
wire [1:0] g_bvalid;
wire [1:0] g_bready;
wire [1:0][5:0] g_arid;
wire [1:0][31:0] g_araddr;
wire [1:0][7:0] g_arlen;
wire [1:0][2:0] g_arsize;
wire [1:0][1:0] g_arburst;
wire [1:0] g_arlock;
wire [1:0][3:0] g_arcache;
wire [1:0][2:0] g_arprot;
wire [1:0] g_arvalid;
wire [1:0] g_arready;
wire [1:0][5:0] g_rid;
wire [1:0][127:0] g_rdata;
wire [1:0][1:0] g_rresp;
wire [1:0] g_rlast;
wire [1:0] g_rvalid;
wire [1:0] g_rready;
wire [3:0] a_awid,n_awid_small;
wire [3:0] a_bid,n_bid_small;
wire [3:0] a_arid,n_arid_small;
wire [3:0] a_rid,n_rid_small;
assign g_awid[0]={2'b00,a_awid};assign g_awid[1]={2'b00,n_awid_small};
assign g_arid[0]={2'b00,a_arid};assign g_arid[1]={2'b00,n_arid_small};
assign a_bid=g_bid[0][3:0];assign n_bid_small=g_bid[1][3:0];
assign a_rid=g_rid[0][3:0];assign n_rid_small=g_rid[1][3:0];
// Passive, core-clock diagnostic wires; no diagnostic signal drives control.
wire [2:0] c_diag_camera_read,c_diag_nn_read,c_diag_system_read,c_diag_cat_read;
wire [12:0] c_diag_scheduler;
wire [5:0] c_diag_display;
wire[15:0] video_underflows,video_bad_row;
wire[31:0] video_frame_quality;
wire[31:0] video_nn_total,video_new_total,video_shown_total;
wire[9:0] video_hdmi_hz;
localparam integer VIDEO_CORE_HZ=160000000;
reg[$clog2(VIDEO_CORE_HZ/1000)-1:0] video_ms_div;reg[31:0] video_uptime_ms;
always @(posedge core_clk or negedge vid_rst_n)begin
 if(!vid_rst_n)begin video_ms_div<=0;video_uptime_ms<=0;end
 else if(video_ms_div==VIDEO_CORE_HZ/1000-1)begin video_ms_div<=0;video_uptime_ms<=video_uptime_ms+1'b1;end
 else video_ms_div<=video_ms_div+1'b1;
end
wire [2:0] c_diag_nn_phase;
wire c_diag_nn_timeout;
wire [31:0] c_diag_state,c_diag_axi;
assign c_diag_state={copy_in_done_ready,copy_in_req_ready,copy_in_req_valid,
                    copy_in_error,c_diag_nn_timeout,c_diag_nn_phase,
                    c_diag_display,live_nn_shown,live_nn_quiet,
                    live_nn_display_enable,c_diag_scheduler};
assign c_diag_axi={s_axi_bvalid,s_axi_wready,s_axi_wvalid,s_axi_awready,s_axi_awvalid,
                  s_axi_rlast,s_axi_rready,s_axi_rvalid,s_axi_arready,s_axi_arvalid,
                  cat_disp_rlast,cat_disp_rready,cat_disp_rvalid,cat_disp_arready,cat_disp_arvalid,
                  boot_nn_rlast,boot_nn_rready,boot_nn_rvalid,boot_nn_arready,boot_nn_arvalid,
                  c_diag_cat_read,c_diag_camera_read,c_diag_nn_read,c_diag_system_read};

axi_ddr_arbiter_2 u_camera_group (.debug_read_state(c_diag_camera_read),.read_urgent({1'b0,raw_video_read_urgent}),
    .read_critical({1'b0,raw_video_read_critical}),
    .clk        (core_clk),
    .rst_n      (w_arstn),

    // =========================
    // 两个 Master：写地址通道
    // =========================
    .m_awid     (m_awid),
    .m_awaddr   (m_awaddr),
    .m_awlen    (m_awlen),
    .m_awsize   (m_awsize),
    .m_awburst  (m_awburst),
    .m_awlock   (m_awlock),
    .m_awcache  (m_awcache),
    .m_awprot   (m_awprot),
    .m_awvalid  (m_awvalid),
    .m_awready  (m_awready),

    // 写数据通道
    .m_wdata    (m_wdata),
    .m_wstrb    (m_wstrb),
    .m_wlast    (m_wlast),
    .m_wvalid   (m_wvalid),
    .m_wready   (m_wready),

    // 写响应通道
    .m_bid      (m_bid),
    .m_bresp    (m_bresp),
    .m_bvalid   (m_bvalid),
    .m_bready   (m_bready),

    // =========================
    // 两个 Master：读地址通道
    // =========================
    .m_arid     (m_arid),
    .m_araddr   (m_araddr),
    .m_arlen    (m_arlen),
    .m_arsize   (m_arsize),
    .m_arburst  (m_arburst),
    .m_arlock   (m_arlock),
    .m_arcache  (m_arcache),
    .m_arprot   (m_arprot),
    .m_arvalid  (m_arvalid),
    .m_arready  (m_arready),

    // 读数据通道
    .m_rid      (m_rid),
    .m_rdata    (m_rdata),
    .m_rresp    (m_rresp),
    .m_rlast    (m_rlast),
    .m_rvalid   (m_rvalid),
    .m_rready   (m_rready),

    // =========================
    // 仲裁器 → DDR3
    // =========================

    // 写地址
    .s_awid     (a_awid),
    .s_awaddr   (g_awaddr[0]),
    .s_awlen    (g_awlen[0]),
    .s_awsize   (g_awsize[0]),
    .s_awburst  (g_awburst[0]),
    .s_awlock   (g_awlock[0]),
    .s_awcache  (g_awcache[0]),
    .s_awprot   (g_awprot[0]),
    .s_awvalid  (g_awvalid[0]),
    .s_awready  (g_awready[0]),

    // 写数据
    .s_wdata    (g_wdata[0]),
    .s_wstrb    (g_wstrb[0]),
    .s_wlast    (g_wlast[0]),
    .s_wvalid   (g_wvalid[0]),
    .s_wready   (g_wready[0]),

    // 写响应
    .s_bid      (a_bid),
    .s_bresp    (g_bresp[0]),
    .s_bvalid   (g_bvalid[0]),
    .s_bready   (g_bready[0]),

    // 读地址
    .s_arid     (a_arid),
    .s_araddr   (g_araddr[0]),
    .s_arlen    (g_arlen[0]),
    .s_arsize   (g_arsize[0]),
    .s_arburst  (g_arburst[0]),
    .s_arlock   (g_arlock[0]),
    .s_arcache  (g_arcache[0]),
    .s_arprot   (g_arprot[0]),
    .s_arvalid  (g_arvalid[0]),
    .s_arready  (g_arready[0]),

    // 读数据
    .s_rid      (a_rid),
    .s_rdata    (g_rdata[0]),
    .s_rresp    (g_rresp[0]),
    .s_rlast    (g_rlast[0]),
    .s_rvalid   (g_rvalid[0]),
    .s_rready   (g_rready[0])
);
axi_ddr_arbiter_2 u_nn_group(.debug_read_state(c_diag_nn_read),.read_urgent({live_display_read_pending,1'b0}),
 .read_critical({live_display_read_critical,1'b0}),
 .clk(core_clk),.rst_n(w_arstn),.debug_enable(1'b0),.debug_write_code(),
 .m_awid(n_awid),
 .m_awaddr(n_awaddr),
 .m_awlen(n_awlen),
 .m_awsize(n_awsize),
 .m_awburst(n_awburst),
 .m_awlock(n_awlock),
 .m_awcache(n_awcache),
 .m_awprot(n_awprot),
 .m_awvalid(n_awvalid),
 .m_awready(n_awready),
 .m_wdata(n_wdata),
 .m_wstrb(n_wstrb),
 .m_wlast(n_wlast),
 .m_wvalid(n_wvalid),
 .m_wready(n_wready),
 .m_bid(n_bid),
 .m_bresp(n_bresp),
 .m_bvalid(n_bvalid),
 .m_bready(n_bready),
 .m_arid(n_arid),
 .m_araddr(n_araddr),
 .m_arlen(n_arlen),
 .m_arsize(n_arsize),
 .m_arburst(n_arburst),
 .m_arlock(n_arlock),
 .m_arcache(n_arcache),
 .m_arprot(n_arprot),
 .m_arvalid(n_arvalid),
 .m_arready(n_arready),
 .m_rid(n_rid),
 .m_rdata(n_rdata),
 .m_rresp(n_rresp),
 .m_rlast(n_rlast),
 .m_rvalid(n_rvalid),
 .m_rready(n_rready),
 .s_awid(n_awid_small),
 .s_awaddr(g_awaddr[1]),
 .s_awlen(g_awlen[1]),
 .s_awsize(g_awsize[1]),
 .s_awburst(g_awburst[1]),
 .s_awlock(g_awlock[1]),
 .s_awcache(g_awcache[1]),
 .s_awprot(g_awprot[1]),
 .s_awvalid(g_awvalid[1]),
 .s_awready(g_awready[1]),
 .s_wdata(g_wdata[1]),
 .s_wstrb(g_wstrb[1]),
 .s_wlast(g_wlast[1]),
 .s_wvalid(g_wvalid[1]),
 .s_wready(g_wready[1]),
 .s_bid(n_bid_small),
 .s_bresp(g_bresp[1]),
 .s_bvalid(g_bvalid[1]),
 .s_bready(g_bready[1]),
 .s_arid(n_arid_small),
 .s_araddr(g_araddr[1]),
 .s_arlen(g_arlen[1]),
 .s_arsize(g_arsize[1]),
 .s_arburst(g_arburst[1]),
 .s_arlock(g_arlock[1]),
 .s_arcache(g_arcache[1]),
 .s_arprot(g_arprot[1]),
 .s_arvalid(g_arvalid[1]),
 .s_arready(g_arready[1]),
 .s_rid(n_rid_small),
 .s_rdata(g_rdata[1]),
 .s_rresp(g_rresp[1]),
 .s_rlast(g_rlast[1]),
 .s_rvalid(g_rvalid[1]),
 .s_rready(g_rready[1])
);
axi_ddr_arbiter_2 u_system_arbiter(.debug_read_state(c_diag_system_read),.read_urgent({live_display_read_pending,raw_video_read_urgent}),
 .read_critical({live_display_read_critical,raw_video_read_critical}),
 .clk(core_clk),.rst_n(w_arstn),.debug_enable(1'b0),.debug_write_code(),
 .m_awid(g_awid),
 .m_awaddr(g_awaddr),
 .m_awlen(g_awlen),
 .m_awsize(g_awsize),
 .m_awburst(g_awburst),
 .m_awlock(g_awlock),
 .m_awcache(g_awcache),
 .m_awprot(g_awprot),
 .m_awvalid(g_awvalid),
 .m_awready(g_awready),
 .m_wdata(g_wdata),
 .m_wstrb(g_wstrb),
 .m_wlast(g_wlast),
 .m_wvalid(g_wvalid),
 .m_wready(g_wready),
 .m_bid(g_bid),
 .m_bresp(g_bresp),
 .m_bvalid(g_bvalid),
 .m_bready(g_bready),
 .m_arid(g_arid),
 .m_araddr(g_araddr),
 .m_arlen(g_arlen),
 .m_arsize(g_arsize),
 .m_arburst(g_arburst),
 .m_arlock(g_arlock),
 .m_arcache(g_arcache),
 .m_arprot(g_arprot),
 .m_arvalid(g_arvalid),
 .m_arready(g_arready),
 .m_rid(g_rid),
 .m_rdata(g_rdata),
 .m_rresp(g_rresp),
 .m_rlast(g_rlast),
 .m_rvalid(g_rvalid),
 .m_rready(g_rready),
 .s_awid(s_axi_awid),
 .s_awaddr(s_axi_awaddr),
 .s_awlen(s_axi_awlen),
 .s_awsize(s_axi_awsize),
 .s_awburst(s_axi_awburst),
 .s_awlock(s_axi_awlock),
 .s_awcache(s_axi_awcache),
 .s_awprot(s_axi_awprot),
 .s_awvalid(s_axi_awvalid),
 .s_awready(s_axi_awready),
 .s_wdata(s_axi_wdata),
 .s_wstrb(s_axi_wstrb),
 .s_wlast(s_axi_wlast),
 .s_wvalid(s_axi_wvalid),
 .s_wready(s_axi_wready),
 .s_bid(s_axi_bid),
 .s_bresp(s_axi_bresp),
 .s_bvalid(s_axi_bvalid),
 .s_bready(s_axi_bready),
 .s_arid(s_axi_arid),
 .s_araddr(s_axi_araddr),
 .s_arlen(s_axi_arlen),
 .s_arsize(s_axi_arsize),
 .s_arburst(s_axi_arburst),
 .s_arlock(s_axi_arlock),
 .s_arcache(s_axi_arcache),
 .s_arprot(s_axi_arprot),
 .s_arvalid(s_axi_arvalid),
 .s_arready(s_axi_arready),
 .s_rid(s_axi_rid),
 .s_rdata(s_axi_rdata),
 .s_rresp(s_axi_rresp),
 .s_rlast(s_axi_rlast),
 .s_rvalid(s_axi_rvalid),
 .s_rready(s_axi_rready)
);

        ddr3_top #(.ASYN_AXI_CLK(1)) u_ddr3_top
        (

        .axi_clk                (core_clk            ),
        .core_clk               (mipi_tx_feedback100 ),
        .sdram_clk              (sdram_clk           ),  
        .rx_cal_clk             (rx_cal_clk          ),
        .tx_cal_clk             (tx_cal_clk          ),
        .tx_cal_clk_90edge      (tx_cal_clk_90edge   ),
        .rstn                   (w_arstn             ),      
        .pll_shift              (pll_shift           ),
        .pll_shift_sel          (pll_shift_sel       ),
        .pll_shift_ena          (pll_shift_ena       ),       
        ///////////////DDR BUS
        .ddr_ck_hi              (ddr_ck_hi           ),
        .ddr_ck_lo              (ddr_ck_lo           ),
        .ddr_cke                (ddr_cke             ),    
        .ddr_reset_n            (ddr_reset_n         ),
        .ddr_cs_n               (ddr_cs_n            ),
        .ddr_ras_n              (ddr_ras_n           ),
        .ddr_cas_n              (ddr_cas_n           ),
        .ddr_we_n               (ddr_we_n            ),     
        .ddr_addr               (ddr_addr            ),
        .ddr_ba                 (ddr_ba              ),

        .ddr_dqs_oe             (ddr_dqs_oe          ),
        .ddr_dqs_oe_n           (ddr_dqs_oe_n        ),
        .ddr_dq_oe              (ddr_dq_oe           ),
        .ddr_dqs_in_hi          (ddr_dqs_in_hi       ),
        .ddr_dqs_in_lo          (ddr_dqs_in_lo       ),
        .ddr_dq_in_hi           (ddr_dq_in_hi        ),
        .ddr_dq_in_lo           (ddr_dq_in_lo        ),

        .ddr_dqs_out_hi         (ddr_dqs_out_hi      ),
        .ddr_dqs_out_lo         (ddr_dqs_out_lo      ),
        .ddr_dq_out_hi          (ddr_dq_out_hi       ),
        .ddr_dq_out_lo          (ddr_dq_out_lo       ),

        .ddr_dm_hi              (ddr_dm_hi           ),
        .ddr_dm_lo              (ddr_dm_lo           ),
        .ddr_odt                (ddr_odt             ),

        // Application interface ports
        .app_sr_req                     (1'b0),
        .app_ref_req                    (1'b0),
        .app_zq_req                     (1'b0),
        .app_sr_active                  (app_sr_active),
        .app_ref_ack                    (app_ref_ack),
        .app_zq_ack                     (app_zq_ack),

        // Slave Interface Write Address Ports
        .s_axi_awid                     (s_axi_awid        ),
        .s_axi_awaddr                   (s_axi_awaddr      ),
        .s_axi_awlen                    (s_axi_awlen       ),
        .s_axi_awsize                   (s_axi_awsize      ),
        .s_axi_awburst                  (s_axi_awburst     ),
        .s_axi_awlock                   (s_axi_awlock      ),
        .s_axi_awcache                  (s_axi_awcache     ),
        .s_axi_awprot                   (s_axi_awprot      ),
        .s_axi_awqos                    (4'h0              ),
        .s_axi_awvalid                  (s_axi_awvalid     ),
        .s_axi_awready                  (s_axi_awready     ),
        // Slave Interface Write Data Ports
        .s_axi_wdata                    (s_axi_wdata       ),
        .s_axi_wstrb                    (s_axi_wstrb       ),
        .s_axi_wlast                    (s_axi_wlast       ),
        .s_axi_wvalid                   (s_axi_wvalid      ),
        .s_axi_wready                   (s_axi_wready      ),
        // Slave Interface Write Response Ports
        .s_axi_bid                      (s_axi_bid         ),
        .s_axi_bresp                    (s_axi_bresp       ),
        .s_axi_bvalid                   (s_axi_bvalid      ),
        .s_axi_bready                   (s_axi_bready      ),
        // Slave Interface Read Address Ports
        .s_axi_arid                     (s_axi_arid        ),
        .s_axi_araddr                   (s_axi_araddr      ),
        .s_axi_arlen                    (s_axi_arlen       ),
        .s_axi_arsize                   (s_axi_arsize      ),
        .s_axi_arburst                  (s_axi_arburst     ),
        .s_axi_arlock                   (s_axi_arlock      ),
        .s_axi_arcache                  (s_axi_arcache     ),
        .s_axi_arprot                   (s_axi_arprot      ),
        .s_axi_arqos                    (4'h0              ),
        .s_axi_arvalid                  (s_axi_arvalid     ),
        .s_axi_arready                  (s_axi_arready     ),
        // Slave Interface Read Data Ports
        .s_axi_rid                      (s_axi_rid         ),
        .s_axi_rdata                    (s_axi_rdata       ),
        .s_axi_rresp                    (s_axi_rresp       ),
        .s_axi_rlast                    (s_axi_rlast       ),
        .s_axi_rvalid                   (s_axi_rvalid      ),
        .s_axi_rready                   (s_axi_rready      ),
        //DEBUG       
        .wrlvl_dq_check                 (wrlvl_dq_check    ) ,
        .rd_level_dqs_check             (rd_level_dqs_check) ,
        .init_cur_state                 (init_cur_state    ) ,
        .idelay_ld                      (idelay_ld         ) ,
        .mpr_rdlvl_dly                  (mpr_rdlvl_dly     ) ,
        .cal_done                       (ddr_cal_done_100m  ) 
        );

        wire [15:0] c_addr;wire c_sel,c_enable,c_write;wire [31:0] c_wdata;
        wire light_sel=c_addr[15:8]==8'h05;
        wire [31:0] light_prdata;wire light_pready,light_error;
        wire [31:0] rgbx640_data,rgbx640_frame_id,rgbx640_frame_count;
        wire rgbx640_valid,rgbx640_sof,rgbx640_eol,rgbx640_last;
        wire [10:0] rgbx640_x;wire [9:0] rgbx640_y;
        wire rgbx640_frame_done,rgbx640_frame_abort;
        wire [19:0] rgbx640_pixel_count;wire [3:0] rgbx640_error=0;
        wire [31:0] hdmi_bad_frames,hdmi_edid_reads,hdmi_good_frames;wire [15:0] hdmi_width,hdmi_height;
        wire hdmi_report,hdmi_present,hdmi_decoder_reset_n;
        wire rx_vs,rx_hs,rx_de;wire [7:0] rx_r,rx_g,rx_b;
        assign hdmi_rx_clk_RX_ENA=1;
        assign hdmi_rx_d0_RX_ENA=1;assign hdmi_rx_d1_RX_ENA=1;assign hdmi_rx_d2_RX_ENA=1;
        assign hdmi_rx_d0_RX_RST=0;assign hdmi_rx_d1_RX_RST=0;assign hdmi_rx_d2_RX_RST=0;
        wire hdmi_sel=c_addr[15:8]==8'h06;
        wire [31:0] hdmi_data,hdmi_frames_tx,hdmi_skipped_tx;
        wire hdmi_ready,hdmi_error;
        wire [31:0] hdmi_rgbx,hdmi_source_frame_id;wire hdmi_valid,hdmi_sof,hdmi_done,hdmi_abort;
        wire [31:0] cam_rgbx,cam_frame_id,cam_good_frames,cam_overflow_frames;
        wire cam_valid,cam_sof,cam_done,cam_abort,cam_sensor_sof_toggle;
        wire [31:0] hdmi_pipe_rgbx;wire hdmi_pipe_valid,hdmi_pipe_sof,hdmi_pipe_done,hdmi_pipe_abort;
        wire [31:0] hdmi_pipe_overflows,source_switch_count;
        wire requested_source,active_source;wire source_sel=c_addr[15:8]==8'h07;
        wire [31:0] source_data;wire source_ready,source_error;
        hdmi_input_frontend u_hdmi_frontend(
         .ctrl_clk(mipi_tx_feedback100),.pixel_clk(hdmi_rx_slow_clk),.display_clk(hdmi_tx_slow_clk),
         .ctrl_reset_n(w_arstn),.video_reset_n(vid_rst_n),.pixel_reset_n(rx_vid_rst_n),.apb_reset_n(!c_reset),
         .power_n(HDMI_5V_N),.pll_locked(hdmi_rx_pll_LOCKED),
         .lane0(hdmi_rx_d0_RX_DATA),.lane1(hdmi_rx_d1_RX_DATA),.lane2(hdmi_rx_d2_RX_DATA),
         .scl_i(FPGA_HDMI_SCL_IN),.scl_o(FPGA_HDMI_SCL_OUT),.scl_oe(FPGA_HDMI_SCL_OE),
         .sda_i(FPGA_HDMI_SDA_IN),.sda_o(FPGA_HDMI_SDA_OUT),.sda_oe(FPGA_HDMI_SDA_OE),
         .hpd_n(HPD_N),.pll_reset_n(hdmi_rx_pll_RSTN),
         .delay_inc(hdmi_rx_clk_RX_DLY_INC),.delay_rst(hdmi_rx_clk_RX_DLY_RST),.delay_enable(hdmi_rx_clk_RX_DLY_ENA),
         .rgbx(hdmi_rgbx),.valid(hdmi_valid),.sof(hdmi_sof),.eol(),.last(),
         .x(),.y(),.frame_id(hdmi_source_frame_id),.frame_done(hdmi_done),.frame_abort(hdmi_abort),
         .good_frames(hdmi_good_frames),.bad_frames(hdmi_bad_frames),.edid_reads(hdmi_edid_reads),
         .measured_width(hdmi_width),.measured_height(hdmi_height),.report_strobe(hdmi_report),.pixel_count(),
         .present(hdmi_present),.raw_vs(rx_vs),.raw_hs(rx_hs),.raw_de(rx_de),
         .skipped_frames_pixel(32'd0),.frames_display(hdmi_frames_tx),.skipped_display(hdmi_skipped_tx),
         .PADDR(c_addr),.PSEL(c_sel&&hdmi_sel),.PENABLE(c_enable),.PWRITE(c_write),.PRDATA(hdmi_data),.PREADY(hdmi_ready),.PSLVERROR(hdmi_error));

        // Four immutable DDR input slots, released after comparison display drain.

        camera_video_frontend u_camera_frontend(.source_clk(i_mipi_rx_pclk),.pair_clk(vid_clk_dvi2),.pixel_clk(hdmi_tx_slow_clk),
         .ctrl_clk(mipi_tx_feedback100),.rst_n(vid_rst_n),.source_vs(w_mipi_rx_vs),.source_valid(w_mipi_rx_de&&w_mipi_rx_hs),
         .source_raw4({w_mipi_rx_data[39:32],w_mipi_rx_data[29:22],w_mipi_rx_data[19:12],w_mipi_rx_data[9:2]}),
         .PADDR(c_addr),.PSEL(c_sel&&light_sel),.PENABLE(c_enable),.PWRITE(c_write),.PWDATA(c_wdata),.PRDATA(light_prdata),.PREADY(light_pready),.PSLVERROR(light_error),
         .rgbx(cam_rgbx),.frame_id(cam_frame_id),.good_frames(cam_good_frames),.overflow_frames(cam_overflow_frames),
         .valid(cam_valid),.sof(cam_sof),.frame_done(cam_done),.frame_abort(cam_abort),.x(),.y(),.sensor_sof_toggle(cam_sensor_sof_toggle));
        video_stream_cdc u_hdmi_stream(.source_clk(hdmi_rx_slow_clk),.dest_clk(hdmi_tx_slow_clk),.rst_n(vid_rst_n),
         .i_rgbx(hdmi_rgbx),.i_valid(hdmi_valid),.i_sof(hdmi_sof),.i_done(hdmi_done),.i_abort(hdmi_abort),
         .o_rgbx(hdmi_pipe_rgbx),.o_valid(hdmi_pipe_valid),.o_sof(hdmi_pipe_sof),.o_done(hdmi_pipe_done),.o_abort(hdmi_pipe_abort),.overflow_count(hdmi_pipe_overflows));
        video_frame_mux u_source_mux(.clk(hdmi_tx_slow_clk),.rst_n(tx_vid_rst_n),.requested_source(requested_source),
         .cam_rgbx(cam_rgbx),.cam_valid(cam_valid),.cam_sof(cam_sof),.cam_done(cam_done),.cam_abort(cam_abort),
         .hdmi_rgbx(hdmi_pipe_rgbx),.hdmi_valid(hdmi_pipe_valid),.hdmi_sof(hdmi_pipe_sof),.hdmi_done(hdmi_pipe_done),.hdmi_abort(hdmi_pipe_abort),
         .active_source(active_source),.rgbx(rgbx640_data),.frame_id(rgbx640_frame_id),.valid(rgbx640_valid),.sof(rgbx640_sof),
         .frame_done(rgbx640_frame_done),.frame_abort(rgbx640_frame_abort),.switch_count(source_switch_count));
        reg [31:0] selected_good_frames;
        always @(posedge hdmi_tx_slow_clk or negedge tx_vid_rst_n)
         if(!tx_vid_rst_n)selected_good_frames<=0;else if(rgbx640_frame_done)selected_good_frames<=selected_good_frames+1'b1;
        assign rgbx640_frame_count=selected_good_frames;
        wire source_snapshot_busy,source_snapshot_pulse;wire [31:0] source_frame_cpu;
        video_snapshot_cdc #(.WIDTH(32)) u_source_snapshot(.src_clk(hdmi_tx_slow_clk),.dst_clk(mipi_tx_feedback100),.rst_n(vid_rst_n),
         .send(rgbx640_sof),.data(rgbx640_frame_id),.busy(source_snapshot_busy),.pulse(source_snapshot_pulse),.received(source_frame_cpu));
        video_source_control u_source_control(.clk(mipi_tx_feedback100),.rst_n(vid_rst_n),.button_n(fisheye_sw3_n),.active_source(active_source),.source_frame_id(source_frame_cpu),
         .PADDR(c_addr),.PSEL(c_sel&&source_sel),.PENABLE(c_enable),.PWRITE(c_write),.PWDATA(c_wdata),.PRDATA(source_data),.PREADY(source_ready),.PSLVERROR(source_error),.requested_source(requested_source));
         wire [3:0] rgbx_ddr_slot_valid;
        wire [31:0] rgbx_ddr_slot2_frame_id,rgbx_ddr_slot3_frame_id;
         wire [31:0] rgbx_ddr_slot0_frame_id;
         wire [31:0] rgbx_ddr_slot1_frame_id;
         wire [31:0] rgbx_ddr_commit_count;
         wire rgbx_ddr_commit;
         wire [31:0] rgbx_ddr_committed_addr;
         wire [31:0] rgbx_ddr_word_count;
         wire [31:0] rgbx_ddr_b_count;
         wire [31:0] rgbx_ddr_abort_count;
         wire [7:0] rgbx_ddr_error;
         wire rgbx_ddr_busy;
        wire [31:0] rgbx_ddr_skipped_frames_pixel;

        // Four immutable input loans shared with the active comparison pipeline.
        // Release occurs only after the displayed original has drained.
         wire copy_in_req_valid;
         wire copy_in_req_ready;
         wire [1:0] copy_in_req_bank;
         wire [31:0] copy_in_req_addr;
         wire [31:0] copy_in_req_frame_id;
         wire copy_in_busy;
         wire [2:0] copy_in_error;
         wire [3:0] copy_in_release_slots;
         wire [31:0] copy_in_accepted_count;
         wire [31:0] copy_in_released_count;
         wire [31:0] copy_in_failed_count;
         wire [31:0] copy_in_dropped_count;
        wire copy_in_done_valid, copy_in_done_ready;
        wire [1:0] copy_in_done_bank;
        wire copy_in_done_error;
        wire [31:0] copy_in_done_frame_id;
        
        
        
        
        

// SW0/i_arstn stays the global reset. SW2 alone changes requested style.
(* async_reg="true" *) reg [1:0] style_sw2_sync;
reg style_sw2_stable;
reg [2:0] style_button;
wire [12:0] c_platform_config;
wire snapshot_locked,c_capture_allowed,snapshot_pipeline_ready;
wire [1:0] live_nn_display_roi;
wire photo_sel=c_addr[15:8]==8'h08;
wire [31:0] photo_data;wire photo_ready,photo_error;
// CPU-local reset must never reset a live SPI/DDR loader. Cold start is one-shot.
reg c_deployment_started;
always @(posedge core_clk or negedge vid_rst_n)
 if(!vid_rst_n)c_deployment_started<=0;else if(c_platform_config[0])c_deployment_started<=1;
wire [2:0] style_requested=c_platform_config[1]?{c_platform_config[12],c_platform_config[3:2]}:style_button;
reg [21:0] style_debounce;
always @(posedge core_clk or negedge vid_rst_n)begin
 if(!vid_rst_n)begin style_sw2_sync<=2'b11;style_sw2_stable<=1;style_button<=1;style_debounce<=0;end
 else begin
  style_sw2_sync<={style_sw2_sync[0],style_sw2_n};
  if(style_sw2_sync[1]==style_sw2_stable)style_debounce<=0;
  else if(style_debounce==22'd2400000)begin
   style_sw2_stable<=style_sw2_sync[1];style_debounce<=0;
   if(!style_sw2_sync[1])style_button<=(style_button==3'd4)?3'd0:style_button+3'd1;
  end else style_debounce<=style_debounce+1'b1;
 end
end
// SW3 now selects the input source. Geometry remains available over UART.
// Ethernet test profile: no fisheye datapath; direct APB requests cannot enable it.
wire fisheye_requested=1'b0;
wire [2:0] style_active;
wire style_cfg_we,style_cfg_tanh,style_inference_idle;
wire [7:0] style_cfg_index;wire [63:0] style_cfg_data;

wire [2:0] live_nn_compute_fault;
assign live_nn_fault=weights_boot_failed?weights_boot_fault:live_nn_compute_fault;
wire [3:0] boot_nn_awid;
wire [31:0] boot_nn_awaddr;
wire [7:0] boot_nn_awlen;
wire [2:0] boot_nn_awsize;
wire [1:0] boot_nn_awburst;
wire boot_nn_awlock;
wire [3:0] boot_nn_awcache;
wire [2:0] boot_nn_awprot;
wire boot_nn_awvalid;
wire boot_nn_awready;
wire [127:0] boot_nn_wdata;
wire [15:0] boot_nn_wstrb;
wire boot_nn_wlast;
wire boot_nn_wvalid;
wire boot_nn_wready;
wire [3:0] boot_nn_bid;
wire [1:0] boot_nn_bresp;
wire boot_nn_bvalid;
wire boot_nn_bready;
wire [3:0] boot_nn_arid;
wire [31:0] boot_nn_araddr;
wire [7:0] boot_nn_arlen;
wire [2:0] boot_nn_arsize;
wire [1:0] boot_nn_arburst;
wire boot_nn_arlock;
wire [3:0] boot_nn_arcache;
wire [2:0] boot_nn_arprot;
wire boot_nn_arvalid;
wire boot_nn_arready;
wire [3:0] boot_nn_rid;
wire [127:0] boot_nn_rdata;
wire [1:0] boot_nn_rresp;
wire boot_nn_rlast;
wire boot_nn_rvalid;
wire boot_nn_rready;

// Do not withdraw any command once accepted. Pending state survives CPU and
// NN-local resets; a shared DDR reset is the only destructive reset here.
always @(posedge core_clk or negedge vid_rst_n)begin
 if(!vid_rst_n)begin image_nn_write_pending<=0;image_nn_read_pending<=0;image_completion_mask<=0;end
 else begin
  case({boot_nn_awvalid&&boot_nn_awready,boot_nn_bvalid&&boot_nn_bready})
   2'b10:image_nn_write_pending<=1;2'b01:image_nn_write_pending<=0;default:;
  endcase
  case({boot_nn_arvalid&&boot_nn_arready,boot_nn_rvalid&&boot_nn_rready&&boot_nn_rlast})
   2'b10:image_nn_read_pending<=1;2'b01:image_nn_read_pending<=0;default:;
  endcase
  if(image_nn_owner)image_completion_mask<=1;
  else if(!live_nn_reset_n||!image_local_reset_n)image_completion_mask<=0;
 end
end
assign image_nn_quiet=!image_nn_write_pending&&!image_nn_read_pending&&
 !boot_nn_awvalid&&!boot_nn_wvalid&&!boot_nn_arvalid;
// Keep the private task's held DONE masked after lease release, until the next
// normal video task resets the core. Otherwise release creates a false IRQ.
assign live_nn_done=image_actual_done&&!image_nn_owner&&!image_completion_mask;
assign live_nn_pass=image_actual_pass&&!image_nn_owner&&!image_completion_mask;
assign live_nn_fail=image_actual_fail&&!image_nn_owner&&!image_completion_mask;
assign live_nn_busy=image_actual_busy&&!image_nn_owner&&!image_completion_mask;
assign c_scheduler_req_ready=video_scheduler_req_ready&&!image_pause;
// Private raw/result DDR never overlap normal input/front/publication slots.
// A pending display publication may finish independently. The private job
// needs normal compute idle, capture/AXI drained and snapshot unlocked; it
// must not require a camera/HDMI frame to have existed.

assign m_awaddr[1]=image_axi_owner?image_awaddr:cap_awaddr;
assign m_awlen[1]=image_axi_owner?image_awlen:cap_awlen;
assign m_awvalid[1]=image_axi_owner?image_awvalid:cap_awvalid;
assign cap_awready=!image_axi_owner&&m_awready[1];assign image_awready=image_axi_owner&&m_awready[1];
assign m_wdata[1]=image_axi_owner?image_wdata:cap_wdata;
assign m_wlast[1]=image_axi_owner?image_wlast:cap_wlast;
assign m_wvalid[1]=image_axi_owner?image_wvalid:cap_wvalid;
assign cap_wready=!image_axi_owner&&m_wready[1];assign image_wready=image_axi_owner&&m_wready[1];
assign cap_bvalid=!image_axi_owner&&m_bvalid[1];assign image_bvalid=image_axi_owner&&m_bvalid[1];
assign m_bready[1]=image_axi_owner?image_bready:cap_bready;
assign m_araddr[1]=image_axi_owner?image_araddr:cap_araddr;
assign m_arlen[1]=image_axi_owner?image_arlen:cap_arlen;
assign m_arvalid[1]=image_axi_owner?image_arvalid:cap_arvalid;
assign cap_arready=!image_axi_owner&&m_arready[1];assign image_arready=image_axi_owner&&m_arready[1];
assign cap_rvalid=!image_axi_owner&&m_rvalid[1];assign image_rvalid=image_axi_owner&&m_rvalid[1];
assign m_rready[1]=image_axi_owner?image_rready:cap_rready;

wire [3:0] boot_m_awid,boot_m_arid;
assign n_awid[0]={2'b0,boot_m_awid};assign n_arid[0]={2'b0,boot_m_arid};
camera_nn_weight_boot_mux #(.TWO_MODELS(1),.MODEL_COUNT(5),.CORE_HZ(160000000),.WEIGHT_BYTES(20480),.SPI_CLK_DIV(8)) u_weight_boot(.clk(core_clk),
.select_model(image_active?image_style:style_requested),.inference_idle(style_inference_idle && image_phase!=5),.active_model(style_active),
.cfg_we(style_cfg_we),.cfg_tanh(style_cfg_tanh),.cfg_index(style_cfg_index),.cfg_data(style_cfg_data),
.rst_n(vid_rst_n && c_deployment_started),
.cal_done(cal_done),
.ready(weights_boot_ready),
.failed(weights_boot_failed),
.fault_code(weights_boot_fault),
.flash_sclk(spi_flash_SCLK_OUT),
.flash_mosi(spi_flash_MOSI_OUT),
.flash_cs_n(spi_flash_CS_N_OUT),
.flash_miso(spi_flash_MISO_IN),
.n_axi_awid(boot_nn_awid),
.m_axi_awid(boot_m_awid),
.n_axi_awaddr(boot_nn_awaddr),
.m_axi_awaddr(n_awaddr[0]),
.n_axi_awlen(boot_nn_awlen),
.m_axi_awlen(n_awlen[0]),
.n_axi_awsize(boot_nn_awsize),
.m_axi_awsize(n_awsize[0]),
.n_axi_awburst(boot_nn_awburst),
.m_axi_awburst(n_awburst[0]),
.n_axi_awlock(boot_nn_awlock),
.m_axi_awlock(n_awlock[0]),
.n_axi_awcache(boot_nn_awcache),
.m_axi_awcache(n_awcache[0]),
.n_axi_awprot(boot_nn_awprot),
.m_axi_awprot(n_awprot[0]),
.n_axi_awvalid(boot_nn_awvalid),
.m_axi_awvalid(n_awvalid[0]),
.n_axi_awready(boot_nn_awready),
.m_axi_awready(n_awready[0]),
.n_axi_wdata(boot_nn_wdata),
.m_axi_wdata(n_wdata[0]),
.n_axi_wstrb(boot_nn_wstrb),
.m_axi_wstrb(n_wstrb[0]),
.n_axi_wlast(boot_nn_wlast),
.m_axi_wlast(n_wlast[0]),
.n_axi_wvalid(boot_nn_wvalid),
.m_axi_wvalid(n_wvalid[0]),
.n_axi_wready(boot_nn_wready),
.m_axi_wready(n_wready[0]),
.n_axi_bid(boot_nn_bid),
.m_axi_bid(n_bid[0][3:0]),
.n_axi_bresp(boot_nn_bresp),
.m_axi_bresp(n_bresp[0]),
.n_axi_bvalid(boot_nn_bvalid),
.m_axi_bvalid(n_bvalid[0]),
.n_axi_bready(boot_nn_bready),
.m_axi_bready(n_bready[0]),
.n_axi_arid(boot_nn_arid),
.m_axi_arid(boot_m_arid),
.n_axi_araddr(boot_nn_araddr),
.m_axi_araddr(n_araddr[0]),
.n_axi_arlen(boot_nn_arlen),
.m_axi_arlen(n_arlen[0]),
.n_axi_arsize(boot_nn_arsize),
.m_axi_arsize(n_arsize[0]),
.n_axi_arburst(boot_nn_arburst),
.m_axi_arburst(n_arburst[0]),
.n_axi_arlock(boot_nn_arlock),
.m_axi_arlock(n_arlock[0]),
.n_axi_arcache(boot_nn_arcache),
.m_axi_arcache(n_arcache[0]),
.n_axi_arprot(boot_nn_arprot),
.m_axi_arprot(n_arprot[0]),
.n_axi_arvalid(boot_nn_arvalid),
.m_axi_arvalid(n_arvalid[0]),
.n_axi_arready(boot_nn_arready),
.m_axi_arready(n_arready[0]),
.n_axi_rid(boot_nn_rid),
.m_axi_rid(n_rid[0][3:0]),
.n_axi_rdata(boot_nn_rdata),
.m_axi_rdata(n_rdata[0]),
.n_axi_rresp(boot_nn_rresp),
.m_axi_rresp(n_rresp[0]),
.n_axi_rlast(boot_nn_rlast),
.m_axi_rlast(n_rlast[0]),
.n_axi_rvalid(boot_nn_rvalid),
.m_axi_rvalid(n_rvalid[0]),
.n_axi_rready(boot_nn_rready),
.m_axi_rready(n_rready[0]));
wire cat_warp_start,cat_warp_done,cat_warp_pass,cat_warp_fail,cat_warp_busy;
wire [31:0] cat_warp_src,cat_warp_dst,cat_warp_cycles,cat_warp_reads;
wire [2:0] live_nn_display_style,cat_warp_style;
wire cat_warp_fisheye,live_nn_display_fisheye;
wire c_admit_enable,c_scheduler_req_ready,c_control_irq;
assign copy_in_req_ready=c_scheduler_req_ready&&c_admit_enable;
// Diagnostic variant: retain trained style2 NN; remove extra curl/pigment and mixed backing-store path.
camera_nn_compare_pipeline #(.FRAME_ATOMIC(1),.UKIYO_BOTTOM_EN(0),.STYLE_TAG_EN(1),.CAT_FISHEYE_EN(0),.WARP_OVERLAP(0),.RUNTIME_FISHEYE(0),.INPUT0(32'h02000000),.INPUT1(32'h02400000),.INPUT2(32'h02800000),.INPUT3(32'h02c00000),.OUTPUT0(32'h06000000),.OUTPUT1(32'h06800000),.OUTPUT2(32'h07000000),.WARP_OFFSET(32'h00400000)) u_camera_nn_scheduler(
 .debug_state(c_diag_scheduler),
 .warp_model_id(cat_warp_style),.warp_fisheye_enable(cat_warp_fisheye),.display_fisheye_enable(live_nn_display_fisheye),
 .current_model_id(style_active),.roi_requested(c_platform_config[11:10]),.display_roi_mode(live_nn_display_roi),.snapshot_ready(snapshot_pipeline_ready),.display_model_id(live_nn_display_style),
 .fisheye_enable(fisheye_requested),.warp_start(cat_warp_start),.warp_done(cat_warp_done),.warp_pass(cat_warp_pass),.warp_fail(cat_warp_fail),
 .warp_source_base(cat_warp_src),.warp_dest_base(cat_warp_dst),
 .inference_idle(style_inference_idle),
 .clk(core_clk),.rst_n(vid_rst_n),.enable(shared_test_start && weights_boot_ready),
 .req_valid(copy_in_req_valid&&c_admit_enable&&!image_pause),.req_ready(video_scheduler_req_ready),.req_bank(copy_in_req_bank),
 .req_addr(copy_in_req_addr),.req_frame_id(copy_in_req_frame_id),
 .done_valid(copy_in_done_valid),.done_ready(copy_in_done_ready),.done_bank(copy_in_done_bank),
 .done_frame_id(copy_in_done_frame_id),.done_error(copy_in_done_error),
 .nn_start(live_nn_start),.nn_reset_n(live_nn_reset_n),.nn_done(live_nn_done),
 .nn_pass(live_nn_pass),.nn_fail(live_nn_fail),.display_fault(live_nn_display_fault || weights_boot_failed),
 .nn_input_base(live_nn_input_base),.nn_output_base(live_nn_output_base),
 .display_enable(live_nn_display_enable),.display_base(live_nn_display_base),
 .display_buffer(live_nn_display_buffer),.display_frame_id(live_nn_display_frame_id),
 .display_input_base(live_nn_display_input_base),
 .frame_shown(live_nn_shown),.quiescent(live_nn_quiet),.publication_window(live_display_publication_window),.fault(live_nn_scheduler_fault));

// Probe these stable snapshots in the core_clk logic analyzer (cycles, decimal).
 wire nn_profile_compute_active,nn_profile_memory_wait;
 wire nn_profile_valid;
 wire [31:0] nn_profile_total,nn_profile_compute,nn_profile_memory,nn_profile_control,nn_profile_gap;
generate if(NN_CYCLE_PROFILE_ENABLE!=0)begin:G_NN_CYCLE_PROFILE
nn_cycle_profile u_nn_cycle_profile(.clk(core_clk),.rst_n(vid_rst_n),.start(live_nn_start),
 .active(live_nn_busy),.compute_active(nn_profile_compute_active),.memory_wait(nn_profile_memory_wait),
 .valid(nn_profile_valid),.last_total(nn_profile_total),.last_compute(nn_profile_compute),
 .last_memory(nn_profile_memory),.last_control(nn_profile_control),.last_gap(nn_profile_gap));
end else begin:G_NO_NN_CYCLE_PROFILE
 assign nn_profile_valid=0;
 assign nn_profile_total=0;assign nn_profile_compute=0;assign nn_profile_memory=0;
 assign nn_profile_control=0;assign nn_profile_gap=0;
end endgenerate

// Local NN reset releases after two core edges. Assertion remains async;
// no extra clock/reset timing exception is introduced for this local chain.
wire live_nn_core_reset_n;
hdmi_reset_release u_nn_core_release(.clk(core_clk),
 .rst_n(vid_rst_n && image_local_reset_n && (image_nn_owner||live_nn_reset_n)),.released_n(live_nn_core_reset_n));
nn_ddr_selftest #(.A4_COMPACT_WRITES(1),.A4_WRITE_QUEUE_BRAM(1),.A4_PIPELINED_MASK(1),.A4_PACKET_INPUT_PIPE(1),.A4_REQUEST_TRACK(1),.A4_READ_INPUT_PIPE(1),.A4_WRITE_INPUT_PIPE(1),.A4_REGISTERED_FLUSH(1),.A4_PARALLEL_CACHE_READ(1),.A4_RETURN_ADVANCE(1),.A4_PACKET_WORDS(32),.A4_ROW_PCO(4),.A4_FAST_MASK_SEAL(1),.A4_MODE(1),.A4_DEEP_ROW(1),.RUNTIME_MODEL(1),.USE_EXTERNAL_DDR_INPUT(1),.USE_EXTERNAL_DDR_OUTPUT(1),
 .BYPASS_VERIFIED_INPUT(1),.PRELOAD_DDR_INPUT(0),.PRELOAD_DDR_WEIGHTS(0),.USE_DDR_WEIGHTS(1),
 .USE_CAMERA_INPUT(0),.INFERENCE_COMPLETION_ONLY(1),.CHECK_OUTPUT_CRC(0),
 .VERIFY_OUTPUT_REPEAT(0),.FRAME_BASE_ADDR(32'h03000000),.BANK_ADDR_SHIFT(23),
 .IMAGE_SCALE(40),.IMAGE_HEIGHT_SCALE(30),.FRAME_ADDR_BITS(23),.CAMERA_ADDR_WIDTH(20),
 .INPUT_BEATS(230400),.OUTPUT_BEATS(172800),.NETWORK_LAYERS(20)) u_live_nn(
 .runtime_model(style_active),.cfg_we(style_cfg_we),.cfg_tanh(style_cfg_tanh),.cfg_index(style_cfg_index),.cfg_data(style_cfg_data),
 .clk(core_clk),.rst_n(live_nn_core_reset_n),.start(image_nn_owner?image_nn_start:live_nn_start),.ddr_cal_done(cal_done),
 .runtime_input_ddr_base(image_nn_owner?image_input_base:live_nn_input_base),.runtime_output_ddr_base(image_nn_owner?image_output_base:live_nn_output_base),
 .runtime_input_verified(1'b1),.runtime_input_crc32(32'd0),.runtime_output_crc32(32'd0),
 .camera_read_addr(),.camera_read_data(32'd0),.busy(image_actual_busy),.done(image_actual_done),
 .profile_compute_active(nn_profile_compute_active),.profile_memory_wait(nn_profile_memory_wait),
 .pass(image_actual_pass),.fail(image_actual_fail),.fault_code(live_nn_compute_fault),.error_count(),
 .output_crc32(),.output_nonzero_bytes(),.output_byte_min(),.output_byte_max(),
 .preview_byte_valid(),.preview_byte_data(),.debug_phase(c_diag_nn_phase),.debug_timeout(c_diag_nn_timeout),
 .m_axi_awid(boot_nn_awid),
 .m_axi_awaddr(boot_nn_awaddr),
 .m_axi_awlen(boot_nn_awlen),
 .m_axi_awsize(boot_nn_awsize),
 .m_axi_awburst(boot_nn_awburst),
 .m_axi_awlock(boot_nn_awlock),
 .m_axi_awcache(boot_nn_awcache),
 .m_axi_awprot(boot_nn_awprot),
 .m_axi_awvalid(boot_nn_awvalid),
 .m_axi_awready(boot_nn_awready),
 .m_axi_wdata(boot_nn_wdata),
 .m_axi_wstrb(boot_nn_wstrb),
 .m_axi_wlast(boot_nn_wlast),
 .m_axi_wvalid(boot_nn_wvalid),
 .m_axi_wready(boot_nn_wready),
 .m_axi_bid(boot_nn_bid),
 .m_axi_bresp(boot_nn_bresp),
 .m_axi_bvalid(boot_nn_bvalid),
 .m_axi_bready(boot_nn_bready),
 .m_axi_arid(boot_nn_arid),
 .m_axi_araddr(boot_nn_araddr),
 .m_axi_arlen(boot_nn_arlen),
 .m_axi_arsize(boot_nn_arsize),
 .m_axi_arburst(boot_nn_arburst),
 .m_axi_arlock(boot_nn_arlock),
 .m_axi_arcache(boot_nn_arcache),
 .m_axi_arprot(boot_nn_arprot),
 .m_axi_arvalid(boot_nn_arvalid),
 .m_axi_arready(boot_nn_arready),
 .m_axi_rid(boot_nn_rid),
 .m_axi_rdata(boot_nn_rdata),
 .m_axi_rresp(boot_nn_rresp),
 .m_axi_rlast(boot_nn_rlast),
 .m_axi_rvalid(boot_nn_rvalid),
 .m_axi_rready(boot_nn_rready)
);
assign n_awid[1]=0;


assign n_awsize[1]=4;
assign n_awburst[1]=1;
assign n_awlock[1]=0;
assign n_awcache[1]=0;
assign n_awprot[1]=0;






assign n_arid[1]=0;
assign n_arsize[1]=4;
assign n_arburst[1]=1;
assign n_arlock[1]=0;
assign n_arcache[1]=3;
assign n_arprot[1]=2;

wire [31:0] cat_disp_araddr,cat_map_araddr;
wire [7:0] cat_disp_arlen,cat_map_arlen;
wire cat_disp_arvalid,cat_disp_arready,cat_disp_rvalid,cat_disp_rlast,cat_disp_rready;

wire cat_map_arvalid,cat_map_arready,cat_map_rvalid,cat_map_rlast,cat_map_rready;
wire [127:0] cat_disp_rdata,cat_map_rdata;
wire [1:0] cat_disp_rresp,cat_map_rresp;
wire [31:0] snapshot_video_araddr;
wire [7:0] snapshot_video_arlen;
wire snapshot_video_arvalid,snapshot_video_arready;
wire [127:0] snapshot_video_rdata;wire [1:0] snapshot_video_rresp;
wire snapshot_video_rlast,snapshot_video_rvalid,snapshot_video_rready;
wire [31:0] cat_axi_araddr,cat_axi_awaddr;
wire [7:0] cat_axi_arlen,cat_axi_awlen;
wire cat_axi_arvalid,cat_axi_arready,cat_axi_awvalid,cat_axi_awready;
wire [127:0] cat_axi_rdata;wire [1:0] cat_axi_rresp;
wire cat_axi_rlast,cat_axi_rvalid,cat_axi_rready;
axi_command_pipeline #(.WIDTH(40)) u_cat_ar_pipeline(
 .clk(core_clk),.rst_n(vid_rst_n),.in_valid(cat_axi_arvalid),.in_ready(cat_axi_arready),
 .in_payload({cat_axi_araddr,cat_axi_arlen}),.out_valid(n_arvalid[1]),.out_ready(n_arready[1]),
 .out_payload({n_araddr[1],n_arlen[1]}));
// No geometry writer in this profile. Read channel remains for display/photo.
assign n_awaddr[1]=0;assign n_awlen[1]=0;assign n_awvalid[1]=0;
assign n_wdata[1]=0;assign n_wstrb[1]=0;assign n_wlast[1]=0;assign n_wvalid[1]=0;
assign n_bready[1]=1'b1;
axi_read_response_pipeline u_cat_r_pipeline(
 .clk(core_clk),.rst_n(vid_rst_n),.in_data(n_rdata[1]),.in_resp(n_rid[1]!=0?2'b10:n_rresp[1]),
 .in_last(n_rlast[1]),.in_valid(n_rvalid[1]),.in_ready(n_rready[1]),
 .out_data(cat_axi_rdata),.out_resp(cat_axi_rresp),.out_last(cat_axi_rlast),
 .out_valid(cat_axi_rvalid),.out_ready(cat_axi_rready));
// Bypass the removed geometry read client; snapshot service retains its
// exclusive display/photo grant and the original AR/R skid pipelines.
assign cat_warp_done=1'b0;assign cat_warp_pass=1'b0;assign cat_warp_fail=1'b0;
assign cat_warp_busy=1'b0;assign cat_warp_cycles=32'd0;assign cat_warp_reads=32'd0;
assign c_diag_cat_read=2'd0;
assign snapshot_video_araddr=cat_disp_araddr;
assign snapshot_video_arlen=cat_disp_arlen;
assign snapshot_video_arvalid=cat_disp_arvalid;
assign cat_disp_arready=snapshot_video_arready;
assign cat_disp_rdata=snapshot_video_rdata;assign cat_disp_rresp=snapshot_video_rresp;
assign cat_disp_rlast=snapshot_video_rlast;assign cat_disp_rvalid=snapshot_video_rvalid;
assign snapshot_video_rready=cat_disp_rready;
frame_snapshot_service #(.W(1280),.H(720),.APB_BASE(16'h0800),.TIMEOUT_BITS(21)) u_frame_snapshot(
 .cpu_clk(mipi_tx_feedback100),.core_clk(core_clk),.cpu_reset(c_reset),.core_reset_n(vid_rst_n),
 .can_lock(c_capture_allowed && snapshot_pipeline_ready && !image_pause),.display_frame(live_nn_display_frame_id),
 .original_base(live_nn_display_input_base),.result_base(live_nn_display_base),
 .display_style(live_nn_display_style),.display_roi(live_nn_display_roi),.display_fish(live_nn_display_fisheye),.locked(snapshot_locked),
 .PADDR(c_addr),.PSEL(c_sel && photo_sel),.PENABLE(c_enable),.PWRITE(c_write),.PWDATA(c_wdata),
 .PRDATA(photo_data),.PREADY(photo_ready),.PSLVERROR(photo_error),
 .video_araddr(snapshot_video_araddr),.video_arlen(snapshot_video_arlen),.video_arvalid(snapshot_video_arvalid),.video_arready(snapshot_video_arready),
 .video_rdata(snapshot_video_rdata),.video_rresp(snapshot_video_rresp),.video_rlast(snapshot_video_rlast),.video_rvalid(snapshot_video_rvalid),.video_rready(snapshot_video_rready),
 .araddr(cat_axi_araddr),.arlen(cat_axi_arlen),.arvalid(cat_axi_arvalid),.arready(cat_axi_arready),
 .rdata(cat_axi_rdata),.rresp(cat_axi_rresp),.rlast(cat_axi_rlast),.rvalid(cat_axi_rvalid),.rready(cat_axi_rready));


wire [1:0] display_view_request,display_view_active;
display_view_control #(.DEBOUNCE_CYCLES(2970000)) u_display_view_control(
 .clk(hdmi_tx_slow_clk),.rst_n(tx_vid_rst_n),.button_n(display_sw1_n),.requested_view(display_view_request));
nn_ddr_picture_display #(.PACKED_LINE_RAM(1),.SERIAL_CACHE_WRITE(1),.VIEW_MODES(1),.ROI_ENABLE(1),.LOCAL_PIXEL_RESET(1),.UKIYO_BOTTOM_EN(0),.MATCHED_VERTICAL_FILTER(0),.ORIGINAL_VERTICAL_FILTER(0),.ORIGINAL_BOX_FILTER(0),.DECIMATE_X(2),.LINE_BANKS(6),.W(1280),.H(720),.CAT_WIDE_STRENGTH(0),.PARALLEL_UNPACK(1),.RUNTIME_BASE(1),.COMPARE_MODE(1),.RECOVER_UNDERFLOW(1),.SCALE(1),.ZOOM_NUM(7),.ZOOM_DEN(10),.MAX_BURST_BEATS(128)) u_live_nn_display(
 .runtime_view(display_view_request),.active_view(display_view_active),.runtime_roi(live_nn_display_roi),.frame_quality(video_frame_quality),.underflow_total(video_underflows),.last_underflow_row(video_bad_row),.debug_state(c_diag_display),.runtime_style(live_nn_display_style),.runtime_fisheye(live_nn_display_fisheye),
 .clk(core_clk),.pixel_clk(hdmi_tx_slow_clk),.pixel_rst_n(tx_vid_rst_n),.rst_n(vid_rst_n),
 .enable(live_nn_display_enable),.runtime_base(live_nn_display_base),
 .runtime_original_base(live_nn_display_input_base),
 .quiescent(live_nn_quiet),.read_urgent(live_display_read_pending),.frame_shown(live_nn_shown),.fault(live_nn_display_fault),.fault_detail(live_nn_display_detail),
 .read_critical(live_display_read_critical),
 .publication_window(live_display_publication_window),
 .red(live_nn_r),.green(live_nn_g),.blue(live_nn_b),.hs(live_nn_hs),.vs(live_nn_vs),.de(live_nn_de),
 .araddr(cat_disp_araddr),.arlen(cat_disp_arlen),.arvalid(cat_disp_arvalid),.arready(cat_disp_arready),
 .rdata(cat_disp_rdata),.rresp(cat_disp_rresp),.rlast(cat_disp_rlast),.rvalid(cat_disp_rvalid),.rready(cat_disp_rready));

        rgbx_input_slot_handoff3 #(.NUM_SLOTS(4),.LATEST_ONLY(HDMI_LATEST_FRAME),.BASE0(32'h02000000),.BASE1(32'h02400000),.BASE2(32'h02800000),.BASE3(32'h02c00000)) u_input_slot_handoff (
            .clk(core_clk),.rst_n(vid_rst_n),.slot_valid(rgbx_ddr_slot_valid),
            .slot0_frame_id(rgbx_ddr_slot0_frame_id),
            .slot1_frame_id(rgbx_ddr_slot1_frame_id),.slot2_frame_id(rgbx_ddr_slot2_frame_id),.slot3_frame_id(rgbx_ddr_slot3_frame_id),
            .req_valid(copy_in_req_valid),.req_ready(copy_in_req_ready),
            .req_bank(copy_in_req_bank),.req_addr(copy_in_req_addr),
            .req_frame_id(copy_in_req_frame_id),
            .done_valid(copy_in_done_valid),.done_ready(copy_in_done_ready),
            .done_bank(copy_in_done_bank),.done_frame_id(copy_in_done_frame_id),
            .done_error(copy_in_done_error),.release_slots(copy_in_release_slots),
            .busy(copy_in_busy),.error(copy_in_error),
            .accepted_count(copy_in_accepted_count),
            .released_count(copy_in_released_count),.failed_count(copy_in_failed_count),.dropped_count(copy_in_dropped_count)
        );
        generate if (RGBX_DDR_CAPTURE_EN) begin : g_rgbx_ddr
            rgbx_ddr_capture #(.ENABLE_HOLD(1),.CONTROL_PIPELINE(1),.LOCAL_PIXEL_RESET(1),.RGBX_FORMAT(2),.FRAME_PIXELS(921600),.NUM_SLOTS(4),.BURST_WORDS(32),.BASE0(32'h02000000),.BASE1(32'h02400000),.BASE2(32'h02800000),.BASE3(32'h02c00000)) u_capture (
                .pixel_clk(hdmi_tx_slow_clk), .pixel_rst_n(tx_vid_rst_n), .axi_clk(core_clk),
                .rst_n(vid_rst_n), .cal_done(cal_done),
                .hold(image_hold),.hold_ack(image_hold_ack),.capture_idle(image_capture_idle),
                .i_rgbx({8'd0,1'b0,rgbx640_data[23:17],1'b0,rgbx640_data[15:9],1'b0,rgbx640_data[7:1]}), .i_valid(rgbx640_valid),
                .i_sof(rgbx640_sof), .i_frame_id(rgbx640_frame_id),
                .i_frame_done(rgbx640_frame_done),
                .i_frame_abort(rgbx640_frame_abort), .release_slots(copy_in_release_slots),
                .awaddr(cap_awaddr), .awlen(cap_awlen),
                .awvalid(cap_awvalid), .awready(cap_awready),
                .wdata(cap_wdata), .wlast(cap_wlast),
                .wvalid(cap_wvalid), .wready(cap_wready),
                .bid(m_bid[1][3:0]), .bresp(m_bresp[1]),
                .bvalid(cap_bvalid), .bready(cap_bready),
                .araddr(cap_araddr), .arlen(cap_arlen),
                .arvalid(cap_arvalid), .arready(cap_arready),
                .rid(m_rid[1][3:0]), .rdata(m_rdata[1]), .rresp(m_rresp[1]),
                .rlast(m_rlast[1]), .rvalid(cap_rvalid), .rready(cap_rready),
                .slot_valid(rgbx_ddr_slot_valid),
                .slot0_frame_id(rgbx_ddr_slot0_frame_id),
                .slot1_frame_id(rgbx_ddr_slot1_frame_id),.slot2_frame_id(rgbx_ddr_slot2_frame_id),.slot3_frame_id(rgbx_ddr_slot3_frame_id),
                .commit_count(rgbx_ddr_commit_count), .commit_pulse(rgbx_ddr_commit),
                .committed_addr(rgbx_ddr_committed_addr),
                .word_count(rgbx_ddr_word_count), .response_count(rgbx_ddr_b_count),
                .abort_count(rgbx_ddr_abort_count), .error(rgbx_ddr_error),
                .busy(rgbx_ddr_busy), .skipped_frames(rgbx_ddr_skipped_frames_pixel)
            );
        end else begin : g_rgbx_ddr_disabled
            assign image_hold_ack=0;assign image_capture_idle=0;
            assign rgbx_ddr_slot_valid=0;
            assign rgbx_ddr_slot0_frame_id=0; assign rgbx_ddr_slot1_frame_id=0;assign rgbx_ddr_slot2_frame_id=0;assign rgbx_ddr_slot3_frame_id=0;
            assign rgbx_ddr_commit_count=0; assign rgbx_ddr_commit=0;
            assign rgbx_ddr_committed_addr=0; assign rgbx_ddr_word_count=0;
            assign rgbx_ddr_b_count=0; assign rgbx_ddr_abort_count=0;
            assign rgbx_ddr_error=0; assign rgbx_ddr_busy=0;
            assign rgbx_ddr_skipped_frames_pixel=0;
        end endgenerate
        reg [26:0] dly_cnt=0;
        always @(posedge core_clk or negedge w_arstn)
         if(!w_arstn)dly_cnt<=0;else if(!dly_cnt[26])dly_cnt<=dly_cnt+1'b1;
        assign vid_rst_n=dly_cnt[26];
        wire hs;
        wire vs;
        wire de;
        wire [7:0] rgb_r;
        wire [7:0] rgb_g;
        wire [7:0] rgb_b;
          
          // color_bar_rgb #(
          // .HS_POLORY 		(1'b1		),
          // .VS_POLORY 		(1'b1		),
          // .H_FRONT_PORCH 	(HFP		),///2
          // .H_SYNC 		(HSP		),//
          // .H_VALID 		(MAX_HRES	),//
          // .H_BACK_PORCH 	(HBP		),//
          // .V_FRONT_PORCH 	(VFP		),
          // .V_SYNC 		(VSP		),
          // .V_VALID 		(MAX_VRES	),
          // .V_BACK_PORCH 	(VBP		),
          // .TEST_MODE 		(2'd2)
          // )u_color_bar_rgb1(
          // /*i*/.clk	(vid_clk_dvi2),//(vid_clk),
          // /*i*/.rst_n	(vid_rst_n),
          // /*o*/.hs	(hs),
          // /*o*/.vs	(vs),
          // /*o*/.de	(de),
          // // /*O*/.h_cnt (h_cnt),
          // // /*O*/.v_cnt (v_cnt),
          // /*o*/.rgb_r	(rgb_r),    //像素数据、红色分量
          // /*o*/.rgb_g	(rgb_g),    //像素数据、绿色分量
          // /*o*/.rgb_b (rgb_b)    //像素数据、蓝色分量
          
          // );

        //=================================================================================
        //hdmi tx ctrl 
        //=================================================================================
        wire                            video_hs;
        wire                            video_vs;
        wire                            video_de;
        wire[7:0]                       video_r;
        wire[7:0]                       video_g;
        wire[7:0]                       video_b;

        assign tmds_tx_data0_TX_OE = 1'b1;
        assign tmds_tx_data1_TX_OE = 1'b1;
        assign tmds_tx_data2_TX_OE = 1'b1;
        assign tmds_tx_clk_TX_OE   = 1'b1;

        assign tmds_tx_data0_TX_RST = 1'b0;
        assign tmds_tx_data1_TX_RST = 1'b0;
        assign tmds_tx_data2_TX_RST = 1'b0;
        assign tmds_tx_clk_TX_RST   = 1'b0;

        // 	  color_bar color_bar_m0(
        // 	.clk(hdmi_tx_slow_clk),
        // 	.rst(~vid_rst_n),
        // 	.hs(video_hs),
        // 	.vs(video_vs),
        // 	.de(video_de),
        // 	.rgb_r(video_r),
        // 	.rgb_g(video_g),
        // 	.rgb_b(video_b)
        // );

        wire [9:0] tmds_data0;
        wire [9:0] tmds_data1;
        wire [9:0] tmds_data2;
        wire [9:0] tmds_clk ;
        wire [7:0] gamma_rdata ;
        wire [7:0] gamma_gdata ;
        wire [7:0] gamma_bdata ;
        wire gamma_valid;
        wire gamma_hs;
        wire gamma_vs;
        wire gamma_sel;

        wire [7:0] con_rdata ;
        wire [7:0] con_gdata ;
        wire [7:0] con_bdata ;
        wire con_de;
        wire con_hs;
        wire con_vs;
        wire con_sel;

        wire [7:0] BRIGHT_SIG    ;
        wire CONTRAST_SIG_G;
        wire CONTRAST_SIG_R;
        wire [7:0] CONTRAST_G    ;
        wire CONTRAST_SIG_B;
        wire [7:0] BRIGHT        ;
        wire [7:0] CONTRAST_R    ;


        wire CONTRAST_B    ;


        //内部彩条V6_0_1
            // 临时 HDMI RGB 通道测试：1=显示测试彩条，0=恢复摄像头画面V6_0_1
            localparam TEST_COLOR_BAR_EN = 1'b0;

            reg [11:0] test_x;

            always @(posedge hdmi_tx_slow_clk or negedge tx_vid_rst_n)
            begin
                if (!tx_vid_rst_n)
                    test_x <= 12'd0;
                else if (!live_nn_de)
                    test_x <= 12'd0;
                else if (test_x == 12'd1919)
                    test_x <= 12'd0;
                else
                    test_x <= test_x + 1'b1;
            end

            wire [7:0] test_rdata;
            wire [7:0] test_gdata;
            wire [7:0] test_bdata;

            // 从左到右：红、绿、蓝、白，每段480像素
            assign test_rdata = (test_x < 12'd480)  ? 8'hFF :
                                (test_x < 12'd960)  ? 8'h00 :
                                (test_x < 12'd1440) ? 8'h00 :
                                                      8'hFF;

            assign test_gdata = (test_x < 12'd480)  ? 8'h00 :
                                (test_x < 12'd960)  ? 8'hFF :
                                (test_x < 12'd1440) ? 8'h00 :
                                                      8'hFF;

            assign test_bdata = (test_x < 12'd480)  ? 8'h00 :
                                (test_x < 12'd960)  ? 8'h00 :
                                (test_x < 12'd1440) ? 8'hFF :
                                                      8'hFF;
        // User shadow curve on NN display; quantized camera input stays linear.
        wire [7:0] camera_input_r,camera_input_g,camera_input_b;
        wire camera_input_de,camera_input_hs,camera_input_vs;
        // Computer RGB needs no camera exposure/tone compensation.
        assign camera_input_r=TEST_COLOR_BAR_EN?test_rdata:live_nn_r;
        assign camera_input_g=TEST_COLOR_BAR_EN?test_gdata:live_nn_g;
        assign camera_input_b=TEST_COLOR_BAR_EN?test_bdata:live_nn_b;
        assign camera_input_de=live_nn_de;assign camera_input_hs=live_nn_hs;assign camera_input_vs=live_nn_vs;
        reg camera_previous_de,camera_previous_vs;
        reg [11:0] camera_x_count,camera_y_count;
        wire [11:0] camera_x=camera_osd_de?(camera_previous_de?camera_x_count:12'd0):12'd0;
        wire camera_hdmi_event=camera_osd_vs&&!camera_previous_vs;
        always @(posedge hdmi_tx_slow_clk or negedge tx_vid_rst_n)begin
          if(!tx_vid_rst_n)begin camera_previous_de<=0;camera_previous_vs<=0;camera_x_count<=0;camera_y_count<=0;end
          else begin
            camera_previous_de<=camera_osd_de;camera_previous_vs<=camera_osd_vs;
            if(camera_hdmi_event)camera_y_count<=0;
            else if(camera_previous_de&&!camera_osd_de)camera_y_count<=camera_y_count+1'b1;
            if(camera_osd_de)camera_x_count<=camera_previous_de?camera_x_count+1'b1:12'd1;
            else camera_x_count<=0;
          end
        end
        reg hdmi_rx_vs_d;
        always @(posedge hdmi_rx_slow_clk or negedge rx_vid_rst_n)
         if(!rx_vid_rst_n)hdmi_rx_vs_d<=1;else hdmi_rx_vs_d<=rx_vs;
        wire camera_source_event=rgbx640_sof;
        wire [9:0] camera_source_fps;
        wire camera_source_unused_event,camera_source_cdc_error;
        pixel_event_rate #(.HZ(148500000)) u_source_rate(.clk(hdmi_tx_slow_clk),.rst_n(tx_vid_rst_n),.event_in(camera_source_event),.fps(camera_source_fps));
        assign camera_source_unused_event=0;assign camera_source_cdc_error=0;
        wire [9:0] camera_capture_fps,camera_new_fps,camera_hdmi_hz;
        wire camera_new_frame,camera_fps_cdc_error;
        camera_fps_monitor #(.CORE_HZ(160000000)) u_camera_fps_monitor(
          .core_clk(core_clk),.pixel_clk(hdmi_tx_slow_clk),.rst_n(vid_rst_n),
          .capture_commit(camera_capture_commit),.display_done(1'b0),
          .display_valid(1'b0),.display_id(32'd0),
          .capture_fps(camera_capture_fps),.new_frame_event(camera_new_frame),.cdc_error(camera_fps_cdc_error));
        wire [7:0] camera_osd_r,camera_osd_g,camera_osd_b;
        wire camera_osd_de,camera_osd_hs,camera_osd_vs;
        reg source_hdmi_meta,source_hdmi_pixel;
        always @(posedge hdmi_tx_slow_clk or negedge tx_vid_rst_n)
          if(!tx_vid_rst_n)begin source_hdmi_meta<=0;source_hdmi_pixel<=0;end
          else begin source_hdmi_meta<=active_source;source_hdmi_pixel<=source_hdmi_meta;end
        camera_tone_mapper u_camera_display_tone(.clk(hdmi_tx_slow_clk),.rst_n(tx_vid_rst_n),.i_bypass(source_hdmi_pixel|TEST_COLOR_BAR_EN),
          .i_r(camera_input_r),.i_g(camera_input_g),.i_b(camera_input_b),.i_de(camera_input_de),.i_hs(camera_input_hs),.i_vs(camera_input_vs),
          .o_r(camera_osd_r),.o_g(camera_osd_g),.o_b(camera_osd_b),.o_de(camera_osd_de),.o_hs(camera_osd_hs),.o_vs(camera_osd_vs));
        assign camera_new_fps=0;assign camera_hdmi_hz=0;


        wire [9:0] live_nn_fps,live_nn_new_fps;
        nn_fps_monitor #(.LOCAL_PIXEL_RESET(1),.CORE_HZ(160000000),.BUFFER_BITS(2)) u_nn_fps_monitor(.core_clk(core_clk),.pixel_clk(hdmi_tx_slow_clk),.pixel_rst_n(tx_vid_rst_n),.rst_n(vid_rst_n),
            .done(live_nn_done),.pass(live_nn_pass),.fail(live_nn_fail | live_nn_display_fault),
            .display_enable(live_nn_display_enable),.display_buffer(live_nn_display_buffer),
            .frame_shown(live_nn_shown),.success_total(video_nn_total),.new_total(video_new_total),.shown_total(video_shown_total),.nn_fps(live_nn_fps),.new_fps(live_nn_new_fps));
        reg [11:0] nn_osd_x,nn_osd_y;reg nn_osd_vs_d;
        always @(posedge hdmi_tx_slow_clk or negedge tx_vid_rst_n)begin
            if(!tx_vid_rst_n)begin nn_osd_x<=0;nn_osd_y<=0;nn_osd_vs_d<=0;end
            else begin nn_osd_x<=camera_x;nn_osd_y<=camera_y_count;nn_osd_vs_d<=camera_osd_vs;end
        end
        wire [7:0] final_osd_r,final_osd_g,final_osd_b;
        wire final_osd_hs,final_osd_vs,final_osd_de;
        wire[11:0]network_osd_state;
        net_image_status_view u_network_status_view(
          .core_clk(core_clk),.core_rst_n(vid_rst_n),.pixel_clk(hdmi_tx_slow_clk),.pixel_rst_n(tx_vid_rst_n),
          .phase(image_phase),.terminal_status(image_terminal),.fresh_visible_total(video_new_total),.pixel_state(network_osd_state));
        nn_fps_osd #(.SHOW_STATUS(0),.NETWORK_STATUS(0),.FRAME_WIDTH(1280),.FRAME_HEIGHT(720)) u_nn_fps_osd(.clk(hdmi_tx_slow_clk),.rst_n(tx_vid_rst_n),.x(camera_x),.y(camera_y_count),
            .network_state(network_osd_state),.source_hdmi(active_source),.cpu_ui({c_platform_config[6],c_platform_config[9:7]}),.debug_status({rgbx_ddr_commit_count[7:0],rgbx_ddr_slot_valid,rgbx_ddr_error,live_nn_fault,live_nn_display_detail,live_nn_busy,live_nn_pass}),
            .source_fps(camera_source_fps),.camera_capture_fps(camera_capture_fps),.new_fps(live_nn_new_fps),.capture_fps(live_nn_fps),.picture_index(1'b0),
            .frame_commit(camera_new_frame),.frame_tick(camera_osd_vs && !nn_osd_vs_d),
            .r(camera_osd_r),.g(camera_osd_g),.b(camera_osd_b),.de(camera_osd_de),.hs(camera_osd_hs),.vs(camera_osd_vs),
            .o_r(final_osd_r),.o_g(final_osd_g),.o_b(final_osd_b),.o_de(final_osd_de),.o_hs(final_osd_hs),.o_vs(final_osd_vs),
            .image_fps(),.hdmi_hz(video_hdmi_hz));
        dvi_encoder dvi_encoder_m0
        (
            .pixelclk      		(hdmi_tx_slow_clk          ),// system clock
            .rst_p         		(~tx_vid_rst_n      ),// reset
            .i_bdata(final_osd_b),
            .i_gdata(final_osd_g),
            .i_rdata(final_osd_r),
          .i_de(final_osd_de),//(hdmi_tx_de    ),//(video_de           ),//(rx_de		  ),   //
            .i_hs(final_osd_hs),//(video_hs           ),//(rx_hsync	),   //   
            .i_vs(final_osd_vs),//(video_vs           ),//(rx_vsync	),   //  
            
          .video_format     (video_format), //// 00 = RGB, 01 = YCbCr 4:2:2, 10 = YCbCr 4:4:4
          .video_VIC        (0),
            .audio_L			    (audio_L),
          .audio_R			    (audio_R),
          .audio_valid		  (audio_valid),
          .audio_N                (6144),     //(20'h01880),//     
          .audio_CTS              (148500),      //(20'h28488),//      
          .audio_sample_frequency (audio_samp_freq),    //(3'b000),// 
          .audio_word_length      ({audio_samp_word_len,audio_max_word_length}),//(4'b1011),//

            .tmds_data0    		(tmds_data0),
          .tmds_data1    		(tmds_data1),
          .tmds_data2    		(tmds_data2),
          .tmds_clk      	  (tmds_clk  )
        );
        assign tmds_tx_clk_TX_DATA   = ~tmds_clk;
        assign tmds_tx_data0_TX_DATA = ~tmds_data0;
        assign tmds_tx_data1_TX_DATA = ~tmds_data1;
        assign tmds_tx_data2_TX_DATA = ~tmds_data2;

        // C Standard/100MHz/16KB observer. B's USER1 analyzer is retained.
        wire c_reset,c_ready,c_error;
        wire [31:0] c_rdata,probe_data,nn_data;
        wire probe_ready,probe_error,nn_ready,nn_error;
        wire cam_sel=c_addr[15:8]==8'h03;wire[31:0]cam_data;wire cam_ready,cam_error;
        wire nn_sel=(c_addr[15:8]==8'h01)||(c_addr[15:8]==8'h02);
        wire video_sel=c_addr[15:8]==8'h04;wire[31:0]video_data;wire video_ready,video_error;
        wire net_clk=rxc;wire[7:0]net_gmii_rx_data,net_gmii_tx_data;wire net_gmii_rx_valid,net_gmii_rx_error,net_gmii_tx_valid;
        net_physical_link u_net_physical(.osc_inst1_CLKOUT(osc_inst1_CLKOUT),.rxc(rxc),.reset_n(i_arstn),.mdio_i(mdio_i),
          .rxd_hi_i(rxd_hi_i),.rxd_lo_i(rxd_lo_i),.rx_dv_HI(rx_dv_HI),.rx_dv_LO(rx_dv_LO),
          .osc_inst1_ENA(osc_inst1_ENA),.phy_rst_n(phy_rst_n),.mdc_o(mdc_o),.mdio_o(mdio_o),.mdio_oe(mdio_oe),
          .txd_hi_o(txd_hi_o),.txd_lo_o(txd_lo_o),.tx_en_o_HI(tx_en_o_HI),.tx_en_o_LO(tx_en_o_LO),.txc_hi_o(txc_hi_o),.txc_lo_o(txc_lo_o),
          .rx_data(net_gmii_rx_data),.rx_valid(net_gmii_rx_valid),.rx_error(net_gmii_rx_error),.tx_data(net_gmii_tx_data),.tx_valid(net_gmii_tx_valid));
        wire net_sel=c_addr[15:12]==4'h1;wire[31:0]net_data;wire net_ready,net_error,net_irq;
        a_net_service_endpoint #(.HARDWARE_HELLO(0),.APB_BASE(16'h1000)) u_net_endpoint(
          .net_clk(net_clk),.cpu_clk(mipi_tx_feedback100),.reset_n(i_arstn),.cpu_reset(c_reset),
          .gmii_rx_data(net_gmii_rx_data),.gmii_rx_valid(net_gmii_rx_valid),.gmii_rx_error(net_gmii_rx_error),
          .gmii_tx_data(net_gmii_tx_data),.gmii_tx_valid(net_gmii_tx_valid),
          .PADDR(c_addr),.PSEL(c_sel&&net_sel),.PENABLE(c_enable),.PWRITE(c_write),.PWDATA(c_wdata),
          .PRDATA(net_data),.PREADY(net_ready),.PSLVERROR(net_error),.irq(net_irq));

        assign image_sel=c_addr[15:8]==8'h20;
        net_image_service u_image_service(
          .cpu_clk(mipi_tx_feedback100),.core_clk(core_clk),.root_reset_n(vid_rst_n),.cpu_reset(c_reset),
          .PADDR(c_addr),.PSEL(c_sel&&image_sel),.PENABLE(c_enable),.PWRITE(c_write),.PWDATA(c_wdata),
          .PRDATA(image_apb_data),.PREADY(image_apb_ready),.PSLVERROR(image_apb_error),
          .capture_hold_ack(image_hold_ack),.capture_idle(image_capture_idle),
          .video_idle(style_inference_idle&&!snapshot_locked&&weights_boot_ready),
          .core_idle(!image_actual_busy),.external_memory_quiet(image_nn_quiet),
          .capture_hold(image_hold),.pause_video_jobs(image_pause),.use_upload_axi(image_axi_owner),.lease_active(image_active),
          .nn_owner(image_nn_owner),.nn_job_valid(image_job_valid),.nn_job_ready(image_job_ready),
          .nn_job_done(image_job_done),.nn_job_drained(image_job_drained),.nn_job_error(image_job_error),
          .nn_style(image_style),.nn_input_base(image_input_base),.nn_output_base(image_output_base),
          .generation(image_generation),.phase(image_phase),.terminal_status(image_terminal),
          .memory_busy(image_dma_busy),.control_busy(image_control_busy),
          .awaddr(image_awaddr),.awlen(image_awlen),.awvalid(image_awvalid),.awready(image_awready),
          .wdata(image_wdata),.wstrb(image_wstrb),.wlast(image_wlast),.wvalid(image_wvalid),.wready(image_wready),
          .bid(m_bid[1][3:0]),.bresp(m_bresp[1]),.bvalid(image_bvalid),.bready(image_bready),
          .araddr(image_araddr),.arlen(image_arlen),.arvalid(image_arvalid),.arready(image_arready),
          .rid(m_rid[1][3:0]),.rdata(m_rdata[1]),.rresp(m_rresp[1]),.rlast(m_rlast[1]),.rvalid(image_rvalid),.rready(image_rready));
        net_image_nn_launcher u_image_nn_launcher(
          .clk(core_clk),.root_reset_n(vid_rst_n),.owner(image_nn_owner),
          .request_valid(image_job_valid),.request_ready(image_job_ready),
          .weights_ready(weights_boot_ready&&style_active==image_style),.weights_failed(weights_boot_failed),
          .core_busy(image_actual_busy),.core_done(image_actual_done),.core_pass(image_actual_pass),.core_fail(image_actual_fail),
          .core_fault(live_nn_compute_fault),.memory_quiet(image_nn_quiet),
          .local_reset_n(image_local_reset_n),.core_start(image_nn_start),
          .job_done(image_job_done),.job_drained(image_job_drained),.job_error(image_job_error),.debug_state());

        assign c_rdata=image_sel?image_apb_data:net_sel?net_data:photo_sel?photo_data:source_sel?source_data:hdmi_sel?hdmi_data:light_sel?light_prdata:video_sel?video_data:cam_sel?cam_data:nn_sel?nn_data:probe_data;
        assign c_ready=image_sel?image_apb_ready:net_sel?net_ready:photo_sel?photo_ready:source_sel?source_ready:hdmi_sel?hdmi_ready:light_sel?light_pready:video_sel?video_ready:cam_sel?cam_ready:nn_sel?nn_ready:probe_ready;
        assign c_error=image_sel?image_apb_error:net_sel?net_error:photo_sel?photo_error:source_sel?source_error:hdmi_sel?hdmi_error:light_sel?light_error:video_sel?video_error:cam_sel?cam_error:nn_sel?nn_error:probe_error;
        soc u_c_soc(.io_systemClk(mipi_tx_feedback100),.io_asyncReset(!w_arstn || !i_pll_locked),
            .io_systemReset(c_reset),.jtagCtrl_tck(jtag_inst2_TCK),.jtagCtrl_tdi(jtag_inst2_TDI),
            .jtagCtrl_tdo(jtag_inst2_TDO),.jtagCtrl_enable(jtag_inst2_SEL),
            .jtagCtrl_capture(jtag_inst2_CAPTURE),.jtagCtrl_shift(jtag_inst2_SHIFT),
            .jtagCtrl_update(jtag_inst2_UPDATE),.jtagCtrl_reset(jtag_inst2_RESET),
            .system_uart_0_io_txd(system_uart_0_io_txd),.system_uart_0_io_rxd(system_uart_0_io_rxd),
            .userInterruptA(c_control_irq),.io_apbSlave_0_PADDR(c_addr),.io_apbSlave_0_PSEL(c_sel),
            .io_apbSlave_0_PENABLE(c_enable),.io_apbSlave_0_PWRITE(c_write),
            .io_apbSlave_0_PWDATA(c_wdata),.io_apbSlave_0_PRDATA(c_rdata),
            .io_apbSlave_0_PREADY(c_ready),.io_apbSlave_0_PSLVERROR(c_error));
        c_apb_probe #(.RAM_BYTES(32768),.EXTRA_CAPABILITIES(32'h6)) u_c_probe(.clk(mipi_tx_feedback100),.reset(c_reset),
            .PADDR(c_addr),.PSEL(c_sel&&!image_sel&&!net_sel&&!photo_sel&&!nn_sel&&!cam_sel&&!video_sel&&!light_sel&&!hdmi_sel&&!source_sel),.PENABLE(c_enable),.PWRITE(c_write),
            .PWDATA(c_wdata),.PRDATA(probe_data),.PREADY(probe_ready),.PSLVERROR(probe_error));
        c_camera_apb u_c_camera_bridge(.cpu_clk(mipi_tx_feedback100),.cam_clk(mipi_tx_feedback100),.arst(c_reset||!i2c_rst_n),
          .PADDR(c_addr),.PSEL(c_sel&&cam_sel),.PENABLE(c_enable),.PWRITE(c_write),.PWDATA(c_wdata),
          .PRDATA(cam_data),.PREADY(cam_ready),.PSLVERROR(cam_error),
          .wb_addr(c_cam_wb_addr),.wb_wdata(c_cam_wb_wdata),.wb_write(c_cam_wb_write),.wb_stb(c_cam_wb_stb),
          .wb_rdata(c_cam_wb_rdata),.wb_ack(c_cam_wb_ack));
        video_diag_apb u_video_diag(.cpu_clk(mipi_tx_feedback100),.core_clk(core_clk),.pixel_clk(hdmi_tx_slow_clk),.arst(c_reset||!vid_rst_n),
            .core_data({16'd0,copy_in_error,rgbx_ddr_error,weights_boot_failed,live_nn_display_fault,live_nn_fault,
                video_shown_total,video_new_total,video_nn_total,copy_in_dropped_count,rgbx_ddr_abort_count,rgbx_ddr_commit_count,video_uptime_ms}),
            .pixel_data({video_frame_quality,2'd0,camera_capture_fps,live_nn_new_fps,video_hdmi_hz,
                video_bad_row,video_underflows,rgbx_ddr_skipped_frames_pixel,rgbx640_frame_count}),
            .PADDR(c_addr),.PSEL(c_sel&&video_sel),.PENABLE(c_enable),.PWRITE(c_write),.PRDATA(video_data),.PREADY(video_ready),.PSLVERROR(video_error));
        c_nn_snapshot_apb #(.CORE_HZ(160000000),.MEASURE_SWITCH(1),.ENABLE_ROI(1),.FRAME_READBACK(1),.SAME_CLOCK(0)) u_c_nn_bridge(.src_clk(core_clk),.dst_clk(mipi_tx_feedback100),
            .snapshot_lock(snapshot_locked),.capture_allowed(c_capture_allowed),.display_model_id(live_nn_display_style),.display_shown(live_nn_shown),
            .arst(c_reset),.deployment_started(c_deployment_started),.diagnostic_state(c_diag_state),.diagnostic_axi(c_diag_axi),
            .nn_pass(live_nn_pass),.nn_fail(live_nn_fail),
            .input_request_valid(copy_in_req_valid),.scheduler_req_ready(c_scheduler_req_ready),
            .scheduler_idle(style_inference_idle&&!image_pause),.input_frame_id(copy_in_req_frame_id),
            .platform_config(c_platform_config),.admit_enable(c_admit_enable),.control_irq(c_control_irq),.PWDATA(c_wdata),
            .status({(style_inference_idle&&!image_pause),live_nn_display_fault,live_nn_scheduler_fault,
                     live_nn_fail,live_nn_pass,live_nn_done,live_nn_busy,weights_boot_failed,
                     weights_boot_ready,cal_done}),
            .boot_fault(weights_boot_fault),.compute_fault(live_nn_compute_fault),
            .active_model(style_active),.requested_model(style_requested),
            .input_base(live_nn_input_base),.output_base(live_nn_output_base),
            .display_frame_id(live_nn_display_frame_id),.nn_start(live_nn_start),.nn_done(live_nn_done),
            .PADDR(c_addr),.PSEL(c_sel&&nn_sel),.PENABLE(c_enable),.PWRITE(c_write),
            .PRDATA(nn_data),.PREADY(nn_ready),.PSLVERROR(nn_error));

        endmodule
