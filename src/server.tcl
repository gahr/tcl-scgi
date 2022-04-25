##
# The main SCGI server.

namespace eval server {

    eval $::dhelpers

    ##
    # Configuration options
    variable params

    ##
    # Thread pool -related variables. We don't use tpool because we don't have
    # a way to pass channels when posting a job into a tpool instance.
    variable nofThreads  0
    tsv::set tsv freeThreads [list]
    tsv::set tsv mutex [thread::mutex create]
    tsv::set tsv cond [thread::cond create]

    ##
    # Data of each connection is kept in this dictionary. Each key is
    # prepended with the name of the socket used to handle the
    # connection followed by a colon (i.e., sock1234:data)
    #
    # - status  0: connection established, reading the header length
    #           1: reading the header
    #           2: reading the body
    #           3: handling the request
    #
    # - data    data read up to now
    # - hbeg    beginning of the headers (after the len of the netstring)
    # - hlen    header length (length of the header netstring)
    # - head    headers in dictionary (k1 v1 k2 v2) form
    # - bbeg    beginning of the body
    # - blen    body length
    # - afterid id used for the connection timeout
    variable cdata {}

    # if needed, fork and print child pid
    proc fork {argv} {
        variable params
        if {$params(fork) && !$params(forked)} {
            lappend argv --forked
            set child [open "|[info nameofexecutable] [file normalize [info script]] $argv" r]
            puts [pid $child]
            exit 0
        }
    }

    ##
    # Get a free thread by creating up to max_threads. If none is available,
    # wait until one is fed back to the free threads list.
    proc get_thread {} {
        variable params 
        variable nofThreads

        # if there's a free thread available, pick it
        tsv::lock tsv {
            lassign [tsv::lindex tsv freeThreads end] tid ttime
            if {$tid ne {}} {
                tsv::lpop tsv freeThreads end
                return $tid
            }
        }

        # create a new thread
        if {$nofThreads < $params(max_threads)} {
            set tid [thread::create]
            thread::preserve $tid
            incr nofThreads
            return $tid
        }

        # if there's no free threads, wait
        thread::mutex lock [tsv::get tsv mutex]
        while {[tsv::llength tsv freeThreads] == 0} {
            thread::cond wait [tsv::get tsv cond] [tsv::get tsv mutex]
        }
        thread::mutex unlock [tsv::get tsv mutex]
        tsv::lock tsv {
            lassign [tsv::lindex tsv freeThreads end] tid ttime
            tsv::lpop tsv freeThreads end
        }

        return $tid
    }

    ##
    # Cleanup free threads that have been sleeping for long
    proc cleanup_threads {sock} {
        variable params
        variable nofThreads

        tsv::lock tsv {
            set min_threads $params(min_threads)
            set threads [tsv::get tsv freeThreads]
            log $sock "threads: $threads"
            if {[llength $threads] <= $min_threads} {
                log $sock "only [llength $threads] <= $min_threads"
                return
            }

            set now [clock seconds]

            set threads [lsort  -index 1 $threads]
            set newest  [lrange $threads $min_threads+1 end]
            set oldest  [lrange $threads 0 $min_threads]

            log $sock "cleaning up $oldest"
            set keep [lmap elem $oldest {
                lassign $elem tid ttime
                if {[expr {$now - $ttime > $params(thread_keepalive)}]} {
                    thread::release $tid
                    continue
                }
                set elem
            }]
            incr nofThreads [expr {[llength $keep] - [llength $oldest]}]
            log $sock "cleaned up $keep"
            tsv::set tsv freeThreads [concat $keep $newest]
        }
    }

    ##
    # Parse command line arguments.
    proc parse_args {} {
        variable params

        set options {
            {addr.arg 127.0.0.1       {Listen on the specified address}}
            {port.arg 4000            {Listen on the specified port}}
            {path.arg {DOCUMENT_ROOT} {Script path}}
            {fork                     {Fork and return the pid of the child process}}
            {forked.secret            {Set after a fork}}
            {max_threads.arg 50       {Maximum number of threads to spawn}}
            {min_threads.arg 1        {Minimum number of threads to spawn}}
            {thread_keepalive.arg 60  {Number of seconds an idle thread is kept alive}}
            {conn_keepalive.arg -1    {Number of seconds an idle connection is kept alive}}
            {verbose                  {Dump verbose information to stdout}}
        }
        
        set usage {: <$::argv>:scgi.tcl [option...]:}
        try {
            array set params [::cmdline::getoptions ::argv $options $usage]
        } trap {CMDLINE USAGE} {msg o} {
            puts $msg
            exit 0
        }

        if {$params(path) eq {DOCUMENT_ROOT}} {
            array set params {path {}}
        }
    }

    proc log {sock msg} {
        variable params

        if {$params(verbose)} {
            ::puts "[clock format [clock seconds]]: $sock - $msg"
        }
    }

    ##
    # Create server socket.
    proc serve {} {
        variable params
        socket -server [namespace code handle_connect] -myaddr $params(addr) $params(port)
    }

    ##
    # Cleanup a connection's data.
    proc cleanup {sock} {
        variable cdata

        log $sock cleanup

        after cancel [dget? $cdata $sock:afterid]
        catch {chan close $sock}
        set cdata [dict filter $cdata script {k v} {
            expr {[string match $sock:* $k] == 0}
        }]
    }

