package Proxmod::Log;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(log_debug log_info log_warn log_error);

our $VERSION = '0.2.0';

# Logging for code running inside pvedaemon and pveproxy.
#
# systemd wires both daemons' output to the journal, so STDERR *is* the log:
# nothing to rotate, no permissions to get wrong, and extension problems appear
# next to the PVE messages that explain them. `journalctl -u pveproxy` is the
# one place an administrator has to look.
#
# Every line is prefixed "proxmod:". That prefix is contract, not decoration —
# proxmod-verify decides whether the live daemon actually loaded us by grepping
# the journal for it since the unit's last start. Do not change it without
# changing bin/proxmod-verify.
#
# This module deliberately has no dependencies beyond core Perl and does not use
# Proxmod::Registry, because everything else logs — including the code that
# reads the registry. It parses the one setting it needs out of proxmod.conf
# itself rather than pulling in a config layer.

our $PREFIX = 'proxmod';

# Overridable so the unit tests can point at a fixture instead of /etc.
our $CONF_FILE = '/etc/proxmod/proxmod.conf';

# Where output goes. Tests localise this to an in-memory handle to capture it.
our $FH;

my $debug_cached;

sub _truthy {
    my ($v) = @_;
    return 0 if !defined $v;
    return $v =~ /^\s*(?:1|y|yes|on|true)\s*$/i ? 1 : 0;
}

sub _debug_enabled {
    return $debug_cached if defined $debug_cached;
    $debug_cached = 0;

    # pvedaemon clears its environment before running, so an env var alone is
    # not reachable from a normal systemd start — that is the trap pve-gpu-
    # manager hit with PVE_GPU_SYSFS_ROOT. The config file is the switch that
    # actually works in production; the env var only helps when you run a
    # daemon by hand.
    $debug_cached = 1 if _truthy($ENV{PROXMOD_DEBUG});

    if (open(my $fh, '<', $CONF_FILE)) {
        while (my $line = <$fh>) {
            next if $line =~ /^\s*(?:#|$)/;
            $debug_cached = _truthy($1) if $line =~ /^\s*debug\s*=\s*(\S+)/;
        }
        close($fh);
    }

    return $debug_cached;
}

# Only for the tests: forget what we decided about the debug flag.
sub _reset_cache { $debug_cached = undef; return; }

sub _emit {
    my ($level, @parts) = @_;

    my $msg = join('', map { defined($_) ? $_ : '<undef>' } @parts);

    # A message containing a newline would produce a journal line without our
    # prefix, which proxmod-verify would not see and an administrator would not
    # associate with proxmod. Collapse instead.
    $msg =~ s/\s*\n\s*/ /g;
    $msg =~ s/\s+$//;

    my $line = $level eq 'info' ? "$PREFIX: $msg\n" : "$PREFIX: $level: $msg\n";

    my $out = $FH || \*STDERR;
    print {$out} $line;

    return;
}

sub log_debug { _emit('debug', @_) if _debug_enabled(); return }
sub log_info  { _emit('info',  @_); return }
sub log_warn  { _emit('warn',  @_); return }
sub log_error { _emit('error', @_); return }

1;
