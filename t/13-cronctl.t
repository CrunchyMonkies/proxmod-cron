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
use JSON::PP ();

use ProxmodCron::Cluster;
use ProxmodCron::Config;
use ProxmodCron::Journal;
use ProxmodCron::Lease;
use ProxmodCron::Render;
use ProxmodCron::State;

# proxmod-cronctl, run as the script an administrator runs.
#
# This is the surface that has to work when the UI does not — `proxmodctl
# disable` stops management, not execution — so it is exercised as a process
# with an argv, an exit status and two output streams, not as a set of functions.
# Every seam it needs is the same root-guarded environment override the rest of
# the suite uses: the config prefix, the journal socket, and journalctl itself.

plan tests => 13;

my $ROOT = ProxmodCron::Config::prefix();
my $CTL = "$FindBin::Bin/../exec/proxmod-cronctl";
my $PERL_DIR = "$FindBin::Bin/../perl";
my $TEST_LIB = "$FindBin::Bin/lib";

my $drain = ProxmodCronTest::journal_sink();
$ENV{PROXMOD_CRON_TEST_SOCKET} = ProxmodCron::Config::state_dir() . '/journal.sock';

# The wrapper where Render::wrap says it is, so `run` exercises the real path
# rather than a version of it the test invented. A shell shim, so the wait
# status — including a re-raised signal — reaches the caller unaltered.
{
    my $dir = "$ROOT/usr/lib/proxmod-cron";
    File::Path::make_path($dir);

    open(my $fh, '>', "$dir/proxmod-cron-exec") or die "cannot write the shim: $!\n";
    print {$fh} "#!/bin/sh\nexec $^X -I$PERL_DIR $FindBin::Bin/../exec/proxmod-cron-exec \"\$\@\"\n";
    close($fh);
    chmod(0755, "$dir/proxmod-cron-exec");
}

# Run the CLI. Streams are kept apart because several assertions are about which
# one a message came out of.
sub ctl {
    my (@args) = @_;

    my $out = "$ROOT/var/lib/proxmod/cron/ctl.out";
    my $err = "$ROOT/var/lib/proxmod/cron/ctl.err";

    my $pid = fork();
    die "cannot fork: $!\n" if !defined $pid;

    if ($pid == 0) {
        open(STDOUT, '>', $out) or POSIX::_exit(127);
        open(STDERR, '>', $err) or POSIX::_exit(127);
        my @cmd = ($^X, '-I', $PERL_DIR, '-I', $TEST_LIB, $CTL, @args);
        { exec { $cmd[0] } @cmd; }
        POSIX::_exit(127);
    }

    waitpid($pid, 0);
    my $status = $?;

    return {
        exit => $status >> 8,
        signal => $status & 127,
        out => ProxmodCronTest::slurp($out),
        err => ProxmodCronTest::slurp($err),
    };
}

sub store {
    my ($scope, $jobs, %extra) = @_;
    return ProxmodCronTest::write_store($scope, { version => 1, jobs => $jobs, %extra });
}

sub wipe {
    unlink(glob("$ROOT/etc/cron.d/*"));
    unlink(ProxmodCron::State::file());
    store('node', {});
    store('cluster', {});
    return;
}

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or die "cannot write $path: $!\n";
    print {$fh} $text;
    close($fh);
    return;
}

my $COMMAND_JOB = {
    type => 'command',
    schedule => '30 2 * * *',
    command => ['/bin/echo', 'hello'],
};

# ---------------------------------------------------------------------------

subtest 'usage, and an unknown command that does not look like success' => sub {
    plan tests => 6;

    my $help = ctl('--help');
    is($help->{exit}, 0, '--help exits 0');

    like($help->{out}, qr/\b$_\b/, "usage mentions $_")
        for qw(validate reindex doctor);

    my $bad = ctl('frobnicate');
    is($bad->{exit}, 2, 'an unknown command exits 2, not 0 and not 1');
    like($bad->{err}, qr/unknown command 'frobnicate'/, 'and names it on stderr');
};