    ##
    # Reschedule the timeout for a connection.
    proc schedule_timeout {sock} {
        variable cdata
        variable params

        set t $params(conn_keepalive)

        if {$t == -1} {
            return
        }

        after cancel [dget? $cdata $sock:afterid]
        dset cdata $sock:afterid [after [expr {$t * 1000}] [namespace code [list hangup $sock]]]
    }

    ##
    # Hangup a stalling connection.
    proc hangup {sock} {
        variable cdata

        log $sock hangup
        
        # if we're handling the request, then all fine
        if {[dget $cdata $sock:status] > 2} {
            return
        }

        cleanup $sock
    }

    ##
    # Handle a new connection.
    proc handle_connect {sock addr port} {
        variable cdata

        log $sock handle_connect

        # Inizialize the connection data
        dset cdata $sock:status 0

        chan configure $sock -block 0 -trans {binary crlf}
        chan event $sock r [namespace code [list handle_read $sock]]

        # schedule the timeout
        schedule_timeout $sock
    }

    ##
    # Read data from a connection.
    proc handle_read {sock} {
        variable cdata

        # Read from the socket, cleanup on EOF.
        dapp cdata $sock:data [read $sock]
        if {[chan eof $sock]} {
            cleanup $sock
            return
        }

        # Reschedule the timeout.
        schedule_timeout $sock

        if {[dget $cdata $sock:status] == 0} {

            # Connection established, reading the header length.
            log $sock "handle_read 0"

            if {![regexp -indices {^([0-9]+)(:)} [dget $cdata $sock:data] match lenIdx colIdx]} {
                return
            }
            dincr cdata $sock:status

            dset cdata $sock:hbeg [expr {[lindex $colIdx 1] + 1}]
            dset cdata $sock:hlen [string range [dget $cdata $sock:data] 0 [lindex $lenIdx 1]]
            tailcall [dget [info frame 0] proc] $sock
        }

        if {[dget $cdata $sock:status] == 1} {

            # Reading headers.
            log $sock "handle_read 1"

            if {[string length [dget $cdata $sock:data]] < [dget $cdata $sock:hlen] + [dget $cdata $sock:hbeg]} {
                return
            }
            dincr cdata $sock:status

            # compute the beginning and end of the header data, then
            # build a dictionary of the headers
            set hbeg [dget $cdata $sock:hbeg]
            set hend [expr {$hbeg + [dget $cdata $sock:hlen]}]
            set head [lrange [split [string range [dget $cdata $sock:data] $hbeg $hend] \0] 0 end-1]
            set hlist {}
            foreach {k v} $head {
                lappend hlist [string toupper $k] $v
            }
            dset cdata $sock:head $hlist
            dset cdata $sock:bbeg [expr {$hend + 2}] ; # skip the comma
            tailcall [dget [info frame 0] proc] $sock
        }

        if {[dget $cdata $sock:status] == 2} {

            # Reading body.
            log $sock "handle_read 2"

            # Check CONTENT_LENGTH. According to the SCGI specification, this
            # header must always be present, even if it's 0.
            dset cdata $sock:blen [dget? $cdata $sock:head CONTENT_LENGTH]
            if {![string is entier [dget $cdata $sock:blen]]} {
                hangup $sock
            }

            # The request is ready to be handled if
            # - there is no body at all, or
            # - the expected data length equals the actual data length
            set noBody [expr {[dget $cdata $sock:blen] == 0}]
            set expLen [expr {[dget $cdata $sock:hlen] + [dget $cdata $sock:hbeg] + [dget $cdata $sock:blen] + 1}] ;# +1 for the comma
            set actLen [string length [dget $cdata $sock:data]]
            if {$noBody || $expLen == $actLen} {
                dincr cdata $sock:status
                handle_request $sock
            }
        }
    }

    ##
    # Handle a request on a different thread.
    proc handle_request {sock} {
        variable cdata
        variable params

        log $sock handle_request

        # We can't read from the socket once we begin serving the request, and
        # we don't need a timeout anymore.
        chan event $sock r {}
        after cancel [dget? $cdata $sock:afterid]

        # Get a free thread. This call might wait if max_threads was reached.
        set tid [get_thread]

        log $sock "got thread $tid"
        
        # Set up and invoke the worker thread by transferring the client socket
        # to the thread and setting up the necessary state data.
        thread::transfer $tid $sock

        thread::send $tid $::dhelpers
        thread::send $tid $::worker

        thread::send $tid [list set sock $sock]
        thread::send $tid [list set script_path $params(path)]
        thread::send $tid [list set head [dget $cdata $sock:head]]
        thread::send $tid [list set body [string range [dget $cdata $sock:data] [expr {[dget $cdata $sock:bbeg] - 1}] [expr {[dget $cdata $sock:bbeg] -1 + [dget $cdata $sock:blen]}]]]

        thread::send -async $tid {
            ::scgi::handle
            ::scgi::flush

            tsv::lappend tsv freeThreads [list [thread::id] [clock seconds]]
            thread::cond notify [tsv::get tsv cond]
        }

        # Cleanup this connection's state in the master thread. The worker
        # thread is going to handle it from now on.
        cleanup $sock

        # Kill old free threads
        cleanup_threads $sock

    }
}
