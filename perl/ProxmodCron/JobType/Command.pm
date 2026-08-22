package ProxmodCron::JobType::Command;

use strict;
use warnings;

use base qw(ProxmodCron::JobType);

use ProxmodCron::Registry;

# The built-in type: run an arbitrary command.
#
# This is arbitrary root execution, and the access model treats it as such. Note
# what is NOT overridden below: required_privs. The base class returns an empty
# list, an empty list means "not delegable", and so a command job can only ever
# be created by someone holding Sys.Modify on the scope. There is no ACL path
# that honestly describes "runs anything as root", so we do not invent one.

our $VERSION = '202608.22.0';

sub type { 'command' }

sub title { 'Command' }

sub icon_cls { 'fa fa-terminal' }

sub description {
    return 'Run a command. The command runs as root and is not delegable:'
        . ' managing one requires Sys.Modify on the scope.';
}

sub properties {
    return {
        command => {
            type => 'array',
            items => {
                type => 'string',
                maxLength => 4096,
            },
            description => 'The command and its arguments, as a list.'
                . ' Never a shell string — the list is what gets executed.',
        },
    };
}

sub build_command {
    my ($class, $cfg) = @_;

    my $argv = $cfg->{command};

    die "command job has no command\n"
        if !$argv || ref($argv) ne 'ARRAY' || !@$argv;

    return [@$argv];
}

# Registering at load time, exactly as a third-party plugin does. The built-in
# type going through the same path as everyone else's is what keeps that path
# working.
ProxmodCron::Registry->register(__PACKAGE__);

1;
