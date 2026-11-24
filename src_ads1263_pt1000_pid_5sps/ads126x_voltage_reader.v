`timescale 1ns/1ps
// ADC1 only: measure AVDD once, then acquire A0-AINCOM continuously at 5 SPS.
// Invalid frames never update voltage_uv and never produce a good event.
module ads126x_voltage_reader #(
    parameter integer CLK_HZ=50000000,
    parameter integer SPI_HALF_CYCLES=500,
    parameter integer POWER_CYCLES=CLK_HZ/10,
    parameter integer RESET_CYCLES=CLK_HZ/1000,
    parameter integer RESET_WAIT_CYCLES=CLK_HZ/20,
    parameter integer SETTLE_CYCLES=CLK_HZ/50,
    parameter integer TIMEOUT_CYCLES=CLK_HZ/2,
    parameter integer RETRY_CYCLES=CLK_HZ/500,
    parameter integer RECOVERY_CYCLES=CLK_HZ,
    parameter integer MAX_RETRIES=2
)(
    input wire clk,input wire rst,input wire adc_miso,input wire adc_drdy_n,
    output wire adc_cs_n,output wire adc_sclk,output wire adc_mosi,
    output reg adc_reset_n,output reg adc_start,
    input wire report_busy,output reg event_valid,output reg quality,
    output reg [7:0] error_code,device_id,
    output reg signed [31:0] voltage_uv,
    output reg [31:0] avdd_uv,raw_code,
    output reg [7:0] status,
    output reg [31:0] rejected_frames,
    output reg ready
);
    (* ASYNC_REG="TRUE",SHREG_EXTRACT="NO" *) reg [1:0] drdy_sync;
    always @(posedge clk) begin
        if(rst) drdy_sync<=2'b11;
        else drdy_sync<={drdy_sync[0],adc_drdy_n};
    end
    reg spi_start;
    reg [127:0] spi_tx;
    reg [4:0] spi_bytes;
    wire spi_done,spi_busy;
    wire [127:0] spi_rx;
    ads1263_spi #(.HALF_CYCLES(SPI_HALF_CYCLES)) u_spi(
        .clk(clk),.rst(rst),.start(spi_start),.tx_data(spi_tx),.byte_count(spi_bytes),
        .busy(spi_busy),.done(spi_done),.rx_data(spi_rx),
        .cs_n(adc_cs_n),.sclk(adc_sclk),.mosi(adc_mosi),.miso(adc_miso));
    localparam POWER=0,RLOW=1,RWAIT=2,ID=3,ID_WAIT=4,STOP=5,STOP_WAIT=6,
        CFG=7,CFG_WAIT=8,REF=9,REF_WAIT=10,CHECK=11,CHECK_WAIT=12,
        CHECKREF=13,CHECKREF_WAIT=14,SETTLE=15,WAIT_DATA=16,
        READ=17,READ_WAIT=18,RETRY=19,MUL_SUPPLY=20,SCALE_SUPPLY=21,
        MUL_INPUT=22,SCALE_INPUT=23,REPORT=24,ERROR_REPORT=25,RECOVERY=26;
    reg [4:0] state;
    reg input_mode,drdy_armed;
    reg [7:0] retries,last_error;
    reg [31:0] timer,watchdog;
    reg signed [63:0] product;
    wire [47:0] config_bytes=input_mode?48'h03050080810a:48'h0305008001cc;
    wire [7:0] refmux=input_mode?8'h24:8'h00;
    wire [47:0] frame=spi_rx[47:0];
    wire [7:0] check_sum=8'h9b+frame[39:32]+frame[31:24]+frame[23:16]+frame[15:8];
    wire frame_ok=(frame[7:0]==check_sum) && frame[46] && !frame[44] &&
                  !frame[40] && (input_mode || frame[43:41]==0);
    wire signed [63:0] supply_scaled=product>>>31;
    task launch;
        input [127:0] data;input [4:0] bytes;input [4:0] next_state;
        begin spi_tx<=data;spi_bytes<=bytes;spi_start<=1;state<=next_state;end
    endtask
    task fail;
        input [7:0] code;
        begin
            adc_start<=0;ready<=0;quality<=0;error_code<=code;
            state<=ERROR_REPORT;
        end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=POWER;timer<=POWER_CYCLES-1;watchdog<=0;
            adc_reset_n<=1;adc_start<=0;spi_start<=0;spi_tx<=0;spi_bytes<=0;
            input_mode<=0;drdy_armed<=1;retries<=0;last_error<=8'h03;
            event_valid<=0;quality<=0;error_code<=0;device_id<=0;
            voltage_uv<=0;avdd_uv<=0;raw_code<=0;status<=0;
            rejected_frames<=0;product<=0;ready<=0;
        end else begin
            spi_start<=0;event_valid<=0;
            // Count time since the last accepted conversion. A toggling DRDY
            // with continuously corrupt frames must also trigger recovery.
            if(state>=WAIT_DATA && state<=REPORT && watchdog<TIMEOUT_CYCLES)
                watchdog<=watchdog+1;
            // DRDY returns high as soon as reading begins, not after CS rises.
            if(drdy_sync[1]) drdy_armed<=1;
            case(state)
                POWER: if(timer!=0) timer<=timer-1;
                else begin adc_reset_n<=0;timer<=RESET_CYCLES-1;state<=RLOW;end
                RLOW: if(timer!=0) timer<=timer-1;
                else begin
                    adc_reset_n<=1;timer<=RESET_WAIT_CYCLES-1;state<=RWAIT;
                    input_mode<=0;avdd_uv<=0;ready<=0;quality<=0;
                end
                RWAIT: if(timer!=0) timer<=timer-1;else state<=ID;
                ID: launch({24'h200000,104'b0},3,ID_WAIT);
                ID_WAIT: if(spi_done) begin
                    device_id<=spi_rx[7:0];
                    if(spi_rx[7:5]!=0 && spi_rx[7:5]!=1) fail(8'h01);
                    else state<=STOP;
                end
                STOP: begin adc_start<=0;launch({8'h0a,120'b0},1,STOP_WAIT);end
                STOP_WAIT: if(spi_done) state<=CFG;
                CFG: launch({16'h4105,config_bytes,64'b0},8,CFG_WAIT);
                CFG_WAIT: if(spi_done) state<=REF;
                REF: launch({16'h4f00,refmux,104'b0},3,REF_WAIT);
                REF_WAIT: if(spi_done) state<=CHECK;
                CHECK: launch({16'h2006,112'b0},9,CHECK_WAIT);
                CHECK_WAIT: if(spi_done) begin
                    if(spi_rx[55:0]!={device_id,config_bytes}) fail(8'h02);
                    else state<=CHECKREF;
                end
                CHECKREF: launch({16'h2f00,112'b0},3,CHECKREF_WAIT);
                CHECKREF_WAIT: if(spi_done) begin
                    if(spi_rx[7:0]!=refmux) fail(8'h02);
                    else begin timer<=SETTLE_CYCLES-1;state<=SETTLE;end
                end
                SETTLE: if(timer!=0) timer<=timer-1;
                else begin
                    adc_start<=1;drdy_armed<=1;watchdog<=0;retries<=0;
                    last_error<=8'h03;state<=WAIT_DATA;
                end
                WAIT_DATA: if(watchdog>=TIMEOUT_CYCLES) fail(last_error);
                else if(!drdy_sync[1] && drdy_armed) begin
                    drdy_armed<=0;retries<=0;state<=READ;
                end
                READ: launch({8'h12,120'b0},7,READ_WAIT);
                READ_WAIT: if(spi_done) begin
                    if(frame_ok) begin
                        watchdog<=0;
                        if(!input_mode) begin raw_code<=frame[39:8];state<=MUL_SUPPLY;end
                        else begin
                            raw_code<=frame[39:8];status<=frame[47:40];state<=MUL_INPUT;
                        end
                    end else begin
                        rejected_frames<=rejected_frames+1;last_error<=8'h04;
                        // RESET/REF alarms require reconfiguration, not scaling.
                        if(frame[40] || frame[44]) fail(8'h06);
                        else if(watchdog>=TIMEOUT_CYCLES) fail(8'h04);
                        else if(retries<MAX_RETRIES) begin
                            retries<=retries+1;timer<=RETRY_CYCLES-1;state<=RETRY;
                        end else state<=WAIT_DATA;
                    end
                end
                RETRY: if(timer!=0) timer<=timer-1;
                else if(watchdog>=TIMEOUT_CYCLES) fail(8'h04);
                else state<=READ;
                MUL_SUPPLY: begin
                    product<=$signed(raw_code)*64'sd10000000;state<=SCALE_SUPPLY;
                end
                SCALE_SUPPLY: begin
                    if(supply_scaled<4700000 || supply_scaled>5300000) fail(8'h05);
                    else begin
                        avdd_uv<=supply_scaled[31:0];input_mode<=1;adc_start<=0;state<=STOP;
                    end
                end
                MUL_INPUT: begin
                    product<=$signed(raw_code)*$signed({1'b0,avdd_uv});state<=SCALE_INPUT;
                end
                SCALE_INPUT: begin
                    voltage_uv<=(product>>>31)+$signed({1'b0,avdd_uv[31:1]});
                    quality<=1;error_code<=0;ready<=1;state<=REPORT;
                end
                REPORT: if(!report_busy) begin event_valid<=1;state<=WAIT_DATA;end
                ERROR_REPORT: if(!report_busy) begin
                    event_valid<=1;timer<=RECOVERY_CYCLES-1;state<=RECOVERY;
                end
                RECOVERY: if(timer!=0) timer<=timer-1;
                else begin adc_reset_n<=0;timer<=RESET_CYCLES-1;state<=RLOW;end
                default: fail(8'h07);
            endcase
        end
    end
endmodule
