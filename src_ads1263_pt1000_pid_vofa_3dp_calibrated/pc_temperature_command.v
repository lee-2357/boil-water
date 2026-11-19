`timescale 1ns/1ps
`default_nettype none
// Plain ASCII decimal setpoint for VOFA, 115200/8N1 by default.
// Commit at CR/LF or after IDLE_MS silence. Optional sign/outer whitespace;
// 0..3 decimal places. Malformed tokens/framing errors discard the command.
// Valid numbers saturate to 10.000..80.000 C, including huge magnitudes.
module pc_temperature_command #(
    parameter integer CLK_HZ=50000000, BAUD=115200, IDLE_MS=50,
    DEFAULT_TARGET_MDEG=40000
) (
    input wire clk, reset_n, rx,
    output reg [31:0] target_mdeg,
    output reg target_valid
);
    wire [7:0] rx_data;
    wire rx_valid, rx_error;
    pc_temperature_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_rx(
        .clk(clk),.reset_n(reset_n),.rx(rx),.data(rx_data),
        .valid(rx_valid),.framing_error(rx_error));
    localparam integer IDLE_CYCLES=(CLK_HZ/1000)*IDLE_MS;
    reg [31:0] idle_count;
    reg active, bad, negative, digit_seen, point_seen, trailing;
    reg [16:0] whole; // Saturates at 10000, prevents arbitrary input overflow.
    reg [9:0] fraction;
    reg [1:0] fraction_digits;
    wire is_digit=(rx_data>="0" && rx_data<="9");
    wire is_space=(rx_data==8'h20 || rx_data==8'h09);
    wire terminator=(rx_data==8'h0d || rx_data==8'h0a);
    wire [31:0] scaled_fraction=(fraction_digits==0)?0:
        ((fraction_digits==1)?fraction*32'd100:
        ((fraction_digits==2)?fraction*32'd10:{22'd0,fraction}));
    wire [31:0] magnitude=whole*32'd1000+scaled_fraction;
    task clear_token;
        begin
            active<=0; bad<=0; negative<=0; digit_seen<=0; point_seen<=0;
            trailing<=0; whole<=0; fraction<=0; fraction_digits<=0; idle_count<=0;
        end
    endtask
    task commit_token;
        begin
            if(active && digit_seen && !bad) begin
                if(negative || magnitude<10000) target_mdeg<=10000;
                else if(magnitude>80000) target_mdeg<=80000;
                else target_mdeg<=magnitude;
                target_valid<=1;
            end
            clear_token;
        end
    endtask
    always @(posedge clk) begin
        if(!reset_n) begin
            clear_token;
            target_mdeg<=(DEFAULT_TARGET_MDEG<10000)?10000:
                ((DEFAULT_TARGET_MDEG>80000)?80000:DEFAULT_TARGET_MDEG);
            target_valid<=0;
        end else begin
            target_valid<=0;
            if(rx_error) begin
                // Keep a poisoned token until a delimiter/idle; never accept
                // a suffix after a damaged UART byte as a new setpoint.
                bad<=1; active<=1; idle_count<=0;
            end else if(rx_valid) begin
                idle_count<=0;
                if(terminator) commit_token;
                else if(is_space) begin
                    if(active) trailing<=1;
                end else begin
                    active<=1;
                    if(trailing) bad<=1;
                    if(is_digit) begin
                        digit_seen<=1;
                        if(point_seen) begin
                            if(fraction_digits<3) begin
                                fraction<=fraction*10+(rx_data-8'd48);
                                fraction_digits<=fraction_digits+1'b1;
                            end else bad<=1;
                        end else if(whole<10000) whole<=whole*10+(rx_data-8'd48);
                    end else if(rx_data=="." && !point_seen) point_seen<=1;
                    else if((rx_data=="-" || rx_data=="+") && !active)
                        negative<=(rx_data=="-");
                    else bad<=1;
                end
            end else if(active) begin
                if(idle_count>=IDLE_CYCLES-1) commit_token;
                else idle_count<=idle_count+1'b1;
            end
        end
    end
    // synthesis translate_off
    initial if(IDLE_MS<1 || CLK_HZ%1000!=0 || CLK_HZ/BAUD<8)
        $fatal(1,"Invalid PC UART configuration");
    // synthesis translate_on
endmodule

module pc_temperature_uart_rx #(parameter integer CLK_HZ=50000000, BAUD=115200)(
    input wire clk, reset_n, rx,
    output reg [7:0] data,
    output reg valid, framing_error
);
    localparam integer BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=(BIT_CYCLES<2)?1:$clog2(BIT_CYCLES);
    (* ASYNC_REG="TRUE",SHREG_EXTRACT="NO" *) reg [1:0] rx_sync;
    reg [2:0] state;
    reg [CW-1:0] timer;
    reg [2:0] bit_index;
    reg [7:0] shift;
    always @(posedge clk) begin
        if(!reset_n) rx_sync<=2'b11;
        else rx_sync<={rx_sync[0],rx};
    end
    always @(posedge clk) begin
        if(!reset_n) begin
            data<=0; valid<=0; framing_error<=0; state<=0; timer<=0; bit_index<=0; shift<=0;
        end else begin
            valid<=0; framing_error<=0;
            case(state)
                0: if(!rx_sync[1]) begin timer<=BIT_CYCLES/2-1; state<=1; end
                1: if(timer!=0) timer<=timer-1'b1;
                   else if(rx_sync[1]) state<=0;
                   else begin timer<=BIT_CYCLES-1; bit_index<=0; state<=2; end
                2: if(timer!=0) timer<=timer-1'b1;
                   else begin
                       shift[bit_index]<=rx_sync[1]; timer<=BIT_CYCLES-1;
                       if(bit_index==7) state<=3; else bit_index<=bit_index+1'b1;
                   end
                3: if(timer!=0) timer<=timer-1'b1;
                   else if(rx_sync[1]) begin data<=shift; valid<=1; state<=0; end
                   else begin framing_error<=1; state<=4; end
                4: if(rx_sync[1]) state<=0;
                default:state<=0;
            endcase
        end
    end
endmodule
`default_nettype wire
