`timescale 1ns/1ps
`default_nettype none

// Smart ZYNQ SL V1.3B / XC7Z020-CLG484-1, 50 MHz PL clock.
// LZ_TD210 PT1000 UART -> signed fixed-point PID -> BTN7960 TEC bridge.
// Positive command = cooling (RPWM); negative = heating (LPWM).
// All submodules are included in this single Verilog-2001 source file.
module smart_zynq_tec_pid #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200,
    parameter integer PWM_HZ = 1_000,
    parameter [7:0] SENSOR_MODEL = 8'h02, // PT1000=02, PT100=01
    parameter [7:0] SENSOR_ADDR = 8'h01,
    // Documentation specifies x10 temperature, but not byte order/sign encoding.
    // Defaults follow its big-endian threshold examples; verify against real data.
    parameter integer TEMP_LITTLE_ENDIAN = 0,
    parameter integer TEMP_SIGN_MAGNITUDE = 0,
    parameter integer TARGET_TEMP_X10 = 400, // 40.0 degrees C
    parameter integer CONTROL_MS = 500,
    // Q8 gains: permille of duty per 0.1 C, per CONTROL_MS update.
    // Defaults: Kp=10 %/C, Ki~=0.102 %/(C*s), Kd=1 %*s/C at Ts=0.5s.
    parameter integer KP_Q8 = 2560,
    parameter integer KI_Q8 = 13,
    parameter integer KD_Q8 = 512,
    parameter integer MAX_DUTY_PERMILLE = 800, // bidirectional limit: +/-80.0%
    parameter integer SLEW_PER_PWM = 2,       // 0.2% per PWM period
    parameter integer REVERSE_OFF_MS = 20,
    parameter integer MIN_TEMP_X10 = -200,   // application window, not RTD range
    parameter integer MAX_TEMP_X10 = 800,
    parameter integer SENSOR_TIMEOUT_MS = 2000,
    parameter integer GOOD_FRAMES_REQUIRED = 3,
    parameter integer SENSOR_BOOT_MS = 1000,
    parameter integer START_RETRY_MS = 2000,
    parameter integer REPORT_MS = 500,
    parameter integer POR_CYCLES = 65536
) (
    input  wire clk_50,
    input  wire rst_n,             // KEY1 active-low; fault acknowledge/reset
    input  wire sensor_uart_rx,    // F17, module TXD -> FPGA RX
    output wire sensor_uart_tx,    // G17, FPGA TX -> module RXD
    output wire pc_uart_tx,        // L17, board CH340 RX -> USB PC
    output wire r_pwm,             // H19 unchanged
    output wire l_pwm,             // H20 unchanged
    output wire r_en,              // E18 unchanged
    output wire l_en               // F18 unchanged
);
    // FPGA configuration initialization provides POR even without pressing KEY1.
    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_sync = 2'b00;
    reg [31:0] por_count = 0;
    always @(posedge clk_50 or negedge rst_n) begin
        if (!rst_n) reset_sync <= 0;
        else reset_sync <= {reset_sync[0],1'b1};
    end
    always @(posedge clk_50) begin
        if (!reset_sync[1]) por_count <= 0;
        else if (por_count < POR_CYCLES) por_count <= por_count + 1'b1;
    end
    wire reset_ok = rst_n && reset_sync[1] && (por_count == POR_CYCLES);

    localparam integer MS_DIV = CLK_HZ / 1000;
    reg [31:0] ms_divider;
    wire ms_tick = (ms_divider == MS_DIV-1);
    always @(posedge clk_50) begin
        if (!reset_ok || ms_tick) ms_divider <= 0;
        else ms_divider <= ms_divider + 1'b1;
    end

    wire [7:0] rx_byte;
    wire rx_valid, rx_error;
    tec_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_sensor_rx (
        .clk(clk_50),.reset_n(reset_ok),.rx(sensor_uart_rx),
        .data(rx_byte),.valid(rx_valid),.framing_error(rx_error));
    wire signed [15:0] decoded_temp;
    wire temp_valid;
    tec_rtd_parser #(.MODEL(SENSOR_MODEL),.ADDR(SENSOR_ADDR),
        .LITTLE_ENDIAN(TEMP_LITTLE_ENDIAN),.SIGN_MAGNITUDE(TEMP_SIGN_MAGNITUDE)) u_parser (
        .clk(clk_50),.reset_n(reset_ok),.ms_tick(ms_tick),
        .rx_byte(rx_byte),.rx_valid(rx_valid),.rx_error(rx_error),
        .temperature_x10(decoded_temp),.temperature_valid(temp_valid));

    // Only a complete matching, checksummed frame refreshes the watchdog.
    reg signed [15:0] temperature_x10;
    reg [31:0] age_ms;
    reg [15:0] good_frames;
    reg have_sample;
    reg fault_latched;
    reg [3:0] fault_code; // 0=none, 1=stale UART, 2=temperature outside window
    wire temp_in_range = ($signed(decoded_temp) >= MIN_TEMP_X10) &&
                         ($signed(decoded_temp) <= MAX_TEMP_X10);
    wire link_alive = have_sample && (age_ms < SENSOR_TIMEOUT_MS);
    wire control_enable = reset_ok && !fault_latched && link_alive &&
                          (good_frames >= GOOD_FRAMES_REQUIRED);
    always @(posedge clk_50) begin
        if (!reset_ok) begin
            temperature_x10 <= 0; age_ms <= SENSOR_TIMEOUT_MS;
            good_frames <= 0; have_sample <= 0;
            fault_latched <= 0; fault_code <= 0;
        end else begin
            if (ms_tick && age_ms < SENSOR_TIMEOUT_MS) age_ms <= age_ms + 1'b1;
            if (have_sample && ms_tick && age_ms >= SENSOR_TIMEOUT_MS-1 && !temp_valid) begin
                fault_latched <= 1;
                if (!fault_latched) fault_code <= 1;
                good_frames <= 0;
            end
            if (temp_valid) begin
                temperature_x10 <= decoded_temp; // report even an out-of-window value
                if (temp_in_range) begin
                    age_ms <= 0; have_sample <= 1;
                    if (good_frames < GOOD_FRAMES_REQUIRED) good_frames <= good_frames + 1'b1;
                end else begin
                    fault_latched <= 1; good_frames <= 0;
                    if (!fault_latched) fault_code <= 2;
                end
            end
        end
    end

    // Start streaming once after boot. Retry only while no recent temperature exists.
    reg [31:0] start_wait_ms;
    reg [3:0] start_index;
    reg start_sending;
    reg sensor_tx_start;
    reg [7:0] sensor_tx_data;
    wire sensor_tx_busy;
    function [7:0] start_byte;
        input [3:0] index;
        begin
            case (index)
                0: start_byte=8'h4c; 1: start_byte=8'h52;
                2: start_byte=8'h03; 3: start_byte=SENSOR_MODEL;
                4: start_byte=SENSOR_ADDR; 5: start_byte=8'h04;
                6: start_byte=8'h00;
                7: start_byte=8'h03 ^ SENSOR_MODEL ^ SENSOR_ADDR ^ 8'h04;
                8: start_byte=8'h55; default: start_byte=8'haa;
            endcase
        end
    endfunction
    always @(posedge clk_50) begin
        if (!reset_ok) begin
            start_wait_ms <= SENSOR_BOOT_MS; start_index <= 0;
            start_sending <= 0; sensor_tx_start <= 0; sensor_tx_data <= 8'hff;
        end else begin
            sensor_tx_start <= 0;
            if (!start_sending) begin
                if (ms_tick) begin
                    if (start_wait_ms != 0) start_wait_ms <= start_wait_ms-1'b1;
                    else if (!link_alive) begin start_sending<=1; start_index<=0; end
                end
            end else if (!sensor_tx_busy && !sensor_tx_start) begin
                if (start_index < 10) begin
                    sensor_tx_data <= start_byte(start_index);
                    sensor_tx_start <= 1;
                    start_index <= start_index+1'b1;
                end else begin
                    start_sending<=0; start_wait_ms<=START_RETRY_MS;
                end
            end
        end
    end
    tec_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_sensor_tx (
        .clk(clk_50),.reset_n(reset_ok),.start(sensor_tx_start),.data(sensor_tx_data),
        .tx(sensor_uart_tx),.busy(sensor_tx_busy));

    reg [31:0] control_ms_counter;
    wire control_tick = ms_tick && (control_ms_counter == CONTROL_MS-1);
    always @(posedge clk_50) begin
        if (!reset_ok) control_ms_counter<=0;
        else if (ms_tick) begin
            if (control_tick) control_ms_counter<=0;
            else control_ms_counter<=control_ms_counter+1'b1;
        end
    end
    wire signed [15:0] pid_command;
    tec_pid_fixed #(.TARGET_X10(TARGET_TEMP_X10),.KP_Q8(KP_Q8),.KI_Q8(KI_Q8),
        .KD_Q8(KD_Q8),.LIMIT_PERMILLE(MAX_DUTY_PERMILLE)) u_pid (
        .clk(clk_50),.reset_n(reset_ok),.enable(control_enable),.tick(control_tick),
        .temperature_x10(temperature_x10),.command_permille(pid_command));
    wire signed [15:0] applied_command;
    tec_bridge_pwm #(.CLK_HZ(CLK_HZ),.PWM_HZ(PWM_HZ),
        .LIMIT_PERMILLE(MAX_DUTY_PERMILLE),.SLEW_PER_PERIOD(SLEW_PER_PWM),
        .REVERSE_OFF_MS(REVERSE_OFF_MS)) u_bridge (
        .clk(clk_50),.reset_n(reset_ok),.enable(control_enable),
        .command_permille(pid_command),.applied_permille(applied_command),
        .r_pwm(r_pwm),.l_pwm(l_pwm),.r_en(r_en),.l_en(l_en));

    wire [7:0] report_state = fault_latched ? "F" : (control_enable ? "R" : "W");
    tec_pc_reporter #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.REPORT_MS(REPORT_MS),
        .TARGET_X10(TARGET_TEMP_X10)) u_pc (
        .clk(clk_50),.reset_n(reset_ok),.ms_tick(ms_tick),
        .temperature_x10(temperature_x10),.applied_permille(applied_command),
        .status(report_state),.fault_code(fault_code),.tx(pc_uart_tx));

    // Elaboration checks are excluded from synthesis; no initial actuator drive.
    // synthesis translate_off
    initial begin
        if (CLK_HZ%1000 != 0 || CLK_HZ/BAUD < 8 || CONTROL_MS < 1 || REPORT_MS < 10 ||
            SENSOR_TIMEOUT_MS < 2 || GOOD_FRAMES_REQUIRED < 1 || GOOD_FRAMES_REQUIRED > 65535 ||
            POR_CYCLES < 1 || PWM_HZ < 1 || CLK_HZ/PWM_HZ < 2 ||
            MAX_DUTY_PERMILLE < 1 || MAX_DUTY_PERMILLE > 1000 || SLEW_PER_PWM < 1 ||
            REVERSE_OFF_MS < 1 || TARGET_TEMP_X10 < MIN_TEMP_X10 ||
            TARGET_TEMP_X10 > MAX_TEMP_X10 || MIN_TEMP_X10 < -32768 || MAX_TEMP_X10 > 32767 ||
            (SENSOR_MODEL != 8'h01 && SENSOR_MODEL != 8'h02))
            $fatal(1,"Invalid TEC configuration");
    end
    // synthesis translate_on
