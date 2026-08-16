#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/../perl", "$FindBin::Bin/lib";

BEGIN {
    require ProxmodCronTest;
    ProxmodCronTest::prefix_tree();
}

use PVE::API2;
use PVE::RESTHandler;
use Proxmod::API;
use Proxmod::Log;
use ProxmodCron;

# The shape of the REST surface, asserted against the real registration rules.
#
# PVE::RESTHandler and Proxmod::API in t/lib are copies of the production
# modules, not friendly doubles, so everything here is checked the way it is
# checked inside pvedaemon: register_method dies on a duplicate path, refuses a
# regex sibling, and Proxmod::API's post-registration find_handler probe catches
# an endpoint that registered fine and then resolves to nothing [PVE-F-051].
#
# The rules below are the ones that turn into a security bug or a silently dead
# feature if they are relaxed for convenience during a refactor.

# Registration is process-global. Build the tree once and inspect it.
{
    local $Proxmod::Log::FH = \*STDOUT;
    open(my $null, '>', '/dev/null') or die;
    local $Proxmod::Log::FH = $null;

    PVE::API2::_build_tree();
    Proxmod::API::_reset();

    my $api = Proxmod::API->new(id => 'cron', version => '0.1.0', daemon => 'pvedaemon');
    ProxmodCron::proxmod_register($api);
}

my %TREE = (
    'ProxmodCron::API2::Cluster' => { scope => 'cluster', path => '/cluster/proxmod/cron' },
    'ProxmodCron::API2::Node' => { scope => 'node', path => '/nodes/{node}/proxmod/cron' },
);

# §8.2 makes two node reads "X, or delegated", and delegation is for callers who
# may hold nothing at all on the node. A declarative ACL check would refuse them
# before the body could grant, so these two carry { user => 'all' } and do the
# real check as the first act of the handler. Both refusals are proved for real
# in t/09-authz.t; this list exists so that adding a THIRD loose method under
# jobs/ has to be a deliberate edit to this file.
my %LOOSE_UNDER_JOBS = (
    'POST jobs/{id}/run' => 'Sys.Modify or delegated — §8.2',
    'GET jobs/{id}/runs' => 'Sys.Audit or delegated — §8.2',
);

# Reads that go to the journal. www-data is not in the systemd-journal group, so
# an unprotected one of these returns an empty history that reads as "this job
# never ran" rather than as a permissions problem.
my @JOURNAL_READS = ('jobs/{id}/runs', 'runs/{runid}', 'runs/{runid}/log', 'journal');

my %methods;
for my $class (sort keys %TREE) {
    for my $info (@{ PVE::RESTHandler::method_attributes($class) || [] }) {
        $methods{$class}{"$info->{method} $info->{path}"} = $info;
    }
}

plan tests => 13;

is(scalar(@PVE::RESTHandler::ERRORS), 0, 'no path resolved through a die in map_path_to_methods')
    or diag(join("\n", @PVE::RESTHandler::ERRORS));

subtest 'both scopes are mounted where proxmod puts them' => sub {
    plan tests => 2;

    my $regs = Proxmod::API::registrations();
    my %at = map { $_->{subclass} => $_->{path} } @$regs;

    is($at{'ProxmodCron::API2::Cluster'}, '/cluster/proxmod/cron', 'cluster tree');
    is($at{'ProxmodCron::API2::Node'}, '/nodes/{node}/proxmod/cron', 'node tree');
};

subtest 'every method declares permissions' => sub {
    my @all = map { my $c = $_; map { [$c, $_] } sort keys %{ $methods{$c} } } sort keys %methods;

    plan tests => scalar(@all);

    for my $entry (@all) {
        my ($class, $key) = @$entry;
        my $perm = $methods{$class}{$key}{permissions};

        # Proxmod::API already dies without the key. What this asserts is that
        # nobody reached for `permissions => undef`, which is legal and means
        # root@pam only — a working endpoint nobody but root can call, which is
        # not a thing this extension has any use for.
        ok(defined $perm && ref($perm) eq 'HASH', "$key on $class has a real permissions hash");
    }
};

