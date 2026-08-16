package PVE::Exception;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(raise raise_param_exc raise_perm_exc);

# STUB. Enough of Proxmox's PVE::Exception for the API layer to raise the same
# shapes it raises in production, and for the tests to tell them apart.
#
# The real class stringifies with an HTTP status line and carries an `errors`
# hash the API server renders into a 400 body. What the tests care about is the
# status code and the message, so those are the two things this keeps faithful.

use overload '""' => sub { $_[0]->stringify }, fallback => 1;

sub new {
    my ($class, $msg, %param) = @_;

    my $self = bless { msg => $msg, %param }, $class;

    return $self;
}

sub stringify {
    my ($self) = @_;

    my $msg = defined $self->{msg} ? $self->{msg} : 'error';
    $msg .= "\n" if $msg !~ /\n\z/;

    return $msg;
}

sub raise {
    my ($msg, %param) = @_;
    die __PACKAGE__->new($msg, %param);
}

sub raise_param_exc {
    my ($errors, $usage) = @_;

    my $msg = join(', ', map { "$_: $errors->{$_}" } sort keys %$errors);

    die __PACKAGE__->new("Parameter verification failed. ($msg)",
        code => 400, errors => $errors, usage => $usage);
}

sub raise_perm_exc {
    my ($what) = @_;

    my $msg = 'Permission check failed';
    $msg .= " ($what)" if defined $what && $what ne '';

    die __PACKAGE__->new($msg, code => 403);
}

1;