endmodule

module tec_uart_rx #(parameter integer CLK_HZ=50_000_000, BAUD=115200) (
    input wire clk, reset_n, rx,
    output reg [7:0] data, output reg valid, framing_error
);
    localparam integer BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=(BIT_CYCLES<2)?1:$clog2(BIT_CYCLES);
    (* ASYNC_REG = "TRUE" *) reg [1:0] rx_sync;
    reg [2:0] state;
    reg [CW-1:0] timer;
    reg [2:0] bit_index;
    reg [7:0] shift;
    always @(posedge clk) begin
        if (!reset_n) rx_sync<=2'b11;
        else rx_sync<={rx_sync[0],rx};
    end
    always @(posedge clk) begin
        if (!reset_n) begin
            data<=0; valid<=0; framing_error<=0; state<=0; timer<=0; bit_index<=0; shift<=0;
        end else begin
            valid<=0; framing_error<=0;
            case (state)
                0: if (!rx_sync[1]) begin timer<=BIT_CYCLES/2-1; state<=1; end
                1: if (timer!=0) timer<=timer-1'b1;
                   else if (rx_sync[1]) state<=0;
                   else begin timer<=BIT_CYCLES-1; bit_index<=0; state<=2; end
                2: if (timer!=0) timer<=timer-1'b1;
                   else begin
                       shift[bit_index]<=rx_sync[1]; timer<=BIT_CYCLES-1;
                       if (bit_index==7) state<=3; else bit_index<=bit_index+1'b1;
                   end
                3: if (timer!=0) timer<=timer-1'b1;
                   else if (rx_sync[1]) begin data<=shift; valid<=1; state<=0; end
                   else begin framing_error<=1; state<=4; end
                4: if (rx_sync[1]) state<=0; // line-break recovery
                default: state<=0;
            endcase
        end
    end
