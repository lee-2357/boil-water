`timescale 1ns/1ps
`default_nettype none
// Mechanical relay time proportioning. Default 20 s window, 1 s resolution.
// New duty is latched at each window boundary. STOP/fault bypass the window.
module heater_relay_window #(
    parameter integer WINDOW_MS = 20000,
    parameter integer MIN_PULSE_MS = 1000,
    parameter integer LIMIT_PERMILLE = 800
)(
    input wire clk, reset_n, enable, ms_tick,
    input wire [15:0] requested_permille,
    output wire relay_on,
    output wire [15:0] active_permille
);
    localparam integer DUTY_STEP = 1000 * MIN_PULSE_MS / WINDOW_MS;
    reg [15:0] quantized_duty, window_duty;
    reg [31:0] phase_ms, on_time_ms;
    reg started;
    wire [15:0] limited_duty = requested_permille > LIMIT_PERMILLE
        ? LIMIT_PERMILLE : requested_permille;
    always @(posedge clk) begin
        if (!reset_n) quantized_duty <= 0;
        else quantized_duty <= (limited_duty / DUTY_STEP) * DUTY_STEP;
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            window_duty <= 0;
            phase_ms <= 0;
            on_time_ms <= 0;
            started <= 0;
        end else if (!enable) begin
            window_duty <= 0;
            phase_ms <= 0;
            on_time_ms <= 0;
            started <= 0;
        end else if ((!started && quantized_duty != 0) ||
                     (started && ms_tick && phase_ms == WINDOW_MS - 1)) begin
            window_duty <= quantized_duty;
            on_time_ms <= quantized_duty * (WINDOW_MS / 1000);
            phase_ms <= 0;
            started <= 1;
        end else if (ms_tick && started) phase_ms <= phase_ms + 1;
    end
    assign relay_on = reset_n && enable && started && phase_ms < on_time_ms;
    assign active_permille = reset_n && enable ? window_duty : 16'd0;
    // synthesis translate_off
    initial if (WINDOW_MS % 1000 != 0 || MIN_PULSE_MS < 1 ||
        WINDOW_MS % MIN_PULSE_MS != 0 || 1000 % (WINDOW_MS / MIN_PULSE_MS) != 0 ||
        WINDOW_MS <= MIN_PULSE_MS || LIMIT_PERMILLE > 1000)
        $fatal(1, "Invalid mechanical relay window configuration");
    // synthesis translate_on
endmodule
`default_nettype wire
