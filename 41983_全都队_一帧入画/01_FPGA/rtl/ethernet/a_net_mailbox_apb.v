`timescale 1ns/1ps
`default_nettype none
// A-owned dual-clock packet mailbox. Not a MAC or a DDR DMA controller.
// RX input MUST already have passed Ethernet/IP/UDP/ANET validation.
// Common async reset, independently synchronized deassertion. Payload RAM is
// never reset; ownership gates all accesses to prevent exposing stale bytes.
module a_net_mailbox_apb #(parameter [15:0] BASE=16'h1000,parameter integer DIRECT_RX_METADATA=0)(
 input wire reset_n,net_clk,cpu_clk,
 input wire rx_desc_valid,output wire rx_desc_ready,
 input wire[47:0]rx_peer_mac,input wire[31:0]rx_peer_ip,input wire[15:0]rx_peer_port,
 input wire[7:0]rx_op,input wire[31:0]rx_session,rx_sequence,rx_offset,rx_total,
 input wire[15:0]rx_length,
 input wire rx_valid,rx_last,rx_error,input wire[7:0]rx_data,output wire rx_ready,
 output wire tx_desc_valid,input wire tx_desc_ready,
 output reg[47:0]tx_peer_mac,output reg[31:0]tx_peer_ip,output reg[15:0]tx_peer_port,tx_length,
 input wire[10:0]tx_payload_address,output wire[7:0]tx_payload_data,
 input wire tx_done,tx_done_error,
 input wire[15:0]PADDR,input wire PSEL,PENABLE,PWRITE,input wire[31:0]PWDATA,
 output reg[31:0]PRDATA,output reg PREADY,PSLVERROR,output wire irq
);
 (* async_reg="true" *)reg[2:0]nr=0,cr=0;
 always @(posedge net_clk or negedge reset_n)if(!reset_n)nr<=0;else nr<={nr[1:0],1'b1};
 always @(posedge cpu_clk or negedge reset_n)if(!reset_n)cr<=0;else cr<={cr[1:0],1'b1};
 wire net_reset_n=nr[2],cpu_reset_n=cr[2];
 reg[31:0]rx_mem[0:511],tx_mem[0:511];
 localparam RX_IDLE=0,RX_FILL=1,RX_WAIT=2,RX_DROP=3;
 reg[1:0]rx_state;reg[10:0]rx_pos;reg[31:0]rx_word;reg rx_bad;
 reg rx_request,rx_acknowledge;
 (* async_reg="true" *)reg[2:0]rx_ack_sync,rx_req_sync;
 reg[47:0]n_mac;reg[31:0]n_ip,n_sid,n_seq,n_off,n_total,n_token;
 reg[15:0]n_port,n_len;reg[7:0]n_op;
 reg cpu_rx_valid;reg[31:0]rx_last_release_token;
 reg[47:0]held_c_mac;wire[47:0]c_mac=DIRECT_RX_METADATA!=0?n_mac:held_c_mac;
 reg[31:0]held_c_ip;wire[31:0]c_ip=DIRECT_RX_METADATA!=0?n_ip:held_c_ip;
 reg[31:0]held_c_sid;wire[31:0]c_sid=DIRECT_RX_METADATA!=0?n_sid:held_c_sid;
 reg[31:0]held_c_seq;wire[31:0]c_seq=DIRECT_RX_METADATA!=0?n_seq:held_c_seq;
 reg[31:0]held_c_off;wire[31:0]c_off=DIRECT_RX_METADATA!=0?n_off:held_c_off;
 reg[31:0]held_c_total;wire[31:0]c_total=DIRECT_RX_METADATA!=0?n_total:held_c_total;
 reg[31:0]held_c_token;wire[31:0]c_token=DIRECT_RX_METADATA!=0?n_token:held_c_token;
 reg[15:0]held_c_port;wire[15:0]c_port=DIRECT_RX_METADATA!=0?n_port:held_c_port;
 reg[15:0]held_c_len;wire[15:0]c_len=DIRECT_RX_METADATA!=0?n_len:held_c_len;
 reg[7:0]held_c_op;wire[7:0]c_op=DIRECT_RX_METADATA!=0?n_op:held_c_op;

 reg[31:0]rx_next_word;
 always @*begin
  rx_next_word=rx_pos[1:0]==0 ? 32'd0 : rx_word;
  rx_next_word[rx_pos[1:0]*8+:8]=rx_data;
 end
 assign rx_desc_ready=net_reset_n && rx_state==RX_IDLE && rx_length<=1368;
 assign rx_ready=net_reset_n && (rx_state==RX_FILL||rx_state==RX_DROP);
 always @(posedge net_clk)begin
  if(net_reset_n && rx_state==RX_FILL && rx_valid && rx_ready && (rx_pos[1:0]==3||rx_last))
   rx_mem[rx_pos[10:2]]<=rx_next_word;
 end
 always @(posedge net_clk or negedge net_reset_n)begin
  if(!net_reset_n)begin
   rx_state<=RX_IDLE;rx_pos<=0;rx_word<=0;rx_bad<=0;rx_request<=0;rx_ack_sync<=0;
   n_mac<=0;n_ip<=0;n_port<=0;n_op<=0;n_sid<=0;n_seq<=0;n_off<=0;n_total<=0;n_len<=0;n_token<=0;
  end else begin
   rx_ack_sync<={rx_ack_sync[1:0],rx_acknowledge};
   case(rx_state)
    RX_IDLE:if(rx_desc_valid&&rx_desc_ready)begin
     n_mac<=rx_peer_mac;n_ip<=rx_peer_ip;n_port<=rx_peer_port;n_op<=rx_op;
     n_sid<=rx_session;n_seq<=rx_sequence;n_off<=rx_offset;n_total<=rx_total;n_len<=rx_length;
     n_token<=n_token==32'hffffffff ? 32'd1 : n_token+1'b1;
     rx_pos<=0;rx_word<=0;rx_bad<=0;
     if(rx_length==0)begin rx_request<=~rx_request;rx_state<=RX_WAIT;end else rx_state<=RX_FILL;
    end
    RX_FILL:if(rx_valid&&rx_ready)begin
     rx_word<=rx_next_word;rx_bad<=rx_bad||rx_error;
     if(rx_last)begin
      if(rx_pos+1==n_len&&!rx_bad&&!rx_error)begin rx_request<=~rx_request;rx_state<=RX_WAIT;end
      else rx_state<=RX_IDLE;
     end else if(rx_pos+1>=n_len)rx_state<=RX_DROP;
     else rx_pos<=rx_pos+1'b1;
    end
    RX_WAIT:if(rx_ack_sync[2]==rx_request)rx_state<=RX_IDLE;
    RX_DROP:if(rx_valid&&rx_last)rx_state<=RX_IDLE;
   endcase
  end
 end
 // Direct metadata mode exposes the net-owned immutable descriptor only after
 // the three-stage request event. RX_WAIT holds every n_* word until CPU ACK;
 // CPU must finish all descriptor reads before release. Payload RAM is unchanged.
`ifndef SYNTHESIS
 reg[279:0]previous_descriptor;reg previous_valid;
 always @(posedge cpu_clk)begin
  if(DIRECT_RX_METADATA!=0 && cpu_reset_n && previous_valid && cpu_rx_valid &&
     previous_descriptor!={n_mac,n_ip,n_sid,n_seq,n_off,n_total,n_token,n_port,n_len,n_op})
   $fatal(1,"Direct RX descriptor changed during CPU ownership");
  previous_descriptor<={n_mac,n_ip,n_sid,n_seq,n_off,n_total,n_token,n_port,n_len,n_op};
  previous_valid<=cpu_reset_n && cpu_rx_valid;
 end
`endif
 // TX CPU side owns RAM until an explicit submit. Metadata and RAM then remain
 // immutable through descriptor acceptance AND network-engine completion.
 reg[47:0]c_tx_mac;reg[31:0]c_tx_ip,tx_token,tx_done_token;
 reg[15:0]c_tx_port,c_tx_len;reg[8:0]tx_words;
 reg tx_building,cpu_tx_busy,cpu_tx_done,tx_request,tx_complete;
 reg tx_complete_error;
 (* async_reg="true" *)reg[2:0]tx_req_sync,tx_complete_sync;
 localparam TX_IDLE=0,TX_REQUEST=1,TX_ACTIVE=2;
 reg[1:0]tx_state;reg[31:0]tx_word;reg[1:0]tx_lane;reg tx_read_valid;
 assign tx_desc_valid=net_reset_n&&tx_state==TX_REQUEST;
 assign tx_payload_data=net_reset_n&&tx_read_valid?(tx_word>>(tx_lane*8)):8'd0;
 always @(posedge net_clk)begin
  tx_word<=tx_mem[tx_payload_address[10:2]];
  tx_lane<=tx_payload_address[1:0];
  tx_read_valid<=net_reset_n&&tx_state!=TX_IDLE&&tx_payload_address<tx_length;
 end
 always @(posedge net_clk or negedge net_reset_n)begin
  if(!net_reset_n)begin
   tx_req_sync<=0;tx_state<=TX_IDLE;tx_complete<=0;tx_complete_error<=0;
   tx_peer_mac<=0;tx_peer_ip<=0;tx_peer_port<=0;tx_length<=0;
  end else begin
   tx_req_sync<={tx_req_sync[1:0],tx_request};
   case(tx_state)
    TX_IDLE:if(tx_req_sync[2]!=tx_complete)begin
     tx_peer_mac<=c_tx_mac;tx_peer_ip<=c_tx_ip;tx_peer_port<=c_tx_port;tx_length<=c_tx_len;
     tx_state<=TX_REQUEST;
    end
    TX_REQUEST:if(tx_desc_ready)begin
     if(tx_done)begin tx_complete<=tx_req_sync[2];tx_complete_error<=tx_done_error;tx_state<=TX_IDLE;end
     else tx_state<=TX_ACTIVE;
    end
    TX_ACTIVE:if(tx_done)begin tx_complete<=tx_req_sync[2];tx_complete_error<=tx_done_error;tx_state<=TX_IDLE;end
    default:tx_state<=TX_IDLE;
   endcase
  end
 end
 wire[15:0]rel=PADDR-BASE;
 wire in_window=PADDR>=BASE && {1'b0,PADDR}<{1'b0,BASE}+17'h01000;
 wire ram_read=rel>=16'h0800&&rel<16'h1000;
 wire[15:0]rx_padded_length=(c_len+16'd3)&16'hfffc;
 wire ram_allowed=cpu_rx_valid && (rel-16'h0800)<rx_padded_length;
 reg ram_pending;reg[31:0]ram_value,errors;
 wire access=PSEL&&PENABLE;
 wire transfer=access&&PREADY;
 wire reg_write=transfer&&PWRITE&&!PSLVERROR;
 always @*begin
  PRDATA=0;PREADY=1;PSLVERROR=0;
  if(!cpu_reset_n)PREADY=0;
  else if(!in_window||PADDR[1:0]!=0)PSLVERROR=1;
  else if(ram_read)begin
   if(PWRITE||!ram_allowed)PSLVERROR=1;
   else begin PRDATA=ram_value;PREADY=ram_pending;end
  end else begin
   case(rel)
    16'h0000:begin PRDATA=32'h414e4d01;if(PWRITE)PSLVERROR=1;end
    16'h0004:begin PRDATA={27'd0,(errors!=0),cpu_tx_done,tx_building,cpu_tx_busy,cpu_rx_valid};if(PWRITE)PSLVERROR=1;end
    16'h0008:begin PRDATA=c_token;if(PWRITE)PSLVERROR=1;end
    16'h000c:if(!PWRITE||!cpu_rx_valid||PWDATA!=c_token)PSLVERROR=1;
    16'h0010:begin PRDATA=c_ip;if(PWRITE)PSLVERROR=1;end
    16'h0014:begin PRDATA={16'd0,c_port};if(PWRITE)PSLVERROR=1;end
    16'h0018:begin PRDATA={c_len,8'd0,c_op};if(PWRITE)PSLVERROR=1;end
    16'h001c:begin PRDATA=c_sid;if(PWRITE)PSLVERROR=1;end
    16'h0020:begin PRDATA=c_seq;if(PWRITE)PSLVERROR=1;end
    16'h0024:begin PRDATA=c_off;if(PWRITE)PSLVERROR=1;end
    16'h0028:begin PRDATA=c_total;if(PWRITE)PSLVERROR=1;end
    16'h002c:begin PRDATA=c_mac[31:0];if(PWRITE)PSLVERROR=1;end
    16'h0030:begin PRDATA={16'd0,c_mac[47:32]};if(PWRITE)PSLVERROR=1;end
    16'h0034:begin PRDATA=rx_last_release_token;if(PWRITE)PSLVERROR=1;end
    16'h0040:begin PRDATA=c_tx_ip;if(PWRITE&&cpu_tx_busy)PSLVERROR=1;end
    16'h0044:begin PRDATA={16'd0,c_tx_port};if(PWRITE&&(cpu_tx_busy||PWDATA[31:16]!=0))PSLVERROR=1;end
    16'h0048:begin PRDATA=c_tx_mac[31:0];if(PWRITE&&cpu_tx_busy)PSLVERROR=1;end
    16'h004c:begin PRDATA={16'd0,c_tx_mac[47:32]};if(PWRITE&&(cpu_tx_busy||PWDATA[31:16]!=0))PSLVERROR=1;end
    16'h0050:begin PRDATA={16'd0,c_tx_len};if(PWRITE&&(cpu_tx_busy||PWDATA<32||PWDATA>1400))PSLVERROR=1;end
    16'h0054:if(!PWRITE||cpu_tx_busy||!tx_building||tx_words>=((c_tx_len+3)>>2))PSLVERROR=1;
    16'h0058:if(!PWRITE||cpu_tx_busy||!tx_building||PWDATA!=tx_token||tx_words!=((c_tx_len+3)>>2))PSLVERROR=1;
    16'h005c:begin PRDATA=tx_token;if(PWRITE)PSLVERROR=1;end
    16'h0060:begin PRDATA=tx_done_token;if(PWRITE)PSLVERROR=1;end
    16'h0064:PRDATA=errors;
    16'h0068:if(!PWRITE||PWDATA!=1)PSLVERROR=1;
    default:PSLVERROR=1;
   endcase
  end
 end
 wire[31:0]error_clear=(reg_write&&rel==16'h0064)?PWDATA:32'd0;
 wire tx_completed=cpu_tx_busy && tx_complete_sync[2]==tx_request;
 wire[31:0]error_set=(transfer&&PSLVERROR?32'd1:0)|(tx_completed&&tx_complete_error?32'h40:0);
 always @(posedge cpu_clk)begin
  if(cpu_reset_n&&access&&!PWRITE&&ram_read&&ram_allowed&&!ram_pending)ram_value<=rx_mem[rel[10:2]];
  if(cpu_reset_n&&reg_write&&rel==16'h0054)tx_mem[tx_words]<=PWDATA;
 end
 always @(posedge cpu_clk or negedge cpu_reset_n)begin
  if(!cpu_reset_n)begin
   rx_req_sync<=0;rx_acknowledge<=0;cpu_rx_valid<=0;
   held_c_mac<=0;held_c_ip<=0;held_c_port<=0;held_c_op<=0;held_c_sid<=0;held_c_seq<=0;held_c_off<=0;held_c_total<=0;held_c_len<=0;held_c_token<=0;rx_last_release_token<=0;
   tx_complete_sync<=0;tx_request<=0;cpu_tx_busy<=0;cpu_tx_done<=0;tx_building<=0;
   c_tx_mac<=0;c_tx_ip<=0;c_tx_port<=0;c_tx_len<=0;tx_words<=0;tx_token<=0;tx_done_token<=0;errors<=0;ram_pending<=0;
  end else begin
   rx_req_sync<={rx_req_sync[1:0],rx_request};tx_complete_sync<={tx_complete_sync[1:0],tx_complete};
   errors<=(errors&~error_clear)|error_set;
   if(!access||transfer)ram_pending<=0;
   else if(ram_read&&ram_allowed&&!PWRITE)ram_pending<=1;
   if(!cpu_rx_valid&&rx_req_sync[2]!=rx_acknowledge)begin
    held_c_mac<=n_mac;held_c_ip<=n_ip;held_c_port<=n_port;held_c_op<=n_op;held_c_sid<=n_sid;held_c_seq<=n_seq;held_c_off<=n_off;held_c_total<=n_total;held_c_len<=n_len;held_c_token<=n_token;
    cpu_rx_valid<=1;
   end
   if(tx_completed)begin cpu_tx_busy<=0;cpu_tx_done<=1;tx_done_token<=tx_token;end
   if(reg_write)case(rel)
    16'h000c:begin cpu_rx_valid<=0;rx_acknowledge<=rx_req_sync[2];rx_last_release_token<=c_token;end
    16'h0040:c_tx_ip<=PWDATA;
    16'h0044:c_tx_port<=PWDATA[15:0];
    16'h0048:c_tx_mac[31:0]<=PWDATA;
    16'h004c:c_tx_mac[47:32]<=PWDATA[15:0];
    16'h0050:begin c_tx_len<=PWDATA[15:0];tx_words<=0;tx_building<=1;cpu_tx_done<=0;tx_token<=tx_token==32'hffffffff ? 32'd1 : tx_token+1'b1;end
    16'h0054:tx_words<=tx_words+1'b1;
    16'h0058:begin tx_request<=~tx_request;cpu_tx_busy<=1;tx_building<=0;cpu_tx_done<=0;end
    16'h0068:cpu_tx_done<=0;
   endcase
  end
 end
 assign irq=cpu_rx_valid||cpu_tx_done||(errors!=0);
endmodule
`default_nettype wire
