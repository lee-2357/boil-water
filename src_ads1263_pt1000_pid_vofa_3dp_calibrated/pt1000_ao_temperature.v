`timescale 1ns/1ps
`default_nettype none
// LZ_TD210 manual, section 3.2 (printed p.5), PT1000 AO output.
// Nominal gain=4.2933, current=250 uA, baseline=2.5 V.
// R_milliohm=(AO_uV-BASELINE_UV)*40000/42933.
// Calibration of this external AO path is independent of module UART settings.
module pt1000_ao_temperature #(
    parameter integer BASELINE_UV=2500000,
    parameter integer R_SCALE_NUM=40000,
    parameter integer R_SCALE_DEN=42933,
    parameter integer OFFSET_MDEG=0
) (
    input wire clk, reset_n, sample_valid,
    input wire signed [31:0] voltage_uv,
    input wire [31:0] avdd_uv,
    output wire busy,
    output reg result_valid, result_good,
    output reg signed [31:0] temperature_mdeg,
    output reg [31:0] resistance_mohm
);
    localparam IDLE=0, R_MUL=1, R_START=2, R_WAIT=3, SQUARE=4,
        QUAD_MUL=5, QUAD_START=6, QUAD_WAIT=7, LINEAR_MUL=8,
        LINEAR_START=9, LINEAR_WAIT=10, SUM=11, TEMP_START=12, TEMP_WAIT=13;
    reg [3:0] state;
    localparam [63:0] SCALE_NUM_U64=R_SCALE_NUM;
    reg [31:0] delta_uv;
    reg [21:0] r_mohm;
    reg upper_segment;
    reg [43:0] r_squared;
    reg [63:0] product;
    reg signed [31:0] quadratic_udeg, linear_udeg, total_udeg;
    reg temp_negative;
    wire [31:0] temp_magnitude=total_udeg[31] ? (32'd0-total_udeg) : total_udeg;
    reg div_start;
    reg [63:0] numerator, denominator;
    wire div_busy, div_done;
    wire [63:0] quotient;
    assign busy=(state!=IDLE);
    ao_unsigned_div64 u_div(.clk(clk),.reset_n(reset_n),.start(div_start),
        .numerator(numerator),.denominator(denominator),
        .busy(div_busy),.done(div_done),.quotient(quotient));
    // All divisions are sequential: no long combinational division path.
    always @(posedge clk) begin
        if (!reset_n) begin
            state<=IDLE; result_valid<=0; result_good<=0; temperature_mdeg<=0;
            resistance_mohm<=0; delta_uv<=0; r_mohm<=0; upper_segment<=0;
            r_squared<=0; product<=0; quadratic_udeg<=0; linear_udeg<=0;
            total_udeg<=0; temp_negative<=0;
            div_start<=0; numerator<=0; denominator<=1;
        end else begin
            result_valid<=0; div_start<=0;
            case(state)
                IDLE: if(sample_valid) begin
                    result_good<=0;
                    if ($signed(voltage_uv)<=BASELINE_UV ||
                        $signed({1'b0,voltage_uv})>$signed({1'b0,avdd_uv})) begin
                        resistance_mohm<=0; result_valid<=1;
                    end else begin
                        delta_uv<=voltage_uv-BASELINE_UV; state<=R_MUL;
                    end
                end
                R_MUL: begin product<=delta_uv*SCALE_NUM_U64; state<=R_START; end
                R_START: begin
                    numerator<=product+R_SCALE_DEN/2; denominator<=R_SCALE_DEN;
                    div_start<=1; state<=R_WAIT;
                end
                R_WAIT: if(div_done) begin
                    resistance_mohm<=quotient[31:0];
                    // Open interval endpoints follow the manual's fit range.
                    if(quotient<=803063 || quotient>=2120515) begin
                        result_valid<=1; state<=IDLE;
                    end else begin
                        r_mohm<=quotient[21:0]; upper_segment<=(quotient>1385055);
                        state<=SQUARE;
                    end
                end
                SQUARE: begin r_squared<=r_mohm*r_mohm; state<=QUAD_MUL; end
                // Microdegree intermediates: round the total to 0.001 C only at the end.
                QUAD_MUL: begin
                    product<=r_squared*(upper_segment?64'd11610:64'd9962);
                    state<=QUAD_START;
                end
                QUAD_START: begin
                    numerator<=product+64'd500000000; denominator<=64'd1000000000;
                    div_start<=1; state<=QUAD_WAIT;
                end
                QUAD_WAIT: if(div_done) begin quadratic_udeg<=quotient[31:0]; state<=LINEAR_MUL; end
                LINEAR_MUL: begin
                    product<=r_mohm*(upper_segment?64'd2312:64'd2359); state<=LINEAR_START;
                end
                LINEAR_START: begin
                    numerator<=product+64'd5; denominator<=64'd10;
                    div_start<=1; state<=LINEAR_WAIT;
                end
                LINEAR_WAIT: if(div_done) begin linear_udeg<=quotient[31:0]; state<=SUM; end
                SUM: begin
                    total_udeg<=quadratic_udeg+linear_udeg-(upper_segment?32'sd242500000:32'sd245900000);
                    state<=TEMP_START;
                end
                TEMP_START: begin
                    temp_negative<=total_udeg[31];
                    numerator<={32'd0,temp_magnitude}+64'd500;
                    denominator<=1000; div_start<=1; state<=TEMP_WAIT;
                end
                TEMP_WAIT: if(div_done) begin
                    // Apply one fixed offset to valid measurements before both
                    // the PID/window checks and the serial temperature report.
                    temperature_mdeg<=(temp_negative ? -$signed(quotient[31:0]) : $signed(quotient[31:0]))+OFFSET_MDEG;
                    result_valid<=1; result_good<=1; state<=IDLE;
                end
                default: begin result_valid<=1; result_good<=0; state<=IDLE; end
            endcase
        end
    end
    // synthesis translate_off
    initial if(R_SCALE_NUM<=0 || R_SCALE_DEN<=0 || BASELINE_UV<0)
        $fatal(1,"Invalid AO calibration parameters");
    always @(posedge clk) if(reset_n && sample_valid && busy)
        $fatal(1,"AO sample arrived before previous conversion finished");
    // synthesis translate_on
endmodule

// Unsigned restoring divider, 64 clocks; denominator must be nonzero.
module ao_unsigned_div64 (
    input wire clk, reset_n, start,
    input wire [63:0] numerator, denominator,
    output reg busy, done,
    output reg [63:0] quotient
);
    reg [63:0] shift, divisor;
    reg [64:0] remainder;
    reg [6:0] count;
    wire [64:0] trial={remainder[63:0],shift[63]};
    wire subtract=(trial>={1'b0,divisor});
    always @(posedge clk) begin
        if(!reset_n) begin
            busy<=0; done<=0; quotient<=0; shift<=0; divisor<=1; remainder<=0; count<=0;
        end else begin
            done<=0;
            if(start && !busy) begin
                shift<=numerator; divisor<=denominator; remainder<=0; count<=64; busy<=1;
            end else if(busy) begin
                remainder<=subtract ? trial-{1'b0,divisor} : trial;
                shift<={shift[62:0],subtract}; count<=count-1'b1;
                if(count==1) begin quotient<={shift[62:0],subtract}; busy<=0; done<=1; end
            end
        end
    end
endmodule
`default_nettype wire
