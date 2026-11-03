`timescale 1ns/1ps
`default_nettype none
// Two immutable Flash pictures; retain weights across inference sessions.
// Display must drain its AXI reads BEFORE input/NN reuse DDR bank zero.
module nn_picture_scheduler #(parameter integer PIPELINED=0, HOLD_CYCLES=0)(
    input wire clk,rst_n,enable,nn_done,nn_pass,nn_fail,display_quiescent,frame_shown,
    output reg start,session_reset_n,picture_index,display_enable,
    output reg output_buffer,display_buffer,
    output reg ever_started,success_seen,
    output reg [31:0] last_process_cycles,completed_pictures
);
    reg [2:0] state;
    reg [31:0] timer,process_cycles;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=0;timer<=0;process_cycles<=0;start<=0;
            session_reset_n<=1;picture_index<=0;display_enable<=0;
            output_buffer<=0;display_buffer<=0;
            ever_started<=0;success_seen<=0;last_process_cycles<=0;completed_pictures<=0;
        end else begin
            start<=0;
            if(PIPELINED==0) begin
            case(state)
                0:if(enable) begin start<=1;ever_started<=1;process_cycles<=0;state<=1;end
                1:begin
                    process_cycles<=process_cycles+1'b1;
                    if(nn_fail) state<=6;
                    else if(nn_done && nn_pass) begin
                        last_process_cycles<=process_cycles;completed_pictures<=completed_pictures+1'b1;
                        success_seen<=1;display_enable<=1;timer<=0;state<=2;
                    end
                end
                2:if(nn_fail) begin display_enable<=0;state<=6;end
                  else if((HOLD_CYCLES==0) ? frame_shown : (timer>=HOLD_CYCLES-1)) begin display_enable<=0;timer<=0;state<=3;end
                  else timer<=timer+1'b1;
                3:if(nn_fail) state<=6;
                  else if(display_quiescent) begin session_reset_n<=0;timer<=0;state<=4;end
                4:if(timer==15) begin
                    picture_index<=~picture_index;session_reset_n<=1;state<=5;
                  end else timer<=timer+1'b1;
                5:state<=0; // allow reset release and address selection to settle
                default:begin start<=0;display_enable<=0;end // sticky error
            endcase
            end else begin
                case(state)
                    0:if(enable) begin start<=1;ever_started<=1;process_cycles<=0;state<=1;end
                    1:begin
                        process_cycles<=process_cycles+1'b1;
                        if(nn_done && nn_pass) begin
                            last_process_cycles<=process_cycles;
                            completed_pictures<=completed_pictures+1'b1;
                            if(!success_seen) begin
                                // First publication. The opposite output slot
                                // is free; compute there while this one displays.
                                success_seen<=1;display_buffer<=output_buffer;display_enable<=1;
                                output_buffer<=~output_buffer;picture_index<=~picture_index;
                                session_reset_n<=0;timer<=0;state<=4;
                            end else state<=2;
                        end
                    end
                    // Publish only after a fresh complete image. Disabling
                    // here falls in vertical blanking, not midway through it.
                    2:if(frame_shown) begin display_enable<=0;state<=3;end
                    3:if(display_quiescent) begin
                        display_buffer<=output_buffer;display_enable<=1;
                        output_buffer<=~output_buffer;picture_index<=~picture_index;
                        session_reset_n<=0;timer<=0;state<=4;
                    end
                    4:if(timer==15) begin session_reset_n<=1;state<=5;end else timer<=timer+1'b1;
                    5:state<=0;
                    default:begin start<=0;display_enable<=0;end
                endcase
                if(nn_fail) begin start<=0;display_enable<=0;state<=6;end
            end
        end
    end
endmodule
// Four diagnostic pages, independent of per-picture reset. No datapath control.
// {D3,D2,D1}: marker 111, source, phase, error code; repeat until global reset.
module nn_first_fault_led #(
    parameter integer PAGE_BITS = 27
)(
    input wire clk, rst_n, fault,
    input wire [2:0] source, phase, code,
    output reg latched,
    output wire [2:0] led_data
);
    reg [2:0] first_source, first_phase, first_code;
    reg [PAGE_BITS-1:0] page_timer;
    reg [1:0] page;
    assign led_data = page == 0 ? 3'b111 : page == 1 ? first_source :
                      page == 2 ? first_phase : first_code;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latched<=0; first_source<=0; first_phase<=0; first_code<=0;
            page_timer<=0; page<=0;
        end else if (!latched) begin
            if (fault) begin
                latched<=1; first_source<=source; first_phase<=phase; first_code<=code;
                page_timer<=0; page<=0;
            end
        end else begin
            page_timer<=page_timer+1'b1;
            if (&page_timer) page<=page+1'b1;
        end
    end
endmodule
`default_nettype wire