subtest 'list shows what is defined, where it runs and who owns it' => sub {
    plan tests => 8;

    wipe();

    store('node', {
        'nightly-trim' => $COMMAND_JOB,
        'switched-off' => { %$COMMAND_JOB, enabled => JSON::PP::false() },
        'acme-backup' => {
            type => 'command', schedule => '@daily', command => ['/bin/true'],
            origin => 'extension', owner => 'acme',
        },
        'gone-away' => {
            type => 'command', schedule => '@daily', command => ['/bin/true'],
            origin => 'extension', owner => 'ghost',
        },
    });

    store('cluster', {
        'elsewhere' => { %$COMMAND_JOB, nodes => ['some-other-node'] },
    });

    local $ENV{PROXMOD_CRON_TEST_EXTENSIONS} = 'acme';

    my $r = ctl('list');
    is($r->{exit}, 0, 'list exits 0');

    my %row = map { /\A(\S+)\s+(\S+)\s+(\S+)\s+(.*)\z/ ? ($3 => "$1 $2 $4") : () }
        split(/\n/, $r->{out});

    like($row{'nightly-trim'}, qr/\Aon node /, 'an enabled node job');
    like($row{'switched-off'}, qr/\Aoff node /, 'a disabled one says so');

    like($row{'acme-backup'}, qr/\bacme\b/, 'an extension-owned job names its owner');
    like($row{'gone-away'}, qr/\bghost \(orphaned\)/,
        'and one whose owner is not loaded is marked orphaned');

    like($row{'elsewhere'}, qr/not on this node/,
        'a cluster job targeting another node reports that rather than a next run');
    like($row{'nightly-trim'}, qr/never run/, 'no cache record reads as never run');

    wipe();
    like(ctl('list')->{out}, qr/no jobs defined/, 'an empty store says so plainly');
};

subtest 'show, including the last run and an id that does not exist' => sub {
    plan tests => 8;

    wipe();
    store('node', { 'nightly-trim' => { %$COMMAND_JOB, comment => 'fstrim all mounts' } });

    ProxmodCron::State::record('node', 'nightly-trim', {
        run => '1739000000000-abcdef01',
        started => 1739000000,
        finished => 1739000012,
        exit => 3,
        signal => 0,
        duration_ms => 12000,
        lines => 4,
        truncated => 0,
        state => 'failed',
        tail => ['stdout: working', 'stderr: trouble'],
    });

    my $r = ctl('show', 'nightly-trim');
    is($r->{exit}, 0, 'show exits 0');

    like($r->{out}, qr/^type\s+command$/m, 'the type');
    like($r->{out}, qr/^comment\s+fstrim all mounts$/m, 'the comment');
    like($r->{out}, qr{^command\s+\Q$ROOT\E/usr/lib/proxmod-cron/proxmod-cron-exec node nightly-trim --type command -- /bin/echo hello$}m,
        'the command as cron would run it, wrapper included');
    like($r->{out}, qr/^next runs\s+\d{4}-\d\d-\d\d \d\d:\d\d:\d\d, /m, 'three next runs');

    like($r->{out}, qr/result\s+exit 3/, 'the last run result');
    like($r->{out}, qr/stderr: trouble/, 'and its output tail');

    my $missing = ctl('show', 'no-such-job');
    like($missing->{err}, qr/no job named 'no-such-job'/, 'an unknown id is an error, not an empty report')
        or diag($missing->{out});
};

subtest 'validate reports what a write would have refused' => sub {
    plan tests => 6;

    wipe();
    store('node', { 'nightly-trim' => $COMMAND_JOB });

    my $clean = ctl('validate');
    is($clean->{exit}, 0, 'a valid store exits 0');
    like($clean->{out}, qr/1 job checked, no problems found/, 'and says how many it checked');

    store('node', {
        'bad-schedule' => { %$COMMAND_JOB, schedule => '99 * * * *' },
        'bad-type' => { type => 'no-such-type', schedule => '@daily' },
    });

    my $r = ctl('validate');
    is($r->{exit}, 1, 'problems exit 1, so a check job can branch on it');
    like($r->{out}, qr/bad-schedule.*schedule/, 'the bad schedule is named with its job');
    like($r->{out}, qr/bad-type.*unknown job type 'no-such-type'/, 'and the unknown type');
    like($r->{out}, qr/2 jobs checked, 2 problems found/, 'with a count of both');
};

