// Existing generic held-payload CDC retained for FPS diagnostics.
module raw_frame_descriptor_cdc (
    input src_clk, input dst_clk, input rst_n,
    input src_pulse, input [66:0] src_data,
    output src_busy, output reg src_overrun,
    output reg dst_pulse, output reg [66:0] dst_data
);
 wire source_rst_n,destination_rst_n;
 hdmi_reset_release u_source_release(.clk(src_clk),.rst_n(rst_n),.released_n(source_rst_n));
 hdmi_reset_release u_destination_release(.clk(dst_clk),.rst_n(rst_n),.released_n(destination_rst_n));

reg [66:0] payload;
reg request_toggle, acknowledge_toggle;
(* async_reg = "true" *) reg [1:0] ack_sync;
(* async_reg = "true" *) reg [1:0] req_sync;
assign src_busy = request_toggle != ack_sync[1];
always @(posedge src_clk or negedge source_rst_n) begin
    if (!source_rst_n) begin
        payload <= 67'd0;
        request_toggle <= 1'b0;
        ack_sync <= 2'b00;
        src_overrun <= 1'b0;
    end else begin
        ack_sync <= {ack_sync[0], acknowledge_toggle};
        if (src_pulse) begin
            if (!src_busy) begin
                payload <= src_data;
                request_toggle <= ~request_toggle;
            end else
                src_overrun <= 1'b1;
        end
    end
end
always @(posedge dst_clk or negedge destination_rst_n) begin
    if (!destination_rst_n) begin
        req_sync <= 2'b00;
        acknowledge_toggle <= 1'b0;
        dst_pulse <= 1'b0;
        dst_data <= 67'd0;
    end else begin
        req_sync <= {req_sync[0], request_toggle};
        dst_pulse <= 1'b0;
        if (req_sync[1] != acknowledge_toggle) begin
            dst_data <= payload;
            dst_pulse <= 1'b1;
            acknowledge_toggle <= req_sync[1];
        end
    end
end
endmodule
