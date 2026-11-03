`timescale 1ns/1ps
`default_nettype none
// Frozen one-shot RGB raster; only flags cross clock domains.
module nn_camera_snapshot #(
    parameter integer SRC_W=1920, SRC_H=1080,
    parameter integer OUT_W=32, OUT_H=24,
    parameter integer REARM_ON_REQUEST_LOW=0,
    parameter integer CAMERA_ADDR_WIDTH=10
)(
    input wire pixel_clk, core_clk, rst_n, request, vs, de,
    input wire [7:0] r, g, b,
    input wire [CAMERA_ADDR_WIDTH-1:0] read_addr, output reg [31:0] read_data,
    output wire ready, failed
);
    localparam integer STEP_X=SRC_W/OUT_W, STEP_Y=SRC_H/OUT_H;
    localparam integer WORDS=OUT_W*OUT_H;
    (* syn_ramstyle="block_ram" *) reg [31:0] mem [0:WORDS-1];
    (* async_reg="true" *) reg [1:0] request_sync;
    (* async_reg="true" *) reg [1:0] ready_sync, fail_sync;
    reg vs_d, de_d, active, complete, bad;
    reg [11:0] x, y, next_x, next_y;
    reg [CAMERA_ADDR_WIDTH-1:0] count;
    // Fractional vertical spacing: floor((row+1/2)*SRC_H/OUT_H).
    localparam integer YFRAC_W=$clog2(OUT_H+1);
    reg [YFRAC_W-1:0] y_fraction;
    wire frame_edge=vs && !vs_d;
    wire sample=active && de && (x==next_x) && (y==next_y);
    // round(127 * byte / 255) equals byte >> 1 for uint8 input.
    always @(posedge pixel_clk)
        if (sample) mem[count] <= {8'd0,1'b0,b[7:1],1'b0,g[7:1],1'b0,r[7:1]};
    always @(posedge core_clk) read_data <= mem[read_addr];
    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin ready_sync<=0; fail_sync<=0; end
        else begin
            ready_sync<={ready_sync[0],complete};
            fail_sync<={fail_sync[0],bad};
        end
    end
    assign ready=ready_sync[1];
    assign failed=fail_sync[1];
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            request_sync<=0; vs_d<=0; de_d<=0; active<=0;
            complete<=0; bad<=0; x<=0; y<=0; count<=0;
            next_x<=STEP_X/2; next_y<=STEP_Y/2;
            y_fraction<=(SRC_H/2)%OUT_H;
        end else begin
            request_sync<={request_sync[0],request};
            vs_d<=vs; de_d<=de;
            if ((REARM_ON_REQUEST_LOW != 0) && !request_sync[1]) begin
                active<=0; complete<=0; bad<=0; x<=0; y<=0; count<=0;
                next_x<=STEP_X/2; next_y<=STEP_Y/2;
                y_fraction<=(SRC_H/2)%OUT_H;
            end else if (frame_edge) begin
                if (active) begin active<=0; bad<=1; end
                else if (request_sync[1] && !complete && !bad) begin
                    active<=1; x<=0; y<=0; count<=0;
                    next_x<=STEP_X/2; next_y<=STEP_Y/2;
                    y_fraction<=(SRC_H/2)%OUT_H;
                end
            end else if (active) begin
                if (de) begin
                    x<=x+1'b1;
                    if (sample) begin
                        count<=count+1'b1;
                        if (count==WORDS-1) begin active<=0; complete<=1; end
                        if (next_x==STEP_X/2+(OUT_W-1)*STEP_X) begin
                            next_x<=STEP_X/2;
                            if(y_fraction+(SRC_H%OUT_H)>=OUT_H) begin
                                next_y<=next_y+STEP_Y+1;
                                y_fraction<=y_fraction+(SRC_H%OUT_H)-OUT_H;
                            end else begin
                                next_y<=next_y+STEP_Y;
                                y_fraction<=y_fraction+(SRC_H%OUT_H);
                            end
                        end else next_x<=next_x+STEP_X;
                    end
                end else if (de_d) begin
                    x<=0; y<=y+1'b1;
                    if (x!=SRC_W || y>=SRC_H) begin active<=0; bad<=1; end
                end
            end
        end
    end
endmodule
`default_nettype wire
