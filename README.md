tcl-scgi
========

This is a Simple Common Gateway Interface (SCGI) handler implemented as a multi-threaded server using the Tcl programming language.
Each request is first parsed by the main thread then dispatched to be served by a dedicated thread.
The scgi.tcl software requires Tcl 8.6 and the Thread extension.

The result of the following example can be seen <a href="https://www.ptrcrt.ch/example.stcl">here</a>.

    <?xml version="1.0" encoding="utf-8"?>
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
        <head>
            <title>tcl-scgi example</title>
        </head>
        <body>
            <p><label style="font-weight: bold">gray-scale table</label></p>
            <table><tr>
            <?
                set lvl 0
                while {$lvl <= 255} {
                    set color "#[string range [format %02X $lvl] 3]"
                    @ [::scgi::html::td \
                        [list style "background-color: $color; width: 20px; height: 20px" \
                              title $color] \
                        {}]
                    @ "\n"
                    if {[incr lvl] % 16 == 0 && $lvl != 256} {
                        @ "</tr>\n<tr>\n"
                    }
                }
            ?>
            </tr></table>
        </body>
    </html>

## Server

The handler can be invoked with the following arguments:

```
 -addr value              Listen on the specified address <127.0.0.1>
 -port value              Listen on the specified port <4000>
 -path value              Script path <DOCUMENT_ROOT>
 -fork                    Fork and return the pid of the child process
 -max_threads value       Maximum number of threads to spawn <50>
 -min_threads value       Minimum number of threads to spawn <1>
 -thread_keepalive value  Number of seconds an idle thread is kept alive <60>
 -conn_keepalive value    Number of seconds an idle connection is kept alive <-1>
 -verbose                 Dump verbose information to stdout
 --                       Forcibly stop option processing
 -help                    Print this message
 -?                       Print this message
```


## Scripts

User scripts consist of pure HTML code with interleaved Tcl scripts enclosed in &lt;? and ?&gt; tags.

The following special commands are available:

**`@ arg ...`** Synonym to `[puts]`, except it takes multiple arguments. The arguments are evaluated by Tcl if not enclosed in braces. Example:
```
@ [info hostname]
@ "Using Tcl version " [info patchlevel]
@ {Here [square brakets] are dumped literally}
```

**`::scgi::header key value ?replace?`** Append the HTTP header "Key: value" to the output buffer. If replace is true (the default), a previous header with the same key is replaced by the one specified.

**`::scgi::flush`**  Send the output buffered (including headers and body data) to the client and close the connection. Once called, no further output is possible, but the script stays alive and can continue processing data.

**`::scgi::die msg`** Output the message `msg` and quit. The Status header is set to 500 Internal Server Error.

**`::scgi::exit`**  Send the output buffered (including headers and body data) to the client and terminate the execution of the current script. `[exit]` is aliased to `::scgi::exit` and can be used too.

**`xml arg arg arg`**  Produce an xml tag. This command is transparent to the user. The line `<?xml version="1.0" encoding="utf-8"?>` is  a starting `<?` tag, an `xml` command, two arguments, and a closing `?>` tag.

**`::scgi::html::* attrs children`** The `html` namespace exposes commands named after the HTML tags. Each takes an optional (even) list of attributes as key-value pairs and an optional list of children. Example:
```
namespace path scgi
@ [html::a {title "Take me home" href https://example.com} \
    [list [html::pre {} [list "Go to home"]]] ]
```

Additionally, the following variables are available to client scripts:

**`::scgi::params`** A dictionary with the request parameters.

**`::scgi::headers`** A dictionary with the request headers.

**`::scgi::body`** The raw request body.

Short tags are also available by using a combination of an opening tag &lt;? and @ command. Example
```
Running Tcl version <?@ [info patchlevel] ?>
```

