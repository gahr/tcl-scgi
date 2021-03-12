##
# Run the server

::server::fork ;# doesn't return if forked
::server::parse_args
::server::serve
vwait _forever
