
module lvds_dynamic_delay(
input clk,
input rst_n,//!要求用PLL lock信号来控制

input align_fail,
input align_success,
output reg cal_done,
output reg de_sync_check_en,
input      de_sync_pass,
input      de_sync_fail,
output DLY_INC,
output DLY_RST,
output DLY_ENA,
output reg re_algin_start,
output reg pll_rst_n


);
//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/
localparam S_IDLE       = 4'd0;
localparam S_START      = 4'd1;
localparam S_SCAL_DONE  = 4'd2;
localparam S_NX_STEP    = 4'd3;
localparam S_COPY_START = 4'd4;
localparam S_COPY_END   = 4'd5;
localparam S_CALC_MID   = 4'd6;
localparam S_AL_RESTRT  = 4'd7;
localparam S_DELAY      = 4'd8;
localparam S_DE_SYNC_CHECK      = 4'd9;
localparam S_PLL_RESET = 4'd10;


reg [3:0]   pre_state   = S_IDLE;
reg [3:0]   nx_state    = S_IDLE;
wire         dly_inc    ;
reg [5:0]   dly_data    = 'd0;
reg         dly_ena     = 1'b0;
reg         start_record= 1'b0;
reg [5:0]   start_point = 6'd0;
reg [5:0]   end_point   = 6'd0;
reg [15:0]  cnt         = 'd0;
reg r_pll_rst_n = 'd0;
always @( posedge clk or negedge rst_n  )
begin
    if( !rst_n )
        pre_state <= S_IDLE;
    else 
        pre_state <= nx_state;
end

always @( * )
begin
    case( pre_state )
    S_IDLE : begin 
        if( align_fail|de_sync_fail )
            nx_state = S_START;
        else 
            nx_state = cal_done ? S_IDLE : S_START;
    end 
    S_START : begin//先把delay设置为0
        nx_state = S_DELAY;
    end
    S_DELAY : begin //8
        nx_state = cnt[5] ? S_SCAL_DONE : S_DELAY;
    end 
    S_SCAL_DONE : begin//一次校准结束 S_SCAL_DONE  = 3'd2;
        if( align_success)
            nx_state = S_DE_SYNC_CHECK;
            // nx_state = start_record ? S_NX_STEP : S_COPY_START;
        else if( align_fail )
            nx_state = start_record ? S_COPY_END: S_NX_STEP;
        else 
            nx_state = S_SCAL_DONE;
    end
    S_DE_SYNC_CHECK : begin//9
        if( de_sync_pass )
            nx_state = start_record ? S_NX_STEP : S_COPY_START;
        else if( de_sync_fail )
            nx_state = start_record ? S_COPY_END: S_NX_STEP;
        else 
            nx_state = S_DE_SYNC_CHECK;
    end
    S_NX_STEP : begin//one cycle  3
        if( &dly_data[4:0]  )
            nx_state = start_record ?  S_COPY_END : S_PLL_RESET;
        else 
            nx_state = S_AL_RESTRT;//S_CNT;
    end
    S_AL_RESTRT : begin //7
        nx_state = S_DELAY;
    end
    S_COPY_END : begin
        nx_state = S_CALC_MID;
    end
    S_COPY_START : begin //localparam S_COPY_START = 3'd4;
        nx_state = S_NX_STEP;
    end
    S_CALC_MID : begin
        nx_state = S_IDLE;
    end
    S_PLL_RESET : begin
        nx_state = S_IDLE;
    end
    default: begin
        nx_state = S_IDLE;
    end
    endcase
end
  always @( posedge clk  or negedge rst_n )
  begin
        if( !rst_n ) begin
            cal_done        <= 1'b0;
            start_record    <= 1'b0;
            dly_data        <= 'd0;
            start_point     <= 'd0;
            end_point       <= 'd0;
            de_sync_check_en <= 1'b0;
            r_pll_rst_n       <= 1'b1;
        end else begin
            dly_ena <= 1'b0;
            re_algin_start <= 1'b0;
            de_sync_check_en <= 1'b0;
            r_pll_rst_n       <= 1'b1;
            case( nx_state )
            S_IDLE : begin //0
                start_record <= 1'b0;
                cnt <= 'd0;
            end
            S_START : begin //1
                dly_data <= 'd0;
                dly_ena <= 1'b1;
                cal_done <= 1'b0;
                start_point <= 'd0;
                end_point <= 'd0;
                start_record <= 1'b0;
                re_algin_start <= 1'b1;
            end
            S_DELAY : begin
                cnt <= cnt + 1'b1;
            end 
            S_SCAL_DONE : begin //localparam S_SCAL_DONE  = 3'd2;
                cnt <= 'd0;
            end
            S_NX_STEP : begin// one cycle  3
                dly_ena <= ~(&dly_data[4:0]) ;
                dly_data <=  dly_data >= 30 ? 31 : dly_data + 5;//&dly_data ? dly_data :
                cnt <= 'd0;
            end
            S_AL_RESTRT : begin
                re_algin_start <= 1'b1;
                cnt <= 'd0;
            end
            S_COPY_END : begin
                end_point <= dly_data[5]? 31 : dly_data - 2;
            end
            S_COPY_START : begin //state = 4
                start_point <= dly_data;
                start_record <= 1'b1;
            end
            S_CALC_MID : begin
                dly_data <= (start_point + end_point) /2 ;
                cal_done <= 1'b1;
                dly_ena <= 1'b1;
            end
            S_DE_SYNC_CHECK : begin
                de_sync_check_en <= 1'b1;
            end
            S_PLL_RESET : begin
                r_pll_rst_n <= 1'b0;
            end
            default:;
            endcase
        end
  end

  always @( posedge clk or negedge rst_n  )
  begin
    if( !rst_n )
        pll_rst_n <= 1'b1;
    else 
        pll_rst_n <= r_pll_rst_n;
  end

  assign dly_inc = 1'b0;
  wire [4:0] dly_d = dly_inc ? dly_data[4:0] : {~dly_data[4:0]};
  dyn_delay dyn_delay_inst (
    .clk(clk),
    .rst_n(rst_n),
    .dyn_en(dly_ena),
    .dly_d({1'b0,dly_d[4:0]}),
    .dly_inc(dly_inc),
    .mode(1'b0),
    .dyn_rst(DLY_RST),
    .dyn_inc(DLY_INC),
    .dyn_ena(DLY_ENA),
    .dly_cnt(),
    .cal_busy()
  );


endmodule

//Encryption end
