module ddr_addr_test (
    input               clk,
    input               rst_n,
    input               cal_done,

    output [31:0]       awaddr,
    output [7:0]        awlen,
    output              awvalid,
    input               awready,

    output [127:0]      wdata,
    output              wlast,
    output              wvalid,
    input               wready,

    input [3:0]         bid,
    input [1:0]         bresp,
    input               bvalid,
    output              bready,

    output [31:0]       araddr,
    output [7:0]        arlen,
    output              arvalid,
    input               arready,

    input [3:0]         rid,
    input [127:0]       rdata,
    input [1:0]         rresp,
    input               rlast,
    input               rvalid,
    output              rready,

    output reg          test_done,
    output reg          test_error,
    output reg [3:0]    error_code,
    output reg [31:0]   error_addr
);

localparam S_WAIT = 4'd0;
localparam S_AW   = 4'd1;
localparam S_W    = 4'd2;
localparam S_B    = 4'd3;
localparam S_AR   = 4'd4;
localparam S_R    = 4'd5;
localparam S_END  = 4'd6;
localparam S_FAIL = 4'd7;

localparam BASE0 = 32'h02000000;
localparam BASE1 = 32'h02200000;

// 每区16个突发，每个突发16拍，每拍16字节。
reg [3:0] state;
reg       region;
reg [3:0] burst_index;
reg [3:0] beat_index;
reg [19:0] wait_count;

(* async_reg = "true" *) reg [1:0] cal_sync;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        cal_sync <= 2'b00;
    else
        cal_sync <= {cal_sync[0], cal_done};
end

wire [31:0] burst_address =
    (region ? BASE1 : BASE0) +
    {20'd0, burst_index, 8'd0};

wire [31:0] beat_address =
    burst_address + {24'd0, beat_index, 4'd0};

wire [127:0] expected = {
    beat_address ^ 32'hA5A55A5A,
    beat_address ^ 32'h12345678,
    beat_address ^ 32'hFEDCBA98,
    beat_address ^ 32'h55AA33CC
};

assign awaddr  = burst_address;
assign awlen   = 8'd15;
assign awvalid = (state == S_AW);

assign wdata   = expected;
assign wlast   = (beat_index == 4'd15);
assign wvalid  = (state == S_W);
assign bready  = (state == S_B);

assign araddr  = burst_address;
assign arlen   = 8'd15;
assign arvalid = (state == S_AR);
assign rready  = (state == S_R);

wire progress =
    ((state == S_AW) && awready) ||
    ((state == S_W ) && wready ) ||
    ((state == S_B ) && bvalid ) ||
    ((state == S_AR) && arready) ||
    ((state == S_R ) && rvalid );

wire active =
    (state == S_AW) || (state == S_W) ||
    (state == S_B)  || (state == S_AR) ||
    (state == S_R);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= S_WAIT;
        region      <= 1'b0;
        burst_index <= 4'd0;
        beat_index  <= 4'd0;
        wait_count  <= 20'd0;
        test_done   <= 1'b0;
        test_error  <= 1'b0;
        error_code  <= 4'd0;
        error_addr  <= 32'd0;
    end else begin
        if (!active || progress)
            wait_count <= 20'd0;
        else
            wait_count <= wait_count + 1'b1;

        // 100MHz下约10.49ms没有握手，报告超时。
        if (active && !progress && (&wait_count)) begin
            state      <= S_FAIL;
            test_error <= 1'b1;
            error_code <= 4'd5;
            error_addr <= beat_address;
        end else begin
            case (state)
                S_WAIT: begin
                    if (cal_sync[1])
                        state <= S_AW;
                end

                S_AW: begin
                    if (awready) begin
                        beat_index <= 4'd0;
                        state      <= S_W;
                    end
                end

                S_W: begin
                    // 只在实际握手后推进数据和拍号。
                    if (wready) begin
                        if (beat_index == 4'd15) begin
                            beat_index <= 4'd0;
                            state      <= S_B;
                        end else begin
                            beat_index <= beat_index + 1'b1;
                        end
                    end
                end

                S_B: begin
                    // 收到成功写响应后才开始下一突发。
                    if (bvalid) begin
                        if ((bresp != 2'b00) ||
                            (bid != 4'd0)) begin
                            state      <= S_FAIL;
                            test_error <= 1'b1;
                            error_code <= 4'd1;
                            error_addr <= burst_address;
                        end else if (burst_index != 4'd15) begin
                            burst_index <= burst_index + 1'b1;
                            state       <= S_AW;
                        end else if (!region) begin
                            region      <= 1'b1;
                            burst_index <= 4'd0;
                            state       <= S_AW;
                        end else begin
                            // 两区全部写完，开始回读。
                            region      <= 1'b0;
                            burst_index <= 4'd0;
                            beat_index  <= 4'd0;
                            state       <= S_AR;
                        end
                    end
                end

                S_AR: begin
                    if (arready) begin
                        beat_index <= 4'd0;
                        state      <= S_R;
                    end
                end

                S_R: begin
                    if (rvalid) begin
                        if ((rresp != 2'b00) ||
                            (rid != 4'd0)) begin
                            state      <= S_FAIL;
                            test_error <= 1'b1;
                            error_code <= 4'd2;
                            error_addr <= beat_address;
                        end else if (
                            rlast != (beat_index == 4'd15)
                        ) begin
                            // 前15拍不能有RLAST，
                            // 第16拍必须有RLAST。
                            state      <= S_FAIL;
                            test_error <= 1'b1;
                            error_code <= 4'd3;
                            error_addr <= beat_address;
                        end else if (rdata != expected) begin
                            state      <= S_FAIL;
                            test_error <= 1'b1;
                            error_code <= 4'd4;
                            error_addr <= beat_address;
                        end else if (beat_index != 4'd15) begin
                            beat_index <= beat_index + 1'b1;
                        end else begin
                            beat_index <= 4'd0;

                            if (burst_index != 4'd15) begin
                                burst_index <= burst_index + 1'b1;
                                state       <= S_AR;
                            end else if (!region) begin
                                region      <= 1'b1;
                                burst_index <= 4'd0;
                                state       <= S_AR;
                            end else begin
                                test_done <= 1'b1;
                                state     <= S_END;
                            end
                        end
                    end
                end

                S_END:  state <= S_END;
                S_FAIL: state <= S_FAIL;
                default: state <= S_WAIT;
            endcase
        end
    end
end

endmodule