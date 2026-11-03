`timescale 1ns/1ps
`default_nettype none
// Integrated APB/mailbox/lease/DMA control block. It is not yet wired to the
// production capture AXI port or actual NN core. Exclusive ownership must be
// acknowledged by the board before any upload transaction can reach DDR.
// Private results remain outside normal video publication and slot ownership.
module net_image_service #(
 parameter integer PREPARE_TIMEOUT_CYCLES=320000000,
 parameter integer LEASE_TIMEOUT_CYCLES=1600000000,
 parameter integer DMA_TIMEOUT_BITS=20
)(
 input wire cpu_clk,core_clk,root_reset_n,cpu_reset,
 input wire[15:0]PADDR,input wire PSEL,PENABLE,PWRITE,input wire[31:0]PWDATA,
 output wire[31:0]PRDATA,output wire PREADY,PSLVERROR,
 input wire capture_hold_ack,capture_idle,video_idle,core_idle,external_memory_quiet,
 output wire capture_hold,pause_video_jobs,use_upload_axi,lease_active,
 output wire nn_owner,nn_job_valid,input wire nn_job_ready,nn_job_done,nn_job_drained,nn_job_error,
 output wire[2:0]nn_style,output wire[31:0]nn_input_base,nn_output_base,
 output wire[31:0]generation,output wire[3:0]phase,output wire[7:0]terminal_status,
 output wire memory_busy,control_busy,
 output wire[31:0]awaddr,output wire[7:0]awlen,output wire awvalid,input wire awready,
 output wire[127:0]wdata,output wire[15:0]wstrb,output wire wlast,wvalid,input wire wready,
 input wire[3:0]bid,input wire[1:0]bresp,input wire bvalid,output wire bready,
 output wire[31:0]araddr,output wire[7:0]arlen,output wire arvalid,input wire arready,
 input wire[3:0]rid,input wire[127:0]rdata,input wire[1:0]rresp,
 input wire rlast,rvalid,output wire rready
);
 wire request_valid,request_ready,response_valid,response_ready;
 wire[255:0]request,response;
 wire reset_core,orphan_core;
 wire lease_command_valid,lease_ack;
 wire[2:0]lease_command;
 wire[31:0]lease_command_generation,last_released_generation;
 wire[2:0]lease_command_style;
 wire[7:0]lease_status;
 wire memory_allowed,memory_write_allowed;
 wire dma_valid,dma_ready,dma_write,dma_result,dma_response_valid,dma_response_ready;
 wire[31:0]dma_generation,dma_offset,dma_response_generation;
 wire[127:0]dma_data,dma_response_data;
 wire[15:0]dma_mask;
 wire[3:0]dma_error;
 assign nn_input_base=32'h07800000;
 assign nn_output_base=32'h07c00000;
 net_image_mailbox #(.COMPACT_COMMANDS(1)) mailbox(
  .cpu_clk(cpu_clk),.core_clk(core_clk),.root_reset_n(root_reset_n),.cpu_reset(cpu_reset),
  .PADDR(PADDR),.PSEL(PSEL),.PENABLE(PENABLE),.PWRITE(PWRITE),.PWDATA(PWDATA),
  .PRDATA(PRDATA),.PREADY(PREADY),.PSLVERROR(PSLVERROR),
  .core_request_valid(request_valid),.core_request_ready(request_ready),.core_request(request),
  .core_response_valid(response_valid),.core_response_ready(response_ready),.core_response(response),
  .cpu_reset_core(reset_core),.cpu_orphan_core(orphan_core),.core_busy(control_busy));
 net_image_dispatch dispatcher(
  .clk(core_clk),.root_reset_n(root_reset_n),.cpu_quarantine(reset_core||orphan_core),
  .request_valid(request_valid),.request_ready(request_ready),.request(request),
  .response_valid(response_valid),.response_ready(response_ready),.response(response),
  .lease_command_valid(lease_command_valid),.lease_command(lease_command),
  .lease_command_generation(lease_command_generation),.lease_command_style(lease_command_style),
  .lease_ack(lease_ack),.lease_status(lease_status),.generation(generation),.phase(phase),
  .memory_allowed(memory_allowed),.memory_write_allowed(memory_write_allowed),.terminal_status(terminal_status),
  .dma_valid(dma_valid),.dma_ready(dma_ready),.dma_write(dma_write),.dma_result(dma_result),
  .dma_generation(dma_generation),.dma_offset(dma_offset),.dma_data(dma_data),.dma_mask(dma_mask),
  .dma_response_valid(dma_response_valid),.dma_response_ready(dma_response_ready),
  .dma_error(dma_error),.dma_response_data(dma_response_data));
 net_image_lease #(.PREPARE_TIMEOUT_CYCLES(PREPARE_TIMEOUT_CYCLES),.LEASE_TIMEOUT_CYCLES(LEASE_TIMEOUT_CYCLES)) lease(
  .clk(core_clk),.root_reset_n(root_reset_n),.command_valid(lease_command_valid),.command(lease_command),
  .command_generation(lease_command_generation),.command_style(lease_command_style),
  .command_ack(lease_ack),.command_status(lease_status),
  .capture_hold_ack(capture_hold_ack),.capture_idle(capture_idle),.video_idle(video_idle),.core_idle(core_idle),
  .memory_quiet(external_memory_quiet&&!memory_busy),
  .memory_activity(memory_busy||request_valid||control_busy),
  .capture_hold(capture_hold),.pause_video_jobs(pause_video_jobs),.use_upload_axi(use_upload_axi),
  .lease_active(lease_active),.memory_allowed(memory_allowed),.memory_write_allowed(memory_write_allowed),.owns_nn(nn_owner),
  .job_valid(nn_job_valid),.job_ready(nn_job_ready),.job_done(nn_job_done),.job_drained(nn_job_drained),.job_error(nn_job_error),
  .generation(generation),.last_released_generation(last_released_generation),.style(nn_style),.phase(phase),.terminal_status(terminal_status));
 net_image_line_dma #(.TIMEOUT_BITS(DMA_TIMEOUT_BITS),.ALLOW_PRIVATE_RESULT(1)) dma(
  .clk(core_clk),.root_reset_n(root_reset_n),.lease_valid(memory_allowed),.lease_write_enabled(memory_write_allowed),
  .lease_generation(generation),.result_base(32'h07c00000),.result_bytes(32'd2764800),
  .cmd_valid(dma_valid),.cmd_ready(dma_ready),.cmd_write(dma_write),.cmd_result(dma_result),
  .cmd_generation(dma_generation),.cmd_offset(dma_offset),.cmd_data(dma_data),.cmd_mask(dma_mask),
  .busy(memory_busy),.resp_valid(dma_response_valid),.resp_ready(dma_response_ready),
  .resp_error(dma_error),.resp_data(dma_response_data),.resp_generation(dma_response_generation),
  .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
  .wdata(wdata),.wstrb(wstrb),.wlast(wlast),.wvalid(wvalid),.wready(wready),
  .bid(bid),.bresp(bresp),.bvalid(bvalid),.bready(bready),
  .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
  .rid(rid),.rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready));
endmodule
`default_nettype wire
