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

use Fcntl qw(LOCK_EX LOCK_NB);

use ProxmodCron::Config;
use ProxmodCron::Runs;

# Reading run history back out of journald.
#
# The folding is pure and is driven from fixtures, because the interesting cases
# — a start whose finish never arrived, a run whose start has aged out, a field
# journalctl rendered as an array — are ones a live journal will not produce on
# demand.
#
# What is not faked: the argv. The last subtest points $JOURNALCTL at a real
# program and asserts what actually reaches its @ARGV, because every match in
# that list is built from a request parameter and none of it may go near a
# shell.

plan tests => 11;

my $EPOCH = 1_739_000_000;

sub at { my ($offset) = @_; return ($EPOCH + $offset) * 1_000_000 }

sub entry {
    my (%fields) = @_;

    my $offset = delete $fields{at};
    my $cursor = delete $fields{cursor};

    my %out = (
        SYSLOG_IDENTIFIER => 'proxmod-cron',
        __REALTIME_TIMESTAMP => at(defined($offset) ? $offset : 0),
        %fields,
    );

    $out{__CURSOR} = $cursor if defined $cursor;

    return \%out;
}

# One complete run: start, then finish.
sub run_entries {
    my (%opt) = @_;

    my $run = $opt{run};
    my $at = $opt{at} || 0;

    my @out = (entry(
        at => $at,
        cursor => "s=1;i=$run-start",
        PROXMOD_CRON_EVENT => 'start',
        PROXMOD_CRON_RUN => $run,
        PROXMOD_CRON_JOB => $opt{job} || 'nightly-trim',
        PROXMOD_CRON_SCOPE => $opt{scope} || 'node',
        PROXMOD_CRON_TYPE => 'command',
        MESSAGE => 'started',
    ));

    return @out if $opt{unfinished};

    push @out, entry(
        at => $at + 2,
        cursor => "s=1;i=$run-finish",
        PROXMOD_CRON_EVENT => 'finish',
        PROXMOD_CRON_RUN => $run,
        PROXMOD_CRON_JOB => $opt{job} || 'nightly-trim',
        PROXMOD_CRON_SCOPE => $opt{scope} || 'node',
        PROXMOD_CRON_EXIT => defined($opt{exit}) ? $opt{exit} : 0,
        PROXMOD_CRON_SIGNAL => $opt{signal} || 0,
        PROXMOD_CRON_DURATION_MS => 2000,
        PROXMOD_CRON_LINES => defined($opt{lines}) ? $opt{lines} : 3,
        PROXMOD_CRON_TRUNCATED => $opt{truncated} ? 1 : 0,
        MESSAGE => 'finished',
    );

    return @out;
}

sub hold_lock {
    my ($scope, $id) = @_;

    my $path = ProxmodCron::Config::job_lock_path($scope, $id);
    open(my $fh, '>>', $path) or die "cannot open $path: $!\n";
    flock($fh, LOCK_EX | LOCK_NB) or die "cannot lock $path: $!\n";

    return $fh;
}

# ---------------------------------------------------------------------------

subtest 'entries fold into runs' => sub {
    plan tests => 9;

    my $runs = ProxmodCron::Runs::fold([
        run_entries(run => '1739000000000-aaaaaaaa', at => 0),
        run_entries(run => '1739000100000-bbbbbbbb', at => 100, exit => 3, lines => 12),
    ]);

    is(scalar(@$runs), 2, 'two runs from four entries');

    my ($first, $second) = @$runs;

    is($first->{run}, '1739000000000-aaaaaaaa', 'keyed by run id');
    is($first->{job}, 'nightly-trim', 'carrying the job');
    is($first->{started}, $EPOCH, 'the start time comes from the start record');
    is($first->{finished}, $EPOCH + 2, 'and the end from the finish record');
    is($first->{duration_ms}, 2000, 'with the duration the wrapper measured');
    is($first->{state}, 'ok', 'a zero exit is ok');

    is($second->{exit}, 3, 'and the second run kept its own exit status');
    is($second->{lines}, 12, 'and its own line count');
};

