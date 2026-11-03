
module phasealign_v1(
input		clk,
input 	rst_n,
input [9:0] vin,
input  re_algin_start,
output sync_code,
output pos_sync_code,
output bitslip,
output aligned

);
//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/
parameter CTRLTOKEN0 = 10'h354;
parameter CTRLTOKEN1 = 10'h0ab;
parameter CTRLTOKEN2 = 10'h154;
parameter CTRLTOKEN3 = 10'h2ab;
parameter kTimeoutEnd = 38400;   
// parameter SYNC_CNT = 16;
reg            ptkn0_flag;
reg            ptkn1_flag;
reg            ptkn2_flag;
reg            ptkn3_flag;       
//reg define
reg [9:0] 			vin_r = 'd0;    
reg [4:0]      	blank_cnt = 'd0;
reg [20:0]  	timeout_cnt=0;       
wire			time_out_rst;  

//wire define
reg 			bitslip1;
wire             ptkn_flag; 

always @( posedge clk )
begin
	ptkn0_flag <= (vin ==  CTRLTOKEN0 );                                                      
	ptkn1_flag <= (vin ==  CTRLTOKEN1 );                                                          
	ptkn2_flag <= (vin ==  CTRLTOKEN2 );                                                      
	ptkn3_flag <= (vin ==  CTRLTOKEN3 );
end  


assign ptkn_flag = ptkn0_flag || ptkn1_flag || ptkn2_flag || ptkn3_flag;


assign sync_code = ptkn_flag;
always @( posedge clk or negedge rst_n )//出现 16个同步码
begin
	if( !rst_n  ) begin
		blank_cnt <= 'd0;
	end else if( ptkn_flag ) begin
		if( blank_cnt[4] )//SYNC_CNT == 
			blank_cnt <= 0;
		else	
			blank_cnt <= blank_cnt + 1'b1;
	end else 
		blank_cnt <= 'd0;
end


assign time_out_rst = blank_cnt[4];

assign bitslip0 = timeout_cnt[20];//(timeout_cnt == (kTimeoutEnd - 1))? 1'b1 : 1'b0;
always@(posedge clk )begin
    if(time_out_rst | bitslip | re_algin_start )//bitslip0)
        timeout_cnt <= 0;  
    else
        timeout_cnt <= timeout_cnt + 1;
end 
//=============================================================================== 
//bit_slip cycle
//=============================================================================== 
reg 			aligned1 = 'd0;
reg 			aligned2 = 'd0;
reg [23:0] 		align_cnt = 'd0;
always @( posedge clk )
begin
	if( !rst_n )
		align_cnt <= 'd0;    
	else if( bitslip | re_algin_start)
		align_cnt <= 'd0;
	else if( aligned )
		align_cnt <= align_cnt;
	else 
		align_cnt <= align_cnt + 1'b1;
end                               

always @( posedge clk )
begin
	if( !rst_n )
		aligned1 <= 1'b0;
	else if( bitslip | re_algin_start)
		aligned1 <= 1'b0;
	else if( align_cnt[19])//[22]) 
		aligned1 <= 1'b1;
end 

// always @( posedge clk )
// begin
// 	if( !rst_n )
// 		aligned2 <= 1'b0;
// 	else if(bitslip | re_algin_start)
// 		aligned2 <= 1'b0;
// 	else if( align_cnt[21])
// 		aligned2 <= 1'b1;
// end

assign aligned = align_cnt[20];//[23];
//====================================================================== 
//
//======================================================================
reg ptkn_flag_r = 'd0;

reg [1:0] state ;
reg [6:0] cnt = 'd0;
reg pos_pktn_flag;
always @( posedge clk )
begin
	ptkn_flag_r <= ptkn_flag;
	pos_pktn_flag <= ~ptkn_flag_r & ptkn_flag;
end
assign pos_sync_code = pos_pktn_flag;
always @( posedge clk )
begin
	bitslip1 <= 1'b0;

	if( aligned1 ) begin
		case(state )
		2'd0: begin
			state <= pos_pktn_flag ? 2'd1 : 2'd0;
			cnt <= 'd0;
		end
		2'd1 : begin
			if( pos_pktn_flag )
				state <= 2'd2;
			else if( cnt[6] ) 
				state <= 2'd1;
			else 
				cnt <= cnt + 1'b1;
		end
		2'd2 : begin
			bitslip1 <= cnt[6:5] == 2'd0;
		end
		default:;
		endcase	
	end else begin
		state <= 2'd0;
		cnt <= 'd0;
	end

end




assign bitslip = bitslip0 | bitslip1 ;//|bitslip2;//& ~time_out_rst;
endmodule


//Encryption end
