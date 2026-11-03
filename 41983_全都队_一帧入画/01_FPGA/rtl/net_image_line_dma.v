`timescale 1ns/1ps
`default_nettype none
// Single-outstanding 128-bit transfer for an exclusively leased DDR window.
// This is not yet wired into the board. CPU reset must not reset this block:
// root_reset_n may assert only with the DDR fabric reset. Cancellation/timeout
// never retracts an outstanding AXI VALID or releases ownership prematurely.
module net_image_line_dma #(
 parameter [31:0] RAW_BASE=32'h07800000,
 parameter [31:0] RAW_BYTES=32'h00400000,
 parameter integer TIMEOUT_BITS=20,
 parameter integer ALLOW_PRIVATE_RESULT=0
)(
 input wire clk,root_reset_n,
 input wire lease_valid,lease_write_enabled,input wire [31:0]lease_generation,
 input wire [31:0]result_base,result_bytes,
 input wire cmd_valid,output wire cmd_ready,
 input wire cmd_write,cmd_result,input wire [31:0]cmd_generation,cmd_offset,
 input wire [127:0]cmd_data,input wire [15:0]cmd_mask,
 output wire busy,output wire resp_valid,input wire resp_ready,
 output reg [3:0]resp_error,output reg [127:0]resp_data,
 output reg [31:0]resp_generation,
 output wire [31:0]awaddr,output wire [7:0]awlen,output wire awvalid,input wire awready,
 output wire [127:0]wdata,output wire [15:0]wstrb,output wire wlast,wvalid,input wire wready,
 input wire [3:0]bid,input wire [1:0]bresp,input wire bvalid,output wire bready,
 output wire [31:0]araddr,output wire [7:0]arlen,output wire arvalid,input wire arready,
 input wire [3:0]rid,input wire [127:0]rdata,input wire [1:0]rresp,
 input wire rlast,rvalid,output wire rready
);
 localparam IDLE=0,AR=1,R=2,AW=3,W=4,B=5,RESP=6;
 // error bits: range/permission, AXI, lease lost, timeout (after actual drain).
 reg [2:0]state;
 reg write_pending,read_seen;
 reg [31:0]address;
 // The same 16-byte register holds incoming write data, merged RMW data,
 // and read response data. No extra frame/line RAM or duplicate 128-bit copy.
 reg [15:0]mask;
 reg [TIMEOUT_BITS-1:0]wait_count;
 // All legal production windows are 4MiB-aligned. Concatenating the
 // validated offset avoids a wide base+offset adder and overflow chain.
 // Keep the generic arithmetic for non-production RAW parameters.
 wire [31:0]command_address;
 wire address_range_ok;
 wire result_config_ok=(result_base==32'h06000000 || result_base==32'h06800000 ||
                        result_base==32'h07000000 ||
                        (ALLOW_PRIVATE_RESULT!=0 && result_base==32'h07c00000)) && result_bytes<=32'd2764800;
 generate if(RAW_BASE==32'h07800000 && RAW_BYTES==32'h00400000)begin:G_ALIGNED_WINDOWS
  assign command_address={cmd_result?result_base[31:22]:RAW_BASE[31:22],cmd_offset[21:0]};
  // For aligned offsets, offset+16<=bytes iff offset/16<floor(bytes/16).
  assign address_range_ok=cmd_offset[3:0]==0 && cmd_offset[31:22]==0 &&
                         (!cmd_result || (result_config_ok && cmd_offset[21:4]<result_bytes[31:4]));
 end else begin:G_GENERIC_WINDOWS
  wire [31:0]selected_base=cmd_result?result_base:RAW_BASE;
  wire [31:0]selected_bytes=cmd_result?result_bytes:RAW_BYTES;
  wire [32:0]absolute_address={1'b0,selected_base}+{1'b0,cmd_offset};
  wire [32:0]last_offset={1'b0,cmd_offset}+33'd16;
  assign command_address=absolute_address[31:0];
  assign address_range_ok=cmd_offset[3:0]==0 && selected_base[3:0]==0 &&
                         last_offset<={1'b0,selected_bytes} && !absolute_address[32] &&
                         absolute_address<=33'h0fffffff0 && (!cmd_result || result_config_ok);
 end endgenerate
 wire range_ok=address_range_ok && !(cmd_write&&cmd_result) && !(cmd_write&&!lease_write_enabled);
 wire transferred=(state==AR&&arready)||(state==R&&rvalid)||
                  (state==AW&&awready)||(state==W&&wready)||(state==B&&bvalid);
 assign cmd_ready=state==IDLE;
 assign busy=state!=IDLE;
 assign resp_valid=state==RESP;
 assign araddr=address;assign arlen=0;assign arvalid=state==AR;
 assign rready=state==R;
 assign awaddr=address;assign awlen=0;assign awvalid=state==AW;
 assign wdata=resp_data;assign wstrb=16'hffff;assign wlast=1;
 assign wvalid=state==W;assign bready=state==B;
 integer i;
 always @(posedge clk or negedge root_reset_n)begin
  if(!root_reset_n)begin
   state<=IDLE;address<=0;mask<=0;
   write_pending<=0;read_seen<=0;wait_count<=0;
   resp_error<=0;resp_data<=0;resp_generation<=0;
  end else begin
   if(state!=IDLE&&state!=RESP)begin
    if(!lease_valid || lease_generation!=resp_generation)resp_error[2]<=1;
    if(transferred)wait_count<=0;
    else if(!(&wait_count))wait_count<=wait_count+1'b1;
    else resp_error[3]<=1;
   end
   case(state)
    IDLE:if(cmd_valid)begin
     resp_generation<=cmd_generation;resp_error<=0;resp_data<=cmd_data;wait_count<=0;
     address<=command_address;
     mask<=cmd_mask;write_pending<=cmd_write;read_seen<=0;
     if(!lease_valid || cmd_generation!=lease_generation)begin resp_error<=4'b0100;state<=RESP;end
     else if(!range_ok)begin resp_error<=4'b0001;state<=RESP;end
     else if(cmd_write && cmd_mask==0)state<=RESP;
     else if(cmd_write && cmd_mask==16'hffff)state<=AW;
     else state<=AR;
    end
    AR:if(arready)begin state<=R;read_seen<=0;end
    R:if(rvalid)begin
     if(!read_seen)begin
      // RMW preserves untouched bytes while emitting only a full write mask.
      for(i=0;i<16;i=i+1)
       if(!write_pending || !mask[i])resp_data[i*8+:8]<=rdata[i*8+:8];
     end
     if(rresp!=0 || rid!=0 || read_seen || !rlast)resp_error[1]<=1;
     read_seen<=1;
     if(rlast)begin
      if(write_pending && !read_seen && rresp==0 && rid==0 && resp_error==0 &&
         lease_valid && lease_generation==resp_generation)state<=AW;
      else state<=RESP;
     end
    end
    AW:if(awready)state<=W;
    W:if(wready)state<=B;
    B:if(bvalid)begin
     if(bresp!=0 || bid!=0)resp_error[1]<=1;
     state<=RESP;
    end
    RESP:if(resp_ready)state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