subtest "a run is timed by the wrapper's clock, not by journald's" => sub {
    plan tests => 4;

    # PROXMOD_CRON_STARTED is the same reading proxmod-cron-exec wrote into the
    # status cache. journald stamps its own when the datagram arrives, and the
    # two are a different reading of the same instant — close, but not equal.
    # `proxmod-cronctl reindex` rebuilds the cache from these entries, so a fold
    # that preferred the receive timestamp would produce a cache that disagrees
    # with the one the wrapper wrote, by a second, with nothing to explain it.
    my @entries = run_entries(run => '1739000000000-cccccccc', at => 0);
    $_->{PROXMOD_CRON_STARTED} = $EPOCH - 4 for @entries;

    my $run = ProxmodCron::Runs::fold(\@entries)->[0];

    is($run->{started}, $EPOCH - 4, "started is the wrapper's, not the journal's");
    is($run->{finished}, $EPOCH - 2,
        'and finished is that plus the duration it measured, for the same reason');

    # Without the field there is nothing better to use, and an older record that
    # predates it must still fold.
    delete $_->{PROXMOD_CRON_STARTED} for @entries;

    my $legacy = ProxmodCron::Runs::fold(\@entries)->[0];

    is($legacy->{started}, $EPOCH, 'a record without it falls back to the journal');
    is($legacy->{finished}, $EPOCH + 2, 'and is folded exactly as before');
};

subtest 'a run with no finish is only running while its lock is held' => sub {
    plan tests => 6;

    my $entries = [run_entries(run => '1739000200000-cccccccc', at => 200, unfinished => 1)];

    my $held = hold_lock('node', 'nightly-trim');

    my $running = ProxmodCron::Runs::fold($entries)->[0];
    is($running->{state}, 'running', 'a start with no finish and a held lock is running');
    ok(!defined $running->{finished}, 'with no end time invented for it');

    close($held);

    # A node that lost power mid-job leaves a start record and no finish, and
    # nothing will ever write one. Reporting that as `running` forever would make
    # the grid permanently wrong, and would make the wrapper's own overlap
    # protection look broken.
    my $orphan = ProxmodCron::Runs::fold($entries)->[0];
    is($orphan->{state}, 'unknown', 'once the lock is gone it is unknown, not running');

    is(ProxmodCron::Runs::lock_held('node', 'nightly-trim'), 0,
        'and the check says the same on its own');

    # Testing the lock must not take it: proxmod-cron-exec runs from cron a
    # moment later and would find it held by a read.
    my $second = hold_lock('node', 'nightly-trim');
    ok($second, 'testing the lock does not leave it held');
    close($second);

    is(ProxmodCron::Runs::lock_held('node', 'never-ran'), 0,
        'a job that never ran has no lock file and is not running');
};

subtest 'the other states, each from what actually happened' => sub {
    plan tests => 5;

    my %state = map {
        my $run = ProxmodCron::Runs::fold([run_entries(run => "1739000000000-$_->{id}", %{ $_->{opt} })])->[0];
        ($_->{name} => $run->{state});
    } (
        { name => 'ok', id => 'a0000000', opt => {} },
        { name => 'failed', id => 'a0000001', opt => { exit => 1 } },
        { name => 'killed', id => 'a0000002', opt => { exit => 0, signal => 9 } },
    );

    is($state{ok}, 'ok', 'exit 0 is ok');
    is($state{failed}, 'failed', 'a non-zero exit is failed');

    # Signal beats exit: a killed process reports exit 0 in the high byte, and a
    # state derived from the exit alone would call a SIGKILLed backup a success.
    is($state{killed}, 'killed', 'a signal is killed, whatever the exit says');

    my $skipped = ProxmodCron::Runs::fold([entry(
        at => 5,
        PROXMOD_CRON_EVENT => 'skipped',
        PROXMOD_CRON_RUN => '1739000000000-a0000003',
        PROXMOD_CRON_JOB => 'nightly-trim',
        PROXMOD_CRON_SCOPE => 'node',
        MESSAGE => "skipped node job 'nightly-trim': a previous run is still in progress",
    )])->[0];

    is($skipped->{state}, 'skipped', 'a skip is its own state, not a failure');
    like($skipped->{message}, qr/still in progress/, 'and keeps the reason');
};

