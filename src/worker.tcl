##
# The following script is used by worker threads to handle client
# connections. The worker thread is responsible for communicating with the
# client over the client socket and for closing the connection once done.

set worker {
    namespace eval html {

        proc Tag {name attrs children} {
            append out "<$name"
            foreach {k v} $attrs {
                append out " $k='$v'"
            }
            if {[llength $children]} {
                append out ">"
                foreach c $children {
                    append out $c
                }
                append out "</$name>"
            } else {
                append out "/>"
            }
            set out
        }

        foreach t {!DOCTYPE a abbr acronym address applet area article
                    aside audio b base basefont bdi bdo big blockquote body
                    br button canvas caption center cite code col colgroup
                    data datalist dd del details dfn dialog dir div dl dt
                    em embed fieldset figcaption figure font footer form
                    frame frameset h1 head header hr html i iframe img
                    input ins kbd label legend li link main map mark meta
                    meter nav noframes noscript object ol optgroup option
                    output p param picture pre progress q rp rt ruby s samp
                    script section select small source span strike strong
                    style sub summary sup svg table tbody td template
                    textarea tfoot th thead time title tr track tt u ul var
                    video wbr} {
            proc $t {attrs children} "Tag $t \$attrs \$children"
        }
    }

    namespace eval scgi {

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
        # Create and initialize the interpreter to handle the request
        # script
        proc make_interp {script params} {
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

            # Make the ::scgi::html namespace available
            foreach p [info proc ::html::\[a-z\]*] {
                interp alias $int ::scgi$p {} $p
            }

            # the following is an alias that's transparent to the user
            # and is employed to output XML tags, e.g.:
            # <?xml version="1.0" encoding="utf-8"?>
            interp alias $int xml              {} ::scgi::xml

            # Create variables that can be used within the client script
            $int eval [list set ::scgi::params  $params]
            $int eval [list set ::scgi::headers $::head]
            $int eval [list set ::scgi::body    $::body]
            $int eval [list set ::scgi::terminate 0]

            set int
        }

        ##
        # Run the request script in the dedicated interpreter
        proc run {script int} {
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

            set script [locate_script]
            set int [make_interp $script $in_params]

            set ::errorInfo {}

            run $script $int
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
            regsub -all -- {%([CDcd][A-Fa-f0-9])%([89ABab][A-Fa-f0-9])} \
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
}
