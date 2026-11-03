`timescale 1ns/1ps
`default_nettype none

// Held-payload, request/ack CDC. All users share the same global reset.
module camera_light_mailbox #(parameter WIDTH=35)(
 input wire src_clk,dst_clk,rst_n,input wire send,input wire [WIDTH-1:0] data,
 output wire busy,output reg pulse,output reg [WIDTH-1:0] received);
 wire source_rst_n,destination_rst_n;
 hdmi_reset_release u_source_release(.clk(src_clk),.rst_n(rst_n),.released_n(source_rst_n));
 hdmi_reset_release u_destination_release(.clk(dst_clk),.rst_n(rst_n),.released_n(destination_rst_n));

 reg request,ack; reg [WIDTH-1:0] held;
 (* async_reg="true" *) reg [1:0] req_sync,ack_sync;
 assign busy=request!=ack_sync[1];
 always @(posedge src_clk or negedge source_rst_n)
  if(!source_rst_n)begin request<=0;held<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};
   if(send&&!busy)begin held<=data;request<=~request;end
  end
 always @(posedge dst_clk or negedge destination_rst_n)
  if(!destination_rst_n)begin ack<=0;req_sync<=0;pulse<=0;received<=0;end
  else begin
   req_sync<={req_sync[0],request};pulse<=0;
   if(req_sync[1]!=ack)begin received<=held;pulse<=1;ack<=req_sync[1];end
  end
endmodule

// Passive statistics, before the NN input's 7-bit conversion and display tone
// mapping. Never feeds back from a stylised image. One sample per 32x32 grid.
// Complete, unique source frame IDs only; repeated display frames cannot pump AE.
module camera_light_stats #(parameter SAMPLE_LOG2=5,MIN_SAMPLES=256,MIN_NEUTRAL=32)(
 input wire clk,rst_n,valid,sof,frame_done,frame_abort,
 input wire [10:0] x,input wire [9:0] y,input wire [31:0] frame_id,
 input wire [23:0] rgb,output reg result_valid,output reg [34:0] result);
 wire [7:0] r=rgb[7:0],g=rgb[15:8],b=rgb[23:16];
 wire [7:0] mx0=r>g?r:g,mn0=r<g?r:g;
 wire [7:0] mx=mx0>b?mx0:b,mn=mn0<b?mn0:b;
 wire neutral=mn>=16&&mx<224&&{mn,1'b0}>={1'b0,mx};
 wire sample=valid && x[SAMPLE_LOG2-1:0]==(1<<(SAMPLE_LOG2-1)) &&
                           y[SAMPLE_LOG2-1:0]==(1<<(SAMPLE_LOG2-1));
 wire [7:0] lum={2'b0,r[7:2]}+{1'b0,g[7:1]}+{2'b0,b[7:2]};
 reg active,seen,finish_pending;reg [15:0] last_id;
 reg [9:0] count,clips,neutrals;
 wire [17:0] sy,sr,sg,sb;
 wire accumulate=sample&&active&&count!=1023;
 // Paired exact unsigned sums. Rejected B samples add zero while Y advances.
 wire [47:0] sums[0:1];
 wire [17:0] addend[0:1];
 assign addend[0]={2'd0,g,r};assign addend[1]={2'd0,lum,(neutral?b:8'd0)};
 for(genvar k=0;k<2;k=k+1)begin:G_SUM
  EFX_DSP48 #(.MODE("DUAL"),.SIGNED(0),.M_SEL("C"),.N_SEL("W"),.W_SEL("X"),.W_REG(1),.RST_SYNC(1)) u_sum(
   .A(19'd0),.B(18'd0),.C(addend[k]),.CASCIN(48'd0),.OP(2'b00),.SHIFT_ENA(1'b0),
   .CLK(clk),.CE(accumulate&&(k==1||neutral)),.RST(!rst_n||sof),.O(sums[k]),.CASCOUT(),.OVFL());
 end
 assign sr=sums[0][17:0];assign sg=sums[0][41:24];assign sy=sums[1][41:24];assign sb=sums[1][17:0];
 // Use six more spare DSPs for frame-level threshold comparisons. The
 // registered products settle before the delayed result publication.
 wire [47:0] difference[0:5];
 for(genvar q=0;q<6;q=q+1)begin:G_COMPARE
  localparam FACTOR=q==0?112:q==1?72:(q==2||q==4)?31:33;
  wire [18:0] operand=q<2?{9'd0,count}:{1'b0,sg};
  wire [47:0] reference;
  if(q>=2)begin:G_REFERENCE
   // CASCIN requires a dedicated DSP cascade, not a fabric data connection.
   wire [18:0] colour=q<4?{1'b0,sr}:{1'b0,sb};
   EFX_DSP48 #(.SIGNED(0),.P_REG(1),.RST_SYNC(1),.W_SEL("P"),.N_SEL("CONST0"),.CASCOUT_SEL("P")) u_reference(
    .A(colour),.B(18'd32),.C(18'd0),.CASCIN(48'd0),.OP(2'b00),.SHIFT_ENA(1'b0),
    .CLK(clk),.CE(1'b1),.RST(!rst_n),.O(),.CASCOUT(reference),.OVFL());
  end else assign reference=0;
  EFX_DSP48 #(.SIGNED(0),.M_SEL("P"),.N_SEL(q<2?"C":"CASCIN"),.W_SEL("X"),.P_REG(1),.RST_SYNC(1)) u_compare(
   .A(operand),.B(18'(FACTOR)),.C(q<2?sy:18'd0),.CASCIN(reference),.OP(q<2?2'b10:2'b01),
   .SHIFT_ENA(1'b0),.CLK(clk),.CE(1'b1),.RST(!rst_n),.O(difference[q]),.CASCOUT(),.OVFL());
 end
 wire high_mean=!difference[0][47]&&|difference[0][23:0];
 wire [1:0] ae=(clips>(count>>3))?2'd3:
                  (clips>(count>>5)||high_mean)?2'd2:
                  difference[1][47]?2'd1:2'd0;
 // +/- 1/32 ratio deadband, evaluated without a fabric divider or adder.
 wire [1:0] red=(!difference[2][47]&&|difference[2][23:0])?2'd1:difference[3][47]?2'd2:2'd0;
 wire [1:0] blue=(!difference[4][47]&&|difference[4][23:0])?2'd1:difference[5][47]?2'd2:2'd0;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   active<=0;seen<=0;finish_pending<=0;last_id<=0;count<=0;clips<=0;neutrals<=0;
   result_valid<=0;result<=0;
  end else begin
   result_valid<=0;
   finish_pending<=0;
   if(finish_pending)begin
    result<={sy[17:10],count,clips,neutrals>=MIN_NEUTRAL,blue,red,ae};result_valid<=1;
   end
   if(sof)begin
    active<=!seen||frame_id[15:0]!=last_id;
    count<=0;clips<=0;neutrals<=0;
   end
   if(sample&&active&&count!=1023)begin
    count<=count+1'b1;
    if(mx>=240)clips<=clips+1'b1;
    if(neutral)neutrals<=neutrals+1'b1;
   end
   if(frame_done)begin
    if(active&&count>=MIN_SAMPLES)begin
     // Luma field is sy/1024, a brightness index, NOT an exact mean.
     finish_pending<=1;last_id<=frame_id[15:0];seen<=1;
    end
    active<=0;
   end
   if(frame_abort)begin active<=0;result_valid<=0;finish_pending<=0;end
  end
endmodule

`default_nettype wire
