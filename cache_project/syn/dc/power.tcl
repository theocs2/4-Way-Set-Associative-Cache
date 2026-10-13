source wrappers.tcl

check_env_vars {
    STD_CELL_LIB
    SRAM_LIB
    PWR_SAIF_FILE
    PWR_SAIF_TOP
}

try_wrapper {
    get_license DC-Ultra-Features
    get_license DC-Ultra-Opt
    set symbol_library [list generic.sdb]
    set synthetic_library [list dw_foundation.sldb]
    set target_library $env(STD_CELL_LIB)
    set link_library [concat [list "*" $target_library $synthetic_library] $env(SRAM_LIB)]
}

try_wrapper {
    read_file -format ddc synth.ddc
    read_saif -input $env(PWR_SAIF_FILE) -instance $env(PWR_SAIF_TOP)
    report_power -analysis_effort high -hierarchy -levels 3 > power.rpt
    report_power -analysis_effort high > power2.rpt
    exit
}
