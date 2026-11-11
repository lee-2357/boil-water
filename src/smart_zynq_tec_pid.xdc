## Smart ZYNQ SL V1.3B, XC7Z020CLG484-1.
## Source: official SmartZynq_SL_Schematic_V1d3B_20260415.pdf.
## J5 physical numbering changed after V1.1: array J5[0] is NOT physical pin 1.

create_clock -period 20.000 -name clk_50 [get_ports clk_50]
set_property PACKAGE_PIN M19 [get_ports clk_50]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50]

set_property PACKAGE_PIN K21 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

## Existing bridge PACKAGE_PIN assignments preserved exactly.
## V1.3B physical J5: RPWM=7, LPWM=8, R_EN=9, L_EN=10.
set_property PACKAGE_PIN H19 [get_ports r_pwm]
set_property PACKAGE_PIN H20 [get_ports l_pwm]
set_property PACKAGE_PIN E18 [get_ports r_en]
set_property PACKAGE_PIN F18 [get_ports l_en]
set_property IOSTANDARD LVCMOS33 [get_ports {r_pwm l_pwm r_en l_en}]
set_property DRIVE 8 [get_ports {r_pwm l_pwm r_en l_en}]
set_property SLEW SLOW [get_ports {r_pwm l_pwm r_en l_en}]

## New module UART: J5 physical 11 (F17) RX, physical 12 (G17) TX.
## Both are unused BANK35 3.3V GPIOs in the supplied bridge design.
## FPGA RX <- module TXD; FPGA TX -> module RXD. Common GND required.
set_property PACKAGE_PIN F17 [get_ports sensor_uart_rx]
set_property PACKAGE_PIN G17 [get_ports sensor_uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports {sensor_uart_rx sensor_uart_tx}]
set_property PULLUP TRUE [get_ports sensor_uart_rx]
set_property DRIVE 8 [get_ports sensor_uart_tx]
set_property SLEW SLOW [get_ports sensor_uart_tx]

## Board PL UART TX -> onboard CH340 UART_RX -> USB serial port on PC.
## L17 is NOT a new header wire. PC->FPGA RX (M17) is unnecessary here.
set_property PACKAGE_PIN L17 [get_ports pc_uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports pc_uart_tx]
set_property DRIVE 8 [get_ports pc_uart_tx]
set_property SLEW SLOW [get_ports pc_uart_tx]

## Asynchronous inputs only: remove timing to the FIRST synchronizer stage.
## ASYNC_REG keeps the second stage close; do not blanket-false-path the datapath.
set_false_path -from [get_ports rst_n] -to [get_cells -hier -filter {NAME =~ *reset_sync_reg*}]
set_false_path -from [get_ports sensor_uart_rx] -to [get_pins -hier -regexp {.*u_sensor_rx/rx_sync_reg\[0\]/D}]
