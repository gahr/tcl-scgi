#!/usr/bin/env tclsh

#
#  Copyright (C) 2013, 2014 Pietro Cerutti <gahr@gahr.ch>
#  
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
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
# multi-threaded server using the Tcl programming language.
# Each request is first parsed by the main thread then dispatched to be
# served by a dedicated thread.
#
# The handler can be invoked with the following arguments:
#
# -m max_threads
#
#    Maximum number of threads that can be handling requests
#    at any given time.
#
# -p port
#
#    Listen on the specified port number.
#
# -s script_path
#
#    Use this path as a search base for scripts. If it's not set,
#    the DOCUMENT_ROOT set by the HTTP server is used instead.
#
# -t timeout
#
#    Kill an idle connection after timeout seconds. Idle connections are
#    those on which we are still waiting for data. Once the end script is
#    called, a connection is no more killable.
#
# -v
#
#    Dump verbose information.
#
#
# The scgi.tcl software requires Tcl 8.6 and the Thread extension.
#
#
# User scripts can use the following procs:
# 
# ::scgi::header key value ?replace?
#
#      Append the header "Key: value" to the output buffer. If replace is true
#      (the default), a previous header with the same key is replaced by the
#      one specified.
#
# ::scgi::puts data
#
#      Append the data to the output buffer. No new-line is automatically
#      appended to the data.
#      
# ::scgi::flush
#
#      Send the output buffered (including headers and body data) to the client. Once
#      called, no further output is possible.
#
# ::scgi::params
#
#      Return a dictionary with the request parameters.
#
# ::scgi::param name
#
#      Return the value of a specified request parameter. If the parameter does not
#      exist, return the empty string.
# 
# ::scgi::req_head
#
#      Return a dictionary with the request headers.
#
# ::scgi::req_body
#
#      Return the (URL-encoded) request body.
#
# ::scgi::exit
#
#      Send the output buffered (including headers and body data) to the client
#      and terminate the execution of the current script. [exit] is aliased
#      to ::scgi::exit and can be used too.
#

package require Tcl 8.6
package require Thread 2.7

