##
# The main SCGI server.

namespace eval server {

    eval $::dhelpers

    ##
    # Configuration options
    variable params

    ##
    # Thread pool
    variable tp

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
    # Parse command line arguments.
    proc parse_args {} {
        variable params
        variable tp

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

        set tp [tpool::create \
            -minworkers $params(min_threads) \
            -maxworkers $params(max_threads) \
            -idletime $params(thread_keepalive)]
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

    proc make_worker_script {sock} {
        variable params
        variable cdata

        set head [dget $cdata $sock:head]
        set body_fst [expr {[dget $cdata $sock:bbeg] - 1}]
        set body_lst [expr {$body_fst + [dget $cdata $sock:blen]}]
        set body [string range [dget $cdata $sock:data] $body_fst $body_lst]
        list apply {{dhelpers worker path sock head body} {
            eval $dhelpers
            eval $worker
            set ::script_path $path
            thread::attach $sock
            ::scgi::handle $sock $head $body
        }} $::dhelpers $::worker $params(path) $sock $head $body
    }

    ##
    # Handle a request on a different thread.
    proc handle_request {sock} {
        variable tp
        variable cdata
        variable params

        log $sock handle_request

        # We can't read from the socket once we begin serving the request, and
        # we don't need a timeout anymore.
        chan event $sock r {}
        after cancel [dget? $cdata $sock:afterid]

        # Detach the client socket from this thread, the worker script will
        # attach it to the worker thread.
        thread::detach $sock
        tpool::post -detached $tp [make_worker_script $sock]

        # Cleanup the connection state in the server. It is now handled by the
        # worker thread
        cleanup $sock

    }
}
