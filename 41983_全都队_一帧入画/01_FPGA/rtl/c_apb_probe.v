// Hardware bring-up peripheral. This is NOT the A/C NN control interface.
module c_apb_probe #(
    parameter CORE_HZ = 100000000,
    parameter EXTRA_CAPABILITIES = 0,
    parameter RAM_BASE = 32'hF9000000,
    parameter RAM_BYTES = 16384
)(
    input wire clk,
    input wire reset,
    input wire [15:0] PADDR,
    input wire PSEL,
    input wire PENABLE,
    input wire PWRITE,
    input wire [31:0] PWDATA,
    output reg [31:0] PRDATA,
    output wire PREADY,
    output wire PSLVERROR
);
    reg [31:0] heartbeat;
    reg [31:0] scratch;
    reg valid_read;
    assign PREADY = 1'b1;
    assign PSLVERROR = PSEL && PENABLE &&
        (PWRITE ? (PADDR != 16'h0020) : !valid_read);

    always @* begin
        PRDATA = 0;
        valid_read = 1'b1;
        case (PADDR)
            16'h0000: PRDATA = 32'h434D0001; // CM bring-up, revision 1
            16'h0004: PRDATA = 32'h00000001 | EXTRA_CAPABILITIES; // capability: full-word scratch
            16'h0008: PRDATA = CORE_HZ;
            16'h000C: PRDATA = RAM_BASE;
            16'h0010: PRDATA = RAM_BYTES;
            16'h0014: PRDATA = heartbeat;
            16'h0020: PRDATA = scratch;
            default: valid_read = 1'b0;
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            heartbeat <= 0;
            scratch <= 0;
        end else begin
            heartbeat <= heartbeat + 1'b1;
            if (PSEL && PENABLE && PWRITE && PADDR == 16'h0020)
                scratch <= PWDATA;
        end
    end
endmodule
