##
# Dict helpers

set dhelpers {

    proc ::tcl::dict::get? {args} {
        if {[::info tclversion] >= "9.0"} {
            dict getdef {*}$args {}
        } else {
            ::set d [lindex $args 0]
            ::set args [lrange $args 1 end]
            if {[dict exists $d $args]} {
                dict get $d $args
            } else {
                return {}
            }
        }
    }
    namespace ensemble configure dict -map [dict merge [namespace ensemble configure dict -map] {get? ::tcl::dict::get?}]

    interp alias {} dset    {} dict set
    interp alias {} dget    {} dict get
    interp alias {} dget?   {} dict get?
    interp alias {} dapp    {} dict append
    interp alias {} dincr   {} dict incr
    interp alias {} dexists {} dict exists
}
