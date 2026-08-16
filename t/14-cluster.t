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

use ProxmodCron::Cluster;
use ProxmodCron::Config;

# Membership, and the one decision made from it.
#
# Everything here is about a single question — may this node act on cluster
# configuration right now — and about the three ways of getting it wrong:
# answering 'yes' because the file could not be read, answering 'no' on a
# standalone host that has no cluster to be quorate in, and answering from a
# cache written by a sync anchor that stopped running hours ago.

plan tests => 7;

my $ROOT = $ENV{PROXMOD_CRON_TEST_PREFIX};

sub members {
    return ProxmodCronTest::cluster_members(@_);
}

sub no_members {
    unlink("$ROOT/etc/pve/.members");
    return;
}

sub wipe_cache {
    unlink(ProxmodCron::Cluster::cache_file());
    return;
}

# ---------------------------------------------------------------------------

subtest 'a standalone host is its own quorum' => sub {
    plan tests => 6;

    wipe_cache();

    # pmxcfs in local mode: a real PVE host that was never joined to anything.
    # It publishes .members with no 'cluster' key at all.
    members();

    my $local = ProxmodCron::Cluster::membership();
    ok($local->{known}, 'the answer is known');
    ok($local->{standalone}, 'and it is standalone');
    ok($local->{quorate}, 'a single node is quorate by definition');

    my ($ok) = ProxmodCron::Cluster::quorate($local);
    ok($ok, 'so it may act on cluster configuration');

    # No cluster filesystem at all: not PVE, or a test tree. This is the case
    # that must not fail closed — refusing here would stop cluster-scoped jobs
    # on every unclustered install in existence.
    no_members();
    my $dir = ProxmodCron::Config::pve_dir();
    rename($dir, "$dir.away");

    my $bare = ProxmodCron::Cluster::membership();
    ok($bare->{standalone}, 'no /etc/pve at all is standalone too');
    is($bare->{source}, 'standalone', 'and says so');

    rename("$dir.away", $dir);
    members();
};

subtest 'a clustered node reports quorum and who is online' => sub {
    plan tests => 7;

    wipe_cache();

    members(nodename => 'pve1', quorate => 1,
        nodes => { pve1 => 1, pve2 => 1, pve3 => 0 });

    my $m = ProxmodCron::Cluster::membership();

    ok($m->{known}, 'known');
    ok(!$m->{standalone}, 'and not standalone');
    ok($m->{quorate}, 'quorate');
    is($m->{nodename}, 'pve1', 'the node names itself');
    is_deeply([sort keys %{ $m->{nodes} }], [qw(pve1 pve2 pve3)], 'all three listed');
    is($m->{nodes}->{pve3}->{online}, 0, 'and the one that is down is marked down');

    my ($ok) = ProxmodCron::Cluster::quorate($m);
    ok($ok, 'a quorate node may act');
};

subtest 'a node that is not quorate may not act, and is told why' => sub {
    plan tests => 3;

    wipe_cache();

    members(nodename => 'pve3', quorate => 0,
        nodes => { pve1 => 0, pve2 => 0, pve3 => 1 });

    my $m = ProxmodCron::Cluster::membership();

    ok($m->{known}, 'the state is known — this is an answer, not a failure');

    my ($ok, $why) = ProxmodCron::Cluster::quorate($m);
    ok(!$ok, 'and the answer is no');
    like($why, qr/quorate/, 'with a reason that names quorum');
};

subtest 'an unreadable membership file is not evidence of health' => sub {
    plan tests => 4;

    wipe_cache();

    # /etc/pve is there, so this host has a cluster filesystem, but .members
    # cannot be read. On a real host that means the process is not root. It is
    # emphatically not the same statement as "there is no cluster".
    no_members();

    my $m = ProxmodCron::Cluster::membership();

    ok(!$m->{known}, 'the question could not be answered');
    ok(!$m->{standalone}, 'and it must not be mistaken for a standalone host');

    my ($ok, $why) = ProxmodCron::Cluster::quorate($m);
    ok(!$ok, 'so the node stands down');
    like($why, qr/cannot read/, 'and says what it could not read');
};

subtest 'the cache answers for a reader that cannot open /etc/pve' => sub {
    plan tests => 6;

    wipe_cache();

    members(nodename => 'pve1', quorate => 1, nodes => { pve1 => 1, pve2 => 1 });

    is(ProxmodCron::Cluster::cache_write(ProxmodCron::Cluster::membership()),
        'written', 'the sync anchor writes the cache');

    my $mode = (stat(ProxmodCron::Cluster::cache_file()))[2] & 07777;
    is($mode, 0644, 'world-readable, which is the entire point of it existing');

    # Now take .members away, as it is for any non-root process.
    no_members();

    my $status = ProxmodCron::Cluster::status();
    is($status->{source}, 'cache', 'status falls back to the cache');
    ok($status->{quorate}, 'and reports what the cache last saw');

    my ($ok) = ProxmodCron::Cluster::quorate($status);
    ok($ok, 'so a non-root wrapper can still run a cluster job');

    # A non-quorate reading is cached just as faithfully.
    members(nodename => 'pve1', quorate => 0, nodes => { pve1 => 1, pve2 => 1 });
    ProxmodCron::Cluster::cache_write(ProxmodCron::Cluster::membership());
    no_members();

    my ($blocked) = ProxmodCron::Cluster::quorate(ProxmodCron::Cluster::status());
    ok(!$blocked, 'and a cached non-quorate state still stands the node down');
};

subtest 'a stale cache is not an answer' => sub {
    plan tests => 3;

    wipe_cache();

    members(nodename => 'pve1', quorate => 1, nodes => { pve1 => 1, pve2 => 1 });
    ProxmodCron::Cluster::cache_write(ProxmodCron::Cluster::membership());
    no_members();

    ok(ProxmodCron::Cluster::status()->{quorate}, 'a fresh cache is trusted');

    # Wind the cache back past the staleness window. A node whose sync anchor
    # has been dead this long should not be acting on its last opinion of the
    # cluster — that opinion is from before whatever went wrong.
    my $old = time() - $ProxmodCron::Cluster::STALE_AFTER - 60;
    utime($old, $old, ProxmodCron::Cluster::cache_file());

    my $raw = ProxmodCronTest::slurp(ProxmodCron::Cluster::cache_file());
    $raw =~ s/"updated"\s*:\s*\d+/"updated" : $old/;
    open(my $fh, '>', ProxmodCron::Cluster::cache_file()) or die $!;
    print {$fh} $raw;
    close($fh);

    my $status = ProxmodCron::Cluster::status();
    ok(!$status->{known}, 'a stale cache is unknown, not quorate');
    like($status->{reason}, qr/proxmod-cron-sync is not running/,
        'and names the thing that has stopped');
};

subtest 'the cache is only rewritten when it says something new' => sub {
    plan tests => 3;

    wipe_cache();

    members(nodename => 'pve1', quorate => 1, nodes => { pve1 => 1, pve2 => 1 });

    is(ProxmodCron::Cluster::cache_write(ProxmodCron::Cluster::membership()),
        'written', 'the first write happens');

    is(ProxmodCron::Cluster::cache_write(ProxmodCron::Cluster::membership()),
        undef, 'an identical second write does not');

    # A node going offline is a change, and must land in the cache immediately
    # rather than at the next refresh interval.
    members(nodename => 'pve1', quorate => 1, nodes => { pve1 => 1, pve2 => 0 });

    is(ProxmodCron::Cluster::cache_write(ProxmodCron::Cluster::membership()),
        'written', 'a node going offline is written through at once');
};
