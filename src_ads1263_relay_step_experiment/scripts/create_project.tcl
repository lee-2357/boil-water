set root [file normalize [file join [file dirname [info script]] ..]]
create_project relay_step_experiment [file join $root vivado_project] -part xc7z020clg484-1 -force
add_files [glob [file join $root rtl *.v]]
add_files -fileset constrs_1 [glob [file join $root constraints *.xdc]]
set_property top smart_zynq_ads1263_tec_pid [current_fileset]
add_files -fileset sim_1 [glob [file join $root sim *.v]]
set_property top tb_relay_system [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