subtest 'render, and --diff as the drift check it is meant to be' => sub {
    plan tests => 7;

    wipe();
    store('node', { 'nightly-trim' => $COMMAND_JOB });

    my $path = ProxmodCron::Render::path('node');

    my $r = ctl('render', '--scope', 'node');
    is($r->{exit}, 0, 'render exits 0');
    like($r->{out}, qr/^# \Q$path\E$/m, 'naming the file it would write');
    like($r->{out}, qr/^30 2 \* \* \*\troot\t/m, 'with the crontab line');

    ctl('sync');

    my $in_step = ctl('render', '--diff');
    is($in_step->{exit}, 0, 'in step with disk, --diff exits 0');
    like($in_step->{out}, qr/\Q$path\E: unchanged/, 'and says unchanged');

    my $edited = ProxmodCronTest::slurp($path);
    $edited =~ s/^30 2/45 2/m;
    write_file($path, $edited);

    my $drift = ctl('render', '--diff');
    is($drift->{exit}, 1, 'a hand-edited file exits 1');
    like($drift->{out}, qr/^  - 45 2 .*\n  \+ 30 2 /m, 'showing what would be put back');
};

subtest 'sync writes once and then leaves the file alone' => sub {
    plan tests => 5;

    wipe();
    store('node', { 'nightly-trim' => $COMMAND_JOB });

    my $path = ProxmodCron::Render::path('node');

    my $first = ctl('sync');
    is($first->{exit}, 0, 'sync exits 0');
    like($first->{out}, qr/^node: written$/m, 'reporting the file it wrote');
    ok(-f $path, 'and the file is there');

    my $second = ctl('sync');
    like($second->{out}, qr/^node: unchanged$/m, 'a second sync writes nothing');

    store('node', {});
    ctl('sync');
    ok(!-e $path, 'and a store with no jobs removes the generated file');
};

subtest 'run puts a manual run through the same wrapper cron uses' => sub {
    plan tests => 8;

    wipe();
    $drain->();

    store('node', {
        'says-hello' => { type => 'command', schedule => '@daily',
            command => ['/bin/echo', 'hello from cron'] },
        'fails' => { type => 'command', schedule => '@daily',
            command => ['/bin/sh', '-c', 'exit 3'] },
        'untracked' => { type => 'command', schedule => '@daily',
            track => JSON::PP::false(), command => ['/bin/true'] },
    });

    my $r = ctl('run', 'says-hello');
    is($r->{exit}, 0, 'a successful job exits 0');
    like($r->{out}, qr/proxmod-cron-exec node says-hello --type command -- /, 'the argv is shown before it runs');
    like($r->{out}, qr/^finished$/m, 'and the result after');

    my @entries = @{ $drain->() };
    ok(scalar(grep { ($_->{PROXMOD_CRON_EVENT} || '') eq 'finish' } @entries),
        'the run was journalled, so a manual run lands in the same history');
    ok(scalar(grep { ($_->{MESSAGE} || '') =~ /hello from cron/ } @entries),
        'output included');

    my $record = ProxmodCron::State::get('node', 'says-hello');
    is($record->{state}, 'ok', 'and the status cache was updated');

    my $failed = ctl('run', 'fails');
    is($failed->{exit}, 3, "the job's exit status is the CLI's exit status");

    $drain->();
    ctl('run', 'untracked');
    is(scalar(@{ $drain->() }), 0, 'a job with track: false is run directly, with nothing journalled');
};

subtest 'runs and log read history back out of journald' => sub {
    plan tests => 10;

    wipe();
    store('node', { 'nightly-trim' => $COMMAND_JOB });

    # Run ids are hex-suffixed because ProxmodCron::Runs untaints them against
    # that pattern before they reach an argv — a fixture id it would reject
    # would test the rejection, not the query.
    my $first = '1739000000000-000000a1';
    my $second = '1739000100000-000000a2';

    my @entries = (
        entry(1739000000, 'start', run => $first),
        entry(1739000005, 'finish', run => $first, exit => 0, duration => 5000, lines => 0),
        entry(1739000100, 'start', run => $second),
        entry(1739000101, 'output', run => $second, stream => 'stdout', message => 'working', seq => 1),
        # Sequence 2 and 3 are not here: this is a run journald rate-limited,
        # which is the ordinary way a fixture like this one arises in production.
        entry(1739000102, 'output', run => $second, stream => 'stderr', message => 'trouble', seq => 4),
        entry(1739000110, 'finish', run => $second, exit => 3, duration => 10000, lines => 4),
    );

    my $argv_log = ProxmodCronTest::journalctl_stub(\@entries);

    my $r = ctl('runs', 'nightly-trim');
    is($r->{exit}, 0, 'runs exits 0');

    my @rows = grep { /\A1739/ } split(/\n/, $r->{out});
    is(scalar(@rows), 2, 'two runs folded out of six entries');
    like($rows[0], qr/failed\s+3\b/, 'newest first, with its exit status');
    like($rows[1], qr/\bok\b/, 'and the older one below it');

    my $argv = ProxmodCronTest::slurp($argv_log) || '';
    like($argv, qr/^PROXMOD_CRON_JOB=nightly-trim$/m, 'the query was anchored to the job');
    like($argv, qr/^SYSLOG_IDENTIFIER=proxmod-cron$/m, 'and to our identifier');

    my $log = ctl('log', $second);
    like($log->{out}, qr/^  working$/m, 'stdout lines are plain');
    like($log->{out}, qr/^E trouble$/m, 'stderr lines are marked');
    # Said out loud between the two lines it happened between. Printing 'working'
    # and 'trouble' with nothing between them would show a two-line run, which is
    # not what ran.
    like($log->{out}, qr/^--- 2 lines missing from the journal ---$/m,
        'and what the journal dropped is reported rather than quietly skipped');

    my $gone = ctl('log', '1739999999999-deadbeef');
    like($gone->{out}, qr/no longer in the journal/,
        'a run journald has rotated away says so rather than showing an empty box');
};

subtest 'reindex rebuilds the cache the wrapper wrote, byte for byte' => sub {
    plan tests => 9;

    wipe();
    $drain->();

    # max_lines is deliberately tiny so 'noisy' trips the line cap on its fourth
    # echo rather than on its ten-thousandth, while 'chatty' stays just under it.
    store('node', {
        'chatty' => { type => 'command', schedule => '@daily',
            command => ['/bin/sh', '-c', 'echo one; echo two >&2; echo three'] },
        'noisy' => { type => 'command', schedule => '@daily',
            command => ['/bin/sh', '-c', 'echo a; echo b; echo c; echo d'] },
    }, max_lines => 3);

    ctl('run', 'chatty');
    ctl('run', 'noisy');

    my $written = ProxmodCronTest::slurp(ProxmodCron::State::file());
    ok(defined $written && $written =~ /chatty/, 'the wrapper wrote a cache record');

    my $record = ProxmodCron::State::get('node', 'chatty');
    is(scalar(@{ $record->{tail} }), 3, 'with all three output lines in its tail');

    my $capped = ProxmodCron::State::get('node', 'noisy');
    is($capped->{truncated}, 1, 'the capped run is flagged truncated');
    unlike(join("\n", @{ $capped->{tail} }), qr/output truncated/,
        'and its tail is what the job said, not our notice about it');

    # journald stamps its own clock on arrival, and that reading is not the one
    # the wrapper wrote into the cache. Skew every entry by five seconds: a
    # rebuild that took `started` or `finished` from the receive timestamp
    # instead of from the wrapper's own fields would now be five seconds out,
    # which is the difference this test exists to catch.
    my $SKEW = 5;

    my @sent = @{ $drain->() };
    my $seq = 0;

    my @fixture = map {
        my $when = ($record->{started} + $SKEW) * 1_000_000;
        # A leading '+' or perl reads this as a block and returns a flat list.
        +{ %$_, __REALTIME_TIMESTAMP => $when, __CURSOR => 'c' . $seq++ };
    } @sent;

    ok(scalar(@fixture) >= 9, 'both runs produced their start, output and finish records');

    ok(scalar(grep { ($_->{PROXMOD_CRON_NOTICE} || '') eq 'truncated' } @fixture),
        'including the truncation notice, tagged as ours rather than the job\'s');

    ProxmodCronTest::journalctl_stub(\@fixture);

    unlink(ProxmodCron::State::file());
    ok(!-e ProxmodCron::State::file(), 'the cache is deleted, as §5.5 says it may be');

    my $rebuilt = ctl('reindex');
    like($rebuilt->{out}, qr/rebuilt 2 records from the journal/, 'reindex reports what it did');

    is(ProxmodCronTest::slurp(ProxmodCron::State::file()), $written,
        'and the rebuilt cache is byte-identical to the one the wrapper wrote');
};

subtest 'doctor finds the things that break cron and logging silently' => sub {
    plan tests => 11;

    wipe();
    store('node', { 'nightly-trim' => $COMMAND_JOB });

    my $anchor = ProxmodCron::Config::cron_d() . '/proxmod-cron';
    unlink($anchor);

    my $r = ctl('doctor');
    is($r->{exit}, 2, 'an error exits 2');
    like($r->{out}, qr/^ERROR .*anchor.*is missing/m,
        'a missing anchor is the error, because nothing runs without it');

    write_file($anchor, "* * * * * root /usr/lib/proxmod-cron/proxmod-cron-sync\n");

    my $drift = ctl('doctor');
    like($drift->{out}, qr/^WARNING .*differs from what would be rendered/m,
        'an unrendered store is drift the next sync would overwrite');

    # The status is what a monitoring check reads. A warning means something is
    # quietly not working, so it cannot share an exit code with a clean run.
    is($drift->{exit}, 1, 'warnings alone exit 1');

    ctl('sync');

    my $path = ProxmodCron::Render::path('node');
    chmod(0664, $path);

    my $writable = ctl('doctor');
    like($writable->{out}, qr/^ERROR .*group- or world-writable/m,
        'cron ignores a writable file in cron.d, so that is an error');
    chmod(0644, $path);

    store('node', {
        'nightly-trim' => $COMMAND_JOB,
        'silent' => { %$COMMAND_JOB, track => JSON::PP::false() },
    });
    ctl('sync');

    my $mailto = ctl('doctor');
    like($mailto->{out}, qr/^WARNING\s+node job 'silent' is not tracked.*discarded/m,
        'track: false under an empty MAILTO throws the output away');
    is($mailto->{exit}, 1, 'and that warning is enough to make the status non-zero');

    like($mailto->{out}, qr/^WARNING .*journald is volatile/m,
        'a host with no persistent journal is warned about');

    File::Path::make_path("$ROOT/var/log/journal");
    my $persistent = ctl('doctor');
    like($persistent->{out}, qr/^ok .*survives a reboot/m, 'and told so once it does');

    write_file("$ROOT/etc/systemd/journald.conf", "[Journal]\nRateLimitBurst=100\n")
        if File::Path::make_path("$ROOT/etc/systemd") || -d "$ROOT/etc/systemd";

    like(ctl('doctor')->{out}, qr/^ok\s+journald rate limit: RateLimitBurst=100$/m,
        'the rate limit is reported, because it drops entries rather than delaying them');

    store('node', { 'nightly-trim' => $COMMAND_JOB });
    ctl('sync');
    is(ctl('doctor')->{exit}, 0, 'a healthy host exits 0');
};

subtest 'run by hand takes the node it was told to, and says when it will not' => sub {
    plan tests => 8;

    wipe();
    $drain->();

    my $marker = ProxmodCron::Config::state_dir() . '/forced';
    unlink($marker);

    store('cluster', {
        'cluster-echo' => { type => 'command', schedule => '@daily',
            command => ['/bin/sh', '-c', "echo forced > '$marker'"] },
    });

    # A minority partition. Every cluster job stands down here, including one
    # started by hand — the operator's shell is inside the half of the cluster
    # that cannot see the other half.
    ProxmodCronTest::cluster_members(nodename => 'pve3', quorate => 0,
        nodes => { pve1 => 0, pve2 => 0, pve3 => 1 });

    my $blocked = ctl('run', 'cluster-echo', '--scope', 'cluster');

    is($blocked->{exit}, 0, 'the manual run exits cleanly');
    like($blocked->{out}, qr/--require-quorum/, 'the guard is visible in the argv it shows');
    ok(!-e $marker, 'and the job did not run');

    # There is one honest use for --force: a node that is deliberately isolated.
    # It is spelled out rather than assumed, because on a split cluster it is
    # exactly how the same job ends up running in both halves.
    my $forced = ctl('run', 'cluster-echo', '--scope', 'cluster', '--force');

    is($forced->{exit}, 0, '--force runs it anyway');
    unlike($forced->{out}, qr/--require-quorum/, 'with the guard dropped from the argv');
    is(ProxmodCronTest::slurp($marker), "forced\n", 'and the job really ran');

    # A manual run must never lose a race to a scheduled tick on another node:
    # the operator picked this node and this moment, which is the choice the
    # lease exists to make.
    store('cluster', {
        'cluster-once' => { type => 'command', schedule => '30 2 * * *',
            run_on => 'any', command => ['/bin/true'] },
    });
    ProxmodCronTest::cluster_members();

    my $once = ctl('run', 'cluster-once', '--scope', 'cluster');
    unlike($once->{out}, qr/--once/, 'a manual run never claims a tick');
    is($once->{exit}, 0, 'and runs');

    unlink($marker);
};

subtest 'leases show where a job that moves has actually been running' => sub {
    plan tests => 7;

    wipe();
    File::Path::remove_tree(ProxmodCron::Config::lease_dir(), { safe => 0 });
    ProxmodCronTest::cluster_members();

    is(ctl('leases')->{out}, "no cluster jobs use run_on: any\n",
        'a cluster with no moving jobs says so rather than printing an empty table');

    store('cluster', {
        'moves' => { type => 'command', schedule => '*/5 * * * *',
            run_on => 'any', command => ['/bin/true'] },
        'everywhere' => { type => 'command', schedule => '@daily',
            command => ['/bin/true'] },
    });

    like(ctl('leases')->{out}, qr/no run has been claimed yet/,
        'a job that has never fired says that, rather than nothing at all');

    my $tick = 1_800_000_000;
    ProxmodCron::Lease::acquire('moves', $tick, node => 'pve1', run => 'r-1');
    ProxmodCron::Lease::note('moves', $tick, { state => 'ok', duration_ms => 1200 });
    ProxmodCron::Lease::acquire('moves', $tick + 300, node => 'pve2', run => 'r-2');

    my $r = ctl('leases');

    is($r->{exit}, 0, 'the command succeeds');
    like($r->{out}, qr/^JOB\s+SCHEDULED RUN\s+NODE\s+RESULT\s+DURATION/m, 'with a header');
    like($r->{out}, qr/moves\s+\S+ \S+\s+pve1\s+ok\s+1200 ms/, 'a finished run, and where');
    like($r->{out}, qr/moves\s+\S+ \S+\s+pve2\s+running/,
        'and one still in progress, which is what a mid-run death looks like too');

    # run_on: all is not placement, so it has no lease and no row here. Listing
    # it would suggest one node ran it, which is the opposite of the truth.
    unlike($r->{out}, qr/everywhere/, 'a job that runs on every node has no lease to show');
};

subtest 'doctor reports the cluster this node believes it is in' => sub {
    plan tests => 8;

    wipe();
    store('cluster', {
        'moves' => { type => 'command', schedule => '*/5 * * * *',
            run_on => 'any', command => ['/bin/true'] },
    });
    File::Path::remove_tree(ProxmodCron::Config::lease_dir(), { safe => 0 });
    ctl('sync');

    ProxmodCronTest::cluster_members();
    like(ctl('doctor')->{out}, qr/^ok .*not clustered.*unconditionally/m,
        'a standalone host is told its cluster jobs run here regardless');

    ProxmodCronTest::cluster_members(nodename => 'pve1', quorate => 1,
        nodes => { pve1 => 1, pve2 => 1, pve3 => 0 });
    my $partial = ctl('doctor');
    like($partial->{out}, qr/^ok\s+this node is quorate; offline: pve3$/m,
        'a quorate node names the members that are down');

    ProxmodCronTest::cluster_members(nodename => 'pve3', quorate => 0,
        nodes => { pve1 => 0, pve2 => 0, pve3 => 1 });
    my $split = ctl('doctor');
    like($split->{out}, qr/^ERROR .*not quorate.*stand down/m,
        'losing quorum is an error, because jobs stop running because of it');
    is($split->{exit}, 2, 'and it is the exit status a monitoring check reads');

    # The state that is hardest to diagnose from anywhere else: the sync anchor
    # has stopped, so the cache non-root wrappers read is frozen at whatever it
    # last saw. Nothing else on the host mentions it.
    unlink(ProxmodCron::Config::prefix() . '/etc/pve/.members');
    ProxmodCron::Cluster::cache_write({ known => 1, quorate => 1, standalone => 0,
        nodename => 'pve1', nodes => { pve1 => { online => 1 } } });

    my $cache = ProxmodCron::Cluster::cache_file();
    my $raw = ProxmodCronTest::slurp($cache);
    my $old = time() - $ProxmodCron::Cluster::STALE_AFTER - 60;
    $raw =~ s/"updated"\s*:\s*\d+/"updated" : $old/;
    write_file($cache, $raw);

    like(ctl('doctor')->{out}, qr/proxmod-cron-sync is not running on this node/,
        'a stale membership cache names the thing that has stopped');

    # A tick nobody ever finished. Nothing re-runs it by design, so this warning
    # is the only place in the package it is ever mentioned.
    unlink($cache);
    ProxmodCronTest::cluster_members();
    ProxmodCron::Lease::acquire('moves', 1_700_000_000, node => 'pve2', run => 'r-9');

    my $stale = ctl('doctor');
    like($stale->{out}, qr/^WARNING .*'moves' was claimed by pve2 .*never finished/m,
        'a lease left running is reported');
    like($stale->{out}, qr/nothing re-runs that run/,
        'together with the fact that nothing will pick it up');

    ProxmodCron::Lease::note('moves', 1_700_000_000, { state => 'ok' });
    unlike(ctl('doctor')->{out}, qr/never finished/,
        'and a finished one is not');

    File::Path::remove_tree(ProxmodCron::Config::lease_dir(), { safe => 0 });
    ProxmodCronTest::cluster_members();
};

# A journalctl -o json entry, as ProxmodCron::Runs expects to decode one.
sub entry {
    my ($when, $event, %opt) = @_;

    my $run = $opt{run};

    my %fields = (
        SYSLOG_IDENTIFIER => 'proxmod-cron',
        __REALTIME_TIMESTAMP => $when * 1_000_000,
        __CURSOR => "cursor-$when",
        PROXMOD_CRON_JOB => 'nightly-trim',
        PROXMOD_CRON_SCOPE => 'node',
        PROXMOD_CRON_TYPE => 'command',
        PROXMOD_CRON_RUN => $run,
        PROXMOD_CRON_EVENT => $event,
        MESSAGE => defined($opt{message}) ? $opt{message} : "$event nightly-trim",
    );

    $fields{PROXMOD_CRON_STREAM} = $opt{stream} if defined $opt{stream};
    $fields{PROXMOD_CRON_SEQ} = $opt{seq} if defined $opt{seq};
    $fields{PROXMOD_CRON_EXIT} = $opt{exit} if defined $opt{exit};
    $fields{PROXMOD_CRON_SIGNAL} = 0 if defined $opt{exit};
    $fields{PROXMOD_CRON_DURATION_MS} = $opt{duration} if defined $opt{duration};
    $fields{PROXMOD_CRON_LINES} = $opt{lines} if defined $opt{lines};

    return \%fields;
}
