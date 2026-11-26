source [file join [file dirname [info script]] create_project.tcl]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
report_timing_summary -file [file join $root reports timing_summary.rpt]
report_drc -file [file join $root reports drc.rpt]
report_utilization -file [file join $root reports utilization.rpt]
foreach delay_type {max min} {
    if {[get_property SLACK [get_timing_paths -delay_type $delay_type -max_paths 1]] < 0} {
        error "Timing failed for $delay_type"
    }
}
file mkdir [file join $root output]
file copy -force [file join $root vivado_project relay_step_experiment.runs impl_1 smart_zynq_ads1263_tec_pid.bit] [file join $root output relay_step_experiment.bit]
puts "RELAY_BUILD_SUCCESS"
