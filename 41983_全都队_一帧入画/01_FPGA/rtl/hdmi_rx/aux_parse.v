
module aux_parse #(
    parameter AUDIO_CHANNEL = 0// 0 :2channel ;1:8 channel
)(
input clk,
input [3:0] aux_ch0,
input [3:0] aux_ch1,
input [3:0] aux_ch2,
input           data_island,
output [255:0] audio_pkt,
output reg [23:0] audio_L = 'd0,
output reg [23:0] audio_R = 'd0,
output reg         audio_valid = 'd0,
output reg audio_param_valid = 'd0,
output reg audio_max_word_length,     
output reg [2:0] audio_stae,          
output reg [3:0] audio_ch,            
output reg [3:0] audio_samp_freq,     
output reg [2:0] audio_samp_word_len,
output reg [1:0]      avi_infoframe_S   = 'd0,
output reg [1:0]      avi_infoframe_B   = 'd0,
output reg            avi_infoframe_A   = 'd0,
output reg [1:0]      avi_infoframe_Y   = 'd0,
output reg [3:0]      avi_infoframe_R   = 'd0,
output reg [1:0]      avi_infoframe_M   = 'd0,
output reg [1:0]      avi_infoframe_C   = 'd0,
output reg [1:0]      avi_infoframe_SC  = 'd0,
output reg [1:0]      avi_infoframe_Q   = 'd0,
output reg [2:0]      avi_infoframe_EC  = 'd0,
output reg            avi_infoframe_ITC = 'd0,
output reg [6:0]      avi_infoframe_VIC = 'd0,
output reg [3:0]      avi_infoframe_PR  = 'd0,
output reg [1:0]      avi_infoframe_CN  = 'd0,
output reg [1:0]      avi_infoframe_YQ  = 'd0,
output reg [15:0]     avi_infoframe_ETB = 'd0,
output reg [15:0]     avi_infoframe_SBB = 'd0,
output reg [15:0]     avi_infoframe_ELB = 'd0,
output reg [15:0]     avi_infoframe_SRB = 'd0

);

//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/
reg [4:0] cnt = 'd0;
reg data_island_r = 'd0;
always @( posedge clk )
begin
    // data_island_r <= data_island;
    // if( data_island_r )
    if( data_island )
        cnt <= cnt + 1'b1;
    else  
        cnt <= 'd0;
end
reg [63:0] sub_pkt_data0 = 'd0;
reg [63:0] sub_pkt_data1 = 'd0;
reg [63:0] sub_pkt_data2 = 'd0;
reg [63:0] sub_pkt_data3 = 'd0;
reg [31:0] pkt_header    = 'd0;
always @( posedge clk )
begin
    sub_pkt_data0 <= {aux_ch2[0],aux_ch1[0],sub_pkt_data0[63:2]};
    sub_pkt_data1 <= {aux_ch2[1],aux_ch1[1],sub_pkt_data1[63:2]};
    sub_pkt_data2 <= {aux_ch2[2],aux_ch1[2],sub_pkt_data2[63:2]};
    sub_pkt_data3 <= {aux_ch2[3],aux_ch1[3],sub_pkt_data3[63:2]};
end
always@( posedge clk )
begin
    pkt_header <= {aux_ch0[2],pkt_header[31:1]};
end
reg [7:0] HB0;
reg [7:0] HB1;
reg [7:0] HB2;
reg [223:0] SB;
reg aux_valid;
reg [7:0] PB [0:27];
always @( posedge clk )
begin
    if( &cnt ) begin
        aux_valid <= 1'b1;
    end else begin
        aux_valid <= 1'b0;
    end
end 

