`timescale 1ns/1ps
`default_nettype none
// Generic raw-UDP transmitter. ANET encoding/CRC is supplied by the mailbox.
// Payload RAM has one-cycle synchronous read latency. Untagged IPv4 only;
// IPv4 UDP checksum=0, with generated IP checksum and Ethernet FCS.
module a_gmii_udp_tx #(
 parameter[47:0]LOCAL_MAC=48'h02000060f225,
 parameter[31:0]LOCAL_IP=32'hc0a80002,
 parameter[15:0]LOCAL_PORT=16'd40000
)(
 input wire clk,rst_n,start,arp_reply,input wire[47:0]peer_mac,
 input wire[31:0]peer_ip,input wire[15:0]peer_port,payload_length,
 output reg[10:0]payload_address,input wire[7:0]payload_data,
 output wire busy,output reg done,output reg[7:0]gmii_data,output wire gmii_valid
);
 localparam IDLE=0,PREAMBLE=1,BODY=2,FCS=3,IFG=4;
 reg[2:0]state;reg[15:0]pos,n,port;reg ar;
 reg[47:0]pm;reg[31:0]pi,eth_crc;
 wire[15:0]ip_len=16'd28+n,udp_len=16'd8+n;
 wire[15:0]body_length=ar||(n<18) ? 16'd60 : 16'd42+n;
 function[31:0]crc_byte;
  input[31:0]c;input[7:0]d;reg[31:0]q;integer i;
  begin q=c^{24'd0,d};for(i=0;i<8;i=i+1)q=q[0] ? (q>>1)^32'hedb88320 : q>>1;crc_byte=q;end
 endfunction
 function[15:0]complement_sum;
  input[31:0]s;reg[16:0]a,b;
  begin a={1'b0,s[15:0]}+{1'b0,s[31:16]};b={1'b0,a[15:0]}+a[16];complement_sum=~(b[15:0]+b[16]);end
 endfunction
 wire[15:0]ip_checksum=complement_sum(32'h4500+ip_len+32'h4000+32'h4011+
  {16'd0,LOCAL_IP[31:16]}+{16'd0,LOCAL_IP[15:0]}+{16'd0,pi[31:16]}+{16'd0,pi[15:0]});
 function[7:0]body_byte;
  input[15:0]i;
  begin
   body_byte=0;
   if(i<6)body_byte=pm>>(8*(5-i));
   else if(i<12)body_byte=LOCAL_MAC>>(8*(11-i));
   else if(i==12)body_byte=8'h08;
   else if(i==13)body_byte=ar ? 8'h06 : 8'h00;
   else if(ar)begin
    case(i)
     15:body_byte=1;16:body_byte=8'h08;18:body_byte=6;19:body_byte=4;21:body_byte=2;
     default:begin
      if(i>=22&&i<28)body_byte=LOCAL_MAC>>(8*(27-i));
      else if(i>=28&&i<32)body_byte=LOCAL_IP>>(8*(31-i));
      else if(i>=32&&i<38)body_byte=pm>>(8*(37-i));
      else if(i>=38&&i<42)body_byte=pi>>(8*(41-i));
     end
    endcase
   end else begin
    case(i)
     14:body_byte=8'h45;16:body_byte=ip_len[15:8];17:body_byte=ip_len[7:0];
     20:body_byte=8'h40;22:body_byte=64;23:body_byte=17;
     24:body_byte=ip_checksum[15:8];25:body_byte=ip_checksum[7:0];
     34:body_byte=LOCAL_PORT[15:8];35:body_byte=LOCAL_PORT[7:0];
     36:body_byte=port[15:8];37:body_byte=port[7:0];
     38:body_byte=udp_len[15:8];39:body_byte=udp_len[7:0];
     default:begin
      if(i>=26&&i<30)body_byte=LOCAL_IP>>(8*(29-i));
      else if(i>=30&&i<34)body_byte=pi>>(8*(33-i));
      else if(i>=42&&i<42+n)body_byte=payload_data;
     end
    endcase
   end
  end
 endfunction
 assign busy=state!=IDLE;
 assign gmii_valid=state==PREAMBLE||state==BODY||state==FCS;
 always @*begin
  payload_address=0;
  if(state==BODY&&!ar&&pos>=42&&pos+1<42+n)payload_address=pos-41;
  gmii_data=0;
  if(state==PREAMBLE)gmii_data=pos==7 ? 8'hd5 : 8'h55;
  else if(state==BODY)gmii_data=body_byte(pos);
  else if(state==FCS)gmii_data=(~eth_crc)>>(8*pos);
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;pos<=0;n<=0;port<=0;ar<=0;pm<=0;pi<=0;eth_crc<=32'hffffffff;done<=0;end
  else begin
   done<=0;
   case(state)
    IDLE:if(start&&(arp_reply||payload_length<=1400))begin
     pm<=peer_mac;pi<=peer_ip;port<=peer_port;n<=payload_length;ar<=arp_reply;
     pos<=0;eth_crc<=32'hffffffff;state<=PREAMBLE;
    end
    PREAMBLE:if(pos==7)begin state<=BODY;pos<=0;end else pos<=pos+1'b1;
    BODY:begin eth_crc<=crc_byte(eth_crc,gmii_data);if(pos==body_length-1)begin state<=FCS;pos<=0;end else pos<=pos+1'b1;end
    FCS:if(pos==3)begin state<=IFG;pos<=0;end else pos<=pos+1'b1;
    IFG:if(pos==11)begin state<=IDLE;done<=1;end else pos<=pos+1'b1;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
