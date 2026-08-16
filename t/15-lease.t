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

use File::Path ();

use ProxmodCron::Config;
use ProxmodCron::Lease;
use ProxmodCron::Spec;

# The tick lease.
#
# WHAT THIS FILE CANNOT PROVE. The design rests on mkdir being an atomic
# cluster-wide test-and-set on pmxcfs. A tmpfs directory in a temporary tree is
# atomic within one kernel, which is enough to prove the logic around the
# primitive — who wins, who is told they lost, what happens when the parent is
# read-only — and not enough to prove the primitive itself. That claim is
# verified on a real two-node cluster and nowhere else, and the README says so.
#
# What is provable here, and worth as much: that a lost race and an unavailable
# lease are never confused with a won one, in either direction.

plan tests => 6;

my $JOB = 'nightly-backup';

sub wipe {
    File::Path::remove_tree(ProxmodCron::Config::lease_dir(), { safe => 0 });
    return;
}

# ---------------------------------------------------------------------------

subtest 'the first caller wins a tick and the rest are told they lost' => sub {
    plan tests => 8;

    wipe();

    my $tick = 1_800_000_000;

    my ($first, $why) = ProxmodCron::Lease::acquire($JOB, $tick, node => 'pve1');
    is($first, 'won', 'the first node to reach the tick claims it');
    is($why, undef, 'with nothing to explain');

    my ($second, $second_why) =
        ProxmodCron::Lease::acquire($JOB, $tick, node => 'pve2');
    is($second, 'taken', 'the second is told the tick is taken');
    is($second_why, undef, 'which is not an error and needs no reason');

    my ($third) = ProxmodCron::Lease::acquire($JOB, $tick, node => 'pve3');
    is($third, 'taken', 'and so is the third');

    # The next scheduled run is a different token and a fresh race. This is the
    # whole of the failover story: nothing hands the job over, the next tick
    # simply belongs to whoever is up to claim it.
    my ($next) = ProxmodCron::Lease::acquire($JOB, $tick + 86_400, node => 'pve2');
    is($next, 'won', 'the next scheduled run is a fresh race, won by another node');

    # And a different job's tick is nobody else's business.
    my ($other) = ProxmodCron::Lease::acquire('other-job', $tick, node => 'pve3');
    is($other, 'won', 'a different job at the same tick is independent');

    my $holder = ProxmodCron::Lease::holder($JOB, $tick);
    is($holder->{node}, 'pve1', 'and the winner is on record, which is what the UI shows');
};

subtest 'a lease that cannot be claimed is never mistaken for one that was' => sub {
    plan tests => 4;

    wipe();

    my $tick = 1_800_000_060;

    # A read-only parent is what pmxcfs presents the moment quorum is lost: the
    # mkdir fails with EROFS. It is the guard of last resort — a node that got
    # past the membership check somehow still cannot win.
    my $root = ProxmodCron::Config::lease_dir();
    File::Path::make_path("$root/$JOB");
    chmod(0500, "$root/$JOB");

    my ($result, $why) = ProxmodCron::Lease::acquire($JOB, $tick, node => 'pve1');

    isnt($result, 'won', 'an unwritable lease tree never yields a win');
    is($result, 'unavailable', 'it is unavailable, which is distinct from taken');
    ok(defined($why) && $why ne '', 'and it comes with a reason');
    like($why, qr/read-only|root/, 'naming quorum or privilege, the two real causes');

    chmod(0700, "$root/$JOB");
};

subtest 'the holder record follows the run without ever gating it' => sub {
    plan tests => 5;

    wipe();

    my $tick = 1_800_000_120;

    ProxmodCron::Lease::acquire($JOB, $tick, node => 'pve1', run => 'r-1');

    my $started = ProxmodCron::Lease::holder($JOB, $tick);
    is($started->{state}, 'running', 'the winner marks itself running before it runs');
    is($started->{run}, 'r-1', 'carrying the run id, so history and placement join up');

    ProxmodCron::Lease::note($JOB, $tick,
        { state => 'ok', exit => 0, duration_ms => 4200 });

    my $done = ProxmodCron::Lease::holder($JOB, $tick);
    is($done->{state}, 'ok', 'and updates it afterwards');
    is($done->{node}, 'pve1', 'without losing what was already there');
    is($done->{duration_ms}, 4200, 'numbers come back as numbers');
};

