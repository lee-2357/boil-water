# Smart ZYNQ SL V1.3B, XC7Z020 CLG484. Original H-bridge pinout retained.
set_property PACKAGE_PIN M19 [get_ports clk_50]
create_clock -name sys_clk -period 20.000 [get_ports clk_50]
# KEY1 acknowledges latched faults; this follows the original PID controller.
set_property PACKAGE_PIN K21 [get_ports rst_n]
set_property PULLUP TRUE [get_ports rst_n]
set_property PACKAGE_PIN L17 [get_ports pc_uart_tx]
set_property PACKAGE_PIN M17 [get_ports pc_uart_rx] ;# CH340 TX -> PL RX, onboard USB
set_property PULLUP TRUE [get_ports pc_uart_rx]
set_property PACKAGE_PIN P20 [get_ports led_ready]
set_property PACKAGE_PIN P21 [get_ports led_error]

set_property PACKAGE_PIN H19 [get_ports r_pwm] ;# J5.7, cooling RPWM
set_property PACKAGE_PIN H20 [get_ports l_pwm] ;# J5.8, heating LPWM
set_property PACKAGE_PIN E18 [get_ports r_en]  ;# J5.9, R_EN
set_property PACKAGE_PIN F18 [get_ports l_en]  ;# J5.10, L_EN
# Former sensor UART pins F17/G17 are intentionally absent from this top.

set_property PACKAGE_PIN F16 [get_ports adc_sclk]    ;# J5.38 -> ADC P2.8
set_property PACKAGE_PIN E16 [get_ports adc_mosi]    ;# J5.37 -> ADC P2.7
set_property PACKAGE_PIN C19 [get_ports adc_miso]    ;# J5.36 -> ADC P2.9
set_property PACKAGE_PIN D18 [get_ports adc_cs_n]    ;# J5.35 -> ADC P2.6
set_property PACKAGE_PIN E15 [get_ports adc_drdy_n]  ;# J5.34 -> ADC P2.10
set_property PACKAGE_PIN D15 [get_ports adc_reset_n] ;# J5.33 -> ADC P2.12
set_property PACKAGE_PIN D16 [get_ports adc_start]   ;# J5.32 -> ADC P2.5
set_property IOSTANDARD LVCMOS33 [get_ports *]
set_property DRIVE 8 [get_ports {adc_cs_n adc_sclk adc_mosi adc_reset_n adc_start pc_uart_tx led_* r_pwm l_pwm r_en l_en}]
set_property SLEW SLOW [get_ports {adc_cs_n adc_sclk adc_mosi adc_reset_n adc_start pc_uart_tx led_* r_pwm l_pwm r_en l_en}]
set_property PULLUP TRUE [get_ports {adc_miso adc_drdy_n}]

# Async inputs are cut only to their first synchronizer stage.
set_false_path -from [get_ports adc_miso] -to [get_pins -of_objects [get_cells -hier -regexp {.*miso_sync_reg\[0\]}] -filter {REF_PIN_NAME == D}]
set_false_path -from [get_ports adc_drdy_n] -to [get_pins -of_objects [get_cells -hier -regexp {.*drdy_sync_reg\[0\]}] -filter {REF_PIN_NAME == D}]
# KEY1 is an asynchronous safety inhibit. Deassertion is synchronized before
# control starts; its external arrival has no synchronous setup/hold relation.
set_false_path -from [get_ports rst_n]
# Slow GPIO peripherals. Keep register-to-output paths within one PL cycle.
set_max_delay -datapath_only 20.000 -from [all_registers] -to [get_ports {adc_cs_n adc_sclk adc_mosi adc_reset_n adc_start pc_uart_tx led_* r_pwm l_pwm r_en l_en}]

set_false_path -from [get_ports pc_uart_rx] -to [get_pins -of_objects [get_cells -hier -regexp {.*u_command/u_rx/rx_sync_reg\[0\]}] -filter {REF_PIN_NAME == D}]

# Independent active-high mechanical relay IN, board BANK35 silk B16.
set_property PACKAGE_PIN B16 [get_ports heater_relay]
set_property IOSTANDARD LVCMOS33 [get_ports heater_relay]
set_property DRIVE 4 [get_ports heater_relay]
set_property SLEW SLOW [get_ports heater_relay]
set_property PULLDOWN TRUE [get_ports heater_relay]
set_max_delay -datapath_only 20.000 -from [all_registers] -to [get_ports heater_relay]
