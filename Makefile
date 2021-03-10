# vim: set ts=8:
#
SCRIPT=	combine.awk
SRCS=	src/dhelpers.tcl src/run.tcl src/server.tcl src/worker.tcl
IN=	scgi.tcl.in
OUT=	scgi.tcl

${OUT}: ${IN} ${SCRIPT} ${SRCS}
	cat ${IN} | awk -f ${SCRIPT} > ${OUT} && chmod 755 ${OUT}

clean:
	rm -f ${OUT}