subtest 'every mutating method is protected' => sub {
    my @mutators = _select(sub { $_[0]{method} =~ /\A(?:POST|PUT|DELETE)\z/ });

    plan tests => scalar(@mutators);

    for my $entry (@mutators) {
        my ($class, $key, $info) = @$entry;

        # pveproxy runs as www-data and cannot write /etc/cron.d, /etc/proxmod
        # or /etc/pve. Without protected => 1 the request is answered there and
        # fails on a permission error that looks like a bug in this extension.
        ok($info->{protected}, "$key on $class is protected");
    }
};

subtest 'every journal read is protected' => sub {
    my @reads = _select(sub {
        my ($info, $class) = @_;
        return 0 if $class !~ /Node/;
        return scalar(grep { $_ eq $info->{path} } @JOURNAL_READS);
    });

    plan tests => 1 + scalar(@reads);

    is(scalar(@reads), scalar(@JOURNAL_READS), 'found every journal read');

    for my $entry (@reads) {
        my ($class, $key, $info) = @$entry;
        ok($info->{protected}, "$key is protected: www-data cannot read the journal");
    }
};

subtest 'every node method proxies to its node' => sub {
    my @node = _select(sub { $_[1] =~ /Node/ });

    plan tests => scalar(@node);

    for my $entry (@node) {
        my ($class, $key, $info) = @$entry;

        # The answer is about this machine — its /etc/cron.d, its journal, its
        # installed plugins. A request that lands on the wrong node must be
        # forwarded, not answered locally about the wrong host.
        is($info->{proxyto}, 'node', "$key proxies to the node");
    }
};

subtest 'no cluster method proxies anywhere' => sub {
    my @cluster = _select(sub { $_[1] =~ /Cluster/ });

    plan tests => scalar(@cluster);

    for my $entry (@cluster) {
        my ($class, $key, $info) = @$entry;

        # /etc/pve is replicated, so any node can answer. proxyto here would
        # send every cluster write through one node for no reason and turn that
        # node being busy into the whole cluster's problem.
        ok(!defined $info->{proxyto}, "$key does not proxy");
    }
};

subtest 'the jobs/ tree is not open' => sub {
    my @loose = _select(sub {
        my ($info) = @_;
        return 0 if $info->{path} !~ m{\Ajobs(?:/|\z)};
        return (($info->{permissions}{user} || '') eq 'all') ? 1 : 0;
    });

    plan tests => 1 + scalar(@loose);

    for my $entry (@loose) {
        my ($class, $key, $info) = @$entry;
        my $reason = $LOOSE_UNDER_JOBS{$key};
        ok($reason, "$key on $class is a known 'or delegated' method: " . ($reason || 'NOT KNOWN'));
    }

    is(scalar(@loose), scalar(keys %LOOSE_UNDER_JOBS),
        'exactly the known loose methods, no more and no fewer');
};

subtest 'the delegated tree is separate, and open by design' => sub {
    my @delegated = _select(sub { $_[0]{path} =~ m{\Adelegated-jobs(?:/|\z)} });

    plan tests => 1 + 2 * scalar(@delegated);

    # Five per scope: list, get, create, update, delete.
    is(scalar(@delegated), 10, 'both scopes carry the full delegated subtree');

    for my $entry (@delegated) {
        my ($class, $key, $info) = @$entry;

        # { user => 'all' } is correct here and is only safe because every one
        # of these bodies refuses a type with an empty required_privs as its
        # first act — the structural rule in §8.3. t/09-authz.t proves that.
        is($info->{permissions}{user}, 'all', "$key on $class is declaratively open");
        ok(!$info->{permissions}{check}, "$key on $class has no declarative ACL check");
    }
};

