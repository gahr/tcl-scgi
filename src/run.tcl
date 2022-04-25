##
# Run the server

set args $::argv
::server::parse_args
::server::fork $args; # doesn't return if forked
::server::serve
vwait _forever
