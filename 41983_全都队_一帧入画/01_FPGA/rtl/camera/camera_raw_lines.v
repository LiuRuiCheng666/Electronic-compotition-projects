`timescale 1ns/1ps
`default_nettype none
// Two immutable RAW8 line banks replace the old full-frame RAW DDR round trip.
// CSI delivers four adjacent samples per valid word, with arbitrary valid gaps.
// The reader emits 960 continuous two-sample beats per 1920-pixel line.
module camera_raw_lines #(parameter W=1920,H=1080,FRAME_ID_BITS=16)(
 input wire source_clk,pair_clk,rst_n,source_vs,source_valid,
 input wire [31:0] source_raw4,
 output reg pair_vs,pair_de,output reg [15:0] pair_raw2,
 output reg [31:0] frame_id,output reg frame_error,
 output reg [31:0] overflow_frames
);
 localparam WORDS=W/4;
 wire source_reset_n,pair_reset_n;
 hdmi_reset_release u_source_release(.clk(source_clk),.rst_n(rst_n),.released_n(source_reset_n));
 hdmi_reset_release u_pair_release(.clk(pair_clk),.rst_n(rst_n),.released_n(pair_reset_n));
 (* syn_ramstyle="block_ram" *) reg [31:0] mem[0:1023];
 reg [FRAME_ID_BITS+10:0] meta[0:1]; // bounded line ownership; global input IDs are32-bit in mux
 reg [1:0] request,ack;
 (* async_reg="true",syn_preserve=1 *) reg [1:0] ack_meta,ack_sync,req_meta,req_sync;
 reg vs_d,armed,discard,write_bank;
 reg [8:0] write_word;reg [10:0] row;reg [FRAME_ID_BITS-1:0] source_frame;
 wire bank_free=request[write_bank]==ack_sync[write_bank];
 wire accept=source_valid&&armed&&!discard&&bank_free&&row<H;
 always @(posedge source_clk)if(accept)mem[{write_bank,write_word}]<=source_raw4;
 always @(posedge source_clk or negedge source_reset_n)begin
  if(!source_reset_n)begin
   request<=0;ack_meta<=0;ack_sync<=0;vs_d<=0;armed<=0;discard<=0;
   write_bank<=0;write_word<=0;row<=0;source_frame<=0;meta[0]<=0;meta[1]<=0;overflow_frames<=0;
  end else begin
   ack_meta<=ack;ack_sync<=ack_meta;vs_d<=source_vs;
   if(source_vs&&!vs_d)begin
    armed<=1;discard<=0;write_word<=0;row<=0;source_frame<=source_frame+1'b1;
   end else if(source_valid&&armed&&!discard)begin
    if(!bank_free||row>=H)begin discard<=1;overflow_frames<=overflow_frames+1'b1;end
    else if(write_word==WORDS-1)begin
     meta[write_bank]<={source_frame,row};request[write_bank]<=~request[write_bank];
     write_bank<=~write_bank;write_word<=0;row<=row+1'b1;
    end else write_word<=write_word+1'b1;
   end
  end
 end
 localparam WAIT=0,HEADER=1,LOAD=2,PIXELS=3,GAP=4,DECODE=5;
 reg [2:0] state;reg read_bank,half,seen;
 reg [8:0] read_word;reg [31:0] word_q;
 reg [2:0] gap_count;reg [10:0] expected_row;
 (* syn_preserve=1,syn_keep=1 *)reg [FRAME_ID_BITS+10:0] line_meta;
 wire read_enable=state==LOAD||(state==PIXELS&&half&&read_word!=WORDS-1);
 wire [9:0] read_address=state==LOAD?{read_bank,9'd0}:{read_bank,(read_word+9'd1)};
 always @(posedge pair_clk)if(read_enable)word_q<=mem[read_address];
 always @(posedge pair_clk or negedge pair_reset_n)begin
  if(!pair_reset_n)begin
   req_meta<=0;req_sync<=0;ack<=0;state<=WAIT;read_bank<=0;half<=0;seen<=0;
   read_word<=0;pair_vs<=0;pair_de<=0;pair_raw2<=0;frame_id<=0;frame_error<=0;gap_count<=0;expected_row<=0;line_meta<=0;
  end else begin
   req_meta<=request;req_sync<=req_meta;pair_de<=0;
   case(state)
    WAIT:if(req_sync[read_bank]!=ack[read_bank])begin
     line_meta<=meta[read_bank];state<=DECODE;
    end
    DECODE:begin
     read_word<=0;half<=0;
     if(!seen||line_meta[FRAME_ID_BITS+10:11]!=frame_id[FRAME_ID_BITS-1:0])begin
      frame_id<={{(32-FRAME_ID_BITS){1'b0}},line_meta[FRAME_ID_BITS+10:11]};frame_error<=line_meta[10:0]!=0;seen<=1;
      pair_vs<=1;gap_count<=4;expected_row<=1;state<=HEADER;
     end else begin
      if(line_meta[10:0]!=expected_row)frame_error<=1;
      expected_row<=line_meta[10:0]+1'b1;state<=LOAD;
     end
    end
    HEADER:if(gap_count==0)begin pair_vs<=0;state<=LOAD;end else gap_count<=gap_count-1'b1;
    LOAD:state<=PIXELS;
    PIXELS:begin
     pair_de<=1;pair_raw2<=half?word_q[31:16]:word_q[15:0];half<=~half;
     if(half)begin
      read_word<=read_word+1'b1;
      if(read_word==WORDS-1)begin ack[read_bank]<=req_sync[read_bank];read_bank<=~read_bank;gap_count<=4;state<=GAP;end
     end
    end
    GAP:if(gap_count==0)state<=WAIT;else gap_count<=gap_count-1'b1;
    default:state<=WAIT;
   endcase
  end
 end
endmodule
`default_nettype wire
