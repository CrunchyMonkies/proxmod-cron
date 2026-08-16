# The whole build system for proxmod-cron.
#
# Nothing is compiled and nothing is generated. Files land in directories owned
# by Debian or by proxmod, plus one conffile of our own under /etc/cron.d. No
# Proxmox-owned path is read at build time or written at install time.
#
# dh's makefile buildsystem calls `make build` and `make install DESTDIR=…`,
# which is why those two targets are the ones that must not need anything
# outside this tree.

DESTDIR ?=
prefix  ?= /usr

PERLDIR  := $(prefix)/share/perl5
SHAREDIR := $(prefix)/share/proxmod
LIBDIR   := $(prefix)/lib/proxmod-cron
SBINDIR  := $(prefix)/sbin
CRONDIR  := /etc/cron.d

INSTALL      := install
INSTALL_DATA := $(INSTALL) -m 0644
INSTALL_PROG := $(INSTALL) -m 0755

MODULES := $(shell find perl -name '*.pm' | sort)
SCRIPTS := exec/proxmod-cron-sync exec/proxmod-cron-exec exec/proxmod-cronctl

# t/lib holds the PVE stubs. It is on the path for the syntax checks only —
# nothing under perl/ requires a stub at runtime except ProxmodCron::API2::*,
# which is loaded exclusively inside pvedaemon and pveproxy where the real
# modules exist.
PERLI := -Iperl -It/lib

.PHONY: all build install clean lint test check deb

all: build

build:
	@for m in $(MODULES); do perl -c $(PERLI) $$m || exit 1; done
	@for s in $(SCRIPTS); do perl -c $(PERLI) $$s || exit 1; done

# Both daemons run under -T. A module that compiles plainly but not under taint
# fails at require() time inside pvedaemon, which is the worst place to find out.
lint: build
	@for m in $(MODULES); do perl -c -T $(PERLI) $$m || exit 1; done
	@for s in $(SCRIPTS); do perl -c -T $(PERLI) $$s || exit 1; done
	node --check www/proxmod-cron.js
	@# The manifest is read by proxmod's registry at daemon start. A syntax
	@# error there disables the extension silently, so it is worth a check that
	@# does not depend on the registry being installed.
	perl -MJSON::PP -e 'JSON::PP->new->decode(do { local $$/; open my $$fh, "<", $$ARGV[0] or die $$!; <$$fh> })' \
	    conf/50-proxmod-cron.conf

test:
	prove -r t/

check: lint test

install:
	# Loaded by require() inside pvedaemon and pveproxy. /usr/share/perl5 is a
	# Debian vendor directory in perl's default @INC [PVE-F-003], so this works
	# under taint with no path configuration.
	$(INSTALL) -d $(DESTDIR)$(PERLDIR)/ProxmodCron/API2
	$(INSTALL) -d $(DESTDIR)$(PERLDIR)/ProxmodCron/JobType
	$(INSTALL_DATA) perl/ProxmodCron.pm $(DESTDIR)$(PERLDIR)/
	$(INSTALL_DATA) perl/ProxmodCron/*.pm $(DESTDIR)$(PERLDIR)/ProxmodCron/
	$(INSTALL_DATA) perl/ProxmodCron/API2/*.pm $(DESTDIR)$(PERLDIR)/ProxmodCron/API2/
	$(INSTALL_DATA) perl/ProxmodCron/JobType/*.pm $(DESTDIR)$(PERLDIR)/ProxmodCron/JobType/
	# Writing here is what activates proxmod's dpkg trigger. There is no
	# maintainer script involved in loading this extension.
	$(INSTALL) -d $(DESTDIR)$(SHAREDIR)/extensions.d
	$(INSTALL_DATA) conf/50-proxmod-cron.conf $(DESTDIR)$(SHAREDIR)/extensions.d/
	# Served unauthenticated under /proxmod/ [PVE-F-023].
	$(INSTALL) -d $(DESTDIR)$(SHAREDIR)/www
	$(INSTALL_DATA) www/proxmod-cron.js $(DESTDIR)$(SHAREDIR)/www/
	# Internal helpers, not interfaces: the anchor calls one and the rendered
	# crontab lines call the other. /usr/lib rather than /usr/sbin because
	# nobody should be typing these.
	$(INSTALL) -d $(DESTDIR)$(LIBDIR)
	$(INSTALL_PROG) exec/proxmod-cron-sync $(DESTDIR)$(LIBDIR)/
	$(INSTALL_PROG) exec/proxmod-cron-exec $(DESTDIR)$(LIBDIR)/
	# The administrator's interface when the web interface is not reachable.
	$(INSTALL) -d $(DESTDIR)$(SBINDIR)
	$(INSTALL_PROG) exec/proxmod-cronctl $(DESTDIR)$(SBINDIR)/
	# The one conffile. dh_installdeb registers everything under /etc as a
	# conffile automatically, so local edits survive an upgrade.
	$(INSTALL) -d $(DESTDIR)$(CRONDIR)
	$(INSTALL_DATA) cron/proxmod-cron $(DESTDIR)$(CRONDIR)/proxmod-cron

clean:
	rm -rf debian/proxmod-cron debian/.debhelper debian/files \
	       debian/*.substvars debian/debhelper-build-stamp

deb: clean
	dpkg-buildpackage -us -uc -b
