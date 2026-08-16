package PVE::Tools;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(run_command);

# STUB. Only run_command, and only the list form, because that is the only way
# this package calls it — a string would reach a shell, which nothing here does.
#
# By default the command is recorded and not executed, so a test can assert the
# argv a manual run would have produced without running it. Set $EXECUTE to run
# it for real.

our @CALLS;
our $EXECUTE = 0;
our $EXIT = 0;

sub run_command {
    my ($cmd, %opts) = @_;

    die "PVE::Tools::run_command test stub takes an argv, not a string\n"
        if ref($cmd) ne 'ARRAY';

    push @CALLS, { cmd => [@$cmd], opts => \%opts };

    return $EXIT if !$EXECUTE;

    my $rc = system(@$cmd);

    die "command '$cmd->[0]' failed: exit code " . ($rc >> 8) . "\n"
        if $rc != 0 && !$opts{noerr};

    return $rc >> 8;
}

# Copied from pve-common, not approximated: it is what turns '/nodes/{node}' in
# a declarative permission check into the path the ACL is actually tested
# against, and getting the '-' fallback wrong would silently check a path no
# grant could ever match.
sub template_replace {
    my ($tmpl, $data) = @_;

    return $tmpl if !$tmpl;

    my $res = '';
    while ($tmpl =~ m/([^{]+)?(\{([^}]+)\})?/g) {
        $res .= $1 if $1;
        $res .= ($data->{$3} || '-') if $2;
    }

    return $res;
}

sub _reset { @CALLS = (); $EXECUTE = 0; $EXIT = 0; return }

1;
