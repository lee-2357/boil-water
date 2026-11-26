`timescale 1ns/1ps
module tb_relay_system;
    reg clk=0;
    always #500 clk=~clk;
    reg rst_n=0, rx=1, sample_pulse=0;
    reg [31:0] test_voltage=3600000;
    wire tx, relay, rp, lp, re, le;
    wire cs, sclk, mosi, adc_reset, adc_start, led_ready, led_error;
    smart_zynq_ads1263_tec_pid #(
        .CLK_HZ(1000000),.BAUD(100000),.POR_CYCLES(8),
        .CONTROL_MS(10),.REPORT_MS(20),.MAX_DUTY_PERMILLE(200),
        .SLEW_PER_PWM(100),.SENSOR_TIMEOUT_MS(40),.HOST_TIMEOUT_MS(100),
        .RELAY_WINDOW_MS(1000),.RELAY_MIN_PULSE_MS(50)
    ) dut (
        .clk_50(clk),.rst_n(rst_n),.adc_miso(1'b0),.adc_drdy_n(1'b1),.pc_uart_rx(rx),
        .adc_cs_n(cs),.adc_sclk(sclk),.adc_mosi(mosi),.adc_reset_n(adc_reset),.adc_start(adc_start),
        .pc_uart_tx(tx),.r_pwm(rp),.l_pwm(lp),.r_en(re),.l_en(le),
        .led_ready(led_ready),.led_error(led_error),.heater_relay(relay)
    );
    // Inject reader results at the ADC-driver boundary. Real converter, UART,
    // command parser, PID, relay scheduler and bridge operate normally.
    reg feed_samples=1;
    initial begin
        force dut.adc_event=sample_pulse;
        force dut.adc_quality=1'b1;
        force dut.adc_ready=1'b1;
        force dut.adc_error_code=8'd0;
        force dut.voltage_uv=test_voltage;
        force dut.avdd_uv=32'd5000000;
        forever begin
            #5000000;
            if(feed_samples) begin sample_pulse=1; #1000; sample_pulse=0; end
        end
    end
    integer capture, reports=0, checks=0;
    wire byte_valid, rx_error;
    wire [7:0] byte_data;
    pc_temperature_uart_rx #(.CLK_HZ(1000000),.BAUD(100000)) monitor(
        .clk(clk),.reset_n(dut.reset_ok),.rx(tx),.data(byte_data),.valid(byte_valid),.framing_error(rx_error));
    initial capture=$fopen("uart_capture.txt","w");
    always @(posedge clk) if(byte_valid) begin
        $fwrite(capture,"%c",byte_data);
        if(byte_data==10) reports=reports+1;
    end
    reg saw_relay=0, saw_pwm=0;
    always @(posedge clk) begin
        if(relay) saw_relay<=1;
        if(lp) saw_pwm<=1;
        if(rp) $fatal(1,"Cooling direction energized a resistive heater");
        if(rx_error) $fatal(1,"UART telemetry framing error");
    end
    task check;
        input condition;
        input [511:0] message;
        begin
            if(!condition) $fatal(1,"FAIL %0s",message);
            checks=checks+1;
            $display("PASS %0s",message);
        end
    endtask
    task send_byte;
        input [7:0] value;
        integer bit_number;
        begin
            rx=0; #10000;
            for(bit_number=0;bit_number<8;bit_number=bit_number+1) begin
                rx=value[bit_number]; #10000;
            end
            rx=1; #10000;
        end
    endtask
    task run_command;
        begin send_byte("R");send_byte("U");send_byte("N");send_byte(10);end
    endtask
    task stop_command;
        begin send_byte("S");send_byte("T");send_byte("O");send_byte("P");send_byte(10);end
    endtask
    task ping_command;
        begin send_byte("P");send_byte("I");send_byte("N");send_byte("G");send_byte(10);end
    endtask
    task reset_board;
        begin rst_n=0; #10000; rst_n=1; #20000000;end
    endtask
    initial begin
        reset_board;
        check(dut.u_control.sensor_ready,"three ADC samples yield valid temperature");
        check(!relay && !re && !le,"power-on stays disarmed");
        send_byte("3");send_byte("0");send_byte(10);#200000;
        check(dut.target_mdeg==30000,"legacy numeric setpoint retained");
        send_byte("R");send_byte("U");send_byte("N");send_byte("x");send_byte(10);#200000;
        check(!dut.u_control.armed,"invalid RUN suffix rejected");
        run_command;#40000000;
        check(dut.control_enable,"RUN enables only with valid sensor");
        check(saw_relay && saw_pwm,"relay and ceramic PWM both heat");
        repeat(4) begin #30000000; ping_command; end
        check(dut.control_enable && !dut.fault_latched,"PING keeps heating alive past watchdog interval");
        stop_command;#2000;
        check(!relay && !re && !le,"STOP shuts down both loads");
        check(!dut.u_control.armed,"STOP clears arm state");
        run_command;#110000000;
        check(dut.fault_code==5 && !relay && !re,"heartbeat expiry latches and shuts down");
        #20000000;
        run_command;#1000000;
        check(!dut.control_enable,"RUN cannot bypass latched fault");
        reset_board; run_command;#15000000;
        feed_samples=0;#50000000;
        check(dut.fault_code==1 && !relay && !re,"sensor timeout shuts down both loads");
        #20000000;
        feed_samples=1;reset_board;run_command;#15000000;
        test_voltage=4000000;#10000000;
        check(dut.fault_code==2 && !relay && !re,"overtemperature shuts down both loads");
        #20000000;
        test_voltage=3600000;reset_board;
        force dut.u_control.pid_command=16'sd200;
        run_command;#10000000;
        check(!relay && !re && !le,"above-target positive PID command never cools or heats");
        release dut.u_control.pid_command;
        rst_n=0;#1000;
        check(!relay && !re && !le,"KEY reset removes output immediately");
        check(reports>5,"extended telemetry transmitted through UART pins");
        $display("ALL RELAY SYSTEM TESTS PASSED: %0d checks",checks);
        $fclose(capture);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"Simulation timeout");end
endmodule
