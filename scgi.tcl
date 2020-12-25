#!/usr/local/bin/tclsh8.7

#
#  Copyright (C) 2013-2020 Pietro Cerutti <gahr@gahr.ch>
#  
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#  
#  THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
#  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
#  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
#  ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
#  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
#  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
#  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
#  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
#  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
#  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
#  SUCH DAMAGE.
#
# This is a Simple Common Gateway Interface (SCGI) handler implemented as a
# multi-threaded server using the Tcl programming language.  Each request is
# first parsed by the main thread then dispatched to be served by a dedicated
# thread.  The scgi.tcl software requires Tcl 8.6 and the Thread extension.
#
# The SCGI specification is here: http://www.python.ca/scgi/protocol.txt .
#
# See README.md for documentation.
#

set version [list 0 1 0]

package require Tcl 8.6
package require Thread 2.7

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


namespace eval ::scgi:: {

    ##
    # The following script is used by worker threads to handle client
    # connections. The worker thread is responsible for communicating with the
    # client over the client socket and for closing the connection once done.
    set worker_script {
        eval $dhelpers

        namespace eval ::scgi:: {

            variable has_ncgi [expr {[catch {package require ncgi}] == 0}]
            variable out_head {}
            variable out_body {}
            variable in_params {}
            variable flushed  0

            ##
            # Quit with an error
            proc die {{msg {}}} {
                ::scgi::header Status {500 Internal server error} false
                if {$msg ne {}} {
                    ::scgi::puts "<pre>$msg</pre>"
                } else {
                    ::scgi::puts "<pre>$::errorInfo</pre>"
                }
                flush
                tailcall uplevel return
            }

            ##
            # Locate the script to parse
            proc locate_script {} {
                set droot [dget? $::head DOCUMENT_ROOT]
                set duri  [regsub {^/} [dget? $::head DOCUMENT_URI] {}]
                set sname [regsub {^/} [dget? $::head SCRIPT_NAME] {}]
                set pinfo [regsub {^/} [dget? $::head PATH_INFO] {}]

                # If no script_path (-s) argument was provided, use DOCUMENT_ROOT
                # as a base. Then try to append, in order:
                # - DOCUMENT_URI
                # - SCRIPT_NAME
                # - PATH_INFO
                # - index.tcl
                set script [dget? $::conf script_path]
                if {$script eq {}} {
                    set script $droot
                }

                set sfound 0
                foreach trial [list $duri $sname $pinfo index.tcl] {
                    set script [file join $script $trial]
                    if {[file isfile $script] && [file exists $script] && [file readable $script]} {
                        set sfound 1
                        break
                    }
                }

                if {!$sfound} {
                    ::scgi::header Status {404 Not found}
                    die "Could not find $script on the server"
                }

                return $script
            }

            ##
            # Handle the request
            proc handle {} {
                variable in_params
                variable has_ncgi

                #
                # Build the params dictionary, composed of the query string and
                # the body.

                # Decode query string parameters
                set plist [dget? $::head QUERY_STRING]

                # Parse content type
                set content_type [dget? $::head HTTP_CONTENT_TYPE]
                switch -glob $content_type {
                    {application/x-www-form-urlencoded} {
                        # decode form-urlencoded parameters
                        if {$::body ne {}} {
                            lappend plist $::body
                        }
                    }
                    {multipart/form-data*} {
                        # decode multipart MIME data
                        if {$has_ncgi} {
                            set parts [::ncgi::multipart $content_type $::body]
                            foreach {name props} $parts {
                                dict set in_params $name $props
                            }
                        }
                    }
                }

                # Parse url-encoded parameters - can come from query string and
                # body.
                foreach {k v} [split $plist {& =}] {
                    dict set in_params [::scgi::decode $k] [::scgi::decode $v]
                }

                # locate the script to parse
                set script [locate_script]

                # create the interpreter that will be used to
                # eval the code inside the script
                set int [interp create]
                $int bgerror ::scgi::die

                # Go into the directory where the script is
                set dir [file normalize [file dirname $script]]
                if {[catch {$int eval cd $dir}]} {
                    die
                }

                # Close the standard I/O channels
                $int eval chan close stdin
                $int eval chan close stdout
                $int eval chan close stderr

                # Setup aliases in the ::scgi::namespace
                interp alias $int @                {} ::scgi::puts
                interp alias $int ::scgi::header   {} ::scgi::header
                interp alias $int ::scgi::flush    {} ::scgi::flush
                interp alias $int ::scgi::die      {} ::scgi::die
                interp alias $int ::scgi::exit     $int set ::scgi::terminate 1
                interp alias $int exit             $int set ::scgi::terminate 1

                # the following is an alias that's transparent to the user
                # and is employed to output XML tags, e.g.:
                # <?xml version="1.0" encoding="utf-8"?>
                interp alias $int xml              {} ::scgi::xml

                # Create variables that can be used within the client script
                $int eval [list set ::scgi::params  $in_params]
                $int eval [list set ::scgi::headers $::head]
                $int eval [list set ::scgi::body    $::body]
                $int eval [list set ::scgi::terminate 0]

                # Reset the ::errorInfo variable
                set ::errorInfo {}

                # State in the finite state machine:
                # 0 - HTML code
                # 1 - Tcl code
                set fsmState 0
                set tclCode {}
                set fd [open $script r]
                set data [read $fd]
                close $fd
                set lineNo 0

                foreach line [split $data "\n"] {
                    incr lineNo

                    set moreScripts 1
                    set scanIdx 0
                    while {$moreScripts && ![$int eval set ::scgi::terminate]} {

                        set begIdx [string first "<?" $line $scanIdx]
                        set endIdx [string first "?>" $line $scanIdx]

                        # The following cases are possible, with
                        # a != -1, b != -1, a < b
                        # | branch | $begIdx | $endIdx | meaning
                        # |   A    |   -1    |   -1    | fsmState == 0 ? pure HTML line : pure Tcl line
                        # |   B    |    a    |   -1    | start of a multi-line script. fsmState must be 0. Set fsmState to 1
                        # |   C    |   -1    |    b    | end of a multi-line script. fsmState must be 1. Set fsmState to 0
                        # |   D    |    a    |    b    | script fully enclosed. fsmState must be 0 and remains 0.
                        # |   E    |    b    |    a    | end of a multi-line script, beginning of another script. fsmState must be 1 and remains 1
                        #
                        if {$begIdx == -1 && $endIdx == -1} { ; # ...
                            # A
                            if {$fsmState == 0} {
                                ::scgi::puts [string range $line $scanIdx end]
                            } else {
                                append tclCode [string range $line $scanIdx end] "\n"
                                if {[info complete $tclCode]} {
                                    if {[catch {$int eval $tclCode}]} {
                                        die
                                    }
                                    set tclCode {}
                                }
                            }
                            set moreScripts 0

                        } elseif {$begIdx != -1 && $endIdx == -1} { ; # <? ...
                            # B
                            if {$fsmState != 0} {
                                die "$script:$lineNo -- invalid begin of nested <? ... ?> block"
                            }
                            append tclCode [string range $line $begIdx+2 end] "\n"
                            set fsmState 1
                            set moreScripts 0

                        } elseif {$begIdx == -1 && $endIdx != -1} { ; # ... ?>
                            # C
                            if {$fsmState != 1} {
                                die "$script:$lineNo -- invalid end of <? ... ?> block"
                            }
                            set fsmState 0
                            append tclCode [string range $line $scanIdx $endIdx-1]
                            if {[catch {$int eval $tclCode}]} {
                                die
                            }
                            set tclCode {}
                            ::scgi::puts [string range $line $endIdx+2 end]
                            set moreScripts 0

                        } elseif {$begIdx < $endIdx} { ; # <? ... ?>
                            # D
                            if {$fsmState != 0} {
                                die "$script:$lineNo -- invalid nested <? ... ?> block"
                            }
                            ::scgi::puts [string range $line $scanIdx $begIdx-1]
                            if {[catch {$int eval [string range $line $begIdx+2 $endIdx-1]}]} {
                                die
                            }
                            set scanIdx $endIdx+2
                            set moreScripts 1

                        } elseif {$begIdx > $endIdx} { ; # ... ?> ... <?
                            # E
                            if {$fsmState !=1 } {
                                die "$script:$lineNo -- invalid end of <? ... ?> block"
                            }
                            append tclCode [string range $line $scanIdx $endIdx-1]
                            if {[catch {$int eval $tclCode}]} {
                                die
                            }
                            set tclCode {}
                            ::scgi::puts [string range $line $endIdx+2 $begIdx-1]
                            set scanIdx $begIdx+2
                            set moreScripts 1
                        } else {
                                die "$script:$lineNo -- error parsing input"
                            }

                            if {!$moreScripts} {
                                break
                            }
                        }

                        if {$fsmState == 0} {
                            ::scgi::puts "\n"
                        }
                    }
            }

            ##
            # Decode a www-url-encoded string (from ncgi module).
            proc decode {str} {
                # rewrite "+" back to space
                # protect \ from quoting another '\'
                set str [string map [list + { } "\\" "\\\\" \[ \\\[ \] \\\]] $str]

                # prepare to process all %-escapes
                regsub -all -- {%([Ee][A-Fa-f0-9])%([89ABab][A-Fa-f0-9])%([89ABab][A-Fa-f0-9])} \
                    $str {[encoding convertfrom utf-8 [binary decode hex \1\2\3]]} str
                regsub -all -- {%([CDcd][A-Fa-f0-9])%([89ABab][A-Fa-f0-9])}                     \
                    $str {[encoding convertfrom utf-8 [binary decode hex \1\2]]} str
                regsub -all -- {%([0-7][A-Fa-f0-9])} $str {\\u00\1} str

                # process \u unicode mapped chars
                return [subst -novar $str]
            }

            ##
            # Add a header to the response (buffered).
            proc header {key value {replace 1}} {
                variable out_head
                variable flushed

                if {$flushed} {
                    return
                }

                set k [string totitle [string trim $key]]
                set v [string trim $value]

                if {[dexists $out_head $k] && [string is false $replace]} {
                    return
                }

                # Handle a couple of special headers
                switch $k {
                    Location {
                        header Status {302 Found}
                    }
                }
                dset out_head $k $v
            }

            ##
            # Append data to the response (buffered).
            proc puts {data} {
                variable out_body
                variable flushed
                if {!$flushed} {
                    append out_body $data
                }
            }

            ##
            # Create an XML tag.
            proc xml {args} {
                set xml "<?xml"
                foreach a $args {
                    append xml " $a"
                }
                append xml "?>"
                ::scgi::puts $xml
            }

            ##
            # Flush any output (headers and body) waiting on the output
            # buffer. If we get here, at least the Status header has been
            # set.
            proc flush {} {
                variable out_head
                variable out_body
                variable flushed

                if {$flushed} {
                    return
                }

                set utf8_body [encoding convertto utf-8 $out_body]

                # Set Status and Content-type, if not set yet
                header Status {200} false
                header Content-type {text/html;charset=utf-8} false
                #header Content-length [expr {[string length $utf8_body] + 2}]

                # Output the headers
                foreach {k v} $out_head {
                    append out "$k: $v\n"
                }

                # Output the body
                append out "\n$utf8_body"

                # Flush
                ::puts -nonewline $::sock $out

                set flushed 1

                catch {close $::sock}
            }

        }

        ::scgi::handle
        ::scgi::flush

        tsv::lappend tsv freeThreads [thread::id]
        thread::cond notify [tsv::get tsv cond]
    }

