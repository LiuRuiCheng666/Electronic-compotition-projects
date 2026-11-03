`timescale 1ns/1ps
`default_nettype none
// A-owned raw-GMII/APB transport wrapper. No DDR, frame grant or NN access.
// Common reset must also be coordinated with the software image backend.
module a_net_service_endpoint #(
 parameter[47:0]LOCAL_MAC=48'h02000060f225,
 parameter[31:0]LOCAL_IP=32'hc0a80002,
 parameter[15:0]LOCAL_PORT=16'd40000,
 parameter integer HARDWARE_HELLO=1,
 parameter[15:0]APB_BASE=16'h1000
)(
 input wire net_clk,cpu_clk,reset_n,
 input wire cpu_reset, // Only mailbox ownership follows CPU reset; physical discovery stays alive.
 input wire[7:0]gmii_rx_data,input wire gmii_rx_valid,gmii_rx_error,
 output wire[7:0]gmii_tx_data,output wire gmii_tx_valid,
 input wire[15:0]PADDR,input wire PSEL,PENABLE,PWRITE,input wire[31:0]PWDATA,
 output wire[31:0]PRDATA,output wire PREADY,PSLVERROR,irq,
 output wire[31:0]good_udp,good_arp,busy_drops,bad_fcs,bad_header,
 output wire[31:0]app_good,app_bad_crc,app_bad_format,
 output reg[31:0]rx_copied,arp_sent,udp_sent
);
 (* async_reg="true" *)reg[2:0]net_release=0;
 always @(posedge net_clk or negedge reset_n)if(!reset_n)net_release<=0;else net_release<={net_release[1:0],1'b1};
 wire net_reset_n=net_release[2];
 wire mailbox_reset_n=reset_n && !cpu_reset;
 (* async_reg="true" *)reg[2:0]cpu_release=0;
 always @(posedge net_clk or negedge mailbox_reset_n)
  if(!mailbox_reset_n)cpu_release<=0;else cpu_release<={cpu_release[1:0],1'b1};
 localparam IDLE=0,RAW_READ=1,RAW_FEED=2,APP_CHECK=3,MB_DESC=4,
            APP_READ=5,MB_PUSH=6,RELEASE=7,ARP_REQUEST=8,HELLO_REQUEST=9,HELLO_WAIT=10,HELLO_CRC_READ=11,HELLO_CRC_FEED=12;
 reg[3:0]state;reg[10:0]pos; // Validated UDP payload is at most1400 bytes.
 wire fv,ar,pv;wire[47:0]pm;wire[31:0]pi,sid,seq,off,total;
 wire[15:0]sport,raw_len,app_len;wire[7:0]raw_q,app_q,op;
 wire tx_busy,tx_done;
 wire mb_rx_desc_ready,mb_rx_ready;
 wire mb_tx_valid,mb_tx_ready;wire[47:0]mb_mac;wire[31:0]mb_ip;
 wire[15:0]mb_port,mb_len;wire[10:0]tx_addr;wire[7:0]tx_q;
 wire[10:0]app_addr=pos[10:0];
 wire arp_request=state==ARP_REQUEST,hello_request=HARDWARE_HELLO!=0 && state==HELLO_REQUEST;
 wire hello_pending=HARDWARE_HELLO!=0 && (state==HELLO_CRC_READ || state==HELLO_CRC_FEED || hello_request || state==HELLO_WAIT);
 wire tx_start=!tx_busy && (arp_request || hello_request || (!hello_pending && mb_tx_valid));
 reg tx_owner_mailbox,tx_owner_hello;
 assign mb_tx_ready=!tx_busy && !arp_request && !hello_pending;
 wire copying_payload=state==APP_READ || state==MB_PUSH;
 wire[10:0]raw_addr=copying_payload?
  (11'd32+((state==MB_PUSH && mb_rx_ready && pos+1<app_len)?pos+1'b1:pos)):
  (state==RAW_FEED && pos+1<raw_len)?pos+1'b1:
                       ((hello_request || (HARDWARE_HELLO!=0 && state==HELLO_WAIT))?tx_addr:pos[10:0]);
 reg[31:0]hello_acc,hello_crc;
 function[31:0]crc_byte;
  input[31:0]c;input[7:0]d;reg[31:0]q;integer i;
  begin q=c^{24'd0,d};for(i=0;i<8;i=i+1)q=q[0]?(q>>1)^32'hedb88320:(q>>1);crc_byte=q;end
 endfunction
 // ANET CRC covers the first 28 header bytes plus payload; skip CRC bytes.
 wire[31:0]hello_next=(pos>=28 && pos<32)?hello_acc:
                            crc_byte(hello_acc,pos==5?8'h12:raw_q);
 wire[7:0]hello_q=tx_addr==5?8'h12:
                  (tx_addr>=28 && tx_addr<32)?(hello_crc>>(8*(31-tx_addr))):raw_q;

 a_gmii_udp_rx #(.LOCAL_MAC(LOCAL_MAC),.LOCAL_IP(LOCAL_IP),.LOCAL_PORT(LOCAL_PORT)) u_rx(
  .clk(net_clk),.rst_n(net_reset_n),.gmii_data(gmii_rx_data),.gmii_valid(gmii_rx_valid),.gmii_error(gmii_rx_error),
  .frame_valid(fv),.frame_ready(state==RELEASE),.frame_arp(ar),.peer_mac(pm),.peer_ip(pi),.peer_port(sport),
  .payload_length(raw_len),.payload_address(raw_addr),.payload_data(raw_q),
  .good_udp(good_udp),.good_arp(good_arp),.busy_drops(busy_drops),.bad_fcs(bad_fcs),.bad_header(bad_header));
 a_net_packet_rx #(.STORE_PAYLOAD(0),.DIRECT_METADATA(1)) u_app(
  .clk(net_clk),.rst_n(net_reset_n),.rx_valid(state==RAW_FEED),.rx_first(pos==0),
  .rx_last(pos==raw_len-1),.rx_error(1'b0),.rx_data(raw_q),.packet_valid(pv),.packet_ready(state==RELEASE),
  .packet_op(op),.packet_session(sid),.packet_sequence(seq),.packet_offset(off),.packet_total(total),.packet_length(app_len),
  .payload_address(app_addr),.payload_data(app_q),.good_packets(app_good),.dropped_busy(),.bad_crc(app_bad_crc),.bad_format(app_bad_format));
 a_net_mailbox_apb #(.BASE(APB_BASE),.DIRECT_RX_METADATA(1)) u_mailbox(
  .reset_n(mailbox_reset_n),.net_clk(net_clk),.cpu_clk(cpu_clk),
  .rx_desc_valid(state==MB_DESC),.rx_desc_ready(mb_rx_desc_ready),
  .rx_peer_mac(pm),.rx_peer_ip(pi),.rx_peer_port(sport),.rx_op(op),.rx_session(sid),.rx_sequence(seq),
  .rx_offset(off),.rx_total(total),.rx_length(app_len),
  .rx_valid(state==MB_PUSH),.rx_ready(mb_rx_ready),.rx_last(pos==app_len-1),.rx_error(1'b0),.rx_data(raw_q),
  .tx_desc_valid(mb_tx_valid),.tx_desc_ready(mb_tx_ready),.tx_peer_mac(mb_mac),.tx_peer_ip(mb_ip),
  .tx_peer_port(mb_port),.tx_length(mb_len),.tx_payload_address(tx_addr),.tx_payload_data(tx_q),
  .tx_done(tx_done && tx_owner_mailbox),.tx_done_error(1'b0),
  .PADDR(PADDR),.PSEL(PSEL),.PENABLE(PENABLE),.PWRITE(PWRITE),.PWDATA(PWDATA),
  .PRDATA(PRDATA),.PREADY(PREADY),.PSLVERROR(PSLVERROR),.irq(irq));
 // One serializer serves ARP, hardware HELLO and CPU mailbox replies.
 // The immutable validated raw RX buffer supplies HELLO after an ACK CRC pass.
 a_gmii_udp_tx #(.LOCAL_MAC(LOCAL_MAC),.LOCAL_IP(LOCAL_IP),.LOCAL_PORT(LOCAL_PORT)) u_tx(
  .clk(net_clk),.rst_n(net_reset_n),.start(tx_start),.arp_reply(arp_request),
  .peer_mac((arp_request||hello_request)?pm:mb_mac),
  .peer_ip((arp_request||hello_request)?pi:mb_ip),
  .peer_port((arp_request||hello_request)?sport:mb_port),
  .payload_length(arp_request?16'd0:hello_request?raw_len:mb_len),
  .payload_address(tx_addr),.payload_data((HARDWARE_HELLO!=0 && tx_owner_hello)?hello_q:tx_q),
  .busy(tx_busy),.done(tx_done),.gmii_data(gmii_tx_data),.gmii_valid(gmii_tx_valid));

 always @(posedge net_clk or negedge net_reset_n)begin
  if(!net_reset_n)begin state<=IDLE;pos<=0;rx_copied<=0;arp_sent<=0;udp_sent<=0;tx_owner_mailbox<=0;tx_owner_hello<=0;hello_acc<=32'hffffffff;hello_crc<=0;end
  else begin
   // Completion belongs to the previous frame even if a new start coincides.
   if(tx_done)begin
    if(tx_owner_mailbox || (HARDWARE_HELLO!=0 && tx_owner_hello))udp_sent<=udp_sent+1'b1;else arp_sent<=arp_sent+1'b1;
   end
   if(tx_start)begin tx_owner_mailbox<=!arp_request && !hello_request;tx_owner_hello<=hello_request;end
   case(state)
    IDLE:if(fv)begin
     pos<=0;
     if(ar)state<=ARP_REQUEST;else if(raw_len>=32)state<=RAW_READ;else state<=RELEASE;
    end
    RAW_READ:state<=RAW_FEED;
    RAW_FEED:if(pos==raw_len-1)state<=APP_CHECK;else pos<=pos+1'b1;
    APP_CHECK:if(pv)begin pos<=0;
     if(HARDWARE_HELLO!=0 && op==1 && off==0 && total==0)begin hello_acc<=32'hffffffff;state<=HELLO_CRC_READ;end
     else if(cpu_release[2])state<=MB_DESC;else state<=RELEASE;
    end else state<=RELEASE;
    HELLO_CRC_READ:state<=HELLO_CRC_FEED;
    HELLO_CRC_FEED:begin
     hello_acc<=hello_next;
     if(pos==raw_len-1)begin hello_crc<=~hello_next;state<=HELLO_REQUEST;end
     else begin pos<=pos+1'b1;state<=HELLO_CRC_READ;end
    end
    HELLO_REQUEST:if(tx_start)state<=HELLO_WAIT;
    HELLO_WAIT:if(tx_done && tx_owner_hello)state<=RELEASE;
    MB_DESC:if(!cpu_release[2])state<=RELEASE;else if(mb_rx_desc_ready)begin
     pos<=0;
     if(app_len==0)begin state<=RELEASE;rx_copied<=rx_copied+1'b1;end
     else state<=APP_READ;
    end
    // Two-cycle RAM reader keeps each byte stable under arbitrary backpressure.
    APP_READ:if(!cpu_release[2])state<=RELEASE;else state<=MB_PUSH;
    MB_PUSH:if(!cpu_release[2])state<=RELEASE;else if(mb_rx_ready)begin
     if(pos==app_len-1)begin state<=RELEASE;rx_copied<=rx_copied+1'b1;end
     else begin pos<=pos+1'b1;state<=MB_PUSH;end
    end
    ARP_REQUEST:if(tx_start)state<=RELEASE;
    RELEASE:begin state<=IDLE;pos<=0;end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
