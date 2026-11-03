`timescale 1ns / 1ps


module dvi_decoder #(parameter DVI_MODE=0) (
  input  wire         pclk,           // regenerated pixel clock
  input  wire [9:0]   bdata,		// Blue data in
  input  wire [9:0]   gdata,		// Green data in
  input  wire [9:0]   rdata,		// Red data in
  input  wire         pll_lock,        // external reset input, e.g. reset button
  output wire          pll_rst_n,          // rx reset
  output reg         hsync,          // hsync data
  output reg         vsync,          // vsync data
  output reg         de,             // data enable  
  output reg [7:0]   red,      // pixel data out
  output reg [7:0]   green,    // pixel data out
  output reg [7:0]   blue,      // pixel data out  

  output wire         DLY_INC,
  output wire         DLY_RST,
  output wire         DLY_ENA,

  output wire [23:0]  audio_L ,
  output wire [23:0]  audio_R ,
  output wire         audio_valid ,
  output wire         audio_param_valid ,
  output wire         audio_max_word_length,     
  output wire [2:0]   audio_stae,          
  output wire [3:0]   audio_ch,            
  output wire [3:0]   audio_samp_freq,     
  output wire [2:0]   audio_samp_word_len,
  
output wire [1:0]      avi_infoframe_S   ,
output wire [1:0]      avi_infoframe_B   ,
output wire            avi_infoframe_A   ,
output wire [1:0]      avi_infoframe_Y   ,
output wire [3:0]      avi_infoframe_R   ,
output wire [1:0]      avi_infoframe_M   ,
output wire [1:0]      avi_infoframe_C   ,
output wire [1:0]      avi_infoframe_SC  ,
output wire [1:0]      avi_infoframe_Q   ,
output wire [2:0]      avi_infoframe_EC  ,
output wire            avi_infoframe_ITC ,
output wire [6:0]      avi_infoframe_VIC ,
output wire [3:0]      avi_infoframe_PR  ,
output wire [1:0]      avi_infoframe_CN  ,
output wire [1:0]      avi_infoframe_YQ  ,
output wire [15:0]     avi_infoframe_ETB ,
output wire [15:0]     avi_infoframe_SBB ,
output wire [15:0]     avi_infoframe_ELB ,
output wire [15:0]     avi_infoframe_SRB 
  
  );    

//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/

//wire define       
wire        de_b;
wire        de_g;
wire        de_r;
wire        blue_rdy;
wire        green_rdy;
wire        red_rdy;  
wire        b_align;
wire        g_align;
wire        r_align;  
wire [9:0]  rbond_data;
wire [9:0]  gbond_data;
wire [9:0]  bbond_data;
reg          reset;
wire        hsync1,hsync2;
wire   vsync1,vsync2;
wire r_align_fail;
wire g_align_fail;
wire b_align_fail;
wire cal_done;

wire b_sync_code;
wire r_sync_code;
wire g_sync_code;
wire re_channelbond;
wire re_algin_start;
wire align_success;
reg  all_align = 1'b0;

wire w_hsync; 
wire w_vsync; 
wire [7:0] w_red; 
wire [7:0] w_green; 
wire [7:0] w_blue; 
reg [12:0] rst_cnt = 'd0;
//*****************************************************
//**                    main code
//*****************************************************  
always @( posedge pclk or negedge pll_lock )
begin
  if( !pll_lock )
      rst_cnt <= 'd0;
  else 
      rst_cnt <= rst_cnt[12] ? rst_cnt : rst_cnt + 1'b1;
end


 wire rst_n = rst_cnt[12];
//=====================================================
//HDMI rx channel 0
//=====================================================
tmds_decoder #(.DVI_MODE(DVI_MODE)) u_tmds_decoder_0(

    .rst_n          (rst_n),
    .pixelclk       (pclk),
    .datain      		(bdata),
    .ctrl_time      (ctrl_time),
    .re_channelbond (re_channelbond),
    .re_algin_start (re_algin_start),
    .potherchrdy    ({red_rdy,green_rdy}),
    // .potherchvld    ({r_align&g_align}),   
    .all_align      (all_align), 
    .pmerdy         (blue_rdy),
    .paligned         (b_align),  
    .bond_data      (bbond_data), 
    .sync_code(b_sync_code),
       .pc0            (hsync2),
       .pc1            (vsync2),  
    .align_fail     (b_align_fail),
    .pvde           (de_b),
    .pdatain        (w_blue)      
);
//=====================================================
//HDMI rx channel 1
//=====================================================
tmds_decoder #(.DVI_MODE(DVI_MODE)) u_tmds_decoder_1(

    .rst_n          (rst_n),
    .pixelclk       (pclk),
    .datain      		(gdata),
    .ctrl_time      (ctrl_time),
    .re_channelbond (re_channelbond),
    .re_algin_start (re_algin_start),
    .potherchrdy    ({red_rdy,blue_rdy}),
    // .potherchvld    ({r_align&b_align}),    
    .all_align      (all_align),
    .pmerdy         (green_rdy),
    .paligned         (g_align),   
    .bond_data      (gbond_data), 
    .align_fail     (g_align_fail),
    .sync_code(g_sync_code),
    .pc0            (),
    .pc1            (),   
    .pvde           (de_g),
    .pdatain        (w_green)      
);


//=====================================================
//HDMI rx channel 2
//=====================================================
tmds_decoder #(.DVI_MODE(DVI_MODE)) u_tmds_decoder_2(

    .rst_n          (rst_n),
    .pixelclk       (pclk),
    .datain      		(rdata),
    .ctrl_time      (ctrl_time),
    .re_channelbond (re_channelbond),
    .re_algin_start (re_algin_start),
    .potherchrdy    ({blue_rdy,green_rdy}), 
    // .potherchvld    ({b_align&g_align}),  
    .all_align      (all_align),  
    .bond_data      (rbond_data), 
    .pmerdy         (red_rdy),
    .paligned       (r_align),  
    .align_fail     (r_align_fail),
    .sync_code      (r_sync_code),
    .pc0            (),
    .pc1            (),   
    .pvde           (de_r),
    .pdatain        (w_red)      
);

always @( posedge pclk )
begin
  all_align <= align_success;
end
wire sync_fail;
wire sync_pass;
wire de_sync_en;
assign align_success = r_align & g_align & b_align;
wire align_fail = r_align_fail | g_align_fail | b_align_fail;
lvds_dynamic_delay  lvds_dynamic_delay_inst (
    .clk(pclk),
    .rst_n(rst_n),
    .align_fail(align_fail),
    .align_success(align_success),
    .de_sync_check_en(de_sync_en),
    .de_sync_pass(sync_pass),
    .de_sync_fail(sync_fail),
    .DLY_INC(DLY_INC),
    .DLY_RST(DLY_RST),
    .DLY_ENA(DLY_ENA),
    .cal_done(cal_done),
    .re_algin_start(re_algin_start),
    .pll_rst_n(pll_rst_n)
  );

  de_sync  de_sync_inst (
    .clk(pclk),
    .rst_n(rst_n),
    .de_sync_en(de_sync_en ),
    .cal_done(cal_done),
    .i_de(de_b),
    .sync_fail(sync_fail),
    .sync_pass(sync_pass)
  );



  channelboad_ctrl  channelboad_ctrl_inst (
    .clk(pclk),
    .rst_n(rst_n),
    .align(align_success),
    .sync1(r_sync_code),
    .sync2(g_sync_code),
    .sync3(b_sync_code),
    .re_sync(re_channelbond)
  );

//=================================================================
//vide parase
//=================================================================
//8b/10b
wire data_island;
wire [3:0] aux_ch0;
wire [3:0] aux_ch1;
wire [3:0] aux_ch2;



      package_ctrl_v1 u_package_ctrl_v1(
	.clk                        (pclk                 ),
  .i_rdata                    (rbond_data           ),
  .i_gdata                    (gbond_data           ),
  .i_bdata                    (bbond_data           ),
  .data_island                (data_island          ),
  .ctrl_time                  (ctrl_time            ),
  .aux_ch0_o                  (aux_ch0              ),
  .aux_ch1_o                  (aux_ch1              ),
  .aux_ch2_o                  (aux_ch2              ),
  .hs                         (w_hsync                ),
  .vs                         (w_vsync                )
      );  
//================================================================
//8b/10b
    aux_parse  aux_parse_inst (
      .clk                        (pclk                 ),
      .aux_ch0                    (aux_ch0              ),
      .aux_ch1                    (aux_ch1              ),
      .aux_ch2                    (aux_ch2              ),
      .data_island                (data_island          ),
      .audio_L                    (audio_L              ),
      .audio_R                    (audio_R              ),
      .audio_valid                (audio_valid          ),
      .audio_param_valid          (audio_param_valid    ),
      .audio_max_word_length      (audio_max_word_length),     
      .audio_stae                 (audio_stae           ),          
      .audio_ch                   (audio_ch             ),            
      .audio_samp_freq            (audio_samp_freq      ),     
      .audio_samp_word_len        (audio_samp_word_len  ),
      .avi_infoframe_S            (avi_infoframe_S      ),
      .avi_infoframe_B            (avi_infoframe_B      ),
      .avi_infoframe_A            (avi_infoframe_A      ),
      .avi_infoframe_Y            (avi_infoframe_Y      ),
      .avi_infoframe_R            (avi_infoframe_R      ),
      .avi_infoframe_M            (avi_infoframe_M      ),
      .avi_infoframe_C            (avi_infoframe_C      ),
      .avi_infoframe_SC           (avi_infoframe_SC     ),
      .avi_infoframe_Q            (avi_infoframe_Q      ),
      .avi_infoframe_EC           (avi_infoframe_EC     ),
      .avi_infoframe_ITC          (avi_infoframe_ITC    ),
      .avi_infoframe_VIC          (avi_infoframe_VIC    ),
      .avi_infoframe_PR           (avi_infoframe_PR     ),
      .avi_infoframe_CN           (avi_infoframe_CN     ),
      .avi_infoframe_YQ           (avi_infoframe_YQ     ),
      .avi_infoframe_ETB          (avi_infoframe_ETB    ),
      .avi_infoframe_SBB          (avi_infoframe_SBB    ),
      .avi_infoframe_ELB          (avi_infoframe_ELB    ),
      .avi_infoframe_SRB          (avi_infoframe_SRB    )
    );

    always @( posedge pclk )
    begin
      hsync <= DVI_MODE ? hsync2 : w_hsync; 
      vsync <= DVI_MODE ? vsync2 : w_vsync; 
      de    <= de_b;    //assign de = ;
      red   <= w_red; 
      green <= w_green; 
      blue  <= w_blue; 
    end
    
endmodule

//Encryption end
