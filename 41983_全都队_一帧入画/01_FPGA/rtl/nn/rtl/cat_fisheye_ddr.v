`timescale 1ns/1ps
`default_nettype none
// Exact original 2D geometry; continuous coordinate pipeline, 4x32B cache,
// whole-pixel sampling, and an independent four-beat DDR write queue.
module cat_fisheye_ddr #(parameter integer W=640,H=480,STRENGTH=2,TIMEOUT_BITS=24)(
 input wire clk,rst_n,start,input wire [31:0] source_base,dest_base,
 output reg busy,done,passed,failed,output reg [31:0] cycles,read_count,
 output wire [31:0] araddr,output wire [7:0] arlen,output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready,
 output wire [31:0] awaddr,output wire [7:0] awlen,output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
 input wire [1:0] bresp,input wire bvalid,output wire bready
);
 localparam IDLE=0,GET=1,LOOK=2,AR=3,READ=4,FINISH=5,FAIL=6,DRAIN_AR=7,DRAIN_R=8;
 localparam integer PIXELS=W*H,COORD_DEPTH=16;
 reg [3:0] state,last_state;reg [31:0] src;
 reg [11:0] produce_x,produce_y;reg [19:0] produced,consumed;
 reg [4:0] reserved,coord_count;reg [3:0] cp_write,cp_read;
 reg [23:0] coord_mem[0:15];
 wire map_valid;wire [11:0] sx,sy;
 wire map_issue=busy&&!failed&&produced<PIXELS&&reserved<COORD_DEPTH;
 wire coord_pop=state==GET&&coord_count!=0;
 wire [23:0] coord_head=coord_mem[cp_read];
 cat_fisheye_map #(.W(W),.H(H),.STRENGTH(STRENGTH)) u_map(.clk(clk),.rst_n(rst_n),.in_valid(map_issue),.x(produce_x),.y(produce_y),.out_valid(map_valid),.sx(sx),.sy(sy));
 reg [31:0] pixel_addr,miss_addr;reg [31:0] tags[0:3];reg [255:0] cache[0:3];reg [3:0] cache_valid;
 reg [1:0] victim,fill_way;reg read_half;reg [127:0] first_beat;
 reg hit0,hit1;reg [1:0] index0,index1;reg [255:0] data0,data1;integer i;
 wire [31:0] line_addr={pixel_addr[31:5],5'd0};wire needs_second=pixel_addr[4:0]>29;
 always @*begin
  hit0=0;hit1=0;index0=0;index1=0;data0=0;data1=0;
  for(integer k=0;k<4;k=k+1)begin
   if(cache_valid[k]&&tags[k]==line_addr)begin hit0=1;index0=k;data0=cache[k];end
   if(cache_valid[k]&&tags[k]==line_addr+32)begin hit1=1;index1=k;data1=cache[k];end
  end
 end
 wire [511:0] pixel_window={data1,data0}>>(pixel_addr[4:0]*8);
 wire [23:0] pixel=pixel_window[23:0];
 reg [151:0] pack_data;reg [4:0] pack_bytes;
 wire [151:0] appended=pack_data|({128'd0,pixel}<<(pack_bytes*8));
 wire emit_word=pack_bytes+3>=16;
 wire writer_ready,writer_done,writer_failed,writer_progress;
 wire pixel_take=state==LOOK&&hit0&&(!needs_second||hit1)&&(!emit_word||writer_ready);
 wire frame_start=state==IDLE&&start&&!failed;
 cat_fisheye_write_queue #(.TOTAL_BYTES(W*H*3),.TIMEOUT_BITS(TIMEOUT_BITS)) u_writer(
  .clk(clk),.rst_n(rst_n),.frame_start(frame_start),.base(dest_base),.abort(failed),
  .push(pixel_take&&emit_word),.data(appended[127:0]),.push_ready(writer_ready),.producer_done(consumed==PIXELS),
  .done(writer_done),.failed(writer_failed),.progress(writer_progress),
  .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
  .bresp(bresp),.bvalid(bvalid),.bready(bready));
 function [31:0] offset_rgb(input [11:0] a,b);
  reg [31:0] row,col;
  begin row=b;col=a;
   if(W==640)offset_rgb=(row<<11)-(row<<7)+(col<<1)+col;
   else offset_rgb=row*(W*3)+(col<<1)+col;
  end
 endfunction
 assign araddr=miss_addr;assign arlen=1;assign arvalid=state==AR||state==DRAIN_AR;assign rready=state==READ||state==DRAIN_R;
 reg [TIMEOUT_BITS-1:0] watchdog;
 wire progress=state!=last_state||coord_pop||pixel_take||writer_progress||(arvalid&&arready)||(rvalid&&rready);
 wire timeout_hit=busy&& (&watchdog)&&!progress;
 // Reserve space before launch, including all five in-flight map stages.
 always @(posedge clk)if(map_valid)coord_mem[cp_write]<={sy,sx};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin produced<=0;produce_x<=0;produce_y<=0;reserved<=0;coord_count<=0;cp_write<=0;cp_read<=0;end
  else if(frame_start)begin produced<=0;produce_x<=0;produce_y<=0;reserved<=0;coord_count<=0;cp_write<=0;cp_read<=0;end
  else begin
   if(map_issue)begin produced<=produced+1'b1;if(produce_x==W-1)begin produce_x<=0;produce_y<=produce_y+1'b1;end else produce_x<=produce_x+1'b1;end
   case({map_issue,coord_pop})2'b10:reserved<=reserved+1'b1;2'b01:reserved<=reserved-1'b1;default:;endcase
   case({map_valid,coord_pop})2'b10:coord_count<=coord_count+1'b1;2'b01:coord_count<=coord_count-1'b1;default:;endcase
   if(map_valid)cp_write<=cp_write+1'b1;if(coord_pop)cp_read<=cp_read+1'b1;
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;last_state<=IDLE;src<=0;busy<=0;done<=0;passed<=0;failed<=0;cycles<=0;read_count<=0;
   consumed<=0;pixel_addr<=0;miss_addr<=0;cache_valid<=0;victim<=0;fill_way<=0;read_half<=0;first_beat<=0;pack_data<=0;pack_bytes<=0;watchdog<=0;
  end else begin
   done<=0;last_state<=state;if(busy)cycles<=cycles+1'b1;
   if(!busy||progress)watchdog<=0;else watchdog<=watchdog+1'b1;
   if(busy&&(timeout_hit||writer_failed))begin
    failed<=1;passed<=0;busy<=0;done<=1;
    if(state==AR && !(arvalid&&arready))state<=DRAIN_AR;
    else if(state==READ && !(rvalid&&rready&&rlast) || state==AR && arvalid&&arready)state<=DRAIN_R;
    else state<=FAIL;
   end else case(state)
    IDLE:if(frame_start)begin
     src<=source_base;busy<=1;passed<=0;cycles<=0;read_count<=0;consumed<=0;cache_valid<=0;victim<=0;
     pack_data<=0;pack_bytes<=0;state<=GET;
     if(source_base[4:0]!=0||dest_base[3:0]!=0||(source_base<dest_base+W*H*3&&dest_base<source_base+W*H*3))begin state<=FAIL;failed<=1;busy<=0;done<=1;end
    end
    GET:if(coord_pop)begin pixel_addr<=src+offset_rgb(coord_head[11:0],coord_head[23:12]);state<=LOOK;end
    LOOK:if(pixel_take)begin
     consumed<=consumed+1'b1;
     if(emit_word)begin pack_data<=appended>>128;pack_bytes<=pack_bytes+3-16;end
     else begin pack_data<=appended;pack_bytes<=pack_bytes+3;end
     state<=consumed==PIXELS-1?FINISH:GET;
    end else if(!hit0 || needs_second&&!hit1)begin
     miss_addr<=!hit0?line_addr:line_addr+32;
     // Preserve the other half of a pixel crossing a32-byte sector.
     if(hit0&&victim==index0 || needs_second&&hit1&&victim==index1)fill_way<=victim+1'b1;else fill_way<=victim;
     state<=AR;
    end
    AR:if(arready)begin read_count<=read_count+1'b1;read_half<=0;state<=READ;end
    READ:if(rvalid)begin
     if(rresp!=0||rlast!=read_half)begin failed<=1;passed<=0;busy<=0;done<=1;state<=rlast?FAIL:DRAIN_R;end
     else if(!read_half)begin first_beat<=rdata;read_half<=1;end
     else begin cache[fill_way]<={rdata,first_beat};tags[fill_way]<=miss_addr;cache_valid[fill_way]<=1;victim<=fill_way+1'b1;state<=LOOK;end
    end
    FINISH:if(writer_done)begin busy<=0;passed<=1;done<=1;state<=IDLE;end
    DRAIN_AR:if(arready)state<=DRAIN_R;
    DRAIN_R:if(rvalid&&rlast)state<=FAIL;
    FAIL:begin busy<=0;passed<=0;end
    default:begin failed<=1;busy<=0;done<=1;state<=FAIL;end
   endcase
  end
 end
 initial if(W*H*3%32||W*H*3>1048576)$fatal(1,"unsupported fisheye frame size");
endmodule

// Eight words decouple pixels from AW/W/B. All words in a burst remain
// reserved until W handshakes; completion waits for the final B response.
module cat_fisheye_write_queue #(parameter integer TOTAL_BYTES=921600,TIMEOUT_BITS=24)(
 input wire clk,rst_n,frame_start,input wire [31:0] base,input wire abort,
 input wire push,input wire [127:0] data,output wire push_ready,input wire producer_done,
 output reg done,failed,output wire progress,
 output wire [31:0] awaddr,output wire [7:0] awlen,output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
 input wire [1:0] bresp,input wire bvalid,output wire bready
);
 localparam IDLE=0,SEND=1,RESP=2,COMPLETE=3,FAIL=4;
 reg [2:0] state;reg [31:0] addr,end_addr;reg [2:0] rd,wr;reg [3:0] count;
 reg [127:0] mem[0:7];reg [2:0] beats,left;reg aw_sent;
 reg [TIMEOUT_BITS-1:0] watchdog;
 wire pop=wvalid&&wready;wire [8:0] boundary=(13'd4096-{1'b0,addr[11:0]})>>4;
 wire [2:0] available=count>=4?3'd4:count[2:0];
 wire [2:0] packet=boundary<available?boundary[2:0]:available;
 assign push_ready=count<8;
 assign awaddr=addr;assign awlen=beats-1'b1;assign awvalid=state==SEND&&!aw_sent;
 assign wdata=mem[rd];assign wstrb=16'hffff;assign wlast=left==1;assign wvalid=state==SEND&&left!=0;assign bready=state==RESP;
 assign progress=(awvalid&&awready)||pop||(bvalid&&bready);
 always @(posedge clk)if(push&&push_ready)mem[wr]<=data;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;addr<=0;end_addr<=0;rd<=0;wr<=0;count<=0;beats<=1;left<=0;aw_sent<=0;done<=0;failed<=0;watchdog<=0;end
  else if(frame_start)begin state<=IDLE;addr<=base;end_addr<=base+TOTAL_BYTES;rd<=0;wr<=0;count<=0;beats<=1;left<=0;aw_sent<=0;done<=0;failed<=0;watchdog<=0;end
  else begin
   done<=0;
   if(push&&push_ready)wr<=wr+1'b1;if(pop)rd<=rd+1'b1;
   case({push&&push_ready,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
   if(state==IDLE||state==COMPLETE||state==FAIL||progress)watchdog<=0;else watchdog<=watchdog+1'b1;
   if((state==SEND||state==RESP)&& (&watchdog)&&!progress)failed<=1;
   case(state)
    IDLE:if(abort||failed)state<=FAIL;
     else if(count>=4 || producer_done&&count!=0)begin beats<=packet;left<=packet;aw_sent<=0;state<=SEND;end
    SEND:begin
     if(awvalid&&awready)aw_sent<=1;
     if(pop)left<=left-1'b1;
     if((aw_sent||awready)&&(left==0 || pop&&left==1))state<=RESP;
    end
    RESP:if(bvalid)begin
     if(bresp!=0||abort||failed)begin failed<=1;state<=FAIL;end
     else begin addr<=addr+(beats<<4);if(addr+(beats<<4)==end_addr)begin done<=1;state<=COMPLETE;end else state<=IDLE;end
    end
    COMPLETE:;
    FAIL:;
    default:begin failed<=1;state<=FAIL;end
   endcase
  end
 end
endmodule
`default_nettype wire

// Multirow accelerator is embedded here to survive GUI project-list saves.
`timescale 1ns/1ps
`default_nettype none
// Exact 2D geometry with16x8 output tiles and bounded multirow BRAM.
// Burst-prefetch source rows, then pipeline one complete RGB pixel per cycle.
module cat_fisheye_line_accel #(parameter integer UKIYO_BOTTOM_EN=0,MAP_INPUT_PIPE_STAGES=0,INCREMENTAL_ROW_ADDR=0,TILE_WIDTH=16, W=640,H=480,STRENGTH=2,TIMEOUT_BITS=24)(
 input wire runtime_fisheye,input wire [2:0] runtime_style,
 input wire clk,rst_n,start,input wire [31:0] source_base,dest_base,
 output reg busy,done,passed,failed,output reg [31:0] cycles,read_count,
 output wire [31:0] araddr,output wire [7:0] arlen,output wire arvalid,input wire arready,
 input wire [127:0] rdata,input wire [1:0] rresp,input wire rlast,rvalid,output wire rready,
 output wire [31:0] awaddr,output wire [7:0] awlen,output wire awvalid,input wire awready,
 output wire [127:0] wdata,output wire [15:0] wstrb,output wire wlast,wvalid,input wire wready,
 input wire [1:0] bresp,input wire bvalid,output wire bready
);

 localparam COL_BITS=$clog2(TILE_WIDTH), ROW_WORDS=TILE_WIDTH*3/16, WORD_BITS=$clog2(ROW_WORDS+1);
 localparam IDLE=0,MAP=1,BOUNDS=2,ROW_PREP=3,AR=4,READ=5,SAMPLE_INIT=6,SAMPLE=7,AW_PREP=8,WRITE=9,RESP=10,NEXT_ROW=11,NEXT_TILE=12,FAIL=13,DRAIN_AR=14,DRAIN_R=15,DRAIN_W=16,DRAIN_B=17,SOURCE_OFFSET=18,SOURCE_BASE=19;
 // Same512x96-bit source cache; wider tiles reuse adjacent source rows.
 // Same512x96-bit source cache, tightly packed by the checked source-row width.
 localparam CACHE_GROUPS=16,CACHE_WORDS=CACHE_GROUPS*32;
 localparam TOP_ROW=((H*80/100)/8)*8,CORNER_ROWS=((H*54/100+7)/8)*8;
 reg use_fisheye,use_ukiyo;
 localparam FINE_BEGIN=((H*8/100)/8)*8,TIGHT_BEGIN=((H*13/100)/8)*8,FINE_END=((H*20/100+7)/8)*8;
 function [3:0] rows_at;input [12:0] row;input fine;
 begin rows_at=!fine?8:row>=TIGHT_BEGIN&&row<FINE_END?2:row>=FINE_BEGIN&&row<TIGHT_BEGIN?4:8;end endfunction

 reg [4:0] state,last_state;reg [31:0] src,dst;
 reg [11:0] tile_x,tile_y,min_x,max_x,min_y,max_y,x_origin;
 reg [6:0] source_width,source_height;
 reg [3:0] tile_rows;
 reg [COL_BITS+3:0] map_sent,map_received;wire map_valid;wire [11:0] sx,sy;
 wire map_issue=state==MAP&&map_sent<tile_rows*TILE_WIDTH;
 wire [12:0] next_tile_y=use_ukiyo&&!use_fisheye&&tile_y+tile_rows==CORNER_ROWS?TOP_ROW:tile_y+tile_rows;
 wire [3:0] next_rows=rows_at(next_tile_y,UKIYO_BOTTOM_EN!=0&&use_ukiyo&&use_fisheye);

 wire fish_valid;wire [11:0] fish_x,fish_y;
 cat_fisheye_map #(.W(W),.H(H),.STRENGTH(STRENGTH),.INPUT_PIPE_STAGES(MAP_INPUT_PIPE_STAGES)) u_map(.clk(clk),.rst_n(rst_n),.in_valid(map_issue&&use_fisheye),.x(tile_x+map_sent[COL_BITS-1:0]),.y(tile_y+(map_sent>>COL_BITS)),.out_valid(fish_valid),.sx(fish_x),.sy(fish_y));
 wire [4:0] map_alpha;wire wave_valid;wire [11:0] wave_x,wave_y;
 reg identity_valid;reg [11:0] identity_x,identity_y;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin identity_valid<=0;identity_x<=0;identity_y<=0;end
  else begin identity_valid<=map_issue;identity_x<=tile_x+map_sent[COL_BITS-1:0];identity_y<=tile_y+(map_sent>>COL_BITS);end
 end
 generate if(UKIYO_BOTTOM_EN!=0)begin:G_BOTTOM_MAP
  ukiyo_bottom_map #(.W(W),.H(H)) u_bottom(.clk(clk),.rst_n(rst_n),.in_valid(use_ukiyo&&(use_fisheye?fish_valid:map_issue)),
   .x(use_fisheye?fish_x:tile_x+map_sent[COL_BITS-1:0]),.y(use_fisheye?fish_y:tile_y+(map_sent>>COL_BITS)),.out_valid(wave_valid),.sx(wave_x),.sy(wave_y),.alpha(map_alpha));
 end else begin assign wave_valid=0;assign wave_x=0;assign wave_y=0;assign map_alpha=0;end endgenerate
 assign map_valid=use_ukiyo?wave_valid:use_fisheye?fish_valid:identity_valid;
 assign sx=use_ukiyo?wave_x:use_fisheye?fish_x:identity_x;
 assign sy=use_ukiyo?wave_y:use_fisheye?fish_y:identity_y;
 (* syn_ramstyle="block_ram" *) reg [28:0] coordinates[0:TILE_WIDTH*8-1];
 (* syn_ramstyle="block_ram" *) reg [95:0] source_rows[0:CACHE_WORDS-1];
 reg [5:0] source_row;reg [4:0] group_col;
 reg [15:0] remaining,burst_left;reg [31:0] read_address;
 reg [223:0] shift_data;reg [5:0] bytes_left;
 wire emit_group=state==READ&&bytes_left>=12;
 wire [5:0] carry=bytes_left-(emit_group?12:0);
 wire [223:0] consumed_data=emit_group?shift_data>>96:shift_data;
 reg [223:0] refill;
 always @*case(carry)
  0:refill={96'd0,rdata};4:refill={64'd0,rdata,consumed_data[31:0]};
  8:refill={32'd0,rdata,consumed_data[63:0]};default:refill={rdata,consumed_data[95:0]};
 endcase
 wire [8:0] read_boundary=(13'd4096-{1'b0,read_address[11:0]})>>4;
 wire [15:0] read_chunk=remaining<read_boundary?remaining:read_boundary;
 assign araddr=read_address;assign arlen=read_chunk-1'b1;
 assign arvalid=state==AR||state==DRAIN_AR;
 assign rready=(state==READ&&burst_left!=0&&carry<=12)||state==DRAIN_R;
 reg [31:0] tile_offset_q,tile_dest_q,output_row_base,source_row_base;
 reg [31:0] source_row_offset_q,source_col_offset_q,source_offset_q;
 reg [3:0] output_row;reg [COL_BITS:0] sample_sent,sample_received;
 reg [2:0] sample_valid;reg [28:0] coord_q,meta1,meta2;reg [23:0] pixel_q;reg [95:0] row_q;reg [1:0] lane_q;
 wire sample_issue=state==SAMPLE&&sample_sent<TILE_WIDTH;
 wire [11:0] local_x=coord_q[11:0]-x_origin,local_y=coord_q[23:12]-min_y;
 function [9:0] cache_index;input [11:0] row,col;input [6:0] width;
 reg [11:0] stride_row;begin
  case(width)
   16:stride_row=row<<2;
   32:stride_row=row<<3;
   48:stride_row=(row<<3)+(row<<2);
   64:stride_row=row<<4;
   80:stride_row=(row<<4)+(row<<2);
   96:stride_row=(row<<4)+(row<<3);
   112:stride_row=(row<<4)+(row<<3)+(row<<2);
   default:stride_row=0;
  endcase
  cache_index=stride_row+col;
 end endfunction
 wire [9:0] cache_write_index=cache_index({6'd0,source_row},{7'd0,group_col},source_width);
 wire [9:0] cache_read_index=cache_index(local_y,local_x>>2,source_width);
 wire [12:0] bound_width=({1'b0,max_x[11:4],4'd0}+13'd16)-{1'b0,min_x[11:4],4'd0};
 wire [12:0] bound_height={1'b0,max_y}-{1'b0,min_y}+1'b1;
 wire bounds_bad=bound_height>64 || bound_width>112 || bound_width<16 ||
  (bound_width==16&&bound_height>64)||(bound_width==32&&bound_height>64)||
  (bound_width==48&&bound_height>42)||(bound_width==64&&bound_height>32)||
  (bound_width==80&&bound_height>25)||(bound_width==96&&bound_height>21)||
  (bound_width==112&&bound_height>18);
 reg [151:0] pack_data;reg [4:0] pack_bytes;reg [WORD_BITS-1:0] words_written,word_index;
 (* syn_ramstyle="block_ram" *) reg [127:0] words[0:ROW_WORDS-1];
 reg [127:0] write_word;reg [31:0] write_address;
 wire pigment_valid;wire [23:0] pigment_pixel;
 generate if(UKIYO_BOTTOM_EN!=0)begin:G_BOTTOM_PIGMENT
  ukiyo_bottom_pigment #(.W(W),.H(H)) u_pigment(.clk(clk),.rst_n(rst_n),.in_valid(sample_valid[2]),.enable(use_ukiyo),.rgb(pixel_q),
   .x(meta2[11:0]),.y(meta2[23:12]),.alpha(meta2[28:24]),.out_valid(pigment_valid),.out_rgb(pigment_pixel));
 end else begin assign pigment_valid=sample_valid[2];assign pigment_pixel=pixel_q;end endgenerate
 wire [151:0] appended=pack_data|({128'd0,pigment_pixel}<<(pack_bytes*8));
 reg [2:0] write_beats,write_left;reg aw_sent;
 wire [8:0] write_boundary=(13'd4096-{1'b0,write_address[11:0]})>>4;
 wire [2:0] write_remaining=ROW_WORDS-word_index;
 wire [2:0] write_chunk=write_remaining<write_boundary?write_remaining:write_boundary[2:0];
 assign awaddr=write_address;assign awlen=write_beats-1'b1;
 assign awvalid=(state==WRITE||state==DRAIN_W)&&!aw_sent;
 assign wdata=write_word;assign wstrb=16'hffff;assign wlast=write_left==1;
 assign wvalid=(state==WRITE||state==DRAIN_W)&&write_left!=0;assign bready=state==RESP||state==DRAIN_B;
 function [31:0] offset_rgb(input [11:0] a,b);
  reg [31:0] row,col;
  begin row=b;col=a;if(W==640)offset_rgb=(row<<11)-(row<<7)+(col<<1)+col;else offset_rgb=row*(W*3)+(col<<1)+col;end
 endfunction
 // Coordinates, row RAM, lane extraction and output packing are separate stages.
 always @(posedge clk)begin
  tile_offset_q<=offset_rgb(tile_x,tile_y);tile_dest_q<=dst+tile_offset_q;
  // Split constant row scaling, column offset and base addition. Coordinates
  // settle after MAP; the two setup states below make the last mapped bounds
  // pass all stages before any AXI request can observe the result.
  source_row_offset_q<={20'd0,min_y}*(W*3);
  source_col_offset_q<={20'd0,min_x[11:4],4'd0}*3;
  source_offset_q<=source_row_offset_q+source_col_offset_q;
  // Prefetch during AW setup, then advance only when the current W beat is accepted.
  if(state==AW_PREP || wvalid&&wready)write_word<=words[state==AW_PREP?word_index:word_index+1'b1];
  if(map_valid&&state==MAP)coordinates[map_received[COL_BITS+2:0]]<={use_ukiyo?map_alpha:5'd0,sy,sx};
  if(emit_group)source_rows[cache_write_index]<=shift_data[95:0];
  if(sample_issue)coord_q<=coordinates[{output_row[2:0],sample_sent[COL_BITS-1:0]}];
  if(sample_valid[0])begin row_q<=source_rows[cache_read_index];lane_q<=local_x[1:0];end
  pixel_q<=row_q>>(lane_q*24);
  if(state==SAMPLE&&pigment_valid&&pack_bytes+3>=16)words[words_written]<=appended[127:0];
 end
 // One owner for metadata reset and pipeline updates. RAM data remains
 // unreset and is ignored while the separately reset sample_valid is clear.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin meta1<=0;meta2<=0;end
  else begin
   if(sample_valid[0])meta1<=coord_q;
   meta2<=meta1;
  end
 end
 reg [TIMEOUT_BITS-1:0] watchdog;
 wire progress=state!=last_state||map_valid||sample_issue||pigment_valid||emit_group||(arvalid&&arready)||(rvalid&&rready)||(awvalid&&awready)||(wvalid&&wready)||(bvalid&&bready);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   use_fisheye<=1;use_ukiyo<=0;state<=IDLE;last_state<=IDLE;src<=0;dst<=0;busy<=0;done<=0;passed<=0;failed<=0;cycles<=0;read_count<=0;
   tile_x<=0;tile_y<=0;tile_rows<=0;min_x<=0;max_x<=0;min_y<=0;max_y<=0;x_origin<=0;source_width<=0;source_height<=0;
   map_sent<=0;map_received<=0;source_row<=0;group_col<=0;remaining<=0;burst_left<=0;read_address<=0;shift_data<=0;bytes_left<=0;
   output_row_base<=0;source_row_base<=0;output_row<=0;sample_sent<=0;sample_received<=0;sample_valid<=0;pack_data<=0;pack_bytes<=0;words_written<=0;word_index<=0;write_address<=0;
   write_beats<=1;write_left<=0;aw_sent<=0;watchdog<=0;
  end else begin
   done<=0;last_state<=state;sample_valid<={sample_valid[1:0],sample_issue};
   if(busy)cycles<=cycles+1'b1;
   if(!busy||progress)watchdog<=0;else watchdog<=watchdog+1'b1;
   if(busy&&(&watchdog)&&!progress)begin
    failed<=1;passed<=0;busy<=0;done<=1;
    case(state)AR:state<=DRAIN_AR;READ:state<=DRAIN_R;WRITE:state<=DRAIN_W;RESP:state<=DRAIN_B;default:state<=FAIL;endcase
   end else case(state)
    IDLE:if(start&&!failed)begin
     use_fisheye<=UKIYO_BOTTOM_EN!=0?runtime_fisheye:1;use_ukiyo<=UKIYO_BOTTOM_EN!=0&&runtime_style==2;
     src<=source_base;dst<=dest_base;busy<=1;passed<=0;cycles<=0;read_count<=0;tile_x<=0;tile_y<=0;tile_rows<=H<rows_at(0,UKIYO_BOTTOM_EN!=0&&runtime_style==2&&runtime_fisheye)?H:rows_at(0,UKIYO_BOTTOM_EN!=0&&runtime_style==2&&runtime_fisheye);
     map_sent<=0;map_received<=0;min_x<=W-1;max_x<=0;min_y<=H-1;max_y<=0;state<=MAP;
     if(source_base[3:0]!=0||dest_base[3:0]!=0||(source_base<dest_base+W*H*3&&dest_base<source_base+W*H*3))begin failed<=1;busy<=0;done<=1;state<=FAIL;end
    end
    MAP:begin
     if(map_issue)map_sent<=map_sent+1'b1;
     if(map_valid)begin
      if(sx<min_x)min_x<=sx;if(sx>max_x)max_x<=sx;if(sy<min_y)min_y<=sy;if(sy>max_y)max_y<=sy;
      map_received<=map_received+1'b1;if(map_received==tile_rows*TILE_WIDTH-1)state<=BOUNDS;
     end
    end
    BOUNDS:begin
     x_origin<={min_x[11:4],4'd0};source_width<=({max_x[11:4],4'd0}+16)-{min_x[11:4],4'd0};source_height<=max_y-min_y+1;
     source_row<=0;state<=INCREMENTAL_ROW_ADDR!=0?SOURCE_OFFSET:ROW_PREP;
     if(bounds_bad)begin failed<=1;busy<=0;done<=1;state<=FAIL;end
    end
    SOURCE_OFFSET:state<=SOURCE_BASE;
    SOURCE_BASE:begin source_row_base<=src+source_offset_q;state<=ROW_PREP;end
    ROW_PREP:begin
     read_address<=(INCREMENTAL_ROW_ADDR!=0)?source_row_base:src+offset_rgb(x_origin,min_y+source_row);remaining<=source_width*3/16;group_col<=0;shift_data<=0;bytes_left<=0;state<=AR;
    end
    AR:if(arready)begin burst_left<=read_chunk;read_count<=read_count+1'b1;state<=READ;end
    READ:begin
     if(emit_group)begin group_col<=group_col+1'b1;shift_data<=consumed_data;bytes_left<=carry;end
     if(rvalid&&rready)begin
      burst_left<=burst_left-1'b1;remaining<=remaining-1'b1;read_address<=read_address+16;shift_data<=refill;bytes_left<=carry+16;
      if(rresp!=0||rlast!=(burst_left==1))begin failed<=1;passed<=0;busy<=0;done<=1;state<=rlast?FAIL:DRAIN_R;end
     end
     if(burst_left==0)begin
      if(remaining!=0)state<=AR;
      else if(bytes_left==0)begin
       if(source_row==source_height-1)begin output_row<=0;output_row_base<=tile_dest_q;state<=SAMPLE_INIT;end
       else begin source_row_base<=source_row_base+W*3;source_row<=source_row+1'b1;state<=ROW_PREP;end
      end
     end
    end
    SAMPLE_INIT:begin sample_sent<=0;sample_received<=0;sample_valid<=0;pack_data<=0;pack_bytes<=0;words_written<=0;word_index<=0;state<=SAMPLE;end
    SAMPLE:begin
     if(sample_issue)sample_sent<=sample_sent+1'b1;
     if(pigment_valid)begin
      sample_received<=sample_received+1'b1;
      if(pack_bytes+3>=16)begin pack_data<=appended>>128;pack_bytes<=pack_bytes+3-16;words_written<=words_written+1'b1;end
      else begin pack_data<=appended;pack_bytes<=pack_bytes+3;end
      if(sample_received==TILE_WIDTH-1)begin write_address<=(INCREMENTAL_ROW_ADDR!=0)?output_row_base:dst+offset_rgb(tile_x,tile_y+output_row);state<=AW_PREP;end
     end
    end
    AW_PREP:begin write_beats<=write_chunk;write_left<=write_chunk;aw_sent<=0;state<=WRITE;end
    WRITE:begin
     if(awvalid&&awready)aw_sent<=1;
     if(wvalid&&wready)begin write_left<=write_left-1'b1;word_index<=word_index+1'b1;end
     if((aw_sent||awready)&&(write_left==0||wvalid&&wready&&write_left==1))state<=RESP;
    end
    RESP:if(bvalid)begin
     if(bresp!=0)begin failed<=1;passed<=0;busy<=0;done<=1;state<=FAIL;end
     else if(word_index==ROW_WORDS)state<=NEXT_ROW;
     else begin write_address<=write_address+(write_beats<<4);state<=AW_PREP;end
    end
    NEXT_ROW:if(output_row==tile_rows-1)state<=NEXT_TILE;
     else begin output_row_base<=output_row_base+W*3;output_row<=output_row+1'b1;state<=SAMPLE_INIT;end
    NEXT_TILE:begin
     if(tile_x==W-TILE_WIDTH&&tile_y+tile_rows==H)begin passed<=1;busy<=0;done<=1;state<=IDLE;end
     else begin
      if(tile_x==W-TILE_WIDTH)begin tile_x<=0;tile_y<=next_tile_y;tile_rows<=H-next_tile_y<next_rows?H-next_tile_y:next_rows;end else tile_x<=tile_x+TILE_WIDTH;
      map_sent<=0;map_received<=0;min_x<=W-1;max_x<=0;min_y<=H-1;max_y<=0;state<=MAP;
     end
    end
    DRAIN_AR:if(arready)state<=DRAIN_R;
    DRAIN_R:if(rvalid&&rlast)state<=FAIL;
    DRAIN_W:begin
     if(awvalid&&awready)aw_sent<=1;if(wvalid&&wready)begin write_left<=write_left-1'b1;word_index<=word_index+1'b1;end
     if((aw_sent||awready)&&(write_left==0||wvalid&&wready&&write_left==1))state<=DRAIN_B;
    end
    DRAIN_B:if(bvalid)state<=FAIL;
    FAIL:busy<=0;
    default:begin failed<=1;busy<=0;done<=1;state<=FAIL;end
   endcase
  end
 end
 initial if((TILE_WIDTH!=16&&TILE_WIDTH!=32)||W%TILE_WIDTH||H%2||W*H*3>4194304)$fatal(1,"unsupported row accelerator frame");
endmodule
`default_nettype wire
