// ABI6: coherent diagnostics, one CPU-owned inference, and platform requests.
// Admission keeps existing frame ownership. Deployment is a one-shot video-domain
// epoch: platform requests cannot reset an active loader or its AXI transactions.
module c_nn_snapshot_apb #(parameter integer CORE_HZ=120000000,MEASURE_SWITCH=0,ENABLE_ROI=0,FRAME_READBACK=0,SAME_CLOCK=0)(
    input wire src_clk,dst_clk,arst,
    input wire deployment_started,
    input wire [9:0] status,
    input wire [2:0] boot_fault,compute_fault,
    input wire [2:0] active_model,requested_model,
    input wire [2:0] display_model_id,input wire display_shown,
    input wire snapshot_lock,output wire capture_allowed,
    input wire [31:0] input_base,output_base,display_frame_id,
    input wire nn_start,nn_done,nn_pass,nn_fail,
    input wire [31:0] diagnostic_state,diagnostic_axi,
    input wire input_request_valid,scheduler_req_ready,scheduler_idle,
    input wire [31:0] input_frame_id,
    output wire admit_enable,control_irq,
    output reg [12:0] platform_config,
    input wire [15:0] PADDR,
    input wire PSEL,PENABLE,PWRITE,
    input wire [31:0] PWDATA,
    output reg [31:0] PRDATA,
    output wire PREADY,PSLVERROR
);
    (* async_reg="true", syn_preserve=1 *) reg [1:0] src_reset=3,dst_reset=3;
    always @(posedge src_clk or posedge arst)
        if(arst)src_reset<=3;else src_reset<={src_reset[0],1'b0};
    always @(posedge dst_clk or posedge arst)
        if(arst)dst_reset<=3;else dst_reset<={dst_reset[0],1'b0};
    reg request,ack;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] request_sync,ack_sync;
    reg [482:0] held;
    reg [482:0] snapshot_same;
    // Async ACK freezes held until the next blocking read. Only the actual
    // same-clock profile needs a separate local snapshot register.
    wire [482:0] snapshot=(SAME_CLOCK!=0)?snapshot_same:held;
    reg [31:0] starts,dones;
    reg start_d,done_d,valid;
    reg [1:0] read_state,command_state;

    // The CPU holds command_data until a synchronized ACK completes the APB
    // write. The source result is held until the next command is processed.
    reg command_request,command_ack;
    reg [31:0] command_data;
    (* syn_preserve=1, syn_keep=1 *) reg [31:0] source_command_data;
    reg command_pending;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] command_sync,command_ack_sync;
    reg [2:0] command_result,last_command_result;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] irq_sync;
    reg cpu_mode,queued,inflight,done_pending,accepted_valid,task_started,irq_enable;
    reg [31:0] accepted_id,completed_id;
    reg [3:0] task_result;
    wire fault=status[8]||status[7]||status[6]||status[2];
    wire operational=status[0]&&status[1]&&!fault;
    wire command_arrival=command_sync[1]!=command_ack;
    // Suppress admission on a mode-command arrival edge: an AUTO frame must
    // not slip through on the same edge that CPU ownership is established.
    wire capture_locked=(FRAME_READBACK!=0)&&snapshot_lock;
    assign capture_allowed=cpu_mode&&operational&&!queued&&!inflight&&!done_pending;
    assign admit_enable=!src_reset[1]&&!command_arrival&&!capture_locked&&
                        (!cpu_mode||(queued&&operational&&!inflight&&!done_pending));
    wire admitted=input_request_valid&&scheduler_req_ready&&admit_enable;
    wire irq_source=done_pending&&irq_enable;
    assign control_irq=irq_sync[1];
    wire can_queue=cpu_mode&&operational&&!queued&&!inflight&&!done_pending&&!capture_locked;
    wire [31:0] control_flags={12'd0,task_result,4'd0,irq_source,irq_enable,
        input_request_valid,scheduler_idle,can_queue,fault,task_started,
        accepted_valid,done_pending,inflight,queued,cpu_mode};
    wire [31:0] switch_cycles,switch_request_frame,switch_shown_frame,switch_flags;
    generate if(MEASURE_SWITCH!=0)begin:G_SWITCH_MONITOR
        c_style_switch_monitor #(.CORE_HZ(CORE_HZ)) u_monitor(
            .clk(src_clk),.rst(src_reset[1]),.enabled(operational),.video_fault(fault),
            .requested_model(requested_model),.display_model(display_model_id),
            .display_frame(display_frame_id),.display_shown(display_shown),
            .elapsed_cycles(switch_cycles),.request_frame(switch_request_frame),
            .shown_frame(switch_shown_frame),.flags(switch_flags));
    end else begin:G_NO_SWITCH_MONITOR
        assign switch_cycles=0;assign switch_request_frame=0;assign switch_shown_frame=0;assign switch_flags=0;
    end endgenerate
    wire [482:0] live_data={platform_config[12],requested_model[2],active_model[2],platform_config[11:10],switch_flags,switch_shown_frame,switch_request_frame,switch_cycles,platform_config[9:1],(platform_config[0]||deployment_started),completed_id,accepted_id,control_flags,
        diagnostic_axi,diagnostic_state,dones,starts,display_frame_id,output_base,
        input_base,requested_model[1:0],active_model[1:0],compute_fault,boot_fault,status};

    always @(posedge src_clk or posedge src_reset[1]) begin
        if(src_reset[1])begin
            request_sync<=0;ack<=0;held<=0;starts<=0;dones<=0;start_d<=0;done_d<=0;
            command_sync<=0;command_ack<=0;command_result<=0;
            source_command_data<=0;command_pending<=0;
            cpu_mode<=0;queued<=0;inflight<=0;done_pending<=0;accepted_valid<=0;
            task_started<=0;irq_enable<=0;platform_config<=10'd64;accepted_id<=0;completed_id<=0;task_result<=0;
        end else begin
            request_sync<={request_sync[0],request};
            command_sync<={command_sync[0],command_request};
            start_d<=nn_start;done_d<=nn_done;
            if(nn_start&&!start_d)starts<=starts+1'b1;
            if(nn_done&&!done_d)dones<=dones+1'b1;
            if(SAME_CLOCK==0 && request_sync[1]!=ack)begin held<=live_data;ack<=request_sync[1];end

            if(admitted&&cpu_mode&&queued)begin
                queued<=0;inflight<=1;accepted_valid<=1;accepted_id<=input_frame_id;
                task_started<=0;
            end
            if(inflight&&nn_start&&!start_d)task_started<=1;
            // Failures never reset/cancel the real accelerator. They only
            // terminate the CPU record; fault blocks subsequent START commands.
            if((queued||inflight)&&fault)begin
                queued<=0;inflight<=0;done_pending<=1;
                completed_id<=accepted_valid?accepted_id:0;
                task_result<=!accepted_valid?4'd4:nn_fail?4'd2:4'd3;
            end else if(inflight&&task_started&&nn_done&&!done_d)begin
                inflight<=0;done_pending<=1;completed_id<=accepted_id;
                task_result<=(nn_pass&&!nn_fail)?4'd1:4'd2;
            end

            if(command_arrival&&!command_pending)begin
                source_command_data<=command_data;command_pending<=1;
            end
            // Decode a source-clocked register. The asynchronous held payload
            // reaches only the D pins of source_command_data, never state CEs.
            if(command_pending)begin
                command_pending<=0;
                command_ack<=command_sync[1];command_result<=0;
                if((source_command_data[7:0]!=7 && |source_command_data[31:8]) ||
                   (source_command_data[7:0]==7 && (|source_command_data[31:21] || (ENABLE_ROI==0 && |source_command_data[19:18]) || {source_command_data[20],source_command_data[11:10]}>=5)))command_result<=6;
                else case(source_command_data[7:0])
                    32'd1:cpu_mode<=1; // drain an existing AUTO job, admit no new one
                    32'd2:if(queued||inflight||done_pending||capture_locked)command_result<=2;
                          else cpu_mode<=0;
                    32'd3:if(!cpu_mode)command_result<=1;
                          else if(queued||inflight||done_pending||capture_locked)command_result<=2;
                          else if(fault)command_result<=4;
                          else if(!operational)command_result<=3;
                          else begin queued<=1;accepted_valid<=0;task_started<=0;
                              accepted_id<=0;completed_id<=0;task_result<=0;end
                    32'd4:if(!done_pending)command_result<=5;else done_pending<=0;
                    32'd5:irq_enable<=1;
                    32'd6:irq_enable<=0;
                    32'd7:if(!source_command_data[8] && (platform_config[0]||deployment_started))command_result<=2;
                          else platform_config<=source_command_data[20:8];
                    default:command_result<=6;
                endcase
            end
        end
    end
    wire snapshot_read=PSEL&&PENABLE&&!PWRITE&&(PADDR==16'h0108||PADDR==16'h0208);
    wire command_write=PSEL&&PENABLE&&PWRITE&&PADDR==16'h0204;
    always @(posedge dst_clk or posedge dst_reset[1])begin
        if(dst_reset[1])begin
            request<=0;ack_sync<=0;valid<=0;read_state<=0;snapshot_same<=0;
            command_request<=0;command_data<=0;command_ack_sync<=0;
            command_state<=0;last_command_result<=0;irq_sync<=0;
        end else begin
            ack_sync<={ack_sync[0],ack};
            command_ack_sync<={command_ack_sync[0],command_ack};
            irq_sync<={irq_sync[0],irq_source};
            if(SAME_CLOCK!=0)begin
                // Only legal when src_clk and dst_clk are the SAME physical net.
                // One atomic retained record; no duplicated CDC payload bank.
                case(read_state)
                    0:if(snapshot_read)begin snapshot_same<=live_data;valid<=1;read_state<=2;end
                    2:if(PSEL&&PENABLE)read_state<=0;
                    default:read_state<=0;
                endcase
            end else case(read_state)
                0:if(snapshot_read)begin request<=~request;read_state<=1;end
                1:if(ack_sync[1]==request)begin valid<=1;read_state<=2;end
                2:if(PSEL&&PENABLE)read_state<=0;
            endcase
            case(command_state)
                0:if(command_write)begin command_data<=PWDATA;
                    command_request<=~command_request;command_state<=1;end
                1:if(command_ack_sync[1]==command_request)begin
                    last_command_result<=command_result;command_state<=2;end
                2:if(PSEL&&PENABLE)command_state<=0;
            endcase
        end
    end
    reg valid_read;
    assign PREADY=(PADDR==16'h0204&&PWRITE)?command_state==2:
        ((!PWRITE&&(PADDR==16'h0108||PADDR==16'h0208))?read_state==2:1'b1);
    // Valid commands rejected by policy return LAST_CMD_RESULT, not a CPU bus
    // exception. Invalid addresses, alignment and read-only writes still error.
    assign PSLVERROR=PSEL&&PENABLE&&(PWRITE?(PADDR!=16'h0204):!valid_read);
    always @*begin
        PRDATA=0;valid_read=1;
        case(PADDR)
            16'h0100:PRDATA=32'h41435206;
            16'h0104:PRDATA={27'd0,(FRAME_READBACK!=0),(ENABLE_ROI!=0),(MEASURE_SWITCH!=0),valid,1'b1};
            16'h0108:PRDATA={22'd0,snapshot[9:0]};
            16'h010C:PRDATA={21'd0,snapshot[15:13],5'd0,snapshot[12:10]};
            16'h0110:PRDATA={26'd0,snapshot[481:480],snapshot[19:16]};
            16'h0114:PRDATA=snapshot[51:20];
            16'h0118:PRDATA=snapshot[83:52];
            16'h011C:PRDATA=snapshot[115:84];
            16'h0120:PRDATA=CORE_HZ;
            16'h0124:PRDATA=snapshot[147:116];
            16'h0128:PRDATA=snapshot[179:148];
            16'h012C:PRDATA=snapshot[211:180];
            16'h0130:PRDATA=snapshot[243:212];
            16'h0134:begin PRDATA=snapshot[381:350];if(MEASURE_SWITCH==0)valid_read=0;end
            16'h0138:begin PRDATA=snapshot[413:382];if(MEASURE_SWITCH==0)valid_read=0;end
            16'h013C:begin PRDATA=snapshot[445:414];if(MEASURE_SWITCH==0)valid_read=0;end
            16'h0140:begin PRDATA=snapshot[477:446];if(MEASURE_SWITCH==0)valid_read=0;end
            16'h0144:begin PRDATA=32'h53574d01;if(MEASURE_SWITCH==0)valid_read=0;end
            16'h0200:PRDATA=32'h41434302;
            16'h0204:PRDATA=command_data;
            16'h0208:PRDATA=snapshot[275:244];
            16'h020C:PRDATA={29'd0,last_command_result};
            16'h0210:PRDATA=snapshot[307:276];
            16'h0214:PRDATA=snapshot[339:308];
            16'h021C:PRDATA={19'd0,snapshot[482],snapshot[479:478],snapshot[349:340]};
            16'h0218:PRDATA={28'd0,snapshot[263:260]};
            default:valid_read=0;
        endcase
    end
endmodule