subtest 'a run whose start has aged out is still reported' => sub {
    plan tests => 3;

    # journald retention is time-based, so the oldest entries of an in-flight
    # window disappear first. Hiding a run because its start is gone would make
    # history look like it had holes in it.
    my $run = ProxmodCron::Runs::fold([entry(
        at => 60,
        PROXMOD_CRON_EVENT => 'finish',
        PROXMOD_CRON_RUN => '1739000000000-dddddddd',
        PROXMOD_CRON_JOB => 'nightly-trim',
        PROXMOD_CRON_SCOPE => 'node',
        PROXMOD_CRON_EXIT => 0,
        PROXMOD_CRON_DURATION_MS => 500,
        MESSAGE => 'finished',
    )])->[0];

    is($run->{state}, 'ok', 'the run is reported with the state its finish record gives');
    is($run->{finished}, $EPOCH + 60, 'the finish time is real');
    is($run->{started}, $EPOCH + 60,
        'and the start falls back to it rather than being left undefined for the UI to render');
};

subtest 'the history query asks for runs, not for output' => sub {
    plan tests => 6;

    my @seen;
    local $ProxmodCron::Runs::RUNNER = sub {
        my ($args) = @_;
        push @seen, $args;
        return [];
    };

    ProxmodCron::Runs::list(job => 'nightly-trim', scope => 'node', since => '-7d', limit => 10);

    my $args = $seen[0];

    ok(scalar(grep { $_ eq 'SYSLOG_IDENTIFIER=proxmod-cron' } @$args),
        'every query is anchored to our identifier');
    ok(scalar(grep { $_ eq 'PROXMOD_CRON_JOB=nightly-trim' } @$args), 'and to the job');
    ok(scalar(grep { $_ eq 'PROXMOD_CRON_SCOPE=node' } @$args), 'and the scope');

    # A job that prints 100 000 lines would otherwise drown its own history:
    # journalctl's -n counts entries, so the output records would fill the window
    # before a single finish record was reached.
    ok(!scalar(grep { $_ eq 'PROXMOD_CRON_EVENT=output' } @$args),
        'output records are excluded from the history query');
    is(scalar(grep { /\APROXMOD_CRON_EVENT=/ } @$args), 3,
        'which leaves start, finish and skipped');

    # Junk in a time parameter reaches an exec argument list, so it is matched
    # against a pattern rather than filtered.
    @seen = ();
    ProxmodCron::Runs::list(since => "yesterday; rm -rf /");
    ok(!scalar(grep { $_ eq '--since' } @{ $seen[0] }),
        'a since value that is not a time is dropped rather than passed on');
};

subtest 'the newest runs come back first, and the limit counts runs' => sub {
    plan tests => 4;

    my @entries;
    for my $i (1 .. 5) {
        push @entries, run_entries(
            run => sprintf('17390000%02d000-a000000%d', $i * 10, $i),
            at => $i * 10,
        );
    }

    ProxmodCronTest::journal_runner(\@entries);

    my $runs = ProxmodCron::Runs::list(job => 'nightly-trim', limit => 3);

    is(scalar(@$runs), 3, 'the limit applies to runs');

    # One run is up to three entries, so a limit passed straight through as
    # journalctl's -n would return a third of the runs asked for.
    is($runs->[0]{started}, $EPOCH + 50, 'newest first');
    is($runs->[2]{started}, $EPOCH + 30, 'oldest of the three last');

    my $one = ProxmodCron::Runs::get('1739000030000-a0000003');
    is($one->{run}, '1739000030000-a0000003', 'and a single run can be fetched by id');
};