    ##
    # Configuration options
    variable conf {}

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
    proc fork {} {
        set fork [lsearch -exact $::argv -f]
        if {$fork != -1} {
            set args [lreplace $::argv $fork $fork]
            set child [open "|[info nameofexecutable] [file normalize [info script]] $args" r]
            puts [pid $child]
            exit 0
        }
    }

    ##
    # Get a free thread by creating up to max_threads. If none is available,
    # wait until one is fed back to the free threads list.
    proc get_thread {} {
        variable conf
        variable nofThreads

        # create a new thread
        if {$nofThreads < [dget $conf max_threads]} {
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
            set tid [tsv::lindex tsv freeThreads end]
            tsv::lpop tsv freeThreads end
        }

        return $tid
    }

    ##
    # Parse command line arguments.
    proc parse_args {} {
        variable conf

        # Initialize with default values
        set conf {
            max_threads  50
            script_path  {}
            timeout      -1
            addr         127.0.0.1
            port         4000
            verbose      false
        }

        for {set i 0} {$i < $::argc} {incr i} {
            switch [lindex $::argv $i] {
                -a {
                    dset conf addr [lindex $::argv [incr i]]
                }
                -m {
                    dset conf max_threads [lindex $::argv [incr i]]
                }
                -p {
                    dset conf port [lindex $::argv [incr i]]
                }
                -s {
                    dset conf script_path [lindex $::argv [incr i]]
                }
                -t {
                    set t [lindex $::argv [incr i]]
                    if {![string is entier $t]} {
                        error "timeout must be an integer: $t given."
                    }
                    dset conf timeout [expr {$t * 1000}]
                }
                -v {
                    dset conf verbose true
                }
                -version {
                    puts "This is tcl-scgi [join $::version .]"
                    exit 0
                }
                default {
                    error "Unhandled argument: [lindex $::argv $i]"
                }
            }
        }
    }

