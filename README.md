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

`-f`

Fork and return the pid of the child process. Useful in startup scripts.

`-m max_threads`

Maximum number of threads that can be handling requests at any given time.

`-p port`

Listen on the specified port number.

`-s script_path`

Use this path as a search base for scripts. If it's not set, the DOCUMENT_ROOT set by the HTTP server is used instead.

`-t timeout`

Kill an idle connection after timeout seconds. Idle connections are those on which we are still waiting for data.
Once the end script is called, a connection is no more killable.

`-v`

Dump verbose information.

## Scripts

User scripts consist of pure HTML code with interleaved Tcl scripts enclosed in &lt;? and ?&gt; tags.

The following special commands are available:

`@ arg`

Synonym to `[puts]`. The argument is evaluated by Tcl if it's not enclosed in braces. Example:
```
@ [info hostname]
@ "Using Tcl version [tcl patchlevel]"
@ {Here [square brakets] are dumped literally}
```

`::scgi::header key value ?replace?`

Append the header "Key: value" to the output buffer. If replace is true (the default), a previous header with
the same key is replaced by the one specified.

`::scgi::flush`

Send the output buffered (including headers and body data) to the client and close the connection. Once called,
no further output is possible, but the script stays alive and can continue processing data.

`::scgi::die msg`

Output the message msg and quit. The Status header is set to 500 Internal Server Error.

`::scgi::exit`

Send the output buffered (including headers and body data) to the client and terminate the execution of the
current script. `[exit]` is aliased to `::scgi::exit` and can be used too.

`xml arg arg arg`

Produce an xml tag. This command is transparent to the user. A line like the following
`<?xml version="1.0" encoding="utf-8"?>` is really a starting `<?` tag, an `xml` command,
two arguments, and a closing `?>` tag.

`::scgi::html::* attrs children`

The `html` namespace exposes commands named after the HTML tags. Each takes an optional
(even) list of attributes as key-value pairs and an optional list of children. Example:

```
namespace path scgi
@ [html::a {title "Take me home" href https://example.com} \
    [list [html::pre {} [list "Go to home"]]] ]
```

Additionally, the following variables are available to client scripts:

`::scgi::params`

A dictionary with the request parameters.

`::scgi::headers`

A dictionary with the request headers.

`::scgi::body`

The raw request body.

`::scgi::files`

The decoded body of a multipart/form-data request. The data format is explained in tcllib's ncgi documentation.

Short tags are also available by using a combination of an opening tag &lt;? and @ command:

```
Running Tcl version <?@ [info patchlevel] ?>
```

