module channelboad_ctrl(
    input clk,
    input rst_n,
    input align,
    input sync1,
    input sync2,
    input sync3,
    output reg re_sync

);

//Encryption begin
/*----------------------------------------------------------------------------------*\
                                 The main code
\*----------------------------------------------------------------------------------*/
reg sync = 'd0;
reg sync1_r = 'd0;

reg [5:0] cnt1;
reg [5:0] cnt2;
reg [1:0] state ;
reg [5:0] bak_cnt;


always @( posedge clk )
begin
    sync <= sync1 & sync2 & sync3;
    sync1_r <= sync1;
end
wire pos_sync1 = {sync1_r,sync1} == 2'b01;
wire neg_sync1 = {sync1_r,sync1} == 2'b10;

always @( posedge clk )
begin
    re_sync <= 1'b0;
    case( state )
    2'd0 : begin
        state <= pos_sync1 ? 2'd1 : 2'd0 ;
        cnt1 <= 'd0;
        cnt2 <= 'd0;
    end
    2'd1 : begin
         if( neg_sync1 ) begin
            state <= 2'd2;
         end else begin
            cnt1 <= sync1_r ? cnt1 + 1'b1 : cnt1;
            cnt2 <= sync ? cnt2 + 1'b1 : cnt2;
         end

    end
    2'd2 : begin
        if( cnt1 < 16 ) begin
            state <= 2'd0;
        end else begin
            cnt1 <= cnt1 - cnt2;
            state <= 2'd3;
        end
    end
    2'd3 : begin
        if( cnt1 != bak_cnt ) begin
            bak_cnt <= cnt1;
            re_sync <= 1'b1;
        end 
        state <= 2'd0;
    end

    default :;
    endcase
end


endmodule

//Encryption end

