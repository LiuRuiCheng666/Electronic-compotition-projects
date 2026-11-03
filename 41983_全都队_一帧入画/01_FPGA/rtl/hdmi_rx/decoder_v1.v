`timescale 1ns / 1ps


module decoder_v1(
	input			pixelclk,
    input	[9:0]	i_data,
	// input	[1:0]	potherchrdy,
	input			pmerdy_int,
	input           ctrl_time,
	output	reg		pc0,	
	output	reg		pc1,	
	output	reg		pvde,	
	output	reg[7:0]	pdatain	
    );

//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/
//parameter define 	
parameter CTRLTOKEN0 = 10'b1101010100;//
parameter CTRLTOKEN1 = 10'b0010101011;
parameter CTRLTOKEN2 = 10'b0101010100;
parameter CTRLTOKEN3 = 10'b1010101011;

//wire define 
wire	[7:0]	pdatain8b; 

//reg define 
reg [9:0]   data = 'd0;
reg [9:0] data_r = 'd0;
//*****************************************************
//**                    main code
//***************************************************** 
always @( posedge pixelclk )
begin
    data_r <= i_data;
    data <= data_r;
end


assign pdatain8b = (data[9]) ? ~data[7:0] : data[7:0];                
                                                                                          
always @ (posedge pixelclk) begin                                                       
    if(pmerdy_int && ctrl_time ) begin          // && (potherchrdy == 2'b11)                               
        case (data)                                                                   
            CTRLTOKEN0: begin                                                                 
                pc0 <=#1 1'b0;                                                                  
                pc1 <=#1 1'b0;                                                                  
                pvde <=#1 1'b0;                                                                 
            end                                                                               
                                                                                              
            CTRLTOKEN1: begin                                                                 
                pc0 <=#1 1'b1;                                                                  
                pc1 <=#1 1'b0;                                                                  
                pvde <=#1 1'b0;                                                                 
            end                                                                               
                                                                                              
            CTRLTOKEN2: begin                                                                 
                pc0 <=#1 1'b0;                                                                  
                pc1 <=#1 1'b1;                                                                  
                pvde <=#1 1'b0;                                                                 
            end                                                                               
                                                                                              
            CTRLTOKEN3: begin                                                                 
                pc0 <=#1 1'b1;                                                                  
                pc1 <=#1 1'b1;                                                                  
                pvde <=#1 1'b0;                                                                 
            end                                                                                                                                                                
            default: begin                                                                    
                                                                              
            end                                                                              
        endcase                                                                                                                                                                                      
    end 
    else begin                                                                       
        pdatain[0] <= pdatain8b[0];                                                                               
        pdatain[1] <= (data[8]) ? (pdatain8b[1] ^ pdatain8b[0]) : (pdatain8b[1] ~^ pdatain8b[0]);           
        pdatain[2] <= (data[8]) ? (pdatain8b[2] ^ pdatain8b[1]) : (pdatain8b[2] ~^ pdatain8b[1]);           
        pdatain[3] <= (data[8]) ? (pdatain8b[3] ^ pdatain8b[2]) : (pdatain8b[3] ~^ pdatain8b[2]);           
        pdatain[4] <= (data[8]) ? (pdatain8b[4] ^ pdatain8b[3]) : (pdatain8b[4] ~^ pdatain8b[3]);           
        pdatain[5] <= (data[8]) ? (pdatain8b[5] ^ pdatain8b[4]) : (pdatain8b[5] ~^ pdatain8b[4]);           
        pdatain[6] <= (data[8]) ? (pdatain8b[6] ^ pdatain8b[5]) : (pdatain8b[6] ~^ pdatain8b[5]);           
        pdatain[7] <= (data[8]) ? (pdatain8b[7] ^ pdatain8b[6]) : (pdatain8b[7] ~^ pdatain8b[6]);           
        pvde <= 1'b1; 
    end
end	

endmodule


//Encryption end
