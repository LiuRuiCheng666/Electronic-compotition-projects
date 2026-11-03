`timescale 1ns/ 1ns 
module de_sync(
    input clk,
    input rst_n,
    input de_sync_en,
    input i_de,
    output reg sync_fail = 1'b0,
    output  sync_pass,
    input cal_done

);
//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/
localparam  S_IDLE = 3'd0;
localparam  S_DE_START = 3'd1;
localparam S_DE_CNT = 3'd2;
localparam S_STAR_RECORD = 3'd3;
localparam S_LINE_ADD = 3'd5;
localparam S_DE_COMPARE = 3'd4;
localparam S_DE_CLEAR_WAIT = 3'd6;
reg de_sync_en_r = 'd0;
reg [13:0] h_cnt_bak = 'd0;
reg de_r0 = 'd0;
reg [2:0] pre_state = S_IDLE;
reg [2:0] nx_state = S_IDLE;
reg de_record = 'd0;
reg  not_eq = 'd0;
reg [13:0] cnt = 'd0;
reg [10:0] cycle_cnt = 'd0;
reg [25:0] timeout_cnt = 'd0;
wire timeout_flag;
always @( posedge clk )
begin
        de_r0 	<= i_de; 
end
assign pos_de = {de_r0,i_de} == 2'b01;
assign neg_de = {de_r0,i_de} == 2'b10;
//============================================================================================== 
// h_active calc
//==============================================================================================
always @( posedge clk or negedge rst_n  )
begin
    if( !rst_n )
        pre_state <= S_IDLE;
    else
        pre_state <= nx_state;
end

// always @( posedge clk )
// begin
//     de_sync_en_r <= de_sync_en;
// end
// assign pos_de_sync_en = {de_sync_en_r,de_sync_en} == 2'b01;

always @( * )
begin
    case( pre_state )
    S_IDLE : begin
         nx_state = (cal_done| de_sync_en) ? S_DE_START : S_IDLE;
    end
    S_DE_START : begin
        if( pos_de )
            nx_state = S_DE_CNT;
        else if( timeout_flag )
            nx_state = S_IDLE;
        else
            nx_state = S_DE_START;     
    end
    S_DE_CNT : begin
         if( neg_de )
            nx_state = de_record ? S_DE_COMPARE : S_STAR_RECORD;
        else 
            nx_state = S_DE_CNT;
    end
    S_STAR_RECORD : begin
        nx_state = S_DE_START;
    end
    S_DE_COMPARE : begin
        nx_state = sync_fail ? S_IDLE : S_LINE_ADD;
    end
    S_LINE_ADD : begin
        nx_state = cycle_cnt[10] ?  S_DE_CLEAR_WAIT : S_DE_START;
    end
    S_DE_CLEAR_WAIT : begin
        nx_state = S_IDLE;
    end
    default: nx_state = S_IDLE;
    endcase
end


always @( posedge clk )
begin
    sync_fail <= 1'b0;
    case( nx_state )
    S_IDLE : begin
        cnt <= 'd0;
        de_record <= 1'b0;
        cycle_cnt <= 'd0;
        sync_fail <= timeout_flag;
    end
    S_DE_START : begin
        cnt <= 'd0;
    end
    S_DE_CNT : begin
        cnt <= cnt + 1'b1;
    end
    S_STAR_RECORD : begin
        h_cnt_bak <= cnt ;
        de_record <= 1'b1;
    end
    S_DE_COMPARE : begin
        h_cnt_bak <= cnt;
        if( de_record && h_cnt_bak  != cnt)
            sync_fail <= 1'b1;

    end
    S_LINE_ADD : begin
        cycle_cnt <=  cycle_cnt + 1'b1;
    end
    default:;
    endcase
end
assign sync_pass = cycle_cnt[10];

always @( posedge clk )
begin
    if( nx_state == S_DE_START )
        timeout_cnt <= timeout_cnt + 1'b1;
    else 
        timeout_cnt <= 'd0; 
end
assign  timeout_flag = timeout_cnt[22];
endmodule

//Encryption end