subtest 'output paginates by cursor, with no gaps and no repeats' => sub {
    plan tests => 7;

    my $run = '1739000000000-eeeeeeee';

    my @entries = map {
        entry(
            at => $_,
            cursor => "s=1;i=$_",
            PROXMOD_CRON_EVENT => 'output',
            PROXMOD_CRON_RUN => $run,
            PROXMOD_CRON_JOB => 'nightly-trim',
            PROXMOD_CRON_STREAM => ($_ % 2 ? 'stderr' : 'stdout'),
            PRIORITY => ($_ % 2 ? 4 : 6),
            MESSAGE => "line $_",
        );
    } (1 .. 6);

    ProxmodCronTest::journal_runner(\@entries);

    my $first = ProxmodCron::Runs::output($run, limit => 3);

    is(scalar(@{ $first->{lines} }), 3, 'the first page is the size asked for');
    is($first->{lines}[0]{text}, 'line 4', 'a full page is the newest entries, as journalctl gives them');
    is($first->{cursor}, 's=1;i=6', 'and the page reports the cursor it ended on');
    is($first->{done}, 0, 'a full page means there may be more');

    # Cursor, not offset. A live tail polls while the run is still writing, and
    # an offset would skip or repeat lines as entries arrive between polls.
    my $second = ProxmodCron::Runs::output($run, limit => 3, cursor => $first->{cursor});

    is_deeply($second->{lines}, [], 'resuming after that cursor returns nothing new');
    is($second->{done}, 1, 'and says so');

    is($first->{lines}[0]{stream}, 'stdout', 'each line carries the stream it came from');
};

