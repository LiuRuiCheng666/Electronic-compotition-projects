// Two mirrored synchronous RAMs supply the accumulate and emit read ports.
// Writes commit one cycle later; forwarding preserves the original interface:
// registered one-cycle read, pre-write data, and accumulate wins over clear.
`default_nettype none
module acc_bank #(
    parameter integer OVERWRITE=0,
    parameter integer STORE_W=32,
    parameter integer P_PX=32, P_CO=8, ACC_W=32, PXW=5, COW=3
)(
    input wire clk, rst_n,
    input wire clr_valid,
    input wire [PXW-1:0] clr_px,
    input wire acc_valid,
    input wire acc_overwrite,
    input wire [PXW-1:0] acc_px,
    input wire [P_CO*ACC_W-1:0] acc_sum,
    input wire [PXW-1:0] rd_px,
    output wire [P_CO*ACC_W-1:0] rd_data,
    output reg commit_valid,
    output reg [P_CO*ACC_W-1:0] committed_sum
);
    localparam integer WIDTH=P_CO*ACC_W;
    localparam integer SW=(STORE_W<ACC_W)?STORE_W:ACC_W;
    localparam integer MEM_WIDTH=P_CO*SW;
    reg [WIDTH-1:0] commit_data;reg pending;
    wire [MEM_WIDTH-1:0] stored_commit;
    wire [WIDTH-1:0] expanded_acc,expanded_emit;
    reg [MEM_WIDTH-1:0] acc_mem_q,emit_mem_q;
    genvar lane;
    generate for(lane=0;lane<P_CO;lane=lane+1)begin:G_MEMORY_LANE
        assign stored_commit[lane*SW+:SW]=commit_data[lane*ACC_W+:SW];
        assign expanded_acc[lane*ACC_W+:ACC_W]={{(ACC_W-SW){acc_mem_q[lane*SW+SW-1]}},acc_mem_q[lane*SW+:SW]};
        assign expanded_emit[lane*ACC_W+:ACC_W]={{(ACC_W-SW){emit_mem_q[lane*SW+SW-1]}},emit_mem_q[lane*SW+:SW]};
`ifndef SYNTHESIS
        always @(posedge clk)if(rst_n && pending && SW<ACC_W)
            if($signed(commit_data[lane*ACC_W+:ACC_W])!==$signed(stored_commit[lane*SW+:SW]))$fatal(1,"accumulator storage range exceeded");
`endif
    end endgenerate
    // RAM contents need no reset: one validity bit per pixel implements zero.
    reg [P_PX-1:0] live;
    reg base_live,acc_forward;
    reg [PXW-1:0] pending_px;
    reg [WIDTH-1:0] pending_sum, acc_forward_data;
    wire [WIDTH-1:0] acc_q=expanded_acc,emit_q=expanded_emit;
    reg emit_live, emit_forward;
    reg [WIDTH-1:0] emit_forward_data;
    wire [WIDTH-1:0] base_data = !base_live ? {WIDTH{1'b0}} :
                                      acc_forward ? acc_forward_data : acc_q;
    integer c;
    always @* begin
        for (c=0; c<P_CO; c=c+1)
            commit_data[c*ACC_W +: ACC_W] =
                base_data[c*ACC_W +: ACC_W] + pending_sum[c*ACC_W +: ACC_W];
    end
    reg [MEM_WIDTH-1:0] acc_mem [0:P_PX-1];
    reg [MEM_WIDTH-1:0] emit_mem [0:P_PX-1];
    // Explicit READ_FIRST synchronous templates; neither array is reset.
    always @(posedge clk) begin
        if (rst_n && pending) acc_mem[pending_px] <= stored_commit;
        acc_mem_q <= acc_mem[acc_px];
    end
    always @(posedge clk) begin
        if (rst_n && pending) emit_mem[pending_px] <= stored_commit;
        emit_mem_q <= emit_mem[rd_px];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            live <= {P_PX{1'b0}};
            commit_valid<=0;committed_sum<=0;
            pending <= 1'b0;
            pending_px <= 0;
            pending_sum <= 0;
            base_live <= 1'b0;
            acc_forward <= 1'b0;
            acc_forward_data <= 0;
            emit_live <= 1'b0;
            emit_forward <= 1'b0;
            emit_forward_data <= 0;
        end else begin
            commit_valid<=pending;
            if(pending) committed_sum<=commit_data;
            pending <= acc_valid;
            pending_px <= acc_px;
            pending_sum <= acc_sum;
            base_live <= live[acc_px] && !(OVERWRITE!=0 && acc_overwrite);
            acc_forward <= pending && (pending_px == acc_px) && !(OVERWRITE!=0 && acc_overwrite);
            acc_forward_data <= commit_data;
            emit_live <= live[rd_px];
            emit_forward <= pending && (pending_px == rd_px);
            emit_forward_data <= commit_data;
            if (clr_valid) live[clr_px] <= 1'b0;
            if (acc_valid) live[acc_px] <= 1'b1;
        end
    end
    assign rd_data = !emit_live ? {WIDTH{1'b0}} :
                    emit_forward ? emit_forward_data : emit_q;
endmodule
`default_nettype wire
