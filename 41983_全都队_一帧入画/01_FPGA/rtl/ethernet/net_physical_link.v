`default_nettype none
// Candidate shared recovered-clock transport. PHY configuration remains read-only.
// Endpoint/mailbox reset must NOT follow link changes while CPU owns packets.
module net_physical_link(input wire osc_inst1_CLKOUT,rxc,reset_n,mdio_i,
 input wire[3:0]rxd_hi_i,rxd_lo_i,input wire rx_dv_HI,rx_dv_LO,
 output wire osc_inst1_ENA,phy_rst_n,mdc_o,mdio_o,mdio_oe,
 output wire[3:0]txd_hi_o,txd_lo_o,output wire tx_en_o_HI,tx_en_o_LO,txc_hi_o,txc_lo_o,
 output wire[7:0]rx_data,output wire rx_valid,rx_error,input wire[7:0]tx_data,input wire tx_valid);
 (* async_reg="true" *)reg[2:0]osc_release=0;
 always @(posedge osc_inst1_CLKOUT or negedge reset_n)if(!reset_n)osc_release<=0;else osc_release<={osc_release[1:0],1'b1};
 wire osc_reset_n=osc_release[2];
 reg[19:0]power_wait=0;
 always @(posedge osc_inst1_CLKOUT or negedge osc_reset_n)
 if(!osc_reset_n)power_wait<=0;else if(!power_wait[19])power_wait<=power_wait+1'b1;
 assign phy_rst_n=power_wait[19];assign osc_inst1_ENA=1'b1;
 wire gigabit; a_phy_link_poll u_phy(.clk(osc_inst1_CLKOUT),.rst_n(phy_rst_n),.mdio_i(mdio_i),.mdio_o(mdio_o),.mdio_oe(mdio_oe),.mdc(mdc_o),.found(),.link_gigabit(gigabit),.address(),.phy_id(),.specific_status());
 wire run_enable=reset_n&&phy_rst_n&&gigabit;
 (* async_reg="true" *)reg[2:0]run_pipe=0;
 always @(posedge rxc or negedge run_enable)if(!run_enable)run_pipe<=0;else run_pipe<={run_pipe[1:0],1'b1};
 wire rv,re;wire[7:0]rd;
 a_rgmii_fabric_adapter u_adapter(.clk(rxc),.rst_n(run_pipe[2]),.rxd_hi_i(rxd_hi_i),.rxd_lo_i(rxd_lo_i),.rx_dv_HI(rx_dv_HI),.rx_dv_LO(rx_dv_LO),.gmii_rx_data(rd),.gmii_rx_valid(rv),.gmii_rx_error(re),.gmii_tx_data(tx_data),.gmii_tx_valid(tx_valid&&run_pipe[2]),.gmii_tx_error(1'b0),.txd_hi_o(txd_hi_o),.txd_lo_o(txd_lo_o),.tx_en_o_HI(tx_en_o_HI),.tx_en_o_LO(tx_en_o_LO),.txc_hi_o(txc_hi_o),.txc_lo_o(txc_lo_o));
 assign rx_data=rd;assign rx_valid=rv&&run_pipe[2];assign rx_error=re;
endmodule
`default_nettype wire
