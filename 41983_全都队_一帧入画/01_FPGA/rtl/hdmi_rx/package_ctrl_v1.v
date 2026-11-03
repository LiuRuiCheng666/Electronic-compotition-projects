module package_ctrl_v1(
input			clk,
input	[9:0]	i_gdata,
input   [9:0]   i_rdata,
input   [9:0]   i_bdata,
output wire ctrl_time,
output wire data_island ,

output reg [3:0] aux_ch0_o = 'd0,
output reg [3:0] aux_ch1_o = 'd0,
output reg [3:0] aux_ch2_o = 'd0,
output reg hs,
output reg vs
);

//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/

//parameter define 	
parameter CTRLTOKEN0 = 10'b1101010100;//354
parameter CTRLTOKEN1 = 10'b0010101011;//0ab
parameter CTRLTOKEN2 = 10'b0101010100;//154
parameter CTRLTOKEN3 = 10'b1010101011;//2ab

localparam S_IDLE                   = 3'd0;
localparam S_SYNC_CODE              = 3'd1;
localparam S_CTRL_PREAMBLE          = 3'd2;
localparam S_DATA_ISLAND_LEAD_GUARD = 3'd3;
localparam S_DATA_ISLAND            = 3'd4;
localparam S_VID_LEAD_GUARD         = 3'd5;
localparam S_VID_DATA               = 3'd6;
reg [2:0] cnt = 'd0;

//reg define 
reg             b_video_guard_band = 1'b0;
// reg             g_video_guard_band = 1'b0;
reg             r_video_guard_band = 1'b0;
reg             g_preamble_video   = 1'b0;
reg             r_premable_video   = 1'b0;
reg             r_premable_island  = 1'b0;
reg             g_island_guard_band= 1'b0;
// reg             b_island_guard_band= 1'b0;
reg             r_island_guard_band= 1'b0;

reg CTL01_flag0 = 'd0;
reg CTL01_flag1 = 'd0;
reg CTL01_flag2 = 'd0;
reg CTL01_flag3 = 'd0;
reg CTL23_flag0 = 'd0;
reg CTL23_flag1 = 'd0;
reg CTL23_flag2 = 'd0;
reg CTL23_flag3 = 'd0;
wire g_ctl;
wire r_ctl;
reg [2:0] pre_state = S_IDLE;
reg [2:0] nx_state = S_IDLE;
reg ctl_r = 'd0;
reg data_island_premable ;
// reg video_guard_band_r;
reg island_guard_band_r ;
reg [3:0] aux_ch0 = 'd0;
reg [3:0] aux_ch1 = 'd0;
reg [3:0] aux_ch2 = 'd0;
reg control_period = 1'b0;
reg data_island_period = 1'b0;
wire video_guard_band ;
wire island_guard_band;
wire		ctl;
always @( posedge clk )
begin
			CTL01_flag0 <= (i_gdata ==  CTRLTOKEN0 );                                                      
			CTL01_flag1 <= (i_gdata ==  CTRLTOKEN1 );                                                          
			CTL01_flag2 <= (i_gdata ==  CTRLTOKEN2 );                                                      
			CTL01_flag3 <= (i_gdata ==  CTRLTOKEN3 );
end  
assign g_ctl = CTL01_flag0 | CTL01_flag1 | CTL01_flag2 | CTL01_flag3;
always @( posedge clk )
begin
			CTL23_flag0 <= (i_rdata ==  CTRLTOKEN0 );  //视频前导码                                                    
			CTL23_flag1 <= (i_rdata ==  CTRLTOKEN1 );  //data island preamble                                                   
			CTL23_flag2 <= (i_rdata ==  CTRLTOKEN2 );                                                      
			CTL23_flag3 <= (i_rdata ==  CTRLTOKEN3 );
end  
assign r_ctl = CTL23_flag0 | CTL23_flag1 | CTL23_flag2 | CTL23_flag3;
assign ctl = g_ctl & r_ctl;
always @( posedge clk )
begin
    ctl_r <= ctl ;
    data_island_premable <= CTL23_flag1 & CTL01_flag1;//数据岛前导码位置
end
wire pos_ctl = {ctl_r,ctl} == 2'b01;
wire neg_ctl = {ctl_r,ctl} == 2'b10;
wire neg_data_island_premable = {data_island_premable,CTL23_flag1} == 2'b10;

