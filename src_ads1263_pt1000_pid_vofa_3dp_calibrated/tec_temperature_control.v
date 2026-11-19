`timescale 1ns/1ps
`default_nettype none
// ADC-independent supervisor around the PID/PWM/reporter from the old project.
module tec_temperature_control #(
    parameter integer CLK_HZ=50000000, BAUD=115200, PWM_HZ=1000,
    CONTROL_MS=500,
    KP_Q8=2560, KI_Q8=13, KD_Q8=512,
    MAX_DUTY_PERMILLE=800, SLEW_PER_PWM=2, REVERSE_OFF_MS=20,
    MIN_TEMP_MDEG=-20000, MAX_TEMP_MDEG=80000,
    SENSOR_TIMEOUT_MS=2000, GOOD_FRAMES_REQUIRED=3, REPORT_MS=500
) (
    input wire clk, reset_n,
    input wire sample_event, sample_good, adc_ready, adc_fault,
    input wire signed [31:0] sample_temperature_mdeg,
    input wire [31:0] target_mdeg,
    input wire target_changed,
    output wire pc_uart_tx, r_pwm, l_pwm, r_en, l_en,
    output wire control_enable,
    output reg fault_latched,
    output reg [3:0] fault_code
);
    localparam integer MS_DIV=CLK_HZ/1000;
    reg [31:0] ms_divider;
    wire ms_tick=(ms_divider==MS_DIV-1);
    always @(posedge clk) begin
        if(!reset_n || ms_tick) ms_divider<=0;
        else ms_divider<=ms_divider+1'b1;
    end
    reg signed [31:0] temperature_mdeg;
    reg [31:0] age_ms;
    reg [15:0] good_frames;
    reg have_sample;
    wire temp_in_range=($signed(sample_temperature_mdeg)>=MIN_TEMP_MDEG) &&
                       ($signed(sample_temperature_mdeg)<=MAX_TEMP_MDEG);
    wire sample_accepted=sample_event && sample_good && temp_in_range && !adc_fault;
    wire link_alive=have_sample && (age_ms<SENSOR_TIMEOUT_MS);
    // Combinational gating removes drive as soon as ready drops or an error is
    // presented; the registered latch then requires a KEY1 reset to restart.
    assign control_enable=reset_n && !fault_latched && link_alive && adc_ready &&
        !adc_fault && !(sample_event && (!sample_good || !temp_in_range)) &&
        (good_frames>=GOOD_FRAMES_REQUIRED);
    // F=1 stale, 2 temperature outside application window, 3 ADC, 4 AO/RTD range.
    always @(posedge clk) begin
        if(!reset_n) begin
            temperature_mdeg<=0; age_ms<=SENSOR_TIMEOUT_MS; good_frames<=0;
            have_sample<=0; fault_latched<=0; fault_code<=0;
        end else begin
            if(ms_tick && age_ms<SENSOR_TIMEOUT_MS) age_ms<=age_ms+1'b1;
            if(sample_accepted) begin
                temperature_mdeg<=sample_temperature_mdeg; age_ms<=0; have_sample<=1;
                if(good_frames<GOOD_FRAMES_REQUIRED) good_frames<=good_frames+1'b1;
            end
            if(!fault_latched) begin
                if(adc_fault || (have_sample && !adc_ready)) begin
                    fault_latched<=1; fault_code<=3; good_frames<=0;
                end else if(sample_event && !sample_good) begin
                    fault_latched<=1; fault_code<=4; good_frames<=0;
                end else if(sample_event && !temp_in_range) begin
                    temperature_mdeg<=sample_temperature_mdeg;
                    fault_latched<=1; fault_code<=2; good_frames<=0;
                end else if(have_sample && ms_tick && age_ms>=SENSOR_TIMEOUT_MS-1 && !sample_accepted) begin
                    fault_latched<=1; fault_code<=1; good_frames<=0;
                end
            end
        end
    end
    reg [31:0] control_ms_counter;
    wire control_tick=ms_tick && (control_ms_counter==CONTROL_MS-1);
    always @(posedge clk) begin
        if(!reset_n) control_ms_counter<=0;
        else if(ms_tick) begin
            if(control_tick) control_ms_counter<=0;
            else control_ms_counter<=control_ms_counter+1'b1;
        end
    end
    wire signed [15:0] pid_command, applied_command;
    tec_pid_fixed #(.KP_Q8(KP_Q8),.KI_Q8(KI_Q8),
        .KD_Q8(KD_Q8),.LIMIT_PERMILLE(MAX_DUTY_PERMILLE)) u_pid (
        .clk(clk),.reset_n(reset_n && !target_changed),.enable(control_enable),.tick(control_tick),
        .target_mdeg(target_mdeg),
        .temperature_mdeg(temperature_mdeg),.command_permille(pid_command));
    tec_bridge_pwm #(.CLK_HZ(CLK_HZ),.PWM_HZ(PWM_HZ),
        .LIMIT_PERMILLE(MAX_DUTY_PERMILLE),.SLEW_PER_PERIOD(SLEW_PER_PWM),
        .REVERSE_OFF_MS(REVERSE_OFF_MS)) u_bridge (
        .clk(clk),.reset_n(reset_n),.enable(control_enable),.command_permille(pid_command),
        .applied_permille(applied_command),.r_pwm(r_pwm),.l_pwm(l_pwm),.r_en(r_en),.l_en(l_en));
    wire [7:0] report_state=fault_latched ? "F" : (control_enable ? "R" : "W");
    tec_pc_reporter #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.REPORT_MS(REPORT_MS)) u_pc (
        .clk(clk),.reset_n(reset_n),.ms_tick(ms_tick),.temperature_mdeg(temperature_mdeg),
        .target_mdeg(target_mdeg),.applied_permille(applied_command),.status(report_state),.fault_code(fault_code),.tx(pc_uart_tx));
    // synthesis translate_off
    initial if(CLK_HZ%1000!=0 || CONTROL_MS<1 || SENSOR_TIMEOUT_MS<2 ||
        GOOD_FRAMES_REQUIRED<1 || GOOD_FRAMES_REQUIRED>65535)
        $fatal(1,"Invalid temperature control configuration");
    // synthesis translate_on
endmodule
`default_nettype wire
