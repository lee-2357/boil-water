`timescale 1ns/1ps
// ADS1263: SPI mode 1, MSB first. DIN changes on rising SCLK;
// DOUT is sampled on falling SCLK. All logic uses clk, never SCLK.
module ads1263_spi #(
    parameter integer HALF_CYCLES = 25
)(
    input wire clk, input wire rst,
    input wire start,
    input wire [127:0] tx_data, // first byte in [127:120]
    input wire [4:0] byte_count, // 1..16
    output reg busy, output reg done,
    output reg [127:0] rx_data, // received bytes right aligned
    output reg cs_n, output reg sclk, output reg mosi,
    input wire miso
);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] miso_sync;
    always @(posedge clk) begin
        if (rst) miso_sync <= 2'b00;
        else miso_sync <= {miso_sync[0], miso};
    end
    localparam IDLE=0, SETUP=1, HIGH=2, LOW=3, HOLD=4, GAP=5;
    reg [2:0] state;
    reg [31:0] timer;
    reg [7:0] bits_left;
    reg [127:0] tx_shift;
    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE; timer<=0; bits_left<=0; tx_shift<=0;
            rx_data<=0; busy<=0; done<=0; cs_n<=1; sclk<=0; mosi<=0;
        end else begin
            done<=0;
            case (state)
                IDLE: if (start && byte_count!=0 && byte_count<=16) begin
                    busy<=1; cs_n<=0; sclk<=0; mosi<=0;
                    tx_shift<=tx_data; rx_data<=0;
                    bits_left<={byte_count,3'b000};
                    timer<=HALF_CYCLES-1; state<=SETUP;
                end
                SETUP,LOW: if (timer!=0) timer<=timer-1;
                else begin
                    sclk<=1; mosi<=tx_shift[127];
                    timer<=HALF_CYCLES-1; state<=HIGH;
                end
                HIGH: if (timer!=0) timer<=timer-1;
                else begin
                    sclk<=0;
                    rx_data<={rx_data[126:0],miso_sync[1]};
                    tx_shift<={tx_shift[126:0],1'b0};
                    bits_left<=bits_left-1;
                    timer<=HALF_CYCLES-1;
                    if (bits_left==1) state<=HOLD; else state<=LOW;
                end
                HOLD: if (timer!=0) timer<=timer-1;
                else begin
                    cs_n<=1; mosi<=0; timer<=HALF_CYCLES-1; state<=GAP;
                end
                GAP: if (timer!=0) timer<=timer-1;
                else begin busy<=0; done<=1; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
