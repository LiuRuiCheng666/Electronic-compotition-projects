`timescale 1ns / 1ps
//****************************************Copyright (c)***********************************//

//****************************************************************************************//

module channelbond (
  input  wire       clk,
  input  wire [9:0] i_data,
  // input  wire       sync_code,
  input  wire       pos_sync_code,
  input  wire       align_flag0,
  input  wire       other_ch0_rdy,
  input  wire       other_ch1_rdy,
  output reg        iamrdy,
  output wire       bond_rdy,
  output wire [9:0]  sdata
);

//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/
//parameter define 
// parameter CTRLTOKEN0 = 10'b1101010100;//354
// parameter CTRLTOKEN1 = 10'b0010101011;//0ab
// parameter CTRLTOKEN2 = 10'b0101010100;//154
// parameter CTRLTOKEN3 = 10'b1010101011;//25b

//reg define 
reg [3:0] wa;                  //дram��ַ
reg [3:0] ra;                  //��ram��ַ
reg       we;                  //дramʹ��
// reg       rcvd_ctkn;           //�����ַ�ʹ��
reg       rcvd_ctkn_d0;        
reg       rcvd_ctkn_pos;       //�����ַ�������
reg       ra_en;               //��ʹ��
reg       invalid = 'd0;

//wire define                  
wire      align_flag;         //����ȫ��У׼���ʹ��  
wire [9:0]dpfo_dout;           //ram�������
//*****************************************************
//**                    main code
//*****************************************************   
  
// assign align_flag = align_flag1 & align_flag2 & align_flag0;
assign align_flag = align_flag0;
////////////////////////////////////////////////////////
// FIFO Write Control Logic
////////////////////////////////////////////////////////
// always @ (posedge clk) 
// begin
// //   rcvd_ctkn <= ((sdata == CTRLTOKEN0) || (sdata == CTRLTOKEN1) || (sdata == CTRLTOKEN2) || (sdata == CTRLTOKEN3));
//     rcvd_ctkn_d0 <=  sync_code;//rcvd_ctkn;//
//     rcvd_ctkn_pos <= !rcvd_ctkn_d0 &  sync_code;//rcvd_ctkn;//
// end

always @( posedge clk )
begin
  if( ~align_flag )
      invalid <= 1'b0; 
  else if( align_flag & pos_sync_code)//rcvd_ctkn_pos)//blank_cnt[4])//
      invalid <= 1'b1;
end

always @ (posedge clk) 
begin
  we <= invalid;//#1 align_flag;
end

always @ (posedge clk) 
begin
  if(invalid)//(align_flag)
    wa <=#1 wa + 1'b1;
  else
    wa <=#1 4'h0;
end



/////////////////////////////////////////
//FIFO Read Address Counter
/////////////////////////////////////////

always @ (posedge clk) begin
    iamrdy <= invalid;
end

always @ (posedge clk) begin
if( other_ch0_rdy & other_ch1_rdy & iamrdy)
    ra_en <=#1 1'b1;
else 
    ra_en <=#1 1'b0;
end
assign bond_rdy = ra_en;
always @ (posedge clk) begin
  if(ra_en)
    ra <=#1 ra + 1'b1;
  else 
    ra <=#1 4'h0;
end


simple_dual_port_ram
#(
	.DATA_WIDTH(10),
	.ADDR_WIDTH(4),
	.OUTPUT_REG("FALSE"),
  .RAM_INIT_FILE("")

) u_simple_dual_port_ram
(
	/*i*/.wdata	(i_data),
	/*i*/.waddr	(wa), 
	/*i*/.raddr	(ra),
	/*i*/.we	(we), 
	/*i*/.wclk	(clk), 
	/*i*/.re	(1'b1), 
	/*i*/.rclk	(clk),
	// /*o*/.rdata (dpfo_dout)
/*o*/.rdata (sdata)
);

// always @ (posedge clk) begin
//   sdata <=#1 dpfo_dout;
// end






endmodule

//Encryption end