subtest 'a node that died mid-run leaves the tick claimed, and nothing reruns it' => sub {
    plan tests => 3;

    wipe();

    my $tick = 1_800_000_180;

    ProxmodCron::Lease::acquire($JOB, $tick, node => 'pve1', run => 'r-2');
    # pve1 is now gone. No note is ever written.

    my ($retry) = ProxmodCron::Lease::acquire($JOB, $tick, node => 'pve2');
    is($retry, 'taken', 'a survivor cannot take over the tick the dead node claimed');

    is(ProxmodCron::Lease::holder($JOB, $tick)->{state}, 'running',
        'the holder still says running, which is what doctor reports');

    # This is the property the design exists for: for one scheduled time, the
    # job ran at most once. A backup that half-ran is a problem; a backup that
    # ran twice concurrently is a worse one.
    my ($next) = ProxmodCron::Lease::acquire($JOB, $tick + 60, node => 'pve2');
    is($next, 'won', 'and the next scheduled run proceeds normally on the survivor');
};

subtest 'pruning keeps the recent past and drops everything else' => sub {
    plan tests => 5;

    wipe();

    my $base = 1_800_000_000;

    ProxmodCron::Lease::acquire($JOB, $base + 60 * $_, node => 'pve1') for (0 .. 9);
    ProxmodCron::Lease::acquire('deleted-job', $base, node => 'pve1');

    is(scalar @{ ProxmodCron::Lease::ticks($JOB) }, 10, 'ten ticks claimed');

    my $removed = ProxmodCron::Lease::prune({ $JOB => 1 });

    # A per-minute job would otherwise accumulate 1440 directories a day inside
    # a filesystem with a 30 MB ceiling shared with the rest of PVE's config.
    is(scalar @{ ProxmodCron::Lease::ticks($JOB) }, $ProxmodCron::Lease::KEEP,
        'pruning keeps only the newest few');

    is_deeply(ProxmodCron::Lease::ticks($JOB),
        [$base + 540, $base + 480, $base + 420],
        'and they are the newest ones, not an arbitrary few');

    ok($removed >= 8, 'it reports what it removed');

    # A job that no longer exists takes its whole lease tree with it, or the
    # tree grows forever with the ghosts of deleted jobs.
    is_deeply(ProxmodCron::Lease::ticks('deleted-job'), [],
        'a deleted job keeps nothing at all');
};

subtest 'the tick is derived from the schedule, not from the clock' => sub {
    plan tests => 5;

    # Two nodes fire the same job a fraction of a second apart at best, and
    # their clocks differ besides. They have to arrive at the same token without
    # talking to each other, and the only value both can compute is the minute
    # cron meant.
    my $schedule = '0 2 * * *';

    my $at_02_00_04 = ProxmodCron::Spec::tick($schedule, 1_800_000_004);
    my $at_02_00_57 = ProxmodCron::Spec::tick($schedule, 1_800_000_057);

    is($at_02_00_04, $at_02_00_57,
        'callers 53 seconds apart inside the same minute agree');
    is($at_02_00_04 % 60, 0, 'and the token is a whole minute');

    # A node whose cron fired a moment early, so that its clock has not quite
    # reached the scheduled minute, must not claim a different tick.
    my $every_minute = '* * * * *';
    isnt(ProxmodCron::Spec::tick($every_minute, 1_800_000_059),
        ProxmodCron::Spec::tick($every_minute, 1_800_000_061),
        'consecutive minutes of a per-minute job are different runs');

    is(ProxmodCron::Spec::tick($every_minute, 1_800_000_059),
        ProxmodCron::Spec::tick($every_minute, 1_800_000_000),
        'but one minute is one run however late in it the caller arrives');

    # @reboot has no scheduled minute at all, which is why run_on: any refuses
    # it. Asking anyway must still return something usable rather than dying.
    ok(defined ProxmodCron::Spec::tick('@reboot', 1_800_000_059),
        '@reboot still yields a value rather than an exception');
};
