package PVE::RPCEnvironment;

use strict;
use warnings;

use PVE::Exception qw(raise_perm_exc);
use PVE::Tools ();

# STUB, and the load-bearing one. t/09-authz.t drives the whole §8 model through
# this: the test writes a decision table of (user, path, privilege) triples and
# the authorization code is exercised against it, in both directions, without a
# cluster.
#
# `check` keeps the real signature — check($user, $path, $privs, $noerr) — and
# the real semantics: every privilege in the list must be held (AND, not OR),
# and without $noerr a refusal raises rather than returns false. Both are things
# the production code depends on, so a laxer double would hide a real bug.
#
# Grants propagate down the path tree, as PVE's do by default: Sys.Audit on '/'
# satisfies a check on '/nodes/pve1'. Without that a test would have to grant
# every path a method might ask about, and would then pass for a reason
# production does not share. `propagate => 0` is NOT modelled — nothing in this
# extension sets it, and a stub that pretends to implement something it does not
# is worse than one that plainly does not.

my $instance;

sub setup_default_cli_env { return }

sub get {
    $instance = __PACKAGE__->new() if !$instance;
    return $instance;
}

sub new {
    my ($class, %args) = @_;

    return bless {
        user => $args{user} || 'root@pam',
        # { user => { path => { priv => 1 } } }
        acl => $args{acl} || {},
        # Recorded so a test can assert *which* checks a method made, not only
        # what it concluded. A method that reaches the right answer by asking
        # the wrong question is still wrong.
        checks => [],
        workers => [],
    }, $class;
}

sub set_user { $_[0]->{user} = $_[1]; return }
sub get_user { return $_[0]->{user} }

# Grant privileges: $rpcenv->grant('u@pve', '/vms/101', 'VM.Backup', 'VM.Audit')
sub grant {
    my ($self, $user, $path, @privs) = @_;

    $self->{acl}{$user}{$path}{$_} = 1 for @privs;

    return $self;
}

sub revoke {
    my ($self, $user, $path, @privs) = @_;

    delete $self->{acl}{$user}{$path}{$_} for @privs;

    return $self;
}

sub checks { return $_[0]->{checks} }
sub reset_checks { $_[0]->{checks} = []; return }

sub check {
    my ($self, $user, $path, $privs, $noerr) = @_;

    push @{ $self->{checks} }, { user => $user, path => $path, privs => [@$privs] };

    my $held = $self->_effective($user, $path);

    # Every privilege, not any: the real check is an AND, and delegation in §8.3
    # is only safe because of it.
    for my $priv (@$privs) {
        next if $held->{$priv};

        return undef if $noerr;

        raise_perm_exc("$path, $priv");
    }

    return 1;
}

# Everything granted at this path or at any ancestor of it.
sub _effective {
    my ($self, $user, $path) = @_;

    $path = '/' if !defined $path || $path eq '';

    my %held;

    my @parts = grep { length } split(m{/}, $path);
    my $walk = '';

    for my $ancestor ('/', map { $walk .= "/$_" } @parts) {
        my $grants = $self->{acl}{$user}{$ancestor} or next;
        $held{$_} = 1 for keys %$grants;
    }

    return \%held;
}

sub check_full {
    my ($self, $user, $path, $privs, $any, $noerr) = @_;

    return $self->check_any($user, $path, $privs, $noerr) if $any;

    return $self->check($user, $path, $privs, $noerr);
}

# The declarative half of the gate, and the reason it is here rather than
# approximated in a test: in production the `permissions` hash on a method is
# enforced by pve-http-server before the body is ever entered, so a test that
# only calls the body proves the body and nothing else. ProxmodCronTest::call
# runs this first, exactly as the daemon does.
#
# Only the tests this extension actually declares are implemented — 'perm',
# 'and', 'or'. Anything else dies rather than passing, so a method that starts
# using 'userid-param' cannot quietly go unchecked here.
sub check_api2_permissions {
    my ($self, $perm, $username, $param) = @_;

    return 1 if !$username && $perm->{user} && $perm->{user} eq 'world';

    raise_perm_exc("user != null") if !$username;

    # root@pam bypasses every declarative check in production too. Tests that
    # mean to exercise the model must therefore not run as root@pam, and the
    # ones in t/09-authz.t do not.
    return 1 if $username eq 'root@pam';

    raise_perm_exc('user != root@pam') if !$perm;

    return 1 if $perm->{user} && $perm->{user} eq 'all';

    return $self->exec_api2_perm_check($perm->{check}, $username, $param)
        if $perm->{check};

    raise_perm_exc();
}

sub exec_api2_perm_check {
    my ($self, $check, $username, $param, $noerr) = @_;

    my $test = $check->[0];

    die "no permission test specified" if !$test;

    if ($test eq 'and') {
        my @subchecks = @$check[1 .. $#$check];
        $self->exec_api2_perm_check($_, $username, $param) for @subchecks;
        return 1;
    }

    if ($test eq 'or') {
        my @subchecks = @$check[1 .. $#$check];
        for my $subcheck (@subchecks) {
            return 1 if $self->exec_api2_perm_check($subcheck, $username, $param, 1);
        }
        return 0 if $noerr;
        raise_perm_exc();
    }

    if ($test eq 'perm') {
        my ($t, $tmplpath, $privs, %options) = @$check;

        die "missing parameters" if !($tmplpath && $privs);

        # {node} in the template comes from the request's own parameters, so the
        # check reads "may this user modify *this* node".
        my $path = PVE::Tools::template_replace($tmplpath, $param);

        return $self->check_full($username, $path, $privs, $options{any}, $noerr);
    }

    die "the RPCEnvironment stub does not implement the '$test' permission test\n";
}

sub check_any {
    my ($self, $user, $path, $privs, $noerr) = @_;

    for my $priv (@$privs) {
        return 1 if $self->check($user, $path, [$priv], 1);
    }

    return undef if $noerr;

    raise_perm_exc("$path, " . join('|', @$privs));
}

# Records the call and returns a UPID-shaped string. The worker body is run
# synchronously so a test can assert what it did; the real one forks, which is
# not something a unit test should be made to deal with.
sub fork_worker {
    my ($self, $type, $id, $user, $code) = @_;

    push @{ $self->{workers} }, { type => $type, id => $id, user => $user };

    my $err;
    eval { $code->() };
    $err = $@ if $@;

    my $upid = "UPID:testnode:00000000:00000000:00000000:$type:$id:$user:";

    die $err if $err;

    return $upid;
}

sub workers { return $_[0]->{workers} }

sub _reset { $instance = undef; return }

1;
