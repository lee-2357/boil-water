`timescale 1ns/1ps
module tb_relay_window;
    reg clk=0;
    always #5 clk=~clk;
    reg reset_n=0, enable=0, tick=0;
    reg [15:0] demand=0;
    wire relay;
    wire [15:0] duty;
    heater_relay_window #(.WINDOW_MS(20000),.MIN_PULSE_MS(1000)) dut(
        clk,reset_n,enable,tick,demand,relay,duty);
    integer i, on_ticks;
    initial begin
        #20;reset_n=1;demand=327;
        repeat(4) @(negedge clk);
        enable=1;
        @(negedge clk);
        if(duty!=300) $fatal(1,"quantization should floor 32.7%% to 30%%");
        on_ticks=0;
        for(i=0;i<20000;i=i+1) begin
            if(relay) on_ticks=on_ticks+1;
            tick=1;@(negedge clk);
        end
        tick=0;
        if(on_ticks!=6000) $fatal(1,"Expected 6000 ON ms, got %0d",on_ticks);
        demand=800;repeat(4) @(negedge clk);
        if(duty!=300) $fatal(1,"duty changed inside an active window");
        enable=0;#1;
        if(relay || duty!=0) $fatal(1,"disable did not gate output immediately");
        @(negedge clk);
        reset_n=0;enable=1;#1;
        if(relay) $fatal(1,"reset did not remove drive");
        $display("ALL RELAY WINDOW TESTS PASSED");$finish;
    end
endmodule