subtest 'output is sanitised before it ever reaches a browser' => sub {
    plan tests => 4;

    my $run = '1739000000000-ffffffff';

    ProxmodCronTest::journal_runner([
        entry(
            at => 1, cursor => 's=1;i=90',
            PROXMOD_CRON_EVENT => 'output', PROXMOD_CRON_RUN => $run,
            PROXMOD_CRON_STREAM => 'stdout',
            MESSAGE => "clear\x1b[2Jscreen\x00null\x07bell",
        ),
        entry(
            at => 2, cursor => 's=1;i=91',
            PROXMOD_CRON_EVENT => 'output', PROXMOD_CRON_RUN => $run,
            # journalctl renders a field it saw more than once as an array, and
            # one with non-UTF-8 bytes as an array of byte values. Either would
            # be stringified into the UI as ARRAY(0x…) by a naive read.
            MESSAGE => ['first', 'second'],
        ),
    ]);

    my $lines = ProxmodCron::Runs::output($run)->{lines};

    # Control characters are stripped here, HTML encoding happens in the
    # frontend, and the view is a <pre>. All three, because this is the most
    # attacker-influenced text in the extension and it renders in an
    # authenticated root session.
    unlike($lines->[0]{text}, qr/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/,
        'control characters are replaced');
    like($lines->[0]{text}, qr/\Aclear\?\[2Jscreen\?null\?bell\z/,
        'while the readable text survives');

    is($lines->[1]{text}, 'first', 'an array-valued field yields its first usable scalar');
    is($lines->[1]{stream}, 'stdout', 'and a missing stream defaults rather than rendering empty');
};

subtest 'the journal view interleaves changes and runs under one job' => sub {
    plan tests => 5;

    ProxmodCronTest::journal_runner([
        entry(
            at => 0, cursor => 's=1;i=100',
            PROXMOD_CRON_EVENT => 'change', PROXMOD_CRON_JOB => 'nightly-trim',
            PROXMOD_CRON_SCOPE => 'node', PROXMOD_CRON_USER => 'root@pam',
            MESSAGE => "root\@pam changed node job 'nightly-trim'",
        ),
        entry(
            at => 10, cursor => 's=1;i=101',
            PROXMOD_CRON_EVENT => 'start', PROXMOD_CRON_JOB => 'nightly-trim',
            PROXMOD_CRON_SCOPE => 'node', PROXMOD_CRON_RUN => '1739000010000-11111111',
            MESSAGE => 'started',
        ),
        entry(
            at => 12, cursor => 's=1;i=102',
            PROXMOD_CRON_EVENT => 'finish', PROXMOD_CRON_JOB => 'nightly-trim',
            PROXMOD_CRON_SCOPE => 'node', PROXMOD_CRON_RUN => '1739000010000-11111111',
            PROXMOD_CRON_EXIT => 0, MESSAGE => 'finished',
        ),
    ]);

    my $view = ProxmodCron::Runs::journal(job => 'nightly-trim');

    # This is what the second journal sink is for. "Who changed this job, and how
    # has it run since" is one query because management records and run records
    # share PROXMOD_CRON_JOB.
    is_deeply([map { $_->{event} } @{ $view->{entries} }], [qw(change start finish)],
        'management and execution records come back in one timeline');

    is($view->{entries}[0]{user}, 'root@pam', 'the change record names who made it');
    is($view->{entries}[1]{run}, '1739000010000-11111111', 'and the run records name the run');
    is($view->{entries}[2]{time}, $EPOCH + 12, 'timestamps are seconds, not microseconds');
    is($view->{cursor}, 's=1;i=102', 'with a cursor to resume the live tail from');
};

subtest 'what reaches journalctl is an argv, and it is checked' => sub {
    plan tests => 7;

    # A real program, so this exercises the fork/exec path rather than the test
    # seam: every match here is built from a request parameter.
    my $recorder = ProxmodCron::Config::state_dir() . '/fake-journalctl';

    my $body = <<'SCRIPT';
use strict;
use warnings;

open(my $log, '>', $ENV{ARGV_LOG}) or exit 1;
print {$log} join("\n", @ARGV), "\n";
close($log);

print '{"SYSLOG_IDENTIFIER":"proxmod-cron","PROXMOD_CRON_RUN":"1739000000000-abcdef12",'
    . '"PROXMOD_CRON_EVENT":"finish","PROXMOD_CRON_JOB":"nightly-trim",'
    . '"PROXMOD_CRON_SCOPE":"node","PROXMOD_CRON_EXIT":"0","PROXMOD_CRON_SIGNAL":"0",'
    . '"PROXMOD_CRON_DURATION_MS":"5","MESSAGE":"finished",'
    . '"__REALTIME_TIMESTAMP":"1739000000000000"}' . "\n";
SCRIPT

    open(my $fh, '>', $recorder) or die "cannot write $recorder: $!\n";
    print {$fh} "#!$^X\n", $body;
    close($fh);
    chmod(0755, $recorder);

    my $log = ProxmodCron::Config::state_dir() . '/argv.log';
    local $ENV{ARGV_LOG} = $log;
    local $ProxmodCron::Runs::JOURNALCTL = $recorder;
    local $ProxmodCron::Runs::RUNNER;

    my $runs = ProxmodCron::Runs::list(job => 'nightly-trim', limit => 5);

    my @argv = split(/\n/, ProxmodCronTest::slurp($log));

    is($argv[0], '-o', 'the output format is asked for');
    is($argv[1], 'json', 'as json, which is the stable interface');

    # The separator is load-bearing: a match is a positional argument, and
    # without `--` a value that began with a dash would be read as an option.
    my ($sep) = grep { $argv[$_] eq '--' } 0 .. $#argv;
    ok(defined $sep, 'the matches are separated from the options');
    ok(scalar(grep { $_ eq 'PROXMOD_CRON_JOB=nightly-trim' } @argv[$sep + 1 .. $#argv]),
        'and every match is after it');

    is(scalar(@$runs), 1, 'the output is parsed back into a run');
    is($runs->[0]{state}, 'ok', 'with its state');

    # An id that does not match the pattern never becomes a match argument,
    # because it would be one built from a URL path segment.
    unlink($log);
    is(ProxmodCron::Runs::get('../../etc/passwd'), undef,
        'a run id that is not one is refused before anything is executed');
};
