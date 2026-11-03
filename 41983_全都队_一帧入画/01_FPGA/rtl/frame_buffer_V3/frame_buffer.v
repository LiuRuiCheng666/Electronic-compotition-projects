//2026.8.17：V3: 
//（1）使用了通用串并转换模块，理论上可以支持任意位宽的串并，并串转换。

`timescale 1ps/1ps
module frame_buffer #(
parameter I_VID_WIDTH = 16,
parameter O_VID_WIDTH = 16,
parameter AXI_DATA_WIDTH	= 512,
parameter AXI_ADDR_WIDTH 	= 33,
parameter	WR_FIFO_DEPTH		= 1024,    
parameter	RD_FIFO_DEPTH 	= 1024,
parameter START_ADDR			=	33'h000201900,
parameter BURST_LEN       = 8'd15,
parameter FB_NUM			    = 	3,//2 buffer ,3 buffer 
parameter MAX_VID_WIDTH		=	1920 ,//video width 
parameter MAX_VID_HIGHT		=	1080 ,//wideo height
parameter AXI_STRB_WIDTH 	= AXI_DATA_WIDTH/8
) (

input 												axi_clk,
input 												rst_n,
input [1:0] bresp,
input	wire								i_clk	,
input	wire								i_vs, //active hgih
input	wire								i_de, //active high
input	wire	[I_VID_WIDTH-1:0] 			vin ,

input	wire								  o_clk	,
output	wire								o_hs , //active high
output	wire								o_vs , //active hgih
output	wire								o_de , //active high
output	wire	[O_VID_WIDTH-1:0] 			vout ,

input	wire 	[12:0]									H_FRONT_PORCH 	,
input	wire 	[12:0]									H_SYNC 			,
input	wire 	[12:0]									H_VALID 		,
input	wire 	[12:0]									H_BACK_PORCH 	,
input	wire 	[12:0]									V_FRONT_PORCH 	,
input	wire 	[12:0]									V_SYNC 			,
input	wire 	[12:0]									V_VALID 		,
input	wire 	[12:0]									V_BACK_PORCH 	,


output 	[5:0] 								awid,
output  [AXI_ADDR_WIDTH-1:0] 	awaddr,
output  [7:0] 								awlen,
output  [2:0] 								awsize,
output  [1:0] 								awburst,
output  [3:0] 								awcache,
output [2:0]                    awprot,
output  									    awlock,
output  									    awvalid,
output  									    awcobuf,
output  									    awapcmd,
output  									    awallstrb,
output  									    awqos,
input 										    awready,

output [5:0] 									arid,
output  [AXI_ADDR_WIDTH-1:0] 	                araddr,
output  [7:0] 								    arlen,
output  [2:0] 								    arsize,
output  [1:0] 								    arburst,
output  									    arlock,
output  									    arvalid,
output  									    arapcmd,
output 										    arqos,
input 										    arready,
output  [3:0] 									arcache,
output [2:0]                    arprot,

output  [AXI_DATA_WIDTH-1:0] 	wdata,  
output  [AXI_STRB_WIDTH-1:0] 	wstrb,
output  											wlast,
output  											wvalid,
input 												wready,

input [5:0] 									    rid,
input [AXI_DATA_WIDTH-1:0] 		rdata,
input 												rlast,
input 												rvalid,
output  											rready,
input [1:0] 									    rresp,

input [5:0] 									    bid,
input 												bvalid,
output  											bready,
output			[31:0]								test_rd_fifo_rddata,   
output	[31:0]								        test_wdata,
output	[31:0]								        test_rdata,
output wire o_capture_commit,
output reg [31:0] o_frame_id,
output reg o_frame_valid,
output reg [1:0] o_frame_bank,
output reg [31:0] o_frame_addr,
output reg o_frame_latch,
output wire o_frame_meta_error,
output wire read_urgent,
output wire read_critical,
output [7:0] test_BURST_LEN
);
assign test_BURST_LEN = BURST_LEN;
//=============================================================
//parameter define                                                  
//============================================================= 
wire [31:0]               ddr_frame_len ;
wire [AXI_DATA_WIDTH-1:0] wr_fifo_wrdata;

wire                      rd_fifo_rdvalid	;
wire [AXI_DATA_WIDTH-1:0] rd_fifo_rddata	 ; 
wire                      rd_fifo_rdempty	;
wire                      rd_fifo_rden     ;

wire                      fifo_rd_period;

reg [12:0] h_front_porch  = 13'd100; 
reg [12:0] h_sync 	 		= 13'd100; 
reg [12:0] h_valid 	 	 	= 13'd100; 
reg [12:0] h_back_porch = 13'd100; 
reg [12:0] v_front_porch  = 13'd100; 
reg [12:0] v_sync 	 		= 13'd100; 
reg [12:0] v_valid 	 	  = 13'd100; 
reg [12:0] v_back_porch = 13'd100; 

wire		wr_sw_ack ;
wire		wr_sw 		;
wire		rd_sw			;
wire		rd_sw_ack ;

//=============================================================  
//RTL                                                     
//=============================================================  
wire wr_clk_rst_n;
wire axi_clk_rst_n;
wire rd_clk_rst_n;
rst_n_piple #(                       
	.DLY ( 3 )                        
)	u_i_clk_rst_pip(                                          
/*i*/.clk			(i_clk),                        
/*i*/.rst_n_i	(rst_n),                    
/*o*/.rst_n_o (wr_clk_rst_n)            
);

  rst_n_piple #(                       
	.DLY ( 3 )                        
)	u_axi_rst_pip(                                          
/*i*/.clk			(axi_clk),                        
/*i*/.rst_n_i	(rst_n),                    
/*o*/.rst_n_o (axi_clk_rst_n)            
);

  rst_n_piple #(                       
	.DLY ( 3 )                        
)	u_o_clk_rst_pip(                                          
/*i*/.clk			(o_clk),                        
/*i*/.rst_n_i	(rst_n),                    
/*o*/.rst_n_o (rd_clk_rst_n)            
);


wire                      wr_fifo_wren;
wire                      frame_start;
wire                      frame_stable;



vid_rx_align_v1 #(
	.I_VID_WIDTH   (I_VID_WIDTH		),
	.AXI_DDR_WIDTH (AXI_DATA_WIDTH )
)u_vid_rx_align(
/*i*/.clk			    (i_clk			),  
/*i*/.rst_n			  (wr_clk_rst_n	),
/*i*/.i_vs			  (i_vs			), //active hgih
/*i*/.i_de			  (i_de			), //active high
/*i*/.vin			    (vin			),
/*o*/.fifo_wr_en	  (wr_fifo_wren		),
/*o*/.fifo_wr_data	(wr_fifo_wrdata	),
/*o*/.frame_start	  (frame_start	),
/*O*/.fifo_rst_p		  (fifo_rst		  ),
/*O*/.frame_stable  (frame_stable ),
/*O*/.ddr_frame_len (ddr_frame_len)
);


reg fifo_rd_period_r0 = 'd0;
reg fifo_rd_period_r1 = 'd0;
reg fifo_rd_period_r2 = 'd0;
always @( posedge axi_clk)
begin
  fifo_rd_period_r0 <= fifo_rd_period;
  fifo_rd_period_r1 <= fifo_rd_period_r0;
  fifo_rd_period_r2 <= fifo_rd_period_r1; 
end
wire neg_rd_period = {fifo_rd_period_r2,fifo_rd_period_r1} == 2'b10;
// The AXI descriptor describes the address actually latched by the reader.
wire [31:0] read_frame_id, read_frame_addr;
wire read_frame_valid, read_frame_latch;
wire [1:0] read_frame_bank;
wire descriptor_pulse, descriptor_busy, descriptor_overrun;
wire [66:0] descriptor_data;
raw_frame_descriptor_cdc u_raw_descriptor_cdc (
    .src_clk(axi_clk), .dst_clk(o_clk), .rst_n(rst_n),
    .src_pulse(read_frame_latch),
    .src_data({read_frame_addr, read_frame_bank,
               read_frame_valid, read_frame_id}),
    .src_busy(descriptor_busy), .src_overrun(descriptor_overrun),
    .dst_pulse(descriptor_pulse), .dst_data(descriptor_data)
);

reg fifo_rd_period_previous;
reg frame_pixel_seen;
reg descriptor_pending;
reg [66:0] pending_descriptor;
(* async_reg = "true" *) reg [1:0] overrun_sync;
reg video_meta_error;
assign o_frame_meta_error = video_meta_error | overrun_sync[1];
wire output_read_start = fifo_rd_period && !fifo_rd_period_previous;

// Bind metadata at the first active RAW pixel, then hold it through all lines.
always @(posedge o_clk or negedge rst_n) begin
    if (!rst_n) begin
        fifo_rd_period_previous <= 1'b0;
        frame_pixel_seen <= 1'b0;
        descriptor_pending <= 1'b0;
        pending_descriptor <= 67'd0;
        overrun_sync <= 2'b00;
        video_meta_error <= 1'b0;
        o_frame_id <= 32'd0;
        o_frame_valid <= 1'b0;
        o_frame_bank <= 2'd0;
        o_frame_addr <= 32'd0;
        o_frame_latch <= 1'b0;
    end else begin
        fifo_rd_period_previous <= fifo_rd_period;
        overrun_sync <= {overrun_sync[0], descriptor_overrun};
        o_frame_latch <= 1'b0;
        if (output_read_start) begin
            frame_pixel_seen <= 1'b0;
            descriptor_pending <= 1'b0;
            o_frame_valid <= 1'b0;
        end
        if (descriptor_pulse) begin
            pending_descriptor <= descriptor_data;
            descriptor_pending <= 1'b1;
            if (frame_pixel_seen && !output_read_start)
                video_meta_error <= 1'b1;
        end
        if (o_de && !frame_pixel_seen && !output_read_start) begin
            frame_pixel_seen <= 1'b1;
            descriptor_pending <= 1'b0;
            o_frame_latch <= 1'b1;
            if (descriptor_pulse || descriptor_pending) begin
                {o_frame_addr, o_frame_bank, o_frame_valid, o_frame_id}
                    <= descriptor_pulse ? descriptor_data : pending_descriptor;
            end else begin
                o_frame_valid <= 1'b0;
                video_meta_error <= 1'b1;
            end
        end
    end
end

ddr_buffer #(
.AXI_DATA_WIDTH ( AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	( WR_FIFO_DEPTH		),    
.RD_FIFO_DEPTH 	( RD_FIFO_DEPTH 	),
.START_ADDR			( START_ADDR      ),
.I_VID_WIDTH    ( I_VID_WIDTH     ),
.BURST_LEN      (BURST_LEN        )
)u_ddr_buffer(
    .read_urgent(read_urgent),
    .read_critical(read_critical),
.capture_commit(o_capture_commit),
    .read_frame_id(read_frame_id),
    .read_frame_valid(read_frame_valid),
    .read_frame_bank(read_frame_bank),
    .read_frame_addr(read_frame_addr),
    .read_frame_latch(read_frame_latch),
    .axi_clk		    (axi_clk	),
    .wr_clk_rst_n (wr_clk_rst_n),
    .axi_clk_rst_n(axi_clk_rst_n),
    .rd_clk_rst_n (rd_clk_rst_n),
    .bresp (bresp),
/*i*/.rd_start	      (fifo_rd_period),
/*i*/.wr_start	      (frame_start & frame_stable),
    .wr_busrt_len     (ddr_frame_len ),//ddr address scope for one frame
    .rd_burst_len     (ddr_frame_len ),//ddr address scope for one frame

	   .test_cnt				(test_cnt),
/*i*/.wr_fifo_wrclk		(i_clk					),
/*i*/.wr_fifo_rst_p   ( fifo_rst        ),
/*i*/.wr_fifo_wren		(wr_fifo_wren		  ),
/*o*/.wr_fifo_wrfull	(wr_fifo_wrfull	  ),
/*i*/.wr_fifo_wrdata	(wr_fifo_wrdata	  ), 

/*i*/.rd_fifo_rdclk		(o_clk					  ),
/*i*/.rd_fifo_rst_p   (neg_rd_period    ),
/*o*/.rd_fifo_rdvalid	(rd_fifo_rdvalid	),
/*o*/.rd_fifo_rddata	(rd_fifo_rddata	  ),
/*o*/.rd_fifo_rdempty	(rd_fifo_rdempty	),
/*i*/.rd_fifo_rden		(rd_fifo_rden     ),

/*o*/.test_wdata(test_wdata ),
/*o*/.test_rdata(test_rdata ),    
    .awid			  ( awid			),
    .awaddr			( awaddr		),
    .awlen			( awlen			),
    .awsize			( awsize		),
    .awburst		( awburst		),
    .awvalid		( awvalid		),
    .awready		( awready		),
    .awqos			( awqos			),
    .awcache    ( awcache   ),
    .awprot     ( awprot    ),

    .arid			  ( arid			),
    .araddr			( araddr		),
    .arlen			( arlen			),
    .arsize			( arsize		),
    .arburst		( arburst		),
    .arlock			( arlock		),
    .arvalid		( arvalid		),
    .arapcmd		( arapcmd		),
    .arready		( arready		),
    .arqos			( arqos			),
    .arprot     (arprot     ),
    .arcache    (arcache    ),
    //
    .wdata			( wdata			),
    .wstrb			( wstrb			),
    .wlast			( wlast			),
    .wvalid			( wvalid		),
    .wready			( wready		),
    //
    .rid			  ( rid			  ),
    .rdata			( rdata			),
    .rlast			( rlast			),
    .rvalid			( rvalid		),
    .rready			( rready		),
    .rresp			( rresp			),
    .bid			  ( bid			  ),
    .bvalid			( bvalid		),
    .bready			( bready		));

//===================================================================================
//
//===================================================================================


wire tx_valid;
wire [23:0] tx_vin;
    par2ser_parse#(
      .VID_WIDTH 				( O_VID_WIDTH  ),
      .AXI_DATA_WIDTH   (AXI_DATA_WIDTH)
      
    )u_par2ser_parse(
    /*i*/.clk               (o_clk),
    /*i*/.rst_n             (rd_clk_rst_n),
    /*i*/.frame_period      (	fifo_rd_period),
    /*i*/.ddr_frame_len     (ddr_frame_len),
    /*i*/.rd_fifo_rdvalid   (rd_fifo_rdvalid  ),
    /*i*/.rd_fifo_rddata    (rd_fifo_rddata		),
    /*i*/.rd_fifo_rdempty   (rd_fifo_rdempty ),
    /*o*/.rd_fifo_rden      (rd_fifo_rden     ),

    /*o*/.tx_fifo_wrdata     (tx_vin),
    /*o*/.tx_fifo_valid    (tx_valid),
    /*I*/.tx_fifo_full    (tx_almost_full)
);

    



always @( posedge o_clk )
begin
    h_front_porch   <=  H_FRONT_PORCH ;
    h_sync 	 		    <=  H_SYNC 			  ;
    h_valid 	 	    <=  H_VALID 		  ;
    h_back_porch    <=  H_BACK_PORCH 	;
    v_front_porch   <=  V_FRONT_PORCH ;
    v_sync 	 		    <=  V_SYNC 			  ;
    v_valid 	 	    <=  V_VALID 		  ;
    v_back_porch    <=  V_BACK_PORCH 	;
end

reg rd_frame_en_r0 = 'd0;
reg rd_frame_en_r1 = 'd0;
always @( posedge o_clk or negedge rd_clk_rst_n )
begin
    if( !rd_clk_rst_n ) begin
      rd_frame_en_r0 <= 1'b0;
      rd_frame_en_r1 <= 1'b0;
    end else begin
      rd_frame_en_r0 <= frame_stable;
      rd_frame_en_r1 <= rd_frame_en_r0;
    end
end

data_tx #(
	.VID_WIDTH 				( O_VID_WIDTH  ),
	.FIFO_DIPTH  			( 1024 				 ),
	.FIFO_ALMOST_FULL	( 960          )
	
	
	)u_data_tx(
	/*i*/.clk					  (o_clk				),
	/*i*/.rst_n				  (rd_clk_rst_n	),
	/*i*/.H_FRONT_PORCH (h_front_porch),//( 50 			),
	/*i*/.H_SYNC 	 		  (h_sync 	 		),//( 50 			),
	/*i*/.H_VALID 	 	  (h_valid 	 	  ),//( 48 			),
	/*i*/.H_BACK_PORCH  (h_back_porch ),//( 50 			),
	/*i*/.V_FRONT_PORCH (v_front_porch),//( 5 			),
	/*i*/.V_SYNC 	 		  (v_sync 	 		),//( 5 			),
	/*i*/.V_VALID 	 	  (v_valid 	 	  ),//( 20 			),
	/*i*/.V_BACK_PORCH  (v_back_porch ),//( 5 			),
	/*i*/.frame_en		  (rd_frame_en_r1),//(  	frame_stable		),//(tx_frame_en	),
	/*i*/.fifo_wr_data  (tx_vin				),
	/*i*/.fifo_wr_en	  (tx_valid			),
	/*o*/.fifo_wr_almost_full	(tx_almost_full	),
	/*o*/.fifo_rd_period(fifo_rd_period),
	/*o*/.vout		(vout		),
	/*o*/.o_hs		(o_hs		),
	/*o*/.o_vs		(o_vs		),
	/*o*/.o_de		(o_de		)
	
	);


/*----------------------------------------------------------------------------------*\
                                 The function code
\*----------------------------------------------------------------------------------*/
function integer clogb2;
input [31:0] value;
begin
value = value - 1;
for (clogb2 = 0; value > 0; clogb2 = clogb2 + 1)
value = value >> 1;
end
endfunction


endmodule
// Bundled-data mailbox: payload stays fixed until the receiver acknowledges it.
// Both domains share this reset; independent one-sided resets are unsupported.
module raw_frame_descriptor_cdc (
    input src_clk, input dst_clk, input rst_n,
    input src_pulse, input [66:0] src_data,
    output src_busy, output reg src_overrun,
    output reg dst_pulse, output reg [66:0] dst_data
);
reg [66:0] payload;
reg request_toggle, acknowledge_toggle;
(* async_reg = "true" *) reg [1:0] ack_sync;
(* async_reg = "true" *) reg [1:0] req_sync;
assign src_busy = request_toggle != ack_sync[1];
always @(posedge src_clk or negedge rst_n) begin
    if (!rst_n) begin
        payload <= 67'd0;
        request_toggle <= 1'b0;
        ack_sync <= 2'b00;
        src_overrun <= 1'b0;
    end else begin
        ack_sync <= {ack_sync[0], acknowledge_toggle};
        if (src_pulse) begin
            if (!src_busy) begin
                payload <= src_data;
                request_toggle <= ~request_toggle;
            end else
                src_overrun <= 1'b1;
        end
    end
end
always @(posedge dst_clk or negedge rst_n) begin
    if (!rst_n) begin
        req_sync <= 2'b00;
        acknowledge_toggle <= 1'b0;
        dst_pulse <= 1'b0;
        dst_data <= 67'd0;
    end else begin
        req_sync <= {req_sync[0], request_toggle};
        dst_pulse <= 1'b0;
        if (req_sync[1] != acknowledge_toggle) begin
            dst_data <= payload;
            dst_pulse <= 1'b1;
            acknowledge_toggle <= req_sync[1];
        end
    end
end
endmodule