always @( * )//posedge clk
begin
    // if( &cnt ) begin
        HB0 = pkt_header[7:0];
        HB1 = pkt_header[15:8];
        HB2 = pkt_header[24:16];
        // SB  <= {sub_pkt_data3[55:0],sub_pkt_data2[55:0],sub_pkt_data1[55:0],sub_pkt_data0[55:0]};
        PB[0] = sub_pkt_data0[7:0];
        PB[1] = sub_pkt_data0[15:8];
        PB[2] = sub_pkt_data0[23:16];
        PB[3] = sub_pkt_data0[31:24];
        PB[4] = sub_pkt_data0[39:32];
        PB[5] = sub_pkt_data0[47:40];
        PB[6] = sub_pkt_data0[55:48];
        PB[7] = sub_pkt_data1[7:0];
        PB[8] = sub_pkt_data1[15:8];
        PB[9] = sub_pkt_data1[23:16];
        PB[10]= sub_pkt_data1[31:24];
        PB[11]= sub_pkt_data1[39:32];
        PB[12]= sub_pkt_data1[47:40];
        PB[13]= sub_pkt_data1[55:48];
        PB[14]= sub_pkt_data2[7:0];
        PB[15]= sub_pkt_data2[15:8];
        PB[16]= sub_pkt_data2[23:16];
        PB[17]= sub_pkt_data2[31:24];
        PB[18]= sub_pkt_data2[39:32];
        PB[19]= sub_pkt_data2[47:40];
        PB[20]= sub_pkt_data2[55:48];
        PB[21]= sub_pkt_data3[7:0];
        PB[22]= sub_pkt_data3[15:8];
        PB[23]= sub_pkt_data3[23:16];
        PB[24]= sub_pkt_data3[31:24];
        PB[25]= sub_pkt_data3[39:32];
        PB[26]= sub_pkt_data3[47:40];
        PB[27]= sub_pkt_data3[55:48];
        // aux_valid <= 1'b1;
    // end else begin
        // aux_valid <= 1'b0;
    // end
    
end
wire [7:0] SUB0_PB[6:0];
wire [7:0] SUB1_PB[6:0];
wire [7:0] SUB2_PB[6:0];
wire [7:0] SUB3_PB[6:0];
assign SUB0_PB[0] = PB[0];
assign SUB0_PB[1] = PB[1];
assign SUB0_PB[2] = PB[2];
assign SUB0_PB[3] = PB[3];
assign SUB0_PB[4] = PB[4];
assign SUB0_PB[5] = PB[5];
assign SUB0_PB[6] = PB[6];

assign SUB1_PB[0] =PB[7] ;
assign SUB1_PB[1] =PB[8] ;
assign SUB1_PB[2] =PB[9] ;
assign SUB1_PB[3] =PB[10];
assign SUB1_PB[4] =PB[11];
assign SUB1_PB[5] =PB[12];
assign SUB1_PB[6] =PB[13];

assign SUB2_PB[0] =PB[14];
assign SUB2_PB[1] =PB[15];
assign SUB2_PB[2] =PB[16];
assign SUB2_PB[3] =PB[17];
assign SUB2_PB[4] =PB[18];
assign SUB2_PB[5] =PB[19];
assign SUB2_PB[6] =PB[20];