subtest 'enable/disable is its own endpoint' => sub {
    my @writes = _select(sub { $_[0]{path} =~ m{\A(?:delegated-)?jobs(?:/\{id\})?\z}
        && $_[0]{method} =~ /\A(?:POST|PUT)\z/ });

    plan tests => 2 + scalar(@writes);

    for my $class (sort keys %TREE) {
        # It is the only mutation permitted on an extension-owned job. A
        # separate path means that fact is enforced by routing rather than by a
        # conditional inside a general update handler.
        ok($methods{$class}{'PUT jobs/{id}/enabled'},
            "$TREE{$class}{scope}: PUT jobs/{id}/enabled exists");
    }

    for my $entry (@writes) {
        my ($class, $key, $info) = @$entry;

        # Not declared anywhere else, so it never appears in the API viewer or a
        # generated client as a field that always returns 400. The body still
        # refuses the key by name, because these methods leave
        # additionalProperties open for plugin fields.
        ok(!exists $info->{parameters}{properties}{enabled},
            "$key on $class does not accept an enabled parameter");
    }
};

subtest 'output is gated differently from metadata' => sub {
    plan tests => 3;

    my $node = $methods{'ProxmodCron::API2::Node'};

    # §8.2: run metadata is operational status and an auditor should see it;
    # what a job printed is arbitrary text a root command produced, and that is
    # what Sys.Syslog exists to gate. Reading it here must not be a way around
    # the privilege PVE demands for the same bytes at /nodes/{node}/journal.
    is($node->{'GET journal'}{permissions}{check}[2][0], 'Sys.Syslog',
        'the whole journal needs Sys.Syslog outright');

    is($node->{'GET jobs/{id}/status'}{permissions}{check}[2][0], 'Sys.Audit',
        'last-run status needs only Sys.Audit');

    # runs/{runid}/log cannot check declaratively — the delegated carve-out
    # needs the job, which is only known once the run has been looked up — so it
    # is { user => 'all' } with assert_output() first in the body.
    is($node->{'GET runs/{runid}/log'}{permissions}{user}, 'all',
        'a run log checks in the body, because delegation needs the job');
};

subtest 'every method is reachable and unshadowed' => sub {
    my @all = _select(sub { 1 });

    plan tests => scalar(@all);

    for my $entry (@all) {
        my ($class, $key, $info) = @$entry;

        my $path = $TREE{$class}{path};
        $path .= "/$info->{path}" if $info->{path} ne '';

        my ($resolved, $resolved_info) =
            Proxmod::API::_resolve($info->{method}, $path);

        # Registering is not the same as being reachable: a path behind a greedy
        # fragmentDelimiter registers perfectly and then never resolves.
        is($resolved, $class, "$info->{method} $path resolves to $class")
            or diag('resolved to ' . (defined $resolved ? $resolved : 'nothing'));
    }
};

subtest 'parameters are closed except where a plugin owns them' => sub {
    my @all = _select(sub { 1 });

    plan tests => scalar(@all);

    for my $entry (@all) {
        my ($class, $key, $info) = @$entry;

        my $additional = $info->{parameters}{additionalProperties};

        # Only create and update are open, and only because type-specific keys
        # are declared by the plugin's own schema rather than by us. They are
        # not unchecked: ProxmodCron::Registry::validate rejects unknown keys
        # against that schema, and Config::untaint_job rebuilds every value from
        # a strict capture before it reaches a store.
        my $may_be_open = $info->{path} =~ m{\A(?:delegated-)?jobs(?:/\{id\})?\z}
            && $info->{method} =~ /\A(?:POST|PUT)\z/;

        if ($may_be_open) {
            is($additional, 1, "$key on $class is open for plugin properties");
        } else {
            is($additional, 0, "$key on $class takes only what it declares");
        }
    }
};

sub _select {
    my ($want) = @_;

    my @out;
    for my $class (sort keys %methods) {
        for my $key (sort keys %{ $methods{$class} }) {
            my $info = $methods{$class}{$key};
            push @out, [$class, $key, $info] if $want->($info, $class);
        }
    }

    return @out;
}
