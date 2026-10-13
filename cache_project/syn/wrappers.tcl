proc check_env_vars {var_list} {
    foreach var $var_list {
        if {![info exists ::env($var)]} {
            puts "ERROR: Environment variable '$var' is not set"
            exit 1
        }
    }
}

proc try_wrapper {body} {
    set script ""

    foreach line [split $body \n] {
        if {$script eq ""} {
            set script $line
        } else {
            append script "\n$line"
        }

        if {[info complete $script]} {
            set code [catch {uplevel 1 $script} result]

            if {$code == 0} {
                puts "$script : $result"
            } else {
                puts stderr "$script : ERROR -> $result"
                exit 1
            }

            set script ""
        }
    }
}
