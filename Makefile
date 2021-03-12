# vim: set ts=4:

TCLSH?=		/usr/bin/env tclsh
SRCS=		src/dhelpers.tcl src/run.tcl src/server.tcl src/worker.tcl
OUT=		scgi.tcl rc.d/tcl-scgi
TCLSHEXE!=	echo 'puts [info nameofexecutable]' | ${TCLSH}
TCLVERSION!=echo 'puts [info tclversion]' | ${TCLSH}
SUBST=		"s|@@TCLSHEXE@@|${TCLSHEXE}|g; s|@@TCLVERSION@@|${TCLVERSION}|g"

all: ${OUT}

scgi.tcl: scgi.tcl.in combine.awk ${SRCS}
	cat scgi.tcl.in | awk -f combine.awk | sed ${SUBST} > $@ && chmod 754 $@

rc.d/tcl-scgi: rc.d/tcl-scgi.in
	cat rc.d/tcl-scgi.in | sed ${SUBST} > $@

clean:
	rm -f ${OUT}
