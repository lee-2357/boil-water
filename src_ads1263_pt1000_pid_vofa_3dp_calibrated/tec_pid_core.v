`timescale 1ns/1ps
`default_nettype none
// Derived from the proven UART PID/H-bridge controller. PID math is pipelined;
// PWM threshold uses exact constant simplification. Gains/direction unchanged.
module tec_uart_tx #(parameter integer CLK_HZ=50_000_000, BAUD=115200) (
    input wire clk, reset_n, start, input wire [7:0] data,
    output reg tx, busy
);
    localparam integer BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=(BIT_CYCLES<2)?1:$clog2(BIT_CYCLES);
    reg [CW-1:0] timer;
    reg [3:0] bit_index;
    reg [9:0] shift;
    always @(posedge clk) begin
        if (!reset_n) begin tx<=1; busy<=0; timer<=0; bit_index<=0; shift<=10'h3ff; end
        else if (!busy) begin
            tx<=1;
            if (start) begin
                shift<={1'b1,data,1'b0}; tx<=0; busy<=1;
                timer<=BIT_CYCLES-1; bit_index<=0;
            end
        end else if (timer!=0) timer<=timer-1'b1;
        else if (bit_index==9) begin tx<=1; busy<=0; end
        else begin
            shift<={1'b1,shift[9:1]}; tx<=shift[1];
            bit_index<=bit_index+1'b1; timer<=BIT_CYCLES-1;
        end
    end
endmodule

module tec_pid_fixed #(
    parameter integer KP_Q8=2560, KI_Q8=13, KD_Q8=512,
    LIMIT_PERMILLE=800
) (
    input wire clk, reset_n, enable, tick,
    input wire signed [31:0] temperature_mdeg,
    input wire [31:0] target_mdeg,
    output reg signed [15:0] command_permille
);
    // Positive error -> cooling. Derivative on measurement avoids setpoint kick.
    // Fixed Ts supplied by top; last valid measurement is held between ADC frames.
    // Gains retain their old per-0.1C units: scale the entire accumulator by
    // 100, including its clamp, then divide by 25600 to get duty permille.
    localparam signed [63:0] LIMIT_Q8=LIMIT_PERMILLE*64'sd25600;
    reg [3:0] state;
    reg signed [31:0] error_mdeg, delta_mdeg;
    reg signed [31:0] previous_temp_mdeg;
    reg previous_valid;
    reg signed [63:0] p_term, i_step, d_term, integral_q8;
    reg signed [63:0] candidate_i, candidate_sum, chosen_i, result_q8;
    reg div_start, result_negative;
    reg [63:0] duty_numerator;
    wire duty_done, duty_busy;
    wire [63:0] duty_quotient;
    wire [63:0] result_magnitude=result_q8[63] ? -result_q8 : result_q8;
    ao_unsigned_div64 u_duty_div(.clk(clk),.reset_n(reset_n && enable),.start(div_start),
        .numerator(duty_numerator),.denominator(64'd25600),.busy(duty_busy),
        .done(duty_done),.quotient(duty_quotient));
    always @(posedge clk) begin
        if (!reset_n || !enable) begin
            state<=0; command_permille<=0; error_mdeg<=0; delta_mdeg<=0;
            previous_temp_mdeg<=0; previous_valid<=0; integral_q8<=0;
            p_term<=0; i_step<=0; d_term<=0;
            candidate_i<=0; candidate_sum<=0; chosen_i<=0; result_q8<=0;
            div_start<=0; result_negative<=0; duty_numerator<=0;
        end else begin
            div_start<=0;
            case (state)
            0: if (tick) begin
                error_mdeg<=$signed(temperature_mdeg)-$signed(target_mdeg);
                delta_mdeg<=previous_valid ? ($signed(temperature_mdeg)-$signed(previous_temp_mdeg)) : 0;
                previous_temp_mdeg<=temperature_mdeg; previous_valid<=1; state<=1;
            end
            1: begin
                p_term<=error_mdeg*$signed(KP_Q8);
                i_step<=error_mdeg*$signed(KI_Q8);
                d_term<=delta_mdeg*$signed(KD_Q8); state<=2;
            end
            2: begin
                candidate_i<=integral_q8+i_step;
                state<=3;
            end
            3: begin
                if (candidate_i>LIMIT_Q8) candidate_i<=LIMIT_Q8;
                else if (candidate_i< -LIMIT_Q8) candidate_i<= -LIMIT_Q8;
                state<=4;
            end
            4: begin
                candidate_sum<=p_term+candidate_i+d_term;
                state<=5;
            end
            5: begin
                // Conditional integration: do not wind up further into saturation.
                if ((candidate_sum>LIMIT_Q8 && error_mdeg>0) ||
                    (candidate_sum< -LIMIT_Q8 && error_mdeg<0)) chosen_i<=integral_q8;
                else chosen_i<=candidate_i;
                state<=6;
            end
            6: begin
                integral_q8<=chosen_i;
                result_q8<=p_term+chosen_i+d_term;
                state<=7;
            end
            7: begin
                if(result_q8>LIMIT_Q8) begin command_permille<=LIMIT_PERMILLE; state<=0; end
                else if(result_q8< -LIMIT_Q8) begin command_permille<= -LIMIT_PERMILLE; state<=0; end
                else begin
                    result_negative<=result_q8[63]; duty_numerator<=result_magnitude;
                    div_start<=1; state<=8;
                end
            end
            8: if(duty_done) begin
                command_permille<=result_negative ? -$signed(duty_quotient[15:0]) : $signed(duty_quotient[15:0]);
                state<=0;
            end
            default: state<=0;
        endcase
        end
    end
endmodule

module tec_bridge_pwm #(
    parameter integer CLK_HZ=50_000_000, PWM_HZ=1000, LIMIT_PERMILLE=800,
    SLEW_PER_PERIOD=2, REVERSE_OFF_MS=20
) (
    input wire clk, reset_n, enable,
    input wire signed [15:0] command_permille,
    output wire signed [15:0] applied_permille,
    output wire r_pwm, l_pwm, r_en, l_en
);
    localparam integer PERIOD=CLK_HZ/PWM_HZ;
    localparam integer CW=(PERIOD<2)?1:$clog2(PERIOD);
    localparam integer OFF_PERIODS=(REVERSE_OFF_MS*PWM_HZ+999)/1000;
    reg [CW-1:0] counter;
    reg [15:0] magnitude;
    reg direction; // 0 cool, 1 heat
    reg [31:0] off_remaining;
    wire [15:0] requested_abs=command_permille[15] ? -command_permille : command_permille;
    wire [15:0] requested=(requested_abs>LIMIT_PERMILLE)?LIMIT_PERMILLE:requested_abs;
    wire [31:0] high_counts;
    generate
        // At 50 MHz / 1 kHz PERIOD=50000. This is exactly magnitude*50,
        // with no division and no change to PWM duty or period.
        if(PERIOD%1000==0) begin : g_exact_period
            assign high_counts=magnitude*(PERIOD/1000);
        end else begin : g_fractional_period
            assign high_counts=(magnitude*PERIOD)/1000;
        end
    endgenerate
    wire bridge_on=reset_n && enable && (off_remaining==0) && (magnitude!=0);
    always @(posedge clk) begin
        if (!reset_n || !enable) begin counter<=0; magnitude<=0; direction<=0; off_remaining<=0; end
        else if (counter==PERIOD-1) begin
            counter<=0;
            if (off_remaining!=0) begin magnitude<=0; off_remaining<=off_remaining-1'b1; end
            else if (requested!=0 && command_permille[15]!=direction) begin
                magnitude<=0; direction<=command_permille[15]; off_remaining<=OFF_PERIODS;
            end else if (magnitude<requested) begin
                if (requested-magnitude>SLEW_PER_PERIOD) magnitude<=magnitude+SLEW_PER_PERIOD;
                else magnitude<=requested;
            end else if (magnitude>requested) begin
                if (magnitude-requested>SLEW_PER_PERIOD) magnitude<=magnitude-SLEW_PER_PERIOD;
                else magnitude<=requested;
            end
        end else counter<=counter+1'b1;
    end
    assign r_pwm=bridge_on && !direction && (counter<high_counts);
    assign l_pwm=bridge_on &&  direction && (counter<high_counts);
    assign r_en=bridge_on;
    assign l_en=bridge_on;
    assign applied_permille=bridge_on ? (direction ? -$signed(magnitude) : $signed(magnitude)) : 16'sd0;