assign SUB3_PB[0] =PB[21];
assign SUB3_PB[1] =PB[22];
assign SUB3_PB[2] =PB[23];
assign SUB3_PB[3] =PB[24];
assign SUB3_PB[4] =PB[25];
assign SUB3_PB[5] =PB[26];
assign SUB3_PB[6] =PB[27];
//=======================================================================================
//
//=======================================================================================
// Audio Sample
reg layout = 'd0;
reg [3:0] sample_present = 'd0;
reg [3:0] sample_flat = 'd0;
reg [191:0] audio_B = 'd0;
reg [3:0] audio_PR = 'd0;
reg [3:0] audio_CR = 'd0;
reg [3:0] audio_UR = 'd0;
reg [3:0] audio_VR = 'd0;
reg [3:0] audio_PL = 'd0;
reg [3:0] audio_CL = 'd0;
reg [3:0] audio_UL = 'd0;
reg [3:0] audio_VL = 'd0;
reg [191:0] SUB0_audio_CL = 'd0;
reg [191:0] SUB0_audio_CR = 'd0;
reg XOR_B;
reg XNOR_B ;
reg [19:0] audio_N = 'd0;
reg [19:0] audio_CTS = 'd0;
always @( posedge clk )
begin
    if( aux_valid && HB0 == 8'h01 ) begin //Audio clock regeneration
        audio_N <= {SUB0_PB[4][3:0],SUB0_PB[5][7:0],SUB0_PB[6][7:0]};
        audio_CTS <= {SUB0_PB[1][3:0],SUB0_PB[2][7:0],SUB0_PB[3][7:0]};
    end
end

wire [3:0] w_sample_present = HB1[3:0];

always @( posedge clk )
begin
    if( aux_valid && HB0 == 8'h02 ) begin
        layout          <= HB1[4];
        sample_present  <= HB1[3:0];
        sample_flat     <= HB2[3:0];
        // audio_B         <= {HB2[7:4],audio_B[387:4]};//Contains the first frame in a 192 frame
    end
end



generate
    if(AUDIO_CHANNEL == 0) begin : Tow_audio_channel
    
        always @( posedge clk ) begin
            if(aux_valid && HB0 == 8'h02) begin//two channel
                audio_valid <= w_sample_present[0];
            end else begin
                audio_valid <= 1'b0;
            end
        end 

        always @( posedge clk ) begin
            if( aux_valid && HB0 == 8'h02 ) begin
                // audio_B         <= {HB2[7:4],audio_B[387:4]};//Contains the first frame in a 192 frame
                audio_B          <= w_sample_present[0] ? {HB2[4],audio_B[191:1]} : audio_B;
                audio_L          <={SUB0_PB[2],SUB0_PB[1],SUB0_PB[0]};
                audio_R          <={SUB0_PB[5],SUB0_PB[4],SUB0_PB[3]};

                audio_PR         <={SUB0_PB[6][7]};       
                audio_PL         <={SUB0_PB[6][3]}; 

                audio_UR         <={SUB0_PB[6][5]};
                audio_UL         <={SUB0_PB[6][1]};

                audio_VR         <={SUB0_PB[6][4]};
                audio_VL         <={SUB0_PB[6][0]};

                audio_CR         <={SUB0_PB[6][6]};
                audio_CL         <={SUB0_PB[6][2]};

                SUB0_audio_CL    <=w_sample_present[0] ? {SUB0_PB[6][6],SUB0_audio_CL[191:1]} : SUB0_audio_CL  ;
                SUB0_audio_CR    <=w_sample_present[0] ? {SUB0_PB[6][2],SUB0_audio_CR[191:1]} : SUB0_audio_CR  ; 
            end
        end
    end else begin //===================8channel
        always @( posedge clk ) begin
            if( aux_valid && HB0 == 8'h02 ) begin
                // audio_B         <= {HB2[7:4],audio_B[387:4]};//Contains the first frame in a 192 frame
                audio_B          <= w_sample_present[0] ? {HB2[4],audio_B[191:1]} : audio_B;
                audio_L          <={{SUB3_PB[2],SUB3_PB[1],SUB3_PB[0]},{SUB2_PB[2],SUB2_PB[1],SUB2_PB[0]},{SUB1_PB[2],SUB1_PB[1],SUB1_PB[0]},{SUB0_PB[2],SUB0_PB[1],SUB0_PB[0]}};
                audio_R          <={{SUB3_PB[5],SUB3_PB[4],SUB3_PB[3]},{SUB2_PB[5],SUB2_PB[4],SUB2_PB[3]},{SUB1_PB[5],SUB1_PB[4],SUB1_PB[3]},{SUB0_PB[5],SUB0_PB[4],SUB0_PB[3]}};

                audio_PR         <={SUB3_PB[6][7],SUB2_PB[6][7],SUB1_PB[6][7],SUB0_PB[6][7]};
                audio_PL         <={SUB3_PB[6][3],SUB2_PB[6][3],SUB1_PB[6][3],SUB0_PB[6][3]};

                audio_UR         <={SUB3_PB[6][5],SUB2_PB[6][5],SUB1_PB[6][5],SUB0_PB[6][5]};
                audio_UL         <={SUB3_PB[6][1],SUB2_PB[6][1],SUB1_PB[6][1],SUB0_PB[6][1]};

                audio_VR         <={SUB3_PB[6][4],SUB2_PB[6][4],SUB1_PB[6][4],SUB0_PB[6][4]};
                audio_VL         <={SUB3_PB[6][0],SUB2_PB[6][0],SUB1_PB[6][0],SUB0_PB[6][0]};

                audio_CR         <={SUB3_PB[6][6],SUB2_PB[6][6],SUB1_PB[6][6],SUB0_PB[6][6]};
                audio_CL         <={SUB3_PB[6][2],SUB2_PB[6][2],SUB1_PB[6][2],SUB0_PB[6][2]};

                SUB0_audio_CL    <=w_sample_present[0] ? {SUB0_PB[6][6],SUB0_audio_CL[191:1]} : SUB0_audio_CL  ;
                SUB0_audio_CR    <=w_sample_present[0] ? {SUB0_PB[6][2],SUB0_audio_CR[191:1]} : SUB0_audio_CR  ; 
            end
        end
    end
endgenerate
reg audio_param_valid_r = 'd0;
always @( posedge clk )
begin
    if( aux_valid && HB0 == 8'h02 )begin
        audio_param_valid_r <= audio_B[0];
    end else begin
        audio_param_valid_r <= 1'b0;
    end
    audio_param_valid <= audio_param_valid_r;
end
reg audio_consumer_use;
reg audio_pcm;
always @( posedge clk )
begin
    // if( audio_param_valid_r) begin
    if( aux_valid && HB0 == 8'h02 && audio_B[0] == 1'b1 ) begin
        audio_max_word_length    <= SUB0_audio_CL[32]; //0:20bits 1:24bits;
        audio_stae               <= SUB0_audio_CL[5:3];
        audio_ch                 <= SUB0_audio_CL[23:20];
        audio_samp_freq          <= SUB0_audio_CL[27:24];
        audio_samp_word_len      <= SUB0_audio_CL[35:33];
        // audio_consumer_use       <= SUB0_audio_CL[0];
        // audio_pcm                <= SUB0_audio_CL[1];
    end

end







reg [2:0] audio_CC = 'd0;
reg [3:0] audio_CT = 'd0;
reg [4:0] audio_SF = 'd0;
reg [1:0] audio_SS = 'd0;
reg [7:0] audio_CA = 'd0;
reg       audio_DM_INH = 'd0;
reg [3:0] audio_LVS = 'd0;
reg [1:0] audio_LFEPBL = 'd0;
reg [7:0] audio_info_CHK_SUM = 'd0;
always @( posedge clk )
begin
    if( aux_valid && HB0 == 8'h84) begin
        audio_CC <= SUB0_PB[1][2:0];
        audio_CT <= SUB0_PB[1][7:4];
        audio_SF <= SUB0_PB[2][4:2];
        audio_SS <= SUB0_PB[2][1:0];
        audio_CA <= SUB0_PB[3][7:0];
        audio_DM_INH <= SUB0_PB[5][7];
        audio_LVS <= SUB0_PB[5][6:3];
        audio_LFEPBL <= SUB0_PB[5][1:0];
        audio_info_CHK_SUM <= SUB0_PB[0][7:0];
    end
end
//=======================================================================================
//
//=======================================================================================

always @( posedge clk )
begin
    if( aux_valid && HB0 == 8'h82 ) begin
        avi_infoframe_S <= SUB0_PB[1][1:0];
        avi_infoframe_B <= SUB0_PB[1][3:2];
        avi_infoframe_A <= SUB0_PB[1][4];
        avi_infoframe_Y <= SUB0_PB[1][6:5];
        avi_infoframe_R <= SUB0_PB[2][3:0];
        avi_infoframe_M <= SUB0_PB[2][5:4];
        avi_infoframe_C <= SUB0_PB[2][7:6];
        avi_infoframe_SC <=SUB0_PB[3][1:0];
        avi_infoframe_Q <= SUB0_PB[3][3:2];
        avi_infoframe_EC <=SUB0_PB[3][6:4];
        avi_infoframe_ITC <=SUB0_PB[3][7];
        avi_infoframe_VIC <=SUB0_PB[4][6:0];
        avi_infoframe_PR <= SUB0_PB[5][3:0];
        avi_infoframe_CN <= SUB0_PB[5][5:4];
        avi_infoframe_YQ <= SUB0_PB[5][7:6];
        avi_infoframe_ETB <= {SUB1_PB[0],SUB0_PB[0]};
        avi_infoframe_SBB <= {SUB1_PB[2],SUB1_PB[1]};
        avi_infoframe_ELB <= {SUB1_PB[4],SUB1_PB[3]};
        avi_infoframe_SRB <= {SUB1_PB[6],SUB1_PB[5]};


    end
    

end
//============================================================================
//GCP
//===========================================================================

reg [3:0] GCP_PP = 'd0; 
reg [3:0] GCP_CD = 'd0;
reg       GCP_AVMUTE = 'd0;
always @( posedge clk )
begin
    if(aux_valid && HB0 == 8'h03 ) begin
        GCP_PP <= SUB0_PB[1][7:4];
        GCP_CD <= SUB0_PB[1][3:0];
        GCP_AVMUTE <= SUB0_PB[0][0];
    end
end


endmodule

//Encryption end