    proc log {sock msg} {
        variable conf

        if {![dget $conf verbose]} {
            return
        }

        ::puts "[clock format [clock seconds]]: $sock - $msg"
    }

    ##
    # Create server socket.
    proc serve {} {
        variable conf
        socket -server [namespace code handle_connect] -myaddr [dget $conf addr] [dget $conf port]
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
        variable conf

        set t [dget $conf timeout]

        if {$t == -1} {
            return
        }

        after cancel [dget? $cdata $sock:afterid]
        dset cdata $sock:afterid [after $t [namespace code [list hangup $sock]]]
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
        variable conf
        variable worker_script

        log $sock handle_request

        # We can't read from the socket once we begin serving the request, and
        # we don't need a timeout anymore.
        chan event $sock r {}
        after cancel [dget? $cdata $sock:afterid]

        # Get a free thread. This call might wait if max_threads was reached.
        set tid [get_thread]
        
        # Set up and invoke the worker thread by transferring the client socket
        # to the thread and setting up the necessary state data.
        thread::transfer $tid $sock
        thread::send $tid [list set dhelpers $::dhelpers]
        thread::send $tid [list set sock  $sock]
        thread::send $tid [list set conf  $conf]
        thread::send $tid [list set head  [dget $cdata $sock:head]]
        thread::send $tid [list set body  [string range [dget $cdata $sock:data] [expr {[dget $cdata $sock:bbeg] - 1}] [expr {[dget $cdata $sock:bbeg] -1 + [dget $cdata $sock:blen]}]]]
        thread::send -async $tid $worker_script

        # Cleanup this connection's state in the master thread. The worker
        # thread is going to handle it from now on.
        cleanup $sock
    }
}

::scgi::fork ;# doesn't return if forked
::scgi::parse_args
::scgi::serve
vwait _forever
