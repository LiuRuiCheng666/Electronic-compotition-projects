`timescale 1ns/1ps
`default_nettype none
// Independent network-only bring-up endpoint. No NN or shared DDR access.
// ARP -> reply; verified ANET HELLO -> ACK with identical payload/session/seq.
// Other valid ANET operations are counted and rejected without success ACK.
module a_net_hello_endpoint #(
 parameter[47:0] LOCAL_MAC=48'h02000060f225,
 parameter[31:0] LOCAL_IP=32'hc0a80002,
 parameter[15:0] LOCAL_PORT=16'd40000
)(
 input wire clk,rst_n,input wire[7:0]gmii_rx_data,input wire gmii_rx_valid,gmii_rx_error,
 output wire[7:0]gmii_tx_data,output wire gmii_tx_valid,
 output wire[31:0]good_udp,good_arp,busy_drops,bad_fcs,bad_header,
 output wire[31:0]app_good,app_bad_crc,app_bad_format,
 output reg[31:0]unsupported,hello_replies
);
 localparam IDLE=0,PREFETCH=1,FEED=2,DECIDE=3,WAIT_TX=4,RELEASE=5;
 reg[2:0]state;reg[15:0]pos;
 wire fv,ar,pv;wire[47:0]pm;wire[31:0]pi,sid,seq,off,total;
 wire[15:0]sport,length,n;wire[7:0]fq,pq,op;
 wire[10:0]pa;
 reg tx_start,tx_arp;
 wire tx_done,tx_busy;
 wire[10:0]fa=(state==FEED && pos+1<length) ? pos+1'b1 : pos;
 a_gmii_udp_rx #(.LOCAL_MAC(LOCAL_MAC),.LOCAL_IP(LOCAL_IP),.LOCAL_PORT(LOCAL_PORT)) u_rx(
  .clk(clk),.rst_n(rst_n),.gmii_data(gmii_rx_data),.gmii_valid(gmii_rx_valid),.gmii_error(gmii_rx_error),
  .frame_valid(fv),.frame_ready(state==RELEASE),.frame_arp(ar),.peer_mac(pm),.peer_ip(pi),.peer_port(sport),
  .payload_length(length),.payload_address(fa),.payload_data(fq),.good_udp(good_udp),.good_arp(good_arp),
  .busy_drops(busy_drops),.bad_fcs(bad_fcs),.bad_header(bad_header));
 a_net_packet_rx u_app(.clk(clk),.rst_n(rst_n),.rx_valid(state==FEED),.rx_first(pos==0),
  .rx_last(pos==length-1),.rx_error(1'b0),.rx_data(fq),.packet_valid(pv),.packet_ready(state==RELEASE),
  .packet_op(op),.packet_session(sid),.packet_sequence(seq),.packet_offset(off),.packet_total(total),.packet_length(n),
  .payload_address(pa),.payload_data(pq),.good_packets(app_good),.dropped_busy(),.bad_crc(app_bad_crc),.bad_format(app_bad_format));
 a_gmii_reply_tx #(.LOCAL_MAC(LOCAL_MAC),.LOCAL_IP(LOCAL_IP),.LOCAL_PORT(LOCAL_PORT)) u_tx(
  .clk(clk),.rst_n(rst_n),.start(tx_start),.arp_reply(tx_arp),.peer_mac(pm),.peer_ip(pi),.peer_port(sport),
  .payload_length(n),.session_id(sid),.sequence_id(seq),.payload_address(pa),.payload_data(pq),
  .busy(tx_busy),.done(tx_done),.gmii_data(gmii_tx_data),.gmii_valid(gmii_tx_valid));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;pos<=0;tx_start<=0;tx_arp<=0;unsupported<=0;hello_replies<=0;end
  else begin
   tx_start<=0;
   case(state)
    IDLE:if(fv)begin
     pos<=0;
     if(ar)begin tx_arp<=1;tx_start<=1;state<=WAIT_TX;end
     else if(length>=32)state<=PREFETCH;
     else state<=RELEASE;
    end
    PREFETCH:state<=FEED;
    FEED:if(pos==length-1)state<=DECIDE;else pos<=pos+1'b1;
    DECIDE:begin
     if(pv && op==1 && off==0 && total==0)begin tx_arp<=0;tx_start<=1;state<=WAIT_TX;end
     else begin if(pv)unsupported<=unsupported+1'b1;state<=RELEASE;end
    end
    WAIT_TX:if(tx_done)begin if(!tx_arp)hello_replies<=hello_replies+1'b1;state<=RELEASE;end
    RELEASE:begin state<=IDLE;pos<=0;end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