assign ctrl_time = control_period | data_island_period;
always @( posedge clk )
begin
    b_video_guard_band <= i_bdata == 10'h2cc;
    // g_video_guard_band <= i_gdata == 10'h133;
    r_video_guard_band <= i_rdata == 10'h2cc;

    g_preamble_video   <= i_gdata == 10'h0ab;
    r_premable_video   <= i_rdata == 10'h354;

    // g_premable_island <= i_gdata == 10'h0ab;
    r_premable_island <= i_rdata == 10'h0ab;
    
    // b_island_guard_band   <= (i_bdata == 10'h28e) || (i_bdata == 10'h271) || (i_bdata == 10'h163) || (i_bdata == 10'h2c3);
    g_island_guard_band   <= i_gdata == 10'h133;
    r_island_guard_band   <= i_rdata == 10'h133;
end 
assign video_guard_band   = b_video_guard_band & r_video_guard_band & g_island_guard_band;
assign island_guard_band  = r_island_guard_band & g_island_guard_band;
always @( posedge clk )
begin
    // video_guard_band_r <= video_guard_band;
    island_guard_band_r <= island_guard_band;
end

assign data_island = data_island_period;

// wire neg_video_guard_band = {video_guard_band_r,video_guard_band} == 2'b01;
//======================================================================================== 
//
//========================================================================================

always @( posedge clk )
begin
    pre_state <= nx_state;
end

always@(*)
begin
    case( pre_state )
    S_IDLE : begin//0
        nx_state = pos_ctl ? S_SYNC_CODE : S_IDLE;
    end
    S_SYNC_CODE : begin//1
        nx_state = (cnt[2] & ctl_r) ? S_CTRL_PREAMBLE : S_SYNC_CODE;
    end
    S_CTRL_PREAMBLE : begin //前导码  2
        if(neg_data_island_premable )
            nx_state = S_DATA_ISLAND_LEAD_GUARD ;
        else if(neg_ctl)
            nx_state = S_VID_LEAD_GUARD;
        else if( pos_ctl )
            nx_state = S_SYNC_CODE;
        else 
            nx_state = S_CTRL_PREAMBLE;
    end        
    S_DATA_ISLAND_LEAD_GUARD : begin//3
        nx_state = island_guard_band ? S_DATA_ISLAND_LEAD_GUARD : S_DATA_ISLAND;
    end
    S_DATA_ISLAND : begin//4
        if( pos_ctl )
            nx_state = S_SYNC_CODE;
        else 
            nx_state = island_guard_band ? S_IDLE : S_DATA_ISLAND;
    end
    S_VID_LEAD_GUARD : begin//5
        nx_state = video_guard_band ? S_VID_LEAD_GUARD : S_VID_DATA;
    end
    S_VID_DATA : begin//6
        nx_state = pos_ctl ? S_SYNC_CODE : S_VID_DATA;
    end
    default:  nx_state = S_IDLE;
    endcase
end

always @( posedge clk )
begin
    control_period <= 1'b0;
    case( nx_state )
    S_IDLE : begin
        control_period <= 1'b1;
        cnt <= 'd0;
        data_island_period <= 1'b0;
    end
    S_SYNC_CODE : begin //1
        cnt <= cnt[2] ? cnt :cnt + 1'b1;
        control_period <= 1'b1;
        data_island_period <= 1'b0;
    end
    S_CTRL_PREAMBLE : begin
        control_period <= 1'b1;
        cnt <= 'd0;
        data_island_period <= 1'b0;
    end
    S_DATA_ISLAND_LEAD_GUARD : begin
        control_period <= 1'b1;
        data_island_period <= 1'b0;
    end
    S_DATA_ISLAND: begin
        control_period <= 1'b0;
        data_island_period <= 1'b1;
    end
    S_VID_LEAD_GUARD : begin
        control_period <= 1'b1;
        data_island_period <= 1'b0;
    end
    S_VID_DATA : begin
        control_period <= 1'b0;
        data_island_period <= 1'b0;
    end
    default:;
    endcase
end

always @( posedge clk )
begin
case (i_bdata)
    10'b1010011100 : aux_ch0 <= 4'b0000; //29c
    10'b1001100011 : aux_ch0 <= 4'b0001; //263
    10'b1011100100 : aux_ch0 <= 4'b0010; //2e4
    10'b1011100010 : aux_ch0 <= 4'b0011; //2e2
    10'b0101110001 : aux_ch0 <= 4'b0100; //171
    10'b0100011110 : aux_ch0 <= 4'b0101; //11e
    10'b0110001110 : aux_ch0 <= 4'b0110; //30e
    10'b0100111100 : aux_ch0 <= 4'b0111; //13c
    10'b1011001100 : aux_ch0 <= 4'b1000; //2cc
    10'b0100111001 : aux_ch0 <= 4'b1001; //139
    10'b0110011100 : aux_ch0 <= 4'b1010; //19c
    10'b1011000110 : aux_ch0 <= 4'b1011; //2c6
    10'b1010001110 : aux_ch0 <= 4'b1100; //28e
    10'b1001110001 : aux_ch0 <= 4'b1101; //271
    10'b0101100011 : aux_ch0 <= 4'b1110; //163
    10'b1011000011 : aux_ch0 <= 4'b1111; //2c3
    default        : aux_ch0 <= 'd0;
    endcase
