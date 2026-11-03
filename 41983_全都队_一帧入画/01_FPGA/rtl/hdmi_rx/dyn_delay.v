
module dyn_delay #(
	parameter MODE = 0
)(
input					clk,
input 				rst_n,
input	 				dyn_en,
input		[5:0] dly_d,
input				  dly_inc,
input  		mode ,//0: reset every time ; 1: inc or dec 1 step each time

output	reg dyn_rst = 1'b1,
output	wire	dyn_inc,
output	wire	dyn_ena,
output  reg [5:0] dly_cnt = 31,
output	reg	cal_busy

);
//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/
wire dyn_en_pulse ;
wire pre_dyn_en_pulse; // Explicit original implicit net, for strict simulators.
reg [5:0] dly_d_r;
reg [5:0] dly_d_r0;
reg 	dly_inc_r;
reg	dyn_en_r0 = 1'b0;
reg	dyn_en_r1 = 1'b0;
always @( posedge clk or negedge rst_n )
begin
		if( !rst_n ) begin
				dyn_en_r0 <= 1'b0;
				dyn_en_r1 <= 1'b0;
		end else begin
				dyn_en_r0 <= dyn_en ;
				dyn_en_r1 <= dyn_en_r0;
		end
			
end

always @( posedge clk or negedge rst_n )
begin
		if( !rst_n ) begin
			dly_d_r0 <= 'd0;
		end else begin
			dly_d_r0 <= dly_d;
		end
				
end

always @( posedge clk or negedge rst_n )
begin
	if( !rst_n )
		dyn_rst <= 1'b1;
	else 
		dyn_rst <= mode ? 1'b0 : pre_dyn_en_pulse;
end
assign pre_dyn_en_pulse = {dyn_en_r0,dyn_en} == 2'b01;
assign dyn_en_pulse = {dyn_en_r1,dyn_en_r0} == 2'b01;
               

always @( posedge clk or negedge rst_n )
begin
		if( !rst_n ) begin        			
				dly_d_r <= 0;     
		end else if(dyn_en_pulse ) begin	
					dly_d_r <= (mode == 0 )? dly_d_r0 : 1'b1; 
		end else begin											
				dly_d_r <= dly_d_r - |dly_d_r;  	
		end
end        

always @( posedge clk or negedge rst_n )
begin
		if( !rst_n ) begin        			
				dly_inc_r <= 0;     
		end else if(dyn_en_pulse ) begin	
				dly_inc_r <= dly_inc; 
		end
end     

reg dyn_ena_r = 'd0;
always @( posedge clk or negedge rst_n )
begin
		if( !rst_n ) 
			dyn_ena_r <= 1'b0;
		else
			dyn_ena_r <= |dly_d_r ;
end
assign dyn_ena = dyn_ena_r;
reg dyn_inc_r1;
always @( posedge clk )
begin
	dyn_inc_r1 <= dly_inc_r	;  
end
assign dyn_inc = dyn_inc_r1;

always @( posedge clk )
begin
	cal_busy <= dyn_en || (|dly_d_r) || dyn_en_pulse || (|{dyn_en_r1,dyn_en_r0});
end

always @( posedge clk or negedge rst_n )
begin
	if( !rst_n )
		dly_cnt <= 'd31;
	else if( dyn_rst )
			dly_cnt <= 'd31;
	else if(dyn_ena ) begin
		if( dyn_inc ) begin 
			if( &dly_cnt )
				dly_cnt <= dly_cnt ;
			else 
				dly_cnt <= dly_cnt + 1'b1;
		end else begin
			if( dly_cnt == 0 )
				dly_cnt <= 0;
			else 
				dly_cnt <= dly_cnt - 1'b1;
		end
	end
end



endmodule      

//Encryption end
     