endmodule

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

module tec_rtd_parser #(
    parameter [7:0] MODEL=8'h02, ADDR=8'h01,
    parameter integer LITTLE_ENDIAN=0, SIGN_MAGNITUDE=0
) (
    input wire clk, reset_n, ms_tick,
    input wire [7:0] rx_byte, input wire rx_valid, rx_error,
    output reg signed [15:0] temperature_x10, output reg temperature_valid
);
    // Sliding window resynchronizes after noise, truncated frames, and unrelated replies.
    reg [95:0] window;
    reg [4:0] gap_ms;
    wire [95:0] next_frame={window[87:0],rx_byte};
    wire [7:0] checksum=next_frame[79:72]^next_frame[71:64]^next_frame[63:56]^
        next_frame[55:48]^next_frame[47:40]^next_frame[39:32]^next_frame[31:24];
    wire [15:0] raw_temp=LITTLE_ENDIAN ? {next_frame[31:24],next_frame[39:32]} :
                                                       next_frame[39:24];
    wire signed [15:0] decoded=(SIGN_MAGNITUDE && raw_temp[15]) ?
        -$signed({1'b0,raw_temp[14:0]}) : $signed(raw_temp);
    always @(posedge clk) begin
        if (!reset_n) begin window<=0; gap_ms<=0; temperature_x10<=0; temperature_valid<=0; end
        else begin
            temperature_valid<=0;
            if (rx_error) begin window<=0; gap_ms<=0; end
            else if (rx_valid) begin
                gap_ms<=0; window<=next_frame;
                if (next_frame[95:80]==16'h5a4a && next_frame[79:72]==8'h03 &&
                    next_frame[71:64]==MODEL && next_frame[63:56]==ADDR &&
                    next_frame[55:48]==8'h04 && next_frame[47:40]==8'h02 &&
                    next_frame[23:16]==checksum && next_frame[15:0]==16'haa55) begin
                    temperature_x10<=decoded; temperature_valid<=1;
                end
            end else if (ms_tick) begin
                if (gap_ms<20) gap_ms<=gap_ms+1'b1;
                else window<=0;
            end
        end
    end
endmodule

module tec_pid_fixed #(
    parameter integer TARGET_X10=400, KP_Q8=2560, KI_Q8=13, KD_Q8=512,
    LIMIT_PERMILLE=800
) (
    input wire clk, reset_n, enable, tick,
    input wire signed [15:0] temperature_x10,
    output reg signed [15:0] command_permille
);
    // Positive error -> cooling. Derivative on measurement avoids setpoint kick.
    // Fixed Ts supplied by top; last valid measurement is held between UART frames.
    localparam signed [63:0] LIMIT_Q8=LIMIT_PERMILLE*64'sd256;
    reg [1:0] state;
    reg signed [31:0] error_x10, delta_x10;
    reg signed [15:0] previous_temp;
    reg previous_valid;
    reg signed [63:0] p_term, i_step, d_term, integral_q8;
    reg signed [63:0] candidate_i, candidate_sum, chosen_i, result_q8;
    always @(posedge clk) begin
        if (!reset_n || !enable) begin
            state<=0; command_permille<=0; error_x10<=0; delta_x10<=0;
            previous_temp<=0; previous_valid<=0; integral_q8<=0;
            p_term<=0; i_step<=0; d_term<=0;
        end else case (state)
            0: if (tick) begin
                error_x10<=$signed(temperature_x10)-TARGET_X10;
                delta_x10<=previous_valid ? ($signed(temperature_x10)-$signed(previous_temp)) : 0;
                previous_temp<=temperature_x10; previous_valid<=1; state<=1;
            end
            1: begin
                p_term<=error_x10*$signed(KP_Q8);
                i_step<=error_x10*$signed(KI_Q8);
                d_term<=delta_x10*$signed(KD_Q8); state<=2;
            end
            2: begin
                candidate_i=integral_q8+i_step;
                if (candidate_i>LIMIT_Q8) candidate_i=LIMIT_Q8;
                else if (candidate_i< -LIMIT_Q8) candidate_i= -LIMIT_Q8;
                candidate_sum=p_term+candidate_i+d_term;
                // Conditional integration: do not wind up further into saturation.
                if ((candidate_sum>LIMIT_Q8 && error_x10>0) ||
                    (candidate_sum< -LIMIT_Q8 && error_x10<0)) chosen_i=integral_q8;
                else chosen_i=candidate_i;
                integral_q8<=chosen_i;
                result_q8=p_term+chosen_i+d_term;
                if (result_q8>LIMIT_Q8) command_permille<=LIMIT_PERMILLE;
                else if (result_q8< -LIMIT_Q8) command_permille<= -LIMIT_PERMILLE;
                // Truncate toward zero symmetrically, not negative-biased rounding.
                else if (result_q8<0) command_permille<= -((-result_q8)>>>8);
                else command_permille<=result_q8>>>8;
                state<=0;
            end
            default: state<=0;
        endcase
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
    wire [31:0] high_counts=(magnitude*PERIOD)/1000;
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
    parameter integer CLK_HZ=50_000_000, BAUD=115200, REPORT_MS=500, TARGET_X10=400
) (
    input wire clk, reset_n, ms_tick,
    input wire signed [15:0] temperature_x10, applied_permille,
    input wire [7:0] status, input wire [3:0] fault_code,
    output wire tx
);
    // 42-byte ASCII snapshot, e.g. T=+0049.0C,SP=+0040.0C,U=+080.0%,S=R,F=0\r\n
    reg [31:0] elapsed_ms;
    reg sending, start;
    reg [5:0] index;
    reg [7:0] data;
    wire busy;
    reg [15:0] temp_abs, duty_abs;
    reg temp_negative, duty_negative;
    reg [7:0] saved_status;
    reg [3:0] saved_fault;
    localparam integer TARGET_ABS=(TARGET_X10<0)?-TARGET_X10:TARGET_X10;
    function [7:0] report_byte;
        input [5:0] n;
        begin
            case(n)
                0: report_byte="T"; 1: report_byte="=";
                2: report_byte=temp_negative?"-":"+";
                3: report_byte=8'd48+(temp_abs/10000)%10;
                4: report_byte=8'd48+(temp_abs/1000)%10;
                5: report_byte=8'd48+(temp_abs/100)%10;
                6: report_byte=8'd48+(temp_abs/10)%10;
                7: report_byte="."; 8: report_byte=8'd48+temp_abs%10;
                9: report_byte="C"; 10: report_byte=",";
                11: report_byte="S"; 12: report_byte="P"; 13: report_byte="=";
                14: report_byte=(TARGET_X10<0)?"-":"+";
                15: report_byte=8'd48+(TARGET_ABS/10000)%10;
                16: report_byte=8'd48+(TARGET_ABS/1000)%10;
                17: report_byte=8'd48+(TARGET_ABS/100)%10;
                18: report_byte=8'd48+(TARGET_ABS/10)%10;
                19: report_byte="."; 20: report_byte=8'd48+TARGET_ABS%10;
                21: report_byte="C"; 22: report_byte=","; 23: report_byte="U";
                24: report_byte="="; 25: report_byte=duty_negative?"-":"+";
                26: report_byte=8'd48+(duty_abs/1000)%10;
                27: report_byte=8'd48+(duty_abs/100)%10;
                28: report_byte=8'd48+(duty_abs/10)%10;
                29: report_byte="."; 30: report_byte=8'd48+duty_abs%10;
                31: report_byte="%"; 32: report_byte=","; 33: report_byte="S";
                34: report_byte="="; 35: report_byte=saved_status;
                36: report_byte=","; 37: report_byte="F"; 38: report_byte="=";
                39: report_byte=8'd48+saved_fault;
                40: report_byte=8'h0d; default: report_byte=8'h0a;
            endcase
        end
    endfunction
    always @(posedge clk) begin
        if (!reset_n) begin
            elapsed_ms<=0; sending<=0; start<=0; index<=0; data<=8'hff;
            temp_abs<=0; duty_abs<=0; temp_negative<=0; duty_negative<=0;
            saved_status<="W"; saved_fault<=0;
        end else begin
            start<=0;
            if (ms_tick && elapsed_ms<REPORT_MS) elapsed_ms<=elapsed_ms+1'b1;
            if (!sending) begin
                if (elapsed_ms>=REPORT_MS) begin
                    elapsed_ms<=0; sending<=1; index<=0;
                    temp_negative<=temperature_x10[15];
                    temp_abs<=temperature_x10[15] ? -temperature_x10 : temperature_x10;
                    duty_negative<=applied_permille[15];
                    duty_abs<=applied_permille[15] ? -applied_permille : applied_permille;
                    saved_status<=status; saved_fault<=fault_code;
                end
            end else if (!busy && !start) begin
                if (index<42) begin data<=report_byte(index); start<=1; index<=index+1'b1; end
                else sending<=0;
            end
        end
    end
    tec_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx (
        .clk(clk),.reset_n(reset_n),.start(start),.data(data),.tx(tx),.busy(busy));
endmodule
`default_nettype wire
