module nn_fps_monitor #(parameter integer CORE_HZ=100000000,BUFFER_BITS=1)(
 input wire core_clk,pixel_clk,rst_n,done,pass,fail,
 input wire display_enable,
 input wire [BUFFER_BITS-1:0] display_buffer,
 input wire frame_shown,
 output reg [9:0] nn_fps,new_fps);
 reg [31:0] seconds;
 reg [9:0] nn_count,new_count;
 reg done_d,enable_d,pending;
 reg [BUFFER_BITS-1:0] buffer_d;
 wire nn_event=done && !done_d && pass && !fail;
 wire publication=display_enable && (!enable_d || display_buffer!=buffer_d);
 wire new_event=display_enable && frame_shown && (pending || publication) && !fail;
 reg [19:0] snapshot;
 reg request_toggle,ack_toggle;
 (* async_reg="true" *) reg [1:0] ack_sync;
 (* async_reg="true" *) reg [2:0] request_sync;
 wire idle=ack_sync[1]==request_toggle;
 function [9:0] sat_inc;
 input [9:0] value;input event_in;
 begin sat_inc=(event_in && value<999)?value+1'b1:value;end
 endfunction
 always @(posedge core_clk or negedge rst_n) begin
  if(!rst_n)begin seconds<=0;nn_count<=0;new_count<=0;done_d<=0;enable_d<=0;buffer_d<=0;pending<=0;snapshot<=0;request_toggle<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[0],ack_toggle};done_d<=done;enable_d<=display_enable;buffer_d<=display_buffer;
   if(!display_enable) pending<=0;
   else if(new_event) pending<=0;
   else if(publication) pending<=1;
   if(seconds==CORE_HZ-1)begin
    seconds<=0;
    if(idle)begin snapshot<={sat_inc(nn_count,nn_event),sat_inc(new_count,new_event)};request_toggle<=~request_toggle;end
    nn_count<=0;new_count<=0;
   end else begin seconds<=seconds+1'b1;nn_count<=sat_inc(nn_count,nn_event);new_count<=sat_inc(new_count,new_event);end
  end
 end
 always @(posedge pixel_clk or negedge rst_n)begin
  if(!rst_n)begin request_sync<=0;ack_toggle<=0;nn_fps<=0;new_fps<=0;end
  else begin
   request_sync<={request_sync[1:0],request_toggle};
   if(request_sync[2]!=ack_toggle)begin {nn_fps,new_fps}<=snapshot;ack_toggle<=request_sync[2];end
  end
 end
endmodule
module nn_fps_osd #(parameter integer PIXEL_HZ=148500000,SHOW_STATUS=0)(
 input wire clk,rst_n,input wire [11:0] x,y,
 input wire [25:0] debug_status,
 input wire [9:0] source_fps,new_fps,camera_capture_fps,
 input wire picture_index,frame_commit,frame_tick,input wire [9:0] capture_fps,
 input wire [7:0] r,g,b,input wire hs,vs,de,
 output reg [7:0] o_r,o_g,o_b,output reg o_hs,o_vs,o_de,
 output reg [9:0] image_fps,hdmi_hz);
 // Display-only debug sampling, never used for ownership or video control.
 (* async_reg="true" *) reg [25:0] status_meta,status_sync;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin status_meta<=0;status_sync<=0;end
  else if(SHOW_STATUS!=0)begin status_meta<=debug_status;status_sync<=status_meta;end
 end
 function [7:0] hex_char;
 input [3:0] value;begin hex_char=value<10?48+value:65+value-10;end endfunction
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
 8'd85:glyph=35'h46318c62e;
 8'd79:glyph=35'h3a318c62e;
 8'd75:glyph=35'h4654c5631;
 8'd66:glyph=35'h7a31f463e;
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
  box=x>=32 && ((x<32+34*16 && y>=20 && y<36) || (x<32+32*16 && y>=44 && y<60) || (SHOW_STATUS!=0 && x<32+40*16 && y>=68 && y<84));
  if(box)begin
   char_index=(x-32)>>4;gx=((x-32)&15)>>1;gy=(y>=68)?(y-68)/2:(y>=44)?(y-44)/2:(y-20)/2;
   if(y>=68)char_index=char_index+64;else if(y>=44)char_index=char_index+34;
   case(char_index)
    0:character=8'd78;
    1:character=8'd65;
    2:character=8'd32;
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
    13:character=8'd78;
    14:character=8'd69;
    15:character=8'd87;
    16:character=8'd32;
    17:character=8'd70;
    18:character=8'd80;
    19:character=8'd83;
    20:character=8'd58;
    21:character=48+new_fps/100;
    22:character=48+(new_fps/10)%10;
    23:character=48+new_fps%10;
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
    34:character=8'd67;
    35:character=8'd65;
    36:character=8'd80;
    37:character=8'd58;
    38:character=8'd32;
    39:character=48+camera_capture_fps/100;
    40:character=48+(camera_capture_fps/10)%10;
    41:character=48+camera_capture_fps%10;
    42:character=8'd32;
    43:character=8'd32;
    44:character=8'd82;
    45:character=8'd65;
    46:character=8'd87;
    47:character=8'd58;
    48:character=8'd32;
    49:character=48+image_fps/100;
    50:character=48+(image_fps/10)%10;
    51:character=48+image_fps%10;
    52:character=8'd32;
    53:character=8'd32;
    54:character=8'd83;
    55:character=8'd82;
    56:character=8'd67;
    57:character=8'd58;
    58:character=8'd32;
    59:character=48+source_fps/100;
    60:character=48+(source_fps/10)%10;
    61:character=48+source_fps%10;
    62:character=8'd32;
    64:character=73;
    65:character=78;
    66:character=58;
    67:character=hex_char(status_sync[25:22]);
    68:character=hex_char(status_sync[21:18]);
    69:character=32;
    70:character=83;
    71:character=58;
    72:character=48+status_sync[17];
    73:character=48+status_sync[16];
    74:character=48+status_sync[15];
    75:character=32;
    76:character=69;
    77:character=82;
    78:character=82;
    79:character=58;
    80:character=hex_char(status_sync[14:11]);
    81:character=hex_char(status_sync[10:7]);
    82:character=32;
    83:character=78;
    84:character=78;
    85:character=58;
    86:character=hex_char({1'b0,status_sync[6:4]});
    87:character=32;
    88:character=68;
    89:character=83;
    90:character=80;
    91:character=58;
    92:character=hex_char({2'b0,status_sync[3:2]});
    93:character=32;
    94:character=82;
    95:character=85;
    96:character=78;
    97:character=58;
    98:character=48+status_sync[1];
    99:character=32;
    100:character=79;
    101:character=75;
    102:character=58;
    103:character=48+status_sync[0];
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
