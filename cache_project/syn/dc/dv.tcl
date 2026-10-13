source wrappers.tcl

check_env_vars {
    STD_CELL_LIB
}

# Set up libraries
try_wrapper {
    set symbol_library [list generic.sdb]
    set synthetic_library [list dw_foundation.sldb]
    set target_library $env(STD_CELL_LIB)
    set link_library [list "*" $target_library $synthetic_library]
}


get_license DC-Ultra-Features
get_license DC-Ultra-Opt

read_file -format ddc synth.ddc