endmodule

module tec_pc_reporter #(
    parameter integer CLK_HZ=50000000, BAUD=115200, REPORT_MS=500
) (
    input wire clk, reset_n, ms_tick,
    input wire signed [31:0] temperature_mdeg,
    input wire [31:0] target_mdeg,
    input wire signed [15:0] applied_permille,
    input wire [7:0] status, input wire [3:0] fault_code,
    output wire tx
);
    // Atomic snapshot: T=+0021.700C,SP=+0040.000C,U=-080.0%,S=R,F=0\r\n
    reg [31:0] elapsed_ms;
    reg sending, start;
    reg [5:0] index;
    reg [7:0] data;
    wire busy;
    reg [18:0] temp_abs;
    reg [16:0] saved_target;
    reg [15:0] duty_abs;
    reg temp_negative, duty_negative;
    reg [7:0] saved_status;
    reg [3:0] saved_fault;
    function [7:0] report_byte;
        input [5:0] n;
        begin
            case(n)
                0: report_byte=8'h54;
                1: report_byte=8'h3d;
                2: report_byte=temp_negative?"-":"+";
                3: report_byte=8'd48+(temp_abs/1000000)%10;
                4: report_byte=8'd48+(temp_abs/100000)%10;
                5: report_byte=8'd48+(temp_abs/10000)%10;
                6: report_byte=8'd48+(temp_abs/1000)%10;
                7: report_byte=8'h2e;
                8: report_byte=8'd48+(temp_abs/100)%10;
                9: report_byte=8'd48+(temp_abs/10)%10;
                10: report_byte=8'd48+temp_abs%10;
                11: report_byte=8'h43;
                12: report_byte=8'h2c;
                13: report_byte=8'h53;
                14: report_byte=8'h50;
                15: report_byte=8'h3d;
                16: report_byte=8'h2b;
                17: report_byte=8'd48+(saved_target/1000000)%10;
                18: report_byte=8'd48+(saved_target/100000)%10;
                19: report_byte=8'd48+(saved_target/10000)%10;
                20: report_byte=8'd48+(saved_target/1000)%10;
                21: report_byte=8'h2e;
                22: report_byte=8'd48+(saved_target/100)%10;
                23: report_byte=8'd48+(saved_target/10)%10;
                24: report_byte=8'd48+saved_target%10;
                25: report_byte=8'h43;
                26: report_byte=8'h2c;
                27: report_byte=8'h55;
                28: report_byte=8'h3d;
                29: report_byte=duty_negative?"-":"+";
                30: report_byte=8'd48+(duty_abs/1000)%10;
                31: report_byte=8'd48+(duty_abs/100)%10;
                32: report_byte=8'd48+(duty_abs/10)%10;
                33: report_byte=8'h2e;
                34: report_byte=8'd48+duty_abs%10;
                35: report_byte=8'h25;
                36: report_byte=8'h2c;
                37: report_byte=8'h53;
                38: report_byte=8'h3d;
                39: report_byte=saved_status;
                40: report_byte=8'h2c;
                41: report_byte=8'h46;
                42: report_byte=8'h3d;
                43: report_byte=8'd48+saved_fault;
                44: report_byte=8'h0d;
                45: report_byte=8'h0a;
                default:report_byte=8'h0a;
            endcase
        end
    endfunction
    always @(posedge clk) begin
        if(!reset_n) begin
            elapsed_ms<=0; sending<=0; start<=0; index<=0; data<=8'hff;
            temp_abs<=0; saved_target<=40000; duty_abs<=0;
            temp_negative<=0; duty_negative<=0; saved_status<="W"; saved_fault<=0;
        end else begin
            start<=0;
            if(ms_tick && elapsed_ms<REPORT_MS) elapsed_ms<=elapsed_ms+1'b1;
            if(!sending) begin
                if(elapsed_ms>=REPORT_MS) begin
                    elapsed_ms<=0; sending<=1; index<=0;
                    temp_negative<=temperature_mdeg[31];
                    temp_abs<=temperature_mdeg[31] ? -temperature_mdeg : temperature_mdeg;
                    saved_target<=target_mdeg[16:0];
                    duty_negative<=applied_permille[15];
                    duty_abs<=applied_permille[15] ? -applied_permille : applied_permille;
                    saved_status<=status; saved_fault<=fault_code;
                end
            end else if(!busy && !start) begin
                if(index<46) begin data<=report_byte(index); start<=1; index<=index+1'b1; end
                else sending<=0;
            end
        end
    end
    tec_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx(
        .clk(clk),.reset_n(reset_n),.start(start),.data(data),.tx(tx),.busy(busy));
endmodule
`default_nettype wire
