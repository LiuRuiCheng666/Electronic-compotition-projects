`timescale 1ns/1ps
module camera_style_async_fifo #(parameter DATA_WIDTH=130,ADDR_WIDTH=7)(
 input i_arst,i_wclk,i_we,i_rclk,i_re,input [DATA_WIDTH-1:0] i_wdata,
 output wire o_full,o_empty,output reg [DATA_WIDTH-1:0] o_rdata
);
wire writer_rst_n,reader_rst_n;
hdmi_reset_release u_writer_release(.clk(i_wclk),.rst_n(!i_arst),.released_n(writer_rst_n));
hdmi_reset_release u_reader_release(.clk(i_rclk),.rst_n(!i_arst),.released_n(reader_rst_n));
localparam DEPTH=1<<ADDR_WIDTH;
(* syn_ramstyle="block_ram" *) reg [DATA_WIDTH-1:0] mem[0:DEPTH-1];
reg [ADDR_WIDTH:0] write_bin,read_bin,write_gray,read_gray;
(* async_reg="true",syn_preserve=1 *) reg [ADDR_WIDTH:0] read_meta,read_sync,write_meta,write_sync;
wire [ADDR_WIDTH:0] write_next=write_bin+1'b1,read_next=read_bin+1'b1;
assign o_full=write_gray=={~read_sync[ADDR_WIDTH:ADDR_WIDTH-1],read_sync[ADDR_WIDTH-2:0]};
assign o_empty=read_gray==write_sync;
always @(posedge i_wclk)if(i_we && !o_full)mem[write_bin[ADDR_WIDTH-1:0]]<=i_wdata;
always @(posedge i_rclk)if(i_re && !o_empty)o_rdata<=mem[read_bin[ADDR_WIDTH-1:0]];
always @(posedge i_wclk or negedge writer_rst_n)begin
 if(!writer_rst_n)begin write_bin<=0;write_gray<=0;read_meta<=0;read_sync<=0;end
 else begin
  read_meta<=read_gray;read_sync<=read_meta;
  if(i_we && !o_full)begin write_bin<=write_next;write_gray<=(write_next>>1)^write_next;end
 end
end
always @(posedge i_rclk or negedge reader_rst_n)begin
 if(!reader_rst_n)begin read_bin<=0;read_gray<=0;write_meta<=0;write_sync<=0;end
 else begin
  write_meta<=write_gray;write_sync<=write_meta;
  if(i_re && !o_empty)begin read_bin<=read_next;read_gray<=(read_next>>1)^read_next;end
 end
end
endmodule
