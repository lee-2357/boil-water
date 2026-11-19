`timescale 1ns/1ps
`default_nettype none
// Smart ZYNQ SL V1.3B: LZ_TD210 PT1000 AO -> ADS1263 ADC1 5 SPS -> PID -> TEC.
// RPWM=cooling, LPWM=heating, matching the original water-controller project.
module smart_zynq_ads1263_tec_pid #(
    parameter integer CLK_HZ=50000000, BAUD=115200, PWM_HZ=1000,
    TARGET_TEMP_X10=400, CONTROL_MS=500,
    KP_Q8=2560, KI_Q8=13, KD_Q8=512,
    MAX_DUTY_PERMILLE=800, SLEW_PER_PWM=2, REVERSE_OFF_MS=20,
    MIN_TEMP_X10=-200, MAX_TEMP_X10=800, SENSOR_TIMEOUT_MS=2000,
    GOOD_FRAMES_REQUIRED=3, REPORT_MS=500, POR_CYCLES=65536,
    AO_BASELINE_UV=2500000, AO_R_SCALE_NUM=40000, AO_R_SCALE_DEN=42933
) (
    input wire clk_50, rst_n, adc_miso, adc_drdy_n,
    output wire adc_cs_n, adc_sclk, adc_mosi, adc_reset_n, adc_start,
    output wire pc_uart_tx, r_pwm, l_pwm, r_en, l_en,
    output wire led_ready, led_error
);
    (* ASYNC_REG="TRUE",SHREG_EXTRACT="NO" *) reg [1:0] reset_sync=0;
    reg [31:0] por_count=0;
    always @(posedge clk_50 or negedge rst_n) begin
        if(!rst_n) reset_sync<=0;
        else reset_sync<={reset_sync[0],1'b1};
    end
    always @(posedge clk_50) begin
        if(!reset_sync[1]) por_count<=0;
        else if(por_count<POR_CYCLES) por_count<=por_count+1'b1;
    end
    wire reset_ok=rst_n && reset_sync[1] && (por_count==POR_CYCLES);
    wire adc_event, adc_quality, adc_ready;
    wire [7:0] adc_error_code, adc_id, adc_status;
    wire signed [31:0] voltage_uv;
    wire [31:0] avdd_uv, raw_code, rejected_frames;
    ads126x_voltage_reader #(.CLK_HZ(CLK_HZ)) u_reader (
        .clk(clk_50),.rst(!reset_ok),.adc_miso(adc_miso),.adc_drdy_n(adc_drdy_n),
        .adc_cs_n(adc_cs_n),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),
        .adc_reset_n(adc_reset_n),.adc_start(adc_start),.report_busy(1'b0),
        .event_valid(adc_event),.quality(adc_quality),.error_code(adc_error_code),
        .device_id(adc_id),.voltage_uv(voltage_uv),.avdd_uv(avdd_uv),
        .raw_code(raw_code),.status(adc_status),.rejected_frames(rejected_frames),.ready(adc_ready));
    wire temperature_event, temperature_good, converter_busy;
    wire signed [15:0] temperature_x10;
    wire [31:0] resistance_mohm;
    pt1000_ao_temperature #(.BASELINE_UV(AO_BASELINE_UV),
        .R_SCALE_NUM(AO_R_SCALE_NUM),.R_SCALE_DEN(AO_R_SCALE_DEN)) u_temperature (
        .clk(clk_50),.reset_n(reset_ok),.sample_valid(adc_event && adc_quality),
        .voltage_uv(voltage_uv),.avdd_uv(avdd_uv),.busy(converter_busy),
        .result_valid(temperature_event),.result_good(temperature_good),
        .temperature_x10(temperature_x10),.resistance_mohm(resistance_mohm));
    wire control_enable, fault_latched;
    wire [3:0] fault_code;
    tec_temperature_control #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.PWM_HZ(PWM_HZ),
        .TARGET_TEMP_X10(TARGET_TEMP_X10),.CONTROL_MS(CONTROL_MS),
        .KP_Q8(KP_Q8),.KI_Q8(KI_Q8),.KD_Q8(KD_Q8),
        .MAX_DUTY_PERMILLE(MAX_DUTY_PERMILLE),.SLEW_PER_PWM(SLEW_PER_PWM),
        .REVERSE_OFF_MS(REVERSE_OFF_MS),.MIN_TEMP_X10(MIN_TEMP_X10),.MAX_TEMP_X10(MAX_TEMP_X10),
        .SENSOR_TIMEOUT_MS(SENSOR_TIMEOUT_MS),.GOOD_FRAMES_REQUIRED(GOOD_FRAMES_REQUIRED),
        .REPORT_MS(REPORT_MS)) u_control (
        .clk(clk_50),.reset_n(reset_ok),.sample_event(temperature_event),
        .sample_good(temperature_good),.sample_temperature_x10(temperature_x10),
        .adc_ready(adc_ready),.adc_fault(adc_event && !adc_quality),
        .pc_uart_tx(pc_uart_tx),.r_pwm(r_pwm),.l_pwm(l_pwm),.r_en(r_en),.l_en(l_en),
        .control_enable(control_enable),.fault_latched(fault_latched),.fault_code(fault_code));
    assign led_ready=control_enable;
    assign led_error=fault_latched || (adc_error_code!=0);
endmodule
`default_nettype wire