end

always @( posedge clk )
begin
case (i_gdata)
    10'b1010011100 : aux_ch1 <= 4'b0000; //29c
    10'b1001100011 : aux_ch1 <= 4'b0001; //263
    10'b1011100100 : aux_ch1 <= 4'b0010; //2e4
    10'b1011100010 : aux_ch1 <= 4'b0011; //2e2
    10'b0101110001 : aux_ch1 <= 4'b0100; //171
    10'b0100011110 : aux_ch1 <= 4'b0101; //11e
    10'b0110001110 : aux_ch1 <= 4'b0110; 
    10'b0100111100 : aux_ch1 <= 4'b0111; 
    10'b1011001100 : aux_ch1 <= 4'b1000; //2cc
    10'b0100111001 : aux_ch1 <= 4'b1001; 
    10'b0110011100 : aux_ch1 <= 4'b1010; //19c
    10'b1011000110 : aux_ch1 <= 4'b1011; 
    10'b1010001110 : aux_ch1 <= 4'b1100; //28e
    10'b1001110001 : aux_ch1 <= 4'b1101; //271
    10'b0101100011 : aux_ch1 <= 4'b1110; //163
    10'b1011000011 : aux_ch1 <= 4'b1111; //2c3
    default        : aux_ch1 <= 'd0;
    endcase
end
always @( posedge clk )
begin
case (i_rdata )
    10'b1010011100 : aux_ch2 <= 4'b0000; //29c
    10'b1001100011 : aux_ch2 <= 4'b0001; //263
    10'b1011100100 : aux_ch2 <= 4'b0010; //2e4
    10'b1011100010 : aux_ch2 <= 4'b0011; //2e2
    10'b0101110001 : aux_ch2 <= 4'b0100; //171
    10'b0100011110 : aux_ch2 <= 4'b0101; //11e
    10'b0110001110 : aux_ch2 <= 4'b0110; 
    10'b0100111100 : aux_ch2 <= 4'b0111; 
    10'b1011001100 : aux_ch2 <= 4'b1000; //2cc
    10'b0100111001 : aux_ch2 <= 4'b1001; 
    10'b0110011100 : aux_ch2 <= 4'b1010; //19c
    10'b1011000110 : aux_ch2 <= 4'b1011; 
    10'b1010001110 : aux_ch2 <= 4'b1100; //28e
    10'b1001110001 : aux_ch2 <= 4'b1101; //271
    10'b0101100011 : aux_ch2 <= 4'b1110; //163
    10'b1011000011 : aux_ch2 <= 4'b1111; //2c3
    default        : aux_ch2 <= 'd0;
    endcase
end

always @( posedge clk )
begin
    aux_ch0_o <= aux_ch0;
    aux_ch1_o <= aux_ch1;
    aux_ch2_o <= aux_ch2;
end
reg [9:0] bdata_r0,bdata_r1;

always @( posedge clk )
begin
    bdata_r0 <= i_bdata;
    bdata_r1 <= bdata_r0;
end

always @( posedge clk )
begin
    if( ctrl_time ) begin
            if( island_guard_band_r | data_island_period ) begin //video_guard_band |
                hs <= aux_ch0_o[0];
                vs <= aux_ch0_o[1];
            end else begin
                case (bdata_r1)                                                                   
                    CTRLTOKEN0: begin                                                                 
                        hs <=#1 1'b0;                                                                  
                        vs <=#1 1'b0;                                                                  
                    end                                                                               
                    CTRLTOKEN1: begin                                                                 
                        hs <=#1 1'b1;                                                                  
                        vs <=#1 1'b0;                                                                  
                    end                                                                               
                    CTRLTOKEN2: begin                                                                 
                        hs <=#1 1'b0;                                                                  
                        vs <=#1 1'b1;                                                                  
                    end                                                                               
                    CTRLTOKEN3: begin                                                                 
                        hs <=#1 1'b1;                                                                  
                        vs <=#1 1'b1;                                                                  
                    end                                                                                                                                                                
                    default: begin                                                                    
                                                                                    
                    end                                                                              
                endcase       
            end
    end 

end

endmodule

//Encryption end