##
# Dict helpers
set dhelpers {

    # http://wiki.tcl.tk/22807
    proc ::tcl::dict::get? {args} {
        try {
            ::set x [dict get {*}$args]
        } on error message {
            ::set x {}
        }
        return $x
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
    # Configuration options
    variable conf {}

    ##
    # Data of each connection is kept in this dictionary. Each key is
    # prepended with the name of the socket used to handle the
    # connection followed by a colon (i.e., sock1234:data)
    #
    # - status  0: connection established, reading the header length
    #           1: reading the header
    #           2: reading the body
    #           3: dispatched
    #
    # - data    data read up to now
    # - hbeg    beginning of the headers (after the len of the netstring)
    # - hlen    header length (length of the header netstring)
    # - head    headers in dictionary (k1 v1 k2 v2) form
    # - bbeg    beginning of the body
    # - blen    body length
    # - afterid id used for the connection timeout
    variable cdata {}

    ##
    # Parse command line arguments
    #
    proc parse_args {} {
        variable conf
        upvar #0 argc argc argv argv

        # Initialize with default values
        set conf {
            max_threads  50
            script_path  {}
            timeout      -1
            port         4000
            verbose      false
        }

        for {set i 0} {$i < $argc} {incr i} {
            switch [lindex $argv $i] {
                -m {
                    dset conf max_threads [lindex $argv [incr i]]
                }
                -p {
                    dset conf port [lindex $argv [incr i]]
                }
                -s {
                    dset conf script_path [lindex $argv [incr i]]
                }
                -t {
                    set t [lindex $argv [incr i]]
                    if {![string is entier $t]} {
                        error "timeout must be an integer: $t given."
                    }
                    dset conf timeout [expr {$t * 1000}]
                }
                -v {
                    dset conf verbose true
                }
                default {
                    error "Unhandled argument: [lindex $argv $i]"
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
    # Server socket.
    proc serve {} {
        variable conf
        socket -server [namespace code handle_connect] [dget $conf port]
    }

    ##
    # Cleanup a connection's data
    #
    proc cleanup {sock} {
        variable cdata

        log $sock cleanup

        catch {chan close $sock}
        set cdata [dict filter $cdata script {k v} {
            if {[string match $sock:* $k]} {
                return 0
            } else {
                return 1
            }
        }]
    }

    ##
    # Reschedule the timeout for a connection
    #
    proc schedule_timeout {sock} {
        variable cdata
        variable conf

        set t [dget $conf timeout]

        if {$t == -1} {
            return
        }

        after cancel [dget? $cdata $sock,afterid]
        dset cdata $sock,afterid [after $t [namespace code [list hangup $sock]]]
    }

    ##
    # Hangup a stalling connection
    #
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
    #
    # Each connection is assigned a unique identifier.
    #
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
    #
    proc handle_read {sock} {
        variable cdata

        # Read from the socket, cleanup on EOF.
        dapp cdata $sock:data [read $sock]
        if {[chan eof $sock]} {
            cleanup $sock
        }

        # reschedule the timeout
        schedule_timeout $sock

        if {[dget $cdata $sock:status] == 0} {
            log $sock "handle_read 0"
            # connection established, reading the header length
            if {![regexp -indices {^([0-9]+)(:)} [dget $cdata $sock:data] match lenIdx colIdx]} {
                return
            }
            dincr cdata $sock:status

            dset  cdata $sock:hbeg [expr {[lindex $colIdx 1] + 1}]
            dset  cdata $sock:hlen [string range [dget $cdata $sock:data] 0 [lindex $lenIdx 1]]
            tailcall [dget [info frame 0] proc] $sock
        }

        if {[dget $cdata $sock:status] == 1} {
            log $sock "handle_read 1"
            # reading headers
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
            dset cdata $sock:head  $hlist
            dset cdata $sock:bbeg  [expr {$hend + 2}] ; # skip the comma
            tailcall [dget [info frame 0] proc] $sock
        }

        if {[dget $cdata $sock:status] == 2} {
            log $sock "handle_read 2"
            dincr cdata $sock:status

            # headers have been read, check Content-length
            if {![string is entier [dset cdata $sock:blen [dget? $cdata $sock:head CONTENT_LENGTH]]]} {
                dset cdata $sock:blen 0
            }

            # if there's no body, just go on and handle the request (mostly, a shortcut for GETs)
            if {[dget $cdata $sock:blen] != 0 && [string length [dget $cdata $sock:data]] < [dget $cdata $sock:bbeg] + [dget $cdata $sock:blen]} {
                return
            }

            after cancel [dget? $cdata $sock,afterid]
            handle_request $sock
        }
    }

    ##
    # Handle a request on a different thread.
    #
    proc handle_request {sock} {
        variable cdata
        variable conf

        log $sock handle_request

        # we can't read from the socket once we begin serving the request
        chan event $sock r {}

        set tid [::thread::create]
        ::thread::transfer $tid $sock
        ::thread::send $tid [list set dhelpers $::dhelpers]
        ::thread::send $tid [list set sock  $sock]
        ::thread::send $tid [list set conf  $conf]
        ::thread::send $tid [list set head  [dget $cdata $sock:head]]
        ::thread::send $tid [list set body  [string range [dget $cdata $sock:data] [dget $cdata $sock:bbeg] [dget $cdata $sock:blen]]]

        ::thread::send -async $tid {

            eval $dhelpers

            namespace eval ::scgi_handler:: {

                variable in_head    {}
                variable in_body    {}
                variable in_params  {}
                variable out_head   {}
                variable out_body   {}
                variable flushed    0

                ##
                # Handle the request
                #
                proc handle {} {
                    variable in_head
                    variable in_body
                    variable in_params

                    upvar sock sock conf conf

                    set in_head $::head
                    set in_body $::body

                    # decode the parameters (might be in both query string and body)
                    set plist {}
                    lappend plist [dget? $in_head QUERY_STRING]
                    if {[dexists $in_head HTTP_CONTENT_TYPE] && [dget $in_head HTTP_CONTENT_TYPE] eq {application/x-www-form-urlencoded}} {
                        lappend plist $in_body
                    }
                    foreach {k v} [split $plist {& =}] {
                        lappend in_params [::scgi_handler::decode $k] [::scgi_handler::decode $v]
                    }

                    # locate the Tcl script to execute
                    set droot [dget? $in_head DOCUMENT_ROOT]
                    set sname [regsub {^/} [dget? $in_head SCRIPT_NAME] {}]
                    set pinfo [regsub {^/} [dget? $in_head PATH_INFO] {}]

                    if {$sname eq {}} {
                        set sname index.tcl
                    }

                    # If no script_path (-s) argument was provided, use DOCUMENT_ROOT
                    # as a base. Then append SCRIPT_NAME. If the resulting path is
                    # a readable file, use that. Else, try to append PATH_INFO.
                    set script [dget? $::conf script_path]
                    if {$script eq {}} {
                        set script $droot
                    }
                    set script [file join $script $sname]

                    if {![file isfile $script] || ![file exists $script] || ![file readable $script]} {
                        set script [file join $script $pinfo]
                        if {![file isfile $script] || ![file exists $script] || ![file readable $script]} {
                            ::scgi_handler::header Status {404 Not found}
                            ::scgi_handler::puts "Could not find $script on the server"
                            ::scgi_handler::finalize
                        }
                    }

                    set int [interp create]

                    # Setup aliases in the ::scgi::namespace
                    interp alias $int ::scgi::header   {} ::scgi_handler::header
                    interp alias $int ::scgi::puts     {} ::scgi_handler::puts
                    interp alias $int ::scgi::flush    {} ::scgi_handler::flush
                    interp alias $int ::scgi::req_head {} ::scgi_handler::req_head
                    interp alias $int ::scgi::req_body {} ::scgi_handler::req_body
                    interp alias $int ::scgi::param    {} ::scgi_handler::param
                    interp alias $int ::scgi::params   {} ::scgi_handler::params
                    interp alias $int ::scgi::exit     {} ::scgi_handler::finalize
                    interp alias $int exit             {} ::scgi_handler::finalize

                    # Close the standard I/O channels
                    interp eval $int chan close stdin
                    interp eval $int chan close stdout
                    interp eval $int chan close stderr

                    # Source the script in the slave interpreter
                    if {[catch {interp eval $int source $script} err]} {
                        ::scgi_handler::header Status {500 Internal server error}
                        ::scgi_handler::puts $::errorInfo
                    } else {
                        ::scgi_handler::header Status {200 OK}
                    }

                    finalize
                }

                ##
                # Decode a www-url-encoded string (from ncgi module)
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
                # Retrieve a dictionary (k1 v1 k2 v2 ...) with the request headers
                proc req_head {} {
                    variable in_head
                    return $in_head
                }

                ##
                # Retrieve the request body
                proc req_body {} {
                    variable in_body
                    return $in_body
                }

                ##
                # Retrieve a parameter from the query string / body
                proc param {name} {
                    variable in_params
                    return [dget? $in_params $name]
                }

                ##
                # Retrieve an array with all the parameters from the query string / body
                proc params {} {
                    variable in_params
                    return $in_params
                }

                ##
                # Add a header to the response (buffered)
                proc header {key value {replace 1}} {
                    variable out_head
                    variable flushed

                    if {$flushed} {
                        error "Data have already been flushed"
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
                # Append data to the response (buffered)
                proc puts {data} {
                    variable out_body
                    variable flushed
                    if {$flushed} {
                        error "Data have already been flushed"
                    }
                    append out_body $data
                }

                ##
                # Flush any output (headers and body) waiting
                # on the output buffer
                proc flush {} {
                    variable out_head
                    variable out_body
                    variable flushed

                    if {$flushed} {
                        return
                    }

                    if {$out_head eq {} && $out_body eq {}} {
                        return
                    }

                    set out {}

                    # Set the content-type, if not set yet
                    header Content-type {text/html} false

                    # Output the headers
                    foreach {k v} $out_head {
                        append out "$k: $v\n"
                    }

                    # Output the body
                    if {$out_body ne {}} {
                        append out "\n$out_body"
                    }

                    # Flush
                    ::puts -nonewline $::sock $out

                    set flushed 1
                }

                ##
                # Flush any output (headers and body) waiting
                # on the output buffer and terminate
                proc finalize {} {
                    flush
                    close $::sock
                    ::thread::exit
                }
            }
            
            ::scgi_handler::handle
        }
    }
}


::scgi::parse_args
::scgi::serve
vwait _forevert

##
# TODO
# 
# - Use a thread pool and the -m argument