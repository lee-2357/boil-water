# ADS1263 5 SPS + PT1000 AO + PID/H 桥水温控制

本目录保存 2026-11-19 在本地工程完成仿真及 Vivado 2025.2 编译的整合版本源码。6 个 Verilog 文件及 1 个 XDC 与通过验证的构建源文件逐字节相同，校验值见 source_sha256.json。

## 加入 Vivado

器件选择 XC7Z020CLG484-1，开发板 Smart ZYNQ SL V1.3B，PL 时钟 50 MHz。

将本目录全部 6 个 .v 加入 Design Sources，将 smart_zynq_ads1263_tec_pid.xdc 加入 Constraints，顶层设为 smart_zynq_ads1263_tec_pid。其他目录中的旧顶层、旧 XDC、UART 温度解析模块不需要加入本设计。

| 文件 | 作用 |
| --- | --- |
| smart_zynq_ads1263_tec_pid.v | 整合顶层、复位及各模块连接 |
| ads126x_voltage_reader.v | 原来调通的 ADC1 5 SPS 驱动、电压换算 |
| ads1263_spi.v | SPI 模式 1，50 kHz |
| pt1000_ao_temperature.v | AO 电压 → 电阻 → 温度 |
| tec_temperature_control.v | 样本确认、故障保护、PID 调度 |
| tec_pid_core.v | PID、H 桥 PWM、串口报告及 UART TX |

## 传感器接法与公式

LZ_TD210 使用 PT1000。AO 接 ADS1263 模块 A0（P1.2），各模块 GND 共地。ADS1263 ACM 外部悬空，由原驱动内部 VBIAS 驱动至 AVDD/2。温度模块保留原供电及探头接法，TXD/RXD 不再作为温度反馈。

按 LZ_TD200(210) 用户手册 3.2 节（印刷第 5 页）计算，AO 单位 V、R 单位 Ω、T 单位 ℃：

```text
R = (AO - 2.5) / (4.2933 × 0.000250)
803.063 < R ≤ 1385.055: T = 9.962e-6 × R² + 0.2359 × R - 245.9
1385.055 < R < 2120.515: T = 1.161e-5 × R² + 0.2312 × R - 242.5
```

计算结果四舍五入至 0.1℃。标称基准、增益、激励电流可能有误差，实际测温需校准；模块 UART 的补偿设置不能当作 FPGA AO 换算已校准。新顶层 AO_BASELINE_UV、AO_R_SCALE_NUM、AO_R_SCALE_DEN 可用于换算校准。

## 接线表

| 信号 | ZYNQ J5 实体针脚 / 板载位置 | FPGA 球脚 | ADS1263 模块 P2 |
| --- | --- | --- | --- |
| ADC SCLK | J5.38 | F16 | 8 |
| ADC DIN/MOSI | J5.37 | E16 | 7 |
| ADC DOUT/MISO | J5.36 | C19 | 9 |
| ADC CSN | J5.35 | D18 | 6 |
| ADC DRDYN | J5.34 | E15 | 10 |
| ADC RESETN | J5.33 | D15 | 12 |
| ADC START | J5.32 | D16 | 5 |
| GND | J5.5/6 | GND | 1/2/11 |
| RPWM 制冷 | J5.7 | H19 | — |
| LPWM 加热 | J5.8 | H20 | — |
| R_EN | J5.9 | E18 | — |
| L_EN | J5.10 | F18 | — |
| PC 串口 TX | 板载 CH340 | L17 | — |
| 故障复位 | KEY1 | K21 | — |
| 运行/故障指示 | 板载 LED | P20/P21 | — |
| 时钟 | 板载 50 MHz | M19 | — |

START 必须接线。连续采集阶段 START、RESETN 为高，DRDY 约每 200 ms 就绪。

## 控制及输出

- 默认目标 40.0℃，应用窗口 -20.0～80.0℃，保留原 PID 参数 Kp/Ki/Kd（Q8）=2560/13/512。
- ADC 5 SPS；PID 每 500 ms 更新；串口每 500 ms 输出，115200 / 8N1。
- PWM 1 kHz，双向最大 80%，每周期变化最多 0.2%，换向关闭至少 20 ms。
- 连续 3 个有效温度样本后才允许驱动。ADC/AO 故障、温度超窗、数据超时关闭 H 桥并锁存，排除故障后按 KEY1 复位。
- PID 运算增加流水阶段以满足 50 MHz 时序；PWM 阈值作等价化简。已对照原实现检查结果，控制参数及方向保持一致。

```text
T=+0021.7C,SP=+0040.0C,U=-080.0%,S=R,F=0
```

T=温度，SP=目标，U=实际占空比（正制冷、负加热）。S=W 等待、R 运行、F 故障。F=0 正常、1 数据超时、2 温度超窗、3 ADC 故障、4 AO/电阻无效。故障时温度可能保留旧值。

## 验证状态

已通过 1520 个换算向量、控制保护及整链路 SPI/DRDY 仿真；与旧实现比较 1000 次 PID 更新输出和积分状态，并对照 PWM/换向波形。Vivado 2025.2 综合、布局布线、bitstream 生成成功，WNS=+2.613 ns、WHS=+0.137 ns，DRC 无错误；仍有 DSP 流水化及未实例化 PS7 的警告。

尚未对这个整合版本进行实际上板水温闭环测试。上述仿真和编译通过不等同于实际探头精度或闭环性能验证。

本地已生成的 bitstream：
`F:\workplaces\vivado_fpga\boil-water-ads1263-test2\build\smart_zynq_ads1263_tec_pid.bit`

BIT SHA256：`cc0a8d7fc6f1da85bb65b18925f14a195756e992f294923569691dd9c716ba0f`。

本目录遵循仓库现有规则，只同步源码、约束和验证说明；bitstream 留在本地工程 build 下。verified_build_result.txt 保留原本地构建的文件路径和完成状态，用于追溯。
