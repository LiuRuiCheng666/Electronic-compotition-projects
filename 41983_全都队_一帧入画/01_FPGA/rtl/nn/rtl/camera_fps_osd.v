module camera_fps_osd #(parameter integer PIXEL_HZ=148500000)(
 input wire clk,rst_n,input wire [11:0] x,y,
 input wire [9:0] source_fps,
 input wire picture_index,frame_commit,frame_tick,input wire [9:0] capture_fps,
 input wire [7:0] r,g,b,input wire hs,vs,de,
 output reg [7:0] o_r,o_g,o_b,output reg o_hs,o_vs,o_de,
 output reg [9:0] image_fps,hdmi_hz);
 reg [27:0] seconds;
 reg [9:0] images,frames;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin seconds<=0;images<=0;frames<=0;image_fps<=0;hdmi_hz<=0;end
  else if(seconds==PIXEL_HZ-1)begin
   seconds<=0;image_fps<=images+frame_commit;hdmi_hz<=frames+frame_tick;
   images<=0;frames<=0;
  end else begin
   seconds<=seconds+1'b1;
   if(frame_commit && images<999)images<=images+1'b1;
   if(frame_tick && frames<999)frames<=frames+1'b1;
  end
 end
 function [34:0] glyph;
 input [7:0] ch;
 begin case(ch)
 8'd48:glyph=35'h3a33ae62e;
 8'd49:glyph=35'h11842108e;
 8'd50:glyph=35'h3a211111f;
 8'd51:glyph=35'h78217043e;
 8'd52:glyph=35'h08ca97c42;
 8'd53:glyph=35'h7e10f043e;
 8'd54:glyph=35'h3a10f462e;
 8'd55:glyph=35'h7c2222108;
 8'd56:glyph=35'h3a317462e;
 8'd57:glyph=35'h3a317842e;
 8'd73:glyph=35'h7c842109f;
 8'd77:glyph=35'h4775ac631;
 8'd71:glyph=35'h3a30bc62e;
 8'd70:glyph=35'h7e10f4210;
 8'd80:glyph=35'h7a31f4210;
 8'd83:glyph=35'h3e107043e;
 8'd67:glyph=35'h3a308422e;
 8'd72:glyph=35'h4631fc631;
 8'd68:glyph=35'h7a318c63e;
 8'd58:glyph=35'h008401080;
 8'd65:glyph=35'h3a31fc631;
 8'd78:glyph=35'h4739ace71;
 8'd69:glyph=35'h7e10f421f;
 8'd82:glyph=35'h7a31f4a31;
 8'd87:glyph=35'h4631ad771;
 default:glyph=0;endcase end endfunction
 reg [7:0] character;reg [34:0] bits;
 integer char_index,gx,gy;
 reg ink,box;
 always @* begin
  char_index=0;gx=0;gy=0;character=32;bits=0;ink=0;
  box=x>=32 && x<32+43*12 && y>=44 && y<60;
  if(box)begin
   char_index=(x-32)/12;gx=((x-32)%12)/2;gy=(y-44)/2;
   case(char_index)
    0:character=8'd67;
    1:character=8'd65;
    2:character=8'd80;
    3:character=8'd32;
    4:character=8'd70;
    5:character=8'd80;
    6:character=8'd83;
    7:character=8'd58;
    8:character=8'd32;
    9:character=48+capture_fps/100;
    10:character=48+(capture_fps/10)%10;
    11:character=48+capture_fps%10;
    12:character=8'd32;
    13:character=8'd82;
    14:character=8'd65;
    15:character=8'd87;
    16:character=8'd32;
    17:character=8'd70;
    18:character=8'd80;
    19:character=8'd83;
    20:character=8'd58;
    21:character=48+image_fps/100;
    22:character=48+(image_fps/10)%10;
    23:character=48+image_fps%10;
    24:character=8'd32;
    25:character=8'd32;
    26:character=8'd72;
    27:character=8'd68;
    28:character=8'd77;
    29:character=8'd73;
    30:character=8'd58;
    31:character=48+hdmi_hz/100;
    32:character=48+(hdmi_hz/10)%10;
    33:character=48+hdmi_hz%10;
    34:character=8'd32;
    35:character=8'd32;
    36:character=8'd83;
    37:character=8'd82;
    38:character=8'd67;
    39:character=8'd58;
    40:character=48+source_fps/100;
    41:character=48+(source_fps/10)%10;
    42:character=48+source_fps%10;
    default:character=32;
   endcase
   bits=glyph(character);
   if(gx<5 && gy<7)ink=bits[34-gy*5-gx];
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin o_r<=0;o_g<=0;o_b<=0;o_hs<=0;o_vs<=0;o_de<=0;end
  else begin
   o_hs<=hs;o_vs<=vs;o_de<=de;
   o_r<=de&&box?(ink?8'hff:8'd0):r;
   o_g<=de&&box?(ink?8'hff:8'd0):g;
   o_b<=de&&box?(ink?8'hff:8'd0):b;
  end
 end
endmodule
