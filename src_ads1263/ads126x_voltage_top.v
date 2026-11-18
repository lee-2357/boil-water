`timescale 1ns/1ps
module ads126x_voltage_top(
    input wire clk_50m,input wire key_reset_n,input wire adc_miso,input wire adc_drdy_n,
    output wire adc_cs_n,output wire adc_sclk,output wire adc_mosi,
    output wire adc_reset_n,output wire adc_start,
    output wire uart_tx_o,output wire led_ready,output wire led_error
);
    reg [15:0] por_count=0;
    reg por=1;
    (* ASYNC_REG="TRUE",SHREG_EXTRACT="NO" *) reg [1:0] key_sync=0;
    always @(posedge clk_50m) begin
        key_sync<={key_sync[0],key_reset_n};
        if(por_count!=16'hffff) por_count<=por_count+1;else por<=0;
    end
    wire rst=por || !key_sync[1];
    wire valid,busy,quality,ready;
    wire [7:0] error_code,id,status;
    wire signed [31:0] voltage;
    wire [31:0] avdd,raw,rejected;
    assign led_ready=ready;
    assign led_error=(error_code!=0);
    ads126x_voltage_reader u_reader(
        .clk(clk_50m),.rst(rst),.adc_miso(adc_miso),.adc_drdy_n(adc_drdy_n),
        .adc_cs_n(adc_cs_n),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),
        .adc_reset_n(adc_reset_n),.adc_start(adc_start),
        .report_busy(busy),.event_valid(valid),.quality(quality),.error_code(error_code),
        .device_id(id),.voltage_uv(voltage),.avdd_uv(avdd),.raw_code(raw),
        .status(status),.rejected_frames(rejected),.ready(ready));
    voltage_report u_report(.clk(clk_50m),.rst(rst),.event_valid(valid),
        .quality(quality),.voltage_uv(voltage),.avdd_uv(avdd),
        .device_id(id),.error_code(error_code),.busy(busy),.tx(uart_tx_o));
endmodule
