`timescale 1ns/1ps
`default_nettype none
// Display-priority, transaction-locked read mux. Writes only come from warp.
module cat_fisheye_axi_mux(
 input wire clk,rst_n,
 input wire [31:0] d_araddr,input wire [7:0] d_arlen,input wire d_arvalid,output wire d_arready,
 output wire [127:0] d_rdata,output wire [1:0] d_rresp,output wire d_rlast,d_rvalid,input wire d_rready,
 input wire [31:0] w_araddr,input wire [7:0] w_arlen,input wire w_arvalid,output wire w_arready,
 output wire [127:0] w_rdata,output wire [1:0] w_rresp,output wire w_rlast,w_rvalid,input wire w_rready,
 output wire [31:0] m_araddr,output wire [7:0] m_arlen,output wire m_arvalid,input wire m_arready,
 input wire [127:0] m_rdata,input wire [1:0] m_rresp,input wire m_rlast,m_rvalid,output wire m_rready,
 output wire [2:0] debug_read_state
);
 reg [1:0] owner;reg sent;
 assign debug_read_state={sent,owner};
 assign m_araddr=owner==1?d_araddr:w_araddr;assign m_arlen=owner==1?d_arlen:w_arlen;
 assign m_arvalid=!sent && ((owner==1 && d_arvalid)||(owner==2 && w_arvalid));
 assign d_arready=owner==1 && !sent && m_arready;assign w_arready=owner==2 && !sent && m_arready;
 assign d_rdata=m_rdata;assign w_rdata=m_rdata;assign d_rresp=m_rresp;assign w_rresp=m_rresp;
 assign d_rlast=m_rlast;assign w_rlast=m_rlast;
 assign d_rvalid=owner==1 && sent && m_rvalid;assign w_rvalid=owner==2 && sent && m_rvalid;
 assign m_rready=sent && ((owner==1 && d_rready)||(owner==2 && w_rready));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin owner<=0;sent<=0;end
  else begin
   if(owner==0)begin if(d_arvalid)owner<=1;else if(w_arvalid)owner<=2;end
   if(m_arvalid&&m_arready)sent<=1;
   if(m_rvalid&&m_rready&&m_rlast)begin owner<=0;sent<=0;end
  end
 end
endmodule
`default_nettype wire
