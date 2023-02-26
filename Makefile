# vim: set ts=4:

TCLSH?=		tclsh8.7
REPO=		fossil info | grep ^repository | awk '{print $$2}'
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

git:
	@if [ -e git-import ]; then \
	    echo "The 'git-import' directory already exists"; \
	    exit 1; \
	fi; \
	git init -b master git-import && cd git-import && \
	fossil export --git --rename-trunk master --repository `${REPO}` | \
	git fast-import && git reset --hard HEAD && \
	git remote add origin git@github.com:gahr/tcl-scgi.git && \
	git push -f origin master && \
	cd .. && rm -rf git-import

