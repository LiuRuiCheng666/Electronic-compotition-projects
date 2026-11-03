`timescale 1ns / 1ps


module tmds_decoder #(parameter DVI_MODE=0) (
    input              rst_n        ,   
    input              pixelclk    ,   //TMDS clock x1 (CLKDIV)
    input              ctrl_time   ,
    input   [9:0]      datain   	 ,   //TMDS data channel positive
    input   [1:0]      potherchrdy ,   //����2������ͬ������ź� 
    input              all_align   ,
    input             re_channelbond,
    input             re_algin_start,
    output             align_fail  ,
    output             pmerdy      ,   //����ͬ������ź� 
    output             paligned      ,   //����У׼����ź�
    output [9:0]       bond_data   ,
    output      wire    sync_code,
    output             pc0         ,   //�����ź�
    output             pc1         ,   //�����ź�
    output             pvde        ,   //������Чʹ��
    output   [7:0]     pdatain        //�����8bit��ɫ����

    );

//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/
//wire define 
wire  [9:0]                     pdatainraw;    //ת�����10bit��������
wire                            pbitslip;      //�ֶ����ƶ��ź�
wire                            pos_sync_code;
wire                            bond_rdy;

frame_bitslip u_bitslip (
/*i*/.clk     	(pixelclk),
/*i*/.rst_n    	(rst_n),
/*i*/.bitslip 	(pbitslip),
/*i*/.data_in 	(datain),
/*o*/.data_out	(pdatainraw),
/*o*/.align_fail(align_fail)
);

 phasealign_v1 u_phasealgin(
/*i*/.clk					    (pixelclk),
/*i*/.rst_n				    (rst_n),
/*i*/.vin					    (pdatainraw),
/*i*/.re_algin_start  (re_algin_start),
/*o*/.sync_code       (sync_code),
/*O*/.pos_sync_code   (pos_sync_code),
/*o*/.bitslip 		    (pbitslip),
/*o*/.aligned 	      (paligned)//,
// /*o*/.align_timeout(align_timeout)
);


// phasealign_v2 u_phasealgin1(
//   /*i*/.clk					    (pixelclk),
//   /*i*/.rst_n				    (rst_n),
//   /*i*/.vin					    (pdatainraw),
//   /*i*/.re_algin_start  (re_algin_start),
//   /*o*/.sync_code       (sync_code),
//   /*O*/.pos_sync_code   (pos_sync_code),
//   /*o*/.bitslip 		    (pbitslip),
//   /*o*/.aligned 	      (paligned)//,
//   );

// assign align_fail = pbitslip;//align_timeout;

//����ͬ��ģ��
channelbond u_channelbond(
  .clk           (pixelclk),
  .i_data        (pdatainraw),
  // .sync_code     (sync_code),
  .pos_sync_code(pos_sync_code),
  .align_flag0   (all_align & (~re_channelbond)),//(potherchvld & paligned & (~re_channelbond)), //local channel
  .other_ch0_rdy (potherchrdy[0]), //other channel
  .other_ch1_rdy (potherchrdy[1]), //other channel
  .iamrdy        (pmerdy),
  .bond_rdy      (bond_rdy),
  .sdata         (bond_data)
);

generate if(DVI_MODE!=0)begin:G_PC_DVI
 pc_dvi_decode u_decoder(.clk(pixelclk),.ready(bond_rdy),.symbol(bond_data),
  .c0(pc0),.c1(pc1),.de(pvde),.pixel(pdatain));
end else begin:G_HDMI_ORIGINAL
//8b/10b
decoder_v1 u_decoder(
	.pixelclk    (pixelclk),
  .i_data      (bond_data),
	// .potherchrdy (2'b11),//(potherchrdy),
	.pmerdy_int  (bond_rdy),//(pmerdy),
  .ctrl_time   (ctrl_time),
  
	.pc0         (pc0),	
	.pc1         (pc1),	
	.pvde        (pvde),	
	.pdatain	 (pdatain)
    );  


  
end endgenerate
endmodule

//Encryption end