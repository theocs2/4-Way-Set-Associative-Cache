source wrappers.tcl

check_env_vars {
    DC_CORES
    DESIGN_TOP
    STD_CELL_ALIB
    STD_CELL_LIB
    SRAM_LIB
    RTL_SOURCES
    CLOCK_PERIOD_PS
    DC_COMPILE_CMD
    DC_COMPILE_ITER
    DC_COMPILE_CMD_INC
    DC_MIN_POWER
}

# Set up suppression
try_wrapper {
    source "dc_warn.tcl"
}

# Set up synthesis options
try_wrapper {
    get_license DC-Ultra-Features
    get_license DC-Ultra-Opt
    if {$env(DC_MIN_POWER) eq "1"} { set power_enable_minpower true }
    set hdlin_ff_always_sync_set_reset true
    set hdlin_ff_always_async_set_reset true
    set hdlin_infer_multibit default_all
    set hdlin_check_no_latch true
    set hdlin_while_loop_iterations 2000000000
    set_host_options -max_cores $env(DC_CORES)
    set_app_var report_default_significant_digits 6
    set design_toplevel $env(DESIGN_TOP)
}

# Set up libraries
try_wrapper {
    define_design_lib WORK -path ./work
    set alib_library_analysis_path $env(STD_CELL_ALIB)
    set symbol_library [list generic.sdb]
    set synthetic_library [list dw_foundation.sldb]
    set target_library $env(STD_CELL_LIB)
    set link_library [concat [list "*" $target_library $synthetic_library] $env(SRAM_LIB)]
}

# Synthesis setup
try_wrapper {
    analyze -library WORK -format sverilog [split $::env(RTL_SOURCES) " "]
    elaborate $design_toplevel
    current_design $design_toplevel
    change_names -rules verilog -hierarchy
    check_design
    set_wire_load_model -name "5K_hvratio_1_1"
    set_wire_load_mode enclosed
    source "constraints.sdc"
    link
}

# Synthesis
try_wrapper {
    eval $env(DC_COMPILE_CMD)
    for {set i 0} {$i < $env(DC_COMPILE_ITER)} {incr i} {
        eval $env(DC_COMPILE_CMD_INC)
    }
}

# Report and write results
try_wrapper {
    current_design $design_toplevel
    report_area -hier > area.rpt
    report_timing -delay max > timing.rpt
    check_design

    write_file -format ddc -hierarchy -output synth.ddc
    write_file -format verilog -hierarchy -output [format "%s.gate.v" $design_toplevel]
}
exit 0