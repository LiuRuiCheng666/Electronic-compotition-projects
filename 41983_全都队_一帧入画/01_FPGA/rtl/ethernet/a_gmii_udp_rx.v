`timescale 1ns/1ps
`default_nettype none
// Small single-clock candidate RX front end. RGMII DDR conversion stays outside.
// Owns one whole Ethernet frame until release. No partial/unverified frame is
// exposed. A busy receiver drops a new frame instead of overwriting held data.
// IPv4 without options/fragments; UDP checksum zero is legal on IPv4.
module a_gmii_udp_rx #(
 parameter [47:0] LOCAL_MAC=48'h02000060f225,
 parameter [31:0] LOCAL_IP=32'hc0a80002,
 parameter [15:0] LOCAL_PORT=16'd40000
)(
 input wire clk,rst_n,input wire [7:0] gmii_data,input wire gmii_valid,gmii_error,
 output reg frame_valid,input wire frame_ready,
 output reg frame_arp,output reg [47:0] peer_mac,output reg [31:0] peer_ip,
 output reg [15:0] peer_port,payload_length,
 input wire [10:0] payload_address,output reg [7:0] payload_data,
 output reg [31:0] good_udp,good_arp,busy_drops,bad_fcs,bad_header
);
 reg [7:0] mem[0:2047];
 reg active,drop,broken;reg [3:0] preamble;
 reg [10:0] count;
 reg [31:0] crc,ip_sum,udp_sum;
 reg [7:0] previous;
 reg [47:0] dm,sm,arp_sha;
 reg [31:0] sip,dip,arp_sip,arp_dip;
 reg [15:0] etype,ip_len,fragment,sport,dport,udp_len,udp_check;
 reg [63:0] arp_fixed;
 reg [7:0] ip_first,protocol,ttl;
 function [31:0] crc_byte;
  input [31:0] c;input [7:0] d;reg[31:0]q;integer i;
  begin q=c^{24'd0,d};for(i=0;i<8;i=i+1)q=q[0]?(q>>1)^32'hedb88320:q>>1;crc_byte=q;end
 endfunction
 function [15:0] fold;
  input [31:0] s;reg[16:0]a,b;
  begin a={1'b0,s[15:0]}+{1'b0,s[31:16]};b={1'b0,a[15:0]}+a[16];fold=b[15:0]+b[16];end
 endfunction
 // Finish pseudo-header arithmetic while the UDP header arrives. The
 // final UDP sum settles at its last byte; the four Ethernet FCS bytes hide
 // both following checksum stages. Publication stays on the original edge.
 reg[16:0]udp_src_sum,udp_dst_sum;
 reg[18:0]udp_pseudo_sum;
 reg[31:0]udp_total_sum;
 reg[15:0]udp_folded,ip_folded;
 always @(posedge clk)begin
  if(active && gmii_valid && preamble==8)begin
   if(count==34)begin
    udp_src_sum<={1'b0,sip[31:16]}+{1'b0,sip[15:0]};
    udp_dst_sum<={1'b0,dip[31:16]}+{1'b0,dip[15:0]};
   end
   if(count==40)udp_pseudo_sum<=({2'b0,udp_src_sum}+{2'b0,udp_dst_sum})+({3'b0,udp_len}+19'd17);
  end
  udp_total_sum<=udp_sum+{13'b0,udp_pseudo_sum};
  udp_folded<=fold(udp_total_sum);ip_folded<=fold(ip_sum);
 end
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n && !gmii_valid && active && !drop && !broken &&
  preamble==8 && count>=64 && etype==16'h0800 && ip_first==8'h45 &&
  ip_len>=28 && udp_len>=8 && ip_len==udp_len+20 && count>=14+ip_len+4)begin
  if(udp_folded!==fold(udp_sum+{16'd0,sip[31:16]}+{16'd0,sip[15:0]}+
      {16'd0,dip[31:16]}+{16'd0,dip[15:0]}+32'd17+udp_len))
   $fatal(1,"UDP checksum pipeline did not settle before frame publication");
  if(ip_folded!==fold(ip_sum))$fatal(1,"IPv4 checksum pipeline did not settle");
 end
`endif
 wire udp_ok=etype==16'h0800 && dm==LOCAL_MAC && ip_first==8'h45 && protocol==17 && ttl!=0 &&
  fragment[15]==0 && fragment[13:0]==0 && dip==LOCAL_IP && dport==LOCAL_PORT &&
  ip_len>=28 && ip_len<=1428 && udp_len>=8 && udp_len<=1408 && ip_len==udp_len+20 &&
  count>=14+ip_len+4 && ip_folded==16'hffff &&
  (udp_check==0 || udp_folded==16'hffff);
 wire arp_ok=etype==16'h0806 && (dm==LOCAL_MAC || dm==48'hffffffffffff) &&
  arp_fixed==64'h0001080006040001 && arp_dip==LOCAL_IP && arp_sha==sm;
 always @(posedge clk)begin
  // Payload offset zero is Ethernet offset 42 for fixed IPv4/UDP.
  if(frame_valid && payload_address<payload_length)
   payload_data<=mem[{1'b0,payload_address}+12'd42];
  else payload_data<=0;
  if(gmii_valid && active && !drop && preamble==8 && count<1518)mem[count]<=gmii_data;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   frame_valid<=0;frame_arp<=0;peer_mac<=0;peer_ip<=0;peer_port<=0;payload_length<=0;
   active<=0;drop<=0;broken<=0;preamble<=0;count<=0;crc<=32'hffffffff;previous<=0;
   dm<=0;sm<=0;arp_sha<=0;sip<=0;dip<=0;arp_sip<=0;arp_dip<=0;etype<=0;
   ip_len<=0;fragment<=0;sport<=0;dport<=0;udp_len<=0;udp_check<=0;
   arp_fixed<=0;ip_first<=0;protocol<=0;ttl<=0;ip_sum<=0;udp_sum<=0;
   good_udp<=0;good_arp<=0;busy_drops<=0;bad_fcs<=0;bad_header<=0;
  end else begin
   if(frame_valid&&frame_ready)frame_valid<=0;
   if(gmii_valid && !active)begin
    active<=1;drop<=frame_valid&&!frame_ready;
    if(frame_valid&&!frame_ready)busy_drops<=busy_drops+1'b1;
    preamble<=1;broken<=gmii_error || gmii_data!=8'h55;count<=0;
    crc<=32'hffffffff;ip_sum<=0;udp_sum<=0;previous<=0;
    dm<=0;sm<=0;arp_sha<=0;sip<=0;dip<=0;arp_sip<=0;arp_dip<=0;etype<=0;
    ip_len<=0;fragment<=0;sport<=0;dport<=0;udp_len<=0;udp_check<=0;
    arp_fixed<=0;ip_first<=0;protocol<=0;ttl<=0;
   end else if(gmii_valid && active)begin
    if(gmii_error)broken<=1;
    if(preamble<8)begin
     if(gmii_data!=(preamble==7 ? 8'hd5 : 8'h55))broken<=1;
     preamble<=preamble+1'b1;
    end else begin
     if(count>=1518)broken<=1;
     if(count!=2047)count<=count+1'b1;
     crc<=crc_byte(crc,gmii_data);previous<=gmii_data;
     if(count<6)dm<={dm[39:0],gmii_data};
     if(count>=6&&count<12)sm<={sm[39:0],gmii_data};
     if(count==12||count==13)etype<={etype[7:0],gmii_data};
     if(count==14)ip_first<=gmii_data;
     if(count==16||count==17)ip_len<={ip_len[7:0],gmii_data};
     if(count==20||count==21)fragment<={fragment[7:0],gmii_data};
     if(count==22)ttl<=gmii_data;
     if(count==23)protocol<=gmii_data;
     if(count>=26&&count<30)sip<={sip[23:0],gmii_data};
     if(count>=30&&count<34)dip<={dip[23:0],gmii_data};
     if(count==34||count==35)sport<={sport[7:0],gmii_data};
     if(count==36||count==37)dport<={dport[7:0],gmii_data};
     if(count==38||count==39)udp_len<={udp_len[7:0],gmii_data};
     if(count==40||count==41)udp_check<={udp_check[7:0],gmii_data};
     if(count>=14&&count<34&&count[0])ip_sum<=ip_sum+{16'd0,previous,gmii_data};
     if(count>=34 && (count<42 || count<34+udp_len))begin
      if(count[0])udp_sum<=udp_sum+{16'd0,previous,gmii_data};
      else if(count==33+udp_len)udp_sum<=udp_sum+{16'd0,gmii_data,8'd0};
     end
     if(count>=14&&count<22)arp_fixed<={arp_fixed[55:0],gmii_data};
     if(count>=22&&count<28)arp_sha<={arp_sha[39:0],gmii_data};
     if(count>=28&&count<32)arp_sip<={arp_sip[23:0],gmii_data};
     if(count>=38&&count<42)arp_dip<={arp_dip[23:0],gmii_data};
    end
   end else if(active)begin
    active<=0;
    if(!drop)begin
     if(broken||preamble!=8||count<64||count>1518)bad_header<=bad_header+1'b1;
     else if(crc!=32'hdebb20e3)bad_fcs<=bad_fcs+1'b1;
     else if(udp_ok)begin
      frame_valid<=1;frame_arp<=0;peer_mac<=sm;peer_ip<=sip;
      peer_port<=sport;payload_length<=udp_len-8;good_udp<=good_udp+1'b1;
     end else if(arp_ok)begin
      frame_valid<=1;frame_arp<=1;peer_mac<=sm;peer_ip<=arp_sip;
      peer_port<=0;payload_length<=0;good_arp<=good_arp+1'b1;
     end else bad_header<=bad_header+1'b1;
    end
   end
  end
 end
endmodule
`default_nettype wire
