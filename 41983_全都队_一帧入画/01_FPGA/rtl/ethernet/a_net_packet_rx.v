`timescale 1ns/1ps
`default_nettype none
// A-owned ANET datagram validator and one immutable packet buffer.
// Upstream supplies UDP payload bytes AFTER MAC/IP/UDP verification.
// This block is NOT a MAC, an IP stack, or permission to write shared DDR.
module a_net_packet_rx #(
 parameter integer STORE_PAYLOAD=1,DIRECT_METADATA=0,MAX_BYTES=1400,MAX_FRAME_BYTES=8388608
)(
 input wire clk,rst_n,
 input wire rx_valid,rx_first,rx_last,rx_error,input wire [7:0] rx_data,
 output reg packet_valid,input wire packet_ready,
 output wire [7:0] packet_op,output wire [31:0] packet_session,packet_sequence,
 output wire [31:0] packet_offset,packet_total,output wire [15:0] packet_length,
 input wire [10:0] payload_address,output wire [7:0] payload_data,
 output reg [31:0] good_packets,dropped_busy,bad_crc,bad_format
);
 reg [255:0] header;
 // The endpoint holds the verified raw UDP frame until packet_ready. In
 // DIRECT_METADATA mode this header is already immutable while valid, so
 // copying its 152 metadata bits into another register bank is redundant.
 reg [7:0] held_packet_op;
 reg [31:0] held_packet_session,held_packet_sequence,held_packet_offset,held_packet_total;
 reg [15:0] held_packet_length;
 assign packet_op=DIRECT_METADATA?header[215:208]:held_packet_op;
 assign packet_session=DIRECT_METADATA?header[191:160]:held_packet_session;
 assign packet_sequence=DIRECT_METADATA?header[159:128]:held_packet_sequence;
 assign packet_offset=DIRECT_METADATA?header[127:96]:held_packet_offset;
 assign packet_total=DIRECT_METADATA?header[95:64]:held_packet_total;
 assign packet_length=DIRECT_METADATA?header[63:48]:held_packet_length;
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n && DIRECT_METADATA!=0 && packet_valid && !packet_ready && rx_valid)
  $fatal(1,"DIRECT_METADATA requires upstream frame lease until packet_ready");
`endif
 reg [15:0] position;
 reg [31:0] crc;
 reg active,dropping,malformed;
 function [31:0] crc_byte;
  input [31:0] c;input [7:0] d;reg [31:0] q;integer i;
  begin
   q=c^{24'd0,d};
   for(i=0;i<8;i=i+1)q=q[0]?(q>>1)^32'hedb88320:(q>>1);
   crc_byte=q;
  end
 endfunction
 wire [15:0] idx=rx_first?16'd0:position;
 wire [31:0] old_crc=rx_first?32'hffffffff:crc;
 wire [31:0] next_crc=(idx<28 || idx>=32)?crc_byte(old_crc,rx_data):old_crc;
 wire [255:0] next_header=(idx<32)?{header[247:0],rx_data}:header;
 wire is_dropping=rx_first?(packet_valid&&!packet_ready):dropping;
 wire error_seen=rx_first?rx_error:(malformed||rx_error);
 wire [7:0] op=next_header[215:208];
 wire [15:0] length=next_header[63:48];
 wire [31:0] offset=next_header[127:96],total=next_header[95:64];
 wire valid_op=op==1||op==2||op==8'h10||op==8'h11||op==8'h12||op==8'h13||op==8'h14||op==8'h20;
 wire is_data=op==8'h11||op==8'h20;
 wire data_bounds=!is_data || (length!=0 && total!=0 && total<=MAX_FRAME_BYTES &&
                             ({1'b0,offset}+length)<={1'b0,total});
 wire format_ok=idx>=31 && idx<MAX_BYTES && next_header[255:224]==32'h414e4554 &&
   next_header[223:216]==1 && next_header[207:192]==0 && next_header[47:32]==0 &&
   valid_op && length==idx-31 && data_bounds && !error_seen;
 generate if(STORE_PAYLOAD!=0)begin:G_PAYLOAD_STORAGE
 reg [7:0] payload_ram[0:2047];reg [7:0] payload_q;
 always @(posedge clk)begin
  payload_q<=payload_ram[payload_address];
  if(rx_valid && (active||rx_first) && !is_dropping && idx>=32 && idx<MAX_BYTES)
   payload_ram[idx-32]<=rx_data;
 end
 assign payload_data=payload_q;
 end else begin:G_VALIDATION_ONLY
 assign payload_data=8'd0;
 end endgenerate
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   header<=0;position<=0;crc<=32'hffffffff;active<=0;dropping<=0;malformed<=0;
   packet_valid<=0;held_packet_op<=0;held_packet_session<=0;held_packet_sequence<=0;
   held_packet_offset<=0;held_packet_total<=0;held_packet_length<=0;
   good_packets<=0;dropped_busy<=0;bad_crc<=0;bad_format<=0;
  end else begin
   if(packet_valid&&packet_ready)packet_valid<=0;
   if(rx_valid && (active||rx_first))begin
    if(rx_first)begin
     if(active&&!dropping)bad_format<=bad_format+1'b1;
     dropping<=packet_valid&&!packet_ready;
     if(packet_valid&&!packet_ready)dropped_busy<=dropped_busy+1'b1;
    end
    active<=!rx_last;
    malformed<=error_seen;
    header<=next_header;
    // Saturate so a malformed oversized packet cannot wrap the write index.
    position<=(idx==16'hffff) ? idx : idx+1'b1;
    crc<=next_crc;
    if(rx_last && !is_dropping)begin
     if(!format_ok)bad_format<=bad_format+1'b1;
     else if((next_crc^32'hffffffff)!=next_header[31:0])bad_crc<=bad_crc+1'b1;
     else begin
      packet_valid<=1;held_packet_op<=op;held_packet_session<=next_header[191:160];
      held_packet_sequence<=next_header[159:128];held_packet_offset<=offset;
      held_packet_total<=total;held_packet_length<=length;good_packets<=good_packets+1'b1;
     end
    end
   end
  end
 end
endmodule
`default_nettype wire
