`timescale 1ns/1ps
`default_nettype none
// Horizontal perceptual wide-angle remap, not a reconstruction of unseen FOV.
// Inverse sampling: enlarge the center, compress the periphery, retain edges.
// Monotonic four-segment approximation. Constant shift/add logic: no DSP/ROM.
module cat_wide_angle_mapper #(
 parameter integer WIDTH=640, STRENGTH=1,
 parameter integer X_BITS=$clog2(WIDTH)
)(
 input wire [X_BITS-1:0] out_x,
 output reg [X_BITS-1:0] source_x
);
 localparam integer HALF=WIDTH/2, QUARTER=WIDTH/8;
 reg [X_BITS:0] distance_x;
 reg [X_BITS+3:0] distance_wide, mapped_distance;
 reg left_half;
 always @* begin
  left_half=(out_x<HALF);
  distance_x=left_half?(HALF-1-out_x):(out_x-HALF);
  distance_wide=distance_x;
  mapped_distance=distance_wide;
  if(STRENGTH==1)begin
   if(distance_x<QUARTER)mapped_distance=((distance_wide<<1)+distance_wide)>>2;
   else if(distance_x<2*QUARTER)mapped_distance=((distance_wide<<3)-distance_wide-QUARTER)>>3;
   else if(distance_x<3*QUARTER)mapped_distance=((distance_wide<<3)+distance_wide-5*QUARTER)>>3;
   else mapped_distance=((distance_wide<<2)+distance_wide-4*QUARTER)>>2;
  end else if(STRENGTH==2)begin
   if(distance_x<QUARTER)mapped_distance=distance_wide>>1;
   else if(distance_x<2*QUARTER)mapped_distance=((distance_wide<<1)+distance_wide-QUARTER)>>2;
   else if(distance_x<3*QUARTER)mapped_distance=((distance_wide<<2)+distance_wide-5*QUARTER)>>2;
   else mapped_distance=((distance_wide<<1)+distance_wide-4*QUARTER)>>1;
  end
  // Preserve exact edge columns even after integer rounding.
  if(distance_x==HALF-1 || mapped_distance>=HALF)mapped_distance=HALF-1;
  source_x=left_half?(HALF-1-mapped_distance):(HALF+mapped_distance);
  if(STRENGTH==0)source_x=out_x;
  if(out_x>=WIDTH)source_x=WIDTH-1;
 end
 initial begin
  if(WIDTH<16 || WIDTH%16 || STRENGTH<0 || STRENGTH>2)$fatal(1,"unsupported cat wide-angle geometry");
 end
endmodule
`default_nettype wire
