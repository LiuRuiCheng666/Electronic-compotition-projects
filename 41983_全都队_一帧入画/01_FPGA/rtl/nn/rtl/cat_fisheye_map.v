`timescale 1ns/1ps
`default_nettype none
// Full 2-D inverse barrel map. Integer symmetric coordinates, Q10 radius.
// Five pipeline stages; independent of NN and color processing.
module cat_fisheye_map #(parameter integer W=640,H=480,STRENGTH=2,INPUT_PIPE_STAGES=0)(
 input wire clk,rst_n,in_valid,input wire [11:0] x,y,
 output reg out_valid,output reg [11:0] sx,sy
);
 localparam integer NX=((1<<20)+(W-1)/2)/(W-1),NY=((1<<20)+(H-1)/2)/(H-1);
 wire lx=x<W/2,ly=y<H/2;
 wire [11:0] ax=lx?(W-1-2*x):(2*x-(W-1));
 wire [11:0] ay=ly?(H-1-2*y):(2*y-(H-1));
 // Optional input stages separate coordinate/absolute arithmetic from
 // normalization and its clamp. Default0 retains the five-cycle interface.
 wire [11:0] pipe_ax,pipe_ay;wire pipe_lx,pipe_ly,pipe_valid;
 wire [31:0] normx,normy;
 generate if(INPUT_PIPE_STAGES!=0)begin:G_INPUT_PIPE
  reg [11:0] ax0,ay0;reg lx0,ly0,v0;
  wire [31:0] normx0=(ax0*NX+512)>>10,normy0=(ay0*NY+512)>>10;
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin ax0<=0;ay0<=0;lx0<=0;ly0<=0;v0<=0;end
   else begin ax0<=ax;ay0<=ay;lx0<=lx;ly0<=ly;v0<=in_valid;end
  end
  if(INPUT_PIPE_STAGES==2)begin:G_NORMALIZE_PIPE
   reg [31:0] nx0,ny0;reg [11:0] axt,ayt;reg lxt,lyt,vt;
   always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin nx0<=0;ny0<=0;axt<=0;ayt<=0;lxt<=0;lyt<=0;vt<=0;end
    else begin nx0<=normx0;ny0<=normy0;axt<=ax0;ayt<=ay0;lxt<=lx0;lyt<=ly0;vt<=v0;end
   end
   assign normx=nx0;assign normy=ny0;assign pipe_ax=axt;assign pipe_ay=ayt;
   assign pipe_lx=lxt;assign pipe_ly=lyt;assign pipe_valid=vt;
  end else begin:G_ABS_ONLY
   assign normx=normx0;assign normy=normy0;assign pipe_ax=ax0;assign pipe_ay=ay0;
   assign pipe_lx=lx0;assign pipe_ly=ly0;assign pipe_valid=v0;
  end
 end else begin:G_DIRECT_INPUT
  assign normx=(ax*NX+512)>>10;assign normy=(ay*NY+512)>>10;
  assign pipe_ax=ax;assign pipe_ay=ay;assign pipe_lx=lx;assign pipe_ly=ly;assign pipe_valid=in_valid;
 end endgenerate
 reg [10:0] nx1,ny1;reg [21:0] r2;
 reg [10:0] factor3;reg [11:0] dx4,dy4;
 reg [11:0] ax1,ay1,ax2,ay2,ax3,ay3;
 reg [3:0] valid;reg [3:0] leftx,lefty;
 wire [24:0] factor_value=(STRENGTH==2)?384+((({3'd0,r2}<<2)+r2)>>14):512+(r2>>12);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin valid<=0;out_valid<=0;leftx<=0;lefty<=0;nx1<=0;ny1<=0;r2<=0;factor3<=0;dx4<=0;dy4<=0;
   ax1<=0;ay1<=0;ax2<=0;ay2<=0;ax3<=0;ay3<=0;sx<=0;sy<=0;end
  else begin
   valid<={valid[2:0],pipe_valid};leftx<={leftx[2:0],pipe_lx};lefty<={lefty[2:0],pipe_ly};out_valid<=valid[3];
   nx1<=normx>1024?1024:normx;ny1<=normy>1024?1024:normy;ax1<=pipe_ax;ay1<=pipe_ay;
   r2<=nx1*nx1+ny1*ny1;ax2<=ax1;ay2<=ay1;
   factor3<=factor_value>1024?1024:factor_value;ax3<=ax2;ay3<=ay2;
   dx4<=(ax3*factor3+512)>>10;dy4<=(ay3*factor3+512)>>10;
   sx<=leftx[3]?((W-1-dx4)>>1):(W-1-((W-1-dx4)>>1));
   sy<=lefty[3]?((H-1-dy4)>>1):(H-1-((H-1-dy4)>>1));
  end
 end
 initial if(INPUT_PIPE_STAGES<0 || INPUT_PIPE_STAGES>2 || W<16 || H<4 || W>2048 || H>2048 || W%2 || H%2 || STRENGTH<1 || STRENGTH>2)$fatal(1,"unsupported fisheye geometry");
endmodule
`default_nettype wire

`timescale 1ns/1ps
`default_nettype none
// Three bottom curl fields plus two unequal upper-region strong radial curls.
// Bright corner backgrounds avoid tiled foam; the bottom keeps its irregular feather.
// Four parity ROM banks provide bilinear displacement lookup.
module ukiyo_bottom_map #(parameter integer W=1280,H=720)(
 input wire clk,rst_n,in_valid,input wire [11:0] x,y,
 output reg out_valid,output reg [11:0] sx,sy,output reg [4:0] alpha);
 localparam RX0=(W*16+3)/6,RX1=RX0;
 localparam RY0=(H*10*16+50)/100,RY1=RY0;
 localparam BAND_TOP=((H*80/100)/8)*8,FADE_ROWS=H*12/100>0?H*12/100:1;
 localparam CORNER_ROWS=((H*54/100+7)/8)*8;
 localparam LX=(W*12*16+50)/100,LY=(H*32*16+50)/100,LRX=(W*12784*16+50000)/100000,LRY=(H*16864*16+50000)/100000;
 localparam UX=(W*91*16+50)/100,UY=(H*34*16+50)/100,URX=(W*94*16+500)/1000,URY=(H*124*16+500)/1000;
 function signed [15:0] cx;input [2:0] c;begin cx=c==3?LX:c==4?UX:c==0?(W*16+3)/6:c==1?(W*16+1)/2:(W*5*16+3)/6;end endfunction
 function signed [15:0] cy;input [2:0] c;begin cy=c==3?LY:c==4?UY:(H*90*16+50)/100;end endfunction
 function signed [15:0] rx;input [2:0] c;begin rx=c==3?LRX:c==4?URX:RX0;end endfunction
 function signed [15:0] ry;input [2:0] c;begin ry=c==3?LRY:c==4?URY:RY0;end endfunction
 (* syn_ramstyle="block_ram" *) reg [5:0] edge_rom[0:1023];
 reg [5:0] edge_q,edge1;
 initial $readmemh("ukiyo_edge_profile.mem",edge_rom);
 always @(posedge clk)edge_q<=edge_rom[x[10:1]];
 function [4:0] band_feather;input [11:0] y_in;input [5:0] offset;
 reg signed [13:0] depth;begin
  // One shared subtraction; all feather thresholds are now constants.
  depth=$signed({2'b00,y_in})-BAND_TOP-$signed({8'd0,offset});
  if(depth<(FADE_ROWS*1+15)/16)band_feather=5'd0;
  else if(depth<(FADE_ROWS*2+15)/16)band_feather=5'd0;
  else if(depth<(FADE_ROWS*3+15)/16)band_feather=5'd0;
  else if(depth<(FADE_ROWS*4+15)/16)band_feather=5'd1;
  else if(depth<(FADE_ROWS*5+15)/16)band_feather=5'd1;
  else if(depth<(FADE_ROWS*6+15)/16)band_feather=5'd2;
  else if(depth<(FADE_ROWS*7+15)/16)band_feather=5'd3;
  else if(depth<(FADE_ROWS*8+15)/16)band_feather=5'd4;
  else if(depth<(FADE_ROWS*9+15)/16)band_feather=5'd5;
  else if(depth<(FADE_ROWS*10+15)/16)band_feather=5'd6;
  else if(depth<(FADE_ROWS*11+15)/16)band_feather=5'd7;
  else if(depth<(FADE_ROWS*12+15)/16)band_feather=5'd8;
  else if(depth<(FADE_ROWS*13+15)/16)band_feather=5'd9;
  else if(depth<(FADE_ROWS*14+15)/16)band_feather=5'd10;
  else if(depth<(FADE_ROWS*15+15)/16)band_feather=5'd11;
  else if(depth<(FADE_ROWS*16+15)/16)band_feather=5'd12;
  else band_feather=5'd12;
 end endfunction
 wire [2:0] cell_in=y<CORNER_ROWS?(x<W/2?3:4):(x<W/3?0:x<(W*2)/3?1:2);
 wire signed [15:0] dx=$signed({x,4'd0})-cx(cell_in),dy=$signed({y,4'd0})-cy(cell_in);
 wire [19:0] invx=cell_in==3?((1<<24)+LRX/2)/LRX:cell_in==4?((1<<24)+URX/2)/URX:((1<<24)+RX0/2)/RX0;
 wire [19:0] invy=cell_in==3?((1<<24)+LRY/2)/LRY:cell_in==4?((1<<24)+URY/2)/URY:((1<<24)+RY0/2)/RY0;
 reg [11:0] xp[0:6],yp[0:6];reg [2:0] cp[0:6];reg [6:0] valid;
 reg signed [36:0] px0,py0;reg bbox0,bbox1;reg signed [15:0] nx1,ny1;
 wire signed [31:0] square_x=nx1*nx1,square_y=ny1*ny1;
 wire [31:0] radius2=square_x+square_y;
 wire [4:0] strong_alpha=radius2>=1048576?0:radius2<=655360?12:(1048576-radius2)>>15;
 wire [10:0] ux=nx1<-1024?0:nx1>1023?2047:nx1+1024;
 wire [10:0] uy=ny1<-1024?0:ny1>1023?2047:ny1+1024;
 wire [4:0] gx=cp[1]>=3?{1'b0,ux[10:7]}:ux[10:6],gy=cp[1]>=3?{1'b0,uy[10:7]}:uy[10:6];
 reg [1:0] parity2;reg [5:0] fx2,fy2,fy3;
 reg [4:0] a2,a3,a4,a5,a6;reg inside2,inside3,inside4,inside5,inside6;
 wire [79:0] bank_values;
 genvar bank;
 generate for(bank=0;bank<4;bank=bank+1)begin:G_ROM
  (* syn_ramstyle="block_ram" *) reg [19:0] curl_rom[0:1023];reg [19:0] q;reg zero_q;
  localparam BX=bank%2,BY=bank/2;
  wire [5:0] ix={1'b0,gx[4:1]}+(gx[0] && BX==0);
  wire [5:0] iy={1'b0,gy[4:1]}+(gy[0] && BY==0);
  wire [1:0] rom_cell=cp[1]==3?0:cp[1]==4?1:cp[1][1:0];
  wire is_strong=cp[1]>=3;
  wire border_zero=is_strong&&((BX==0&&ix==0)||(BY==0&&iy==0));
  wire [9:0] packed_addr=867+(cp[1]==4?64:0)+(iy-(BY==0?1:0))*8+ix-(BX==0?1:0);
  wire [9:0] addr=is_strong?packed_addr:rom_cell*289+iy*17+ix;
  if(bank==0)initial $readmemh("ukiyo_curl_bank0.mem",curl_rom);
  if(bank==1)initial $readmemh("ukiyo_curl_bank1.mem",curl_rom);
  if(bank==2)initial $readmemh("ukiyo_curl_bank2.mem",curl_rom);
  if(bank==3)initial $readmemh("ukiyo_curl_bank3.mem",curl_rom);
  always @(posedge clk)begin q<=curl_rom[addr];zero_q<=border_zero;end
  assign bank_values[bank*20+:20]=zero_q?20'd0:q;
 end endgenerate
 wire [19:0] c00=bank_values[parity2*20+:20],c10=bank_values[(parity2^2'b01)*20+:20];
 wire [19:0] c01=bank_values[(parity2^2'b10)*20+:20],c11=bank_values[(parity2^2'b11)*20+:20];
 wire signed [9:0] xx00=c00[9:0],xx10=c10[9:0],xx01=c01[9:0],xx11=c11[9:0];
 wire signed [9:0] yy00=c00[19:10],yy10=c10[19:10],yy01=c01[19:10],yy11=c11[19:10];
 reg signed [17:0] ex03,ex13,ey03,ey13;reg signed [25:0] bilx4,bily4;
 reg signed [10:0] ddx5,ddy5;reg signed [26:0] offx6,offy6;
 wire signed [31:0] final_x=$signed({20'd0,xp[6]})+((offx6+27'sd8192)>>>14);
 wire signed [31:0] final_y=$signed({20'd0,yp[6]})+((offy6+27'sd8192)>>>14);
 wire signed [10:0] norm_dx=(bilx4+26'sd2048)>>>12,norm_dy=(bily4+26'sd2048)>>>12;
 integer i;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin valid<=0;out_valid<=0;sx<=0;sy<=0;alpha<=0;edge1<=0;px0<=0;py0<=0;bbox0<=0;bbox1<=0;nx1<=0;ny1<=0;
   fx2<=0;fy2<=0;fy3<=0;parity2<=0;a2<=0;a3<=0;a4<=0;a5<=0;a6<=0;inside2<=0;inside3<=0;inside4<=0;inside5<=0;inside6<=0;
   ex03<=0;ex13<=0;ey03<=0;ey13<=0;bilx4<=0;bily4<=0;ddx5<=0;ddy5<=0;offx6<=0;offy6<=0;
   for(i=0;i<7;i=i+1)begin xp[i]<=0;yp[i]<=0;cp[i]<=0;end
  end else begin
   edge1<=edge_q;valid<={valid[5:0],in_valid};xp[0]<=x;yp[0]<=y;cp[0]<=cell_in;
   for(i=1;i<7;i=i+1)begin xp[i]<=xp[i-1];yp[i]<=yp[i-1];cp[i]<=cp[i-1];end
   px0<=dx*$signed({1'b0,invx});py0<=dy*$signed({1'b0,invy});bbox0<=dx>-rx(cell_in)&&dx<rx(cell_in)&&dy>-ry(cell_in)&&dy<ry(cell_in);
   nx1<=px0>>>14;ny1<=py0>>>14;bbox1<=bbox0;
   fx2<=cp[1]>=3?ux[6:1]:ux[5:0];fy2<=cp[1]>=3?uy[6:1]:uy[5:0];parity2<={gy[0],gx[0]};inside2<=bbox1&&(cp[1]<3||radius2<1048576);
   a2<=cp[1]>=3?(bbox1?strong_alpha:0):band_feather(yp[1],edge1);
   ex03<=($signed(xx00)<<<6)+($signed(xx10)-$signed(xx00))*$signed({1'b0,fx2});
   ex13<=($signed(xx01)<<<6)+($signed(xx11)-$signed(xx01))*$signed({1'b0,fx2});
   ey03<=($signed(yy00)<<<6)+($signed(yy10)-$signed(yy00))*$signed({1'b0,fx2});
   ey13<=($signed(yy01)<<<6)+($signed(yy11)-$signed(yy01))*$signed({1'b0,fx2});fy3<=fy2;a3<=a2;inside3<=inside2;
   bilx4<=(ex03<<<6)+(ex13-ex03)*$signed({1'b0,fy3});bily4<=(ey03<<<6)+(ey13-ey03)*$signed({1'b0,fy3});a4<=a3;inside4<=inside3;
   ddx5<=cp[4]>=3?(norm_dx<<<1):norm_dx;ddy5<=cp[4]>=3?(norm_dy<<<1):norm_dy;a5<=a4;inside5<=inside4;
   offx6<=ddx5*rx(cp[5]);offy6<=ddy5*ry(cp[5]);a6<=a5;inside6<=inside5;
   out_valid<=valid[6];alpha<=a6;
   sx<=!inside6?xp[6]:final_x<0?0:final_x>=W?W-1:final_x;
   sy<=!inside6?yp[6]:final_y<0?0:final_y>=H?H-1:final_y;
  end
 end
endmodule
`default_nettype wire

`timescale 1ns/1ps
`default_nettype none
// Three-stage pigment/foam pipeline. Alpha0 is a byte-exact bypass.
module ukiyo_bottom_pigment #(parameter integer W=1280,H=720)(input wire clk,rst_n,in_valid,enable,input wire [23:0] rgb,
 input wire [11:0] x,y,input wire [4:0] alpha,output reg out_valid,output reg [23:0] out_rgb);
 (* syn_ramstyle="block_ram" *) reg [1:0] foam_rom[0:1023];reg [1:0] foam0;
 initial $readmemh("ukiyo_foam32.mem",foam_rom);
 wire mini_upper=y<((H*54/100+7)/8)*8;
 wire [13:0] tex_x=!mini_upper?{2'd0,x}:x<W/2?((({2'd0,x}<<4)-x)>>2):({2'd0,x}<<2)+x;
 wire [13:0] tex_y=!mini_upper?{2'd0,y}:x<W/2?((({2'd0,y}<<4)-y)>>2):({2'd0,y}<<2)+y;
 always @(posedge clk)foam0<=foam_rom[{tex_y[3:0],1'b0,tex_x[3:0],1'b0}];
 wire [9:0] luminance=({2'd0,rgb[7:0]}+({2'd0,rgb[15:8]}<<1)+{2'd0,rgb[23:16]})>>2;
 reg [23:0] rgb0,rgb1,target1;reg [7:0] lum0;reg [4:0] alpha0,alpha1;reg dot0,line0,highlight0,corner0,v0,v1;
 wire [23:0] palette=lum0<65?24'h4c3110:lum0<105?24'h7a561f:lum0<160?24'ha99760:lum0<205?24'hccd2b8:24'hc2e6f2;
 wire blue=lum0>25 && lum0<210;
 wire foam_allowed=!corner0||(lum0>25&&lum0<175);
 // Background brightness is measured before pigment/foam; no feedback.
 // Constant color cases avoid adding multipliers or a new frame buffer.
 function [23:0] contrast_foam;input [7:0] l;begin
  if(l<112)contrast_foam=24'hffffff;
  else if(l>=176)contrast_foam=24'h764818;
  else case(l[7:2])
   6'd28:contrast_foam=24'hffffff;
   6'd29:contrast_foam=24'hf6f4f1;
   6'd30:contrast_foam=24'heee8e2;
   6'd31:contrast_foam=24'he5ddd4;
   6'd32:contrast_foam=24'hddd1c5;
   6'd33:contrast_foam=24'hd4c6b7;
   6'd34:contrast_foam=24'hccbaa8;
   6'd35:contrast_foam=24'hc3af9a;
   6'd36:contrast_foam=24'hbba48c;
   6'd37:contrast_foam=24'hb2987d;
   6'd38:contrast_foam=24'ha98d6f;
   6'd39:contrast_foam=24'ha18160;
   6'd40:contrast_foam=24'h987652;
   6'd41:contrast_foam=24'h906a43;
   6'd42:contrast_foam=24'h875f35;
   6'd43:contrast_foam=24'h7f5326;
   default:contrast_foam=24'hffffff;
  endcase
 end endfunction
 // alpha follows the band from top to bottom: dark blue -> near white.
 function [23:0] vertical_foam;input [4:0] level;begin
  case(level)
   5'd0:vertical_foam=24'h764818;
   5'd1:vertical_foam=24'h81572b;
   5'd2:vertical_foam=24'h8d673f;
   5'd3:vertical_foam=24'h987652;
   5'd4:vertical_foam=24'ha48565;
   5'd5:vertical_foam=24'haf9478;
   5'd6:vertical_foam=24'hbba48c;
   5'd7:vertical_foam=24'hc6b39f;
   5'd8:vertical_foam=24'hd1c2b2;
   5'd9:vertical_foam=24'hddd1c5;
   5'd10:vertical_foam=24'he8e1d9;
   5'd11:vertical_foam=24'hf4f0ec;
   default:vertical_foam=24'hffffff;
  endcase
 end endfunction
 function [7:0] tint_mix;input [7:0] vertical,adaptive;reg [9:0] sum;begin
  sum=({2'd0,vertical}<<1)+vertical+adaptive+2;tint_mix=sum>>2;
 end endfunction
 wire [23:0] vertical_tint=vertical_foam(alpha0),adaptive_tint=contrast_foam(lum0);
 wire [23:0] foam_tint={tint_mix(vertical_tint[23:16],adaptive_tint[23:16]),tint_mix(vertical_tint[15:8],adaptive_tint[15:8]),tint_mix(vertical_tint[7:0],adaptive_tint[7:0])};
 function [7:0] base_mix;input [7:0] src,flat;reg [9:0] sum;begin sum={2'd0,src}+({2'd0,flat}<<1)+flat;base_mix=sum>>2;end endfunction
 function [7:0] foam_mix;input [7:0] src,tint;reg [8:0] sum;begin sum={1'b0,src}+{1'b0,tint}+1'b1;foam_mix=sum>>1;end endfunction
 function [7:0] foam_rich;input [7:0] src,tint;reg [9:0] sum;begin sum={2'd0,src}+({2'd0,tint}<<1)+tint+2;foam_rich=sum>>2;end endfunction
 // Stronger ink in the upper band; zero stays transparent at the boundary.
 function [4:0] ink_alpha;input [4:0] a;begin case(a)
  5'd0:ink_alpha=5'd0;
  5'd1:ink_alpha=5'd3;
  5'd2:ink_alpha=5'd5;
  5'd3:ink_alpha=5'd6;
  5'd4:ink_alpha=5'd7;
  5'd5:ink_alpha=5'd8;
  5'd6:ink_alpha=5'd9;
  5'd7:ink_alpha=5'd10;
  5'd8:ink_alpha=5'd11;
  5'd9:ink_alpha=5'd12;
  5'd10:ink_alpha=5'd12;
  5'd11:ink_alpha=5'd12;
  5'd12:ink_alpha=5'd12;
  default:ink_alpha=a;
 endcase end endfunction
 function [7:0] feather;input [7:0] src,target;input [4:0] a;reg signed [14:0] weighted;begin
  weighted=($signed({1'b0,target})-$signed({1'b0,src}))*$signed({1'b0,a});
  feather=src+((weighted+15'sd8)>>>4);
 end endfunction
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin rgb0<=0;rgb1<=0;target1<=0;lum0<=0;alpha0<=0;alpha1<=0;corner0<=0;dot0<=0;line0<=0;highlight0<=0;v0<=0;v1<=0;out_valid<=0;out_rgb<=0;end
  else begin
   corner0<=mini_upper;line0<=tex_y[3:0]==0;highlight0<=tex_y[4:0]==3;rgb0<=rgb;lum0<=luminance;alpha0<=enable?alpha:0;dot0<=(((tex_x>>1)^(tex_y<<2)^(tex_x>>5))&127)==11;v0<=in_valid;
   rgb1<=rgb0;alpha1<=(((foam0!=0||dot0)&&foam_allowed)||(blue&&(line0||highlight0)))?ink_alpha(alpha0):alpha0;v1<=v0;
   target1<=((foam0==2||dot0)&&foam_allowed)?foam_tint:
    foam0==3&&foam_allowed?foam_tint:
    foam0==1&&foam_allowed?{foam_rich(rgb0[23:16],foam_tint[23:16]),foam_rich(rgb0[15:8],foam_tint[15:8]),foam_rich(rgb0[7:0],foam_tint[7:0])}:
    blue&&line0?{foam_rich(rgb0[23:16],8'd122),foam_rich(rgb0[15:8],8'd86),foam_rich(rgb0[7:0],8'd31)}:
    blue&&highlight0?{foam_rich(rgb0[23:16],8'd169),foam_rich(rgb0[15:8],8'd151),foam_rich(rgb0[7:0],8'd96)}:
    corner0?rgb0:{base_mix(rgb0[23:16],palette[23:16]),base_mix(rgb0[15:8],palette[15:8]),base_mix(rgb0[7:0],palette[7:0])};
   out_valid<=v1;out_rgb<={feather(rgb1[23:16],target1[23:16],alpha1),feather(rgb1[15:8],target1[15:8],alpha1),feather(rgb1[7:0],target1[7:0],alpha1)};
  end
 end
endmodule
`default_nettype wire
