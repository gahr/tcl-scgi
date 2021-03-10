##
# Dict helpers

set dhelpers {

    proc ::tcl::dict::get? {args} {
        dict getdef {*}$args {}
    }
    namespace ensemble configure dict -map [dict merge [namespace ensemble configure dict -map] {get? ::tcl::dict::get?}]

    interp alias {} dset    {} dict set
    interp alias {} dget    {} dict get
    interp alias {} dget?   {} dict get?
    interp alias {} dapp    {} dict append
    interp alias {} dincr   {} dict incr
    interp alias {} dexists {} dict exists
}
eval $dhelpers
