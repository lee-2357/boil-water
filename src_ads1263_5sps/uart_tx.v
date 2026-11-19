`timescale 1ns/1ps
module uart_tx #(
    parameter integer CLK_HZ=50000000,
    parameter integer BAUD=115200
)(
    input wire clk, input wire rst,
    input wire valid, input wire [7:0] data,
    output reg busy, output reg tx
);
    localparam integer BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD;
    reg [31:0] timer;
    reg [3:0] bit_index;
    reg [9:0] shift;
    always @(posedge clk) begin
        if (rst) begin busy<=0; tx<=1; timer<=0; bit_index<=0; shift<=10'h3ff; end
        else if (!busy) begin
            if (valid) begin
                shift<={1'b1,data,1'b0}; bit_index<=0; tx<=0;
                busy<=1; timer<=BIT_CYCLES-1;
            end
        end else if (timer!=0) timer<=timer-1;
        else if (bit_index==9) begin busy<=0; tx<=1; end
        else begin
            shift<={1'b1,shift[9:1]}; tx<=shift[1];
            bit_index<=bit_index+1; timer<=BIT_CYCLES-1;
        end
    end
endmodule
