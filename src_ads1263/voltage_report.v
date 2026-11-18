`timescale 1ns/1ps
// Good events print a new voltage. Error events contain NO voltage field.
module voltage_report #(
    parameter integer CLK_HZ=50000000,
    parameter integer BAUD=115200
)(
    input wire clk,input wire rst,input wire event_valid,input wire quality,
    input wire signed [31:0] voltage_uv,input wire [31:0] avdd_uv,
    input wire [7:0] device_id,error_code,
    output wire busy,output wire tx
);
    localparam IDLE=0,BCD=1,SEND=2,ACCEPT=3,WAIT_BYTE=4;
    localparam [327:0] GOOD={"V=+00.000000V,AVDD=00.000000V,Q=1,ID=00",8'h0d,8'h0a};
    localparam [95:0] BAD={"ERR=00,Q=0",8'h0d,8'h0a};
    reg [2:0] state;
    reg [31:0] bcd_v,bcd_a,bin_v,bin_a;
    reg [5:0] shift_count,index;
    reg negative,quality_hold;
    reg [7:0] id_hold,error_hold;
    reg uart_valid;
    reg [7:0] uart_data;
    wire uart_busy;
    assign busy=(state!=IDLE);
    uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_uart(
        .clk(clk),.rst(rst),.valid(uart_valid),.data(uart_data),.busy(uart_busy),.tx(tx));
    function [31:0] add3;
        input [31:0] value;
        integer i;
        begin
            add3=value;
            for(i=0;i<8;i=i+1)
                if(value[i*4+:4]>=5) add3[i*4+:4]=value[i*4+:4]+4'd3;
        end
    endfunction
    function [7:0] hexchar;
        input [3:0] n;
        begin hexchar=(n<10)?(8'h30+n):(8'h41+n-10);end
    endfunction
    function [7:0] character;
        input [5:0] pos;
        integer digit;
        begin
            if(!quality_hold) begin
                character=BAD[95-pos*8-:8];
                if(pos==4) character=hexchar(error_hold[7:4]);
                if(pos==5) character=hexchar(error_hold[3:0]);
            end else begin
                character=GOOD[327-pos*8-:8];
                if(pos==2) character=negative?8'h2d:8'h2b;
                if(pos==3 || pos==4 || (pos>=6 && pos<=11)) begin
                    digit=(pos<=4)?pos-3:pos-4;
                    character=8'h30+{4'b0,bcd_v[31-digit*4-:4]};
                end
                if(pos==19 || pos==20 || (pos>=22 && pos<=27)) begin
                    digit=(pos<=20)?pos-19:pos-20;
                    character=8'h30+{4'b0,bcd_a[31-digit*4-:4]};
                end
                if(pos==37) character=hexchar(id_hold[7:4]);
                if(pos==38) character=hexchar(id_hold[3:0]);
            end
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;bcd_v<=0;bcd_a<=0;bin_v<=0;bin_a<=0;shift_count<=0;
            index<=0;negative<=0;quality_hold<=0;id_hold<=0;error_hold<=0;
            uart_valid<=0;uart_data<=0;
        end else begin
            uart_valid<=0;
            case(state)
                IDLE: if(event_valid) begin
                    negative<=voltage_uv[31];quality_hold<=quality;
                    bin_v<=voltage_uv[31]?(~voltage_uv+32'd1):voltage_uv;
                    bin_a<=avdd_uv;bcd_v<=0;bcd_a<=0;shift_count<=0;
                    id_hold<=device_id;error_hold<=error_code;
                    index<=0;state<=quality?BCD:SEND;
                end
                BCD: begin
                    bcd_v<=(add3(bcd_v)<<1)|{31'b0,bin_v[31]};
                    bcd_a<=(add3(bcd_a)<<1)|{31'b0,bin_a[31]};
                    bin_v<=bin_v<<1;bin_a<=bin_a<<1;
                    if(shift_count==31) state<=SEND;
                    else shift_count<=shift_count+1;
                end
                SEND: if(!uart_busy) begin
                    uart_data<=character(index);uart_valid<=1;state<=ACCEPT;
                end
                ACCEPT: if(uart_busy) state<=WAIT_BYTE;
                WAIT_BYTE: if(!uart_busy) begin
                    if(index==(quality_hold?40:11)) state<=IDLE;
                    else begin index<=index+1;state<=SEND;end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
