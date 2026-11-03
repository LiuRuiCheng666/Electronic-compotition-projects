`timescale 1ns/1ps
`default_nettype none
// Efinity peripheral-fabric adapter ONLY, not pad-level DDR primitives.
// Matches the supplied vendor DDIO resynchronization and HI/LO convention.
// Valid only with that peripheral configuration and a 1 Gbit/s RGMII clock.
// PHY delay programming, IO standards, clocks and constraints remain external.
module a_rgmii_fabric_adapter (
 input wire clk,rst_n,
 input wire [3:0] rxd_hi_i,rxd_lo_i,
 input wire rx_dv_HI,rx_dv_LO,
 output reg [7:0] gmii_rx_data,
 output reg gmii_rx_valid,gmii_rx_error,
 input wire [7:0] gmii_tx_data,
 input wire gmii_tx_valid,gmii_tx_error,
 output reg [3:0] txd_hi_o,txd_lo_o,
 output reg tx_en_o_HI,tx_en_o_LO,
 output wire txc_hi_o,txc_lo_o
);
 reg [3:0] align_hi;
 reg align_ctl_hi;
 reg [7:0] tx_data;
 reg tx_valid,tx_error;
 assign txc_hi_o=1'b1;
 assign txc_lo_o=1'b0;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   align_hi<=0;align_ctl_hi<=0;
   gmii_rx_data<=0;gmii_rx_valid<=0;gmii_rx_error<=0;
   tx_data<=0;tx_valid<=0;tx_error<=0;
   txd_hi_o<=0;txd_lo_o<=0;tx_en_o_HI<=0;tx_en_o_LO<=0;
  end else begin
   align_hi<=rxd_hi_i;align_ctl_hi<=rx_dv_HI;
   gmii_rx_data<={rxd_lo_i,align_hi};
   gmii_rx_valid<=rx_dv_LO;
   gmii_rx_error<=rx_dv_LO^align_ctl_hi;
   tx_data<=gmii_tx_data;tx_valid<=gmii_tx_valid;tx_error<=gmii_tx_error;
   txd_hi_o<=tx_data[3:0];txd_lo_o<=tx_data[7:4];
   tx_en_o_HI<=tx_valid;tx_en_o_LO<=tx_valid^tx_error;
  end
 end
endmodule
`default_nettype wire
