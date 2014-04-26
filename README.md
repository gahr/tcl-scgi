tcl-scgi
========

This is a Simple Common Gateway Interface (SCGI) handler implemented as a multi-threaded server using the Tcl programming language.
Each request is first parsed by the main thread then dispatched to be served by a dedicated thread.

The handler can be invoked with the following arguments:

    -c dir
    Change working directory into dir before starting serving requests.

    -m max_threads
    Maximum number of threads that can be handling requests at any given time.
    
    -p port
    Listen on the specified port number.
    
    -s script_path
    Use this path as a search base for scripts. If it's not set, the DOCUMENT_ROOT set by the HTTP server is used instead.
    
    -t timeout
    Kill an idle connection after timeout seconds. Idle connections are those on which we are still waiting for data.
    Once the end script is called, a connection is no more killable.
    
    -v
    Dump verbose information.


The scgi.tcl software requires Tcl 8.6 and the Thread extension.


User scripts can use the following procs:

    ::scgi::header key value ?replace?

    Append the header "Key: value" to the output buffer. If replace is true
    (the default), a previous header with the same key is replaced by the
    one specified.

    ::scgi::puts data

    Append the data to the output buffer. No new-line is automatically appended to the data.
     
    ::scgi::flush

    Send the output buffered (including headers and body data) to the client. Once called, 
    no further output is possible.

    ::scgi::params

    Return a dictionary with the request parameters.

    ::scgi::param name

     Return the value of a specified request parameter. If the parameter does not exist, 
     return the empty string.

    ::scgi::req_head
    
    Return a dictionary with the request headers.

    ::scgi::req_body

    Return the (URL-encoded) request body.

    ::scgi::exit

    Send the output buffered (including headers and body data) to the client
    and terminate the execution of the current script. [exit] is aliased
    to ::scgi::exit and can be used too.

