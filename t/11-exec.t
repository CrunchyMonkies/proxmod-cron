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
use POSIX ();

use ProxmodCron::Config;
use ProxmodCron::Journal;
use ProxmodCron::State;

# The run wrapper, end to end, as a real subprocess against a real datagram
# socket.
#
# It is run rather than called because everything worth asserting about it is a
# process property: what it does with two pipes and a forked child, what wait
# status it leaves behind, and whether it survives a job that prints more than
# it will forward. A version of this test that called the functions in-process
# would pass while the thing cron actually invokes deadlocked.
#
# The journal socket is redirected the same way the config prefix is —
# PROXMOD_CRON_TEST_SOCKET, honoured only for a non-root process — because a
# package variable does not cross a fork+exec.

plan tests => 11;

my $EXEC = "$FindBin::Bin/../exec/proxmod-cron-exec";
my $PERL_DIR = "$FindBin::Bin/../perl";

my $drain = ProxmodCronTest::journal_sink();
$ENV{PROXMOD_CRON_TEST_SOCKET} = ProxmodCron::Config::state_dir() . '/journal.sock';

sub sweep {
    return $drain->();
}

# Run the wrapper, draining the socket while it runs.
#
# The draining is not tidiness: the socket has a finite receive buffer and the
# wrapper's sends are blocking, so a test that collected entries only after
# waitpid would hang the moment a job printed more than the buffer holds — which
# is exactly the case the cap test exercises.
sub run_exec {
    my ($args, %opt) = @_;

    sweep();

    my $pid = fork();
    die "cannot fork: $!\n" if !defined $pid;

    if ($pid == 0) {
        if ($opt{stderr}) {
            open(STDERR, '>', $opt{stderr}) or POSIX::_exit(127);
        }
        my @cmd = ($^X, '-I', $PERL_DIR, $EXEC, @$args);
        { exec { $cmd[0] } @cmd; }
        POSIX::_exit(127);
    }

    my @entries;
    my $status;

    while (1) {
        push @entries, @{ sweep() };

        my $done = waitpid($pid, POSIX::WNOHANG());
        if ($done == $pid) {
            $status = $?;
            last;
        }

        select(undef, undef, undef, 0.005);
    }

    push @entries, @{ sweep() };

    return {
        status => $status,
        exit => $status >> 8,
        signal => $status & 127,
        entries => \@entries,
    };
}

sub events {
    my ($result, $event) = @_;
    return [grep { ($_->{PROXMOD_CRON_EVENT} || '') eq $event } @{ $result->{entries} }];
}

sub one_event {
    my ($result, $event) = @_;
    my $found = events($result, $event);
    return @$found == 1 ? $found->[0] : undef;
}

sub perl_job {
    my ($code) = @_;
    return ($^X, '-e', $code);
}

sub limits {
    my (%limits) = @_;
    ProxmodCronTest::write_store('node', { version => 1, jobs => {}, %limits });
    return;
}

sub wipe_state {
    unlink(ProxmodCron::State::file());
    return;
}

limits();

# ---------------------------------------------------------------------------

subtest 'both streams are captured, tagged and tied to one run' => sub {
    plan tests => 10;

    my $result = run_exec(['node', 'two-streams', '--',
        perl_job(q{ $| = 1; print "first\n"; print STDERR "problem\n"; print "second\n"; })]);

    is($result->{exit}, 0, 'the wrapper exits with the job status');

    my $start = one_event($result, 'start');
    my $finish = one_event($result, 'finish');

    ok($start, 'exactly one start record');
    ok($finish, 'and exactly one finish record');

    my $output = events($result, 'output');
    is(scalar(@$output), 3, 'every line the job printed is its own entry');

    # One field ties the whole run together, which is what makes
    # `journalctl PROXMOD_CRON_RUN=<id>` return a complete run and nothing else.
    my %runs = map { ($_->{PROXMOD_CRON_RUN} || '') => 1 }
        ($start, $finish, @$output);
    is(scalar(keys %runs), 1, 'all of them carry the same run id');

    my @stdout = grep { $_->{PROXMOD_CRON_STREAM} eq 'stdout' } @$output;
    my @stderr = grep { $_->{PROXMOD_CRON_STREAM} eq 'stderr' } @$output;

    is_deeply([map { $_->{MESSAGE} } @stdout], ['first', 'second'],
        'stdout lines arrive in the order they were written');
    is_deeply([map { $_->{MESSAGE} } @stderr], ['problem'], 'and stderr separately');

    # The severity is what makes a failing job findable with
    # `journalctl -p warning`, and what colours the line in the run log window.
    is($stderr[0]{PRIORITY}, '4', 'a stderr line is a warning');
    is($stdout[0]{PRIORITY}, '6', 'a stdout line is informational');

    is($finish->{PROXMOD_CRON_EXIT}, '0', 'and the finish record says it succeeded');
};

subtest 'the type travels with the argv, not out of the store' => sub {
    plan tests => 5;

    my $result = run_exec(['node', 'typed-job', '--type', 'acme-backup', '--',
        perl_job(q{ print "working\n"; })]);

    is($result->{exit}, 0, 'the flag does not disturb the run');

    my $start = one_event($result, 'start');
    my $finish = one_event($result, 'finish');
    my $output = events($result, 'output');

    # Every record of the run, not just one of them: the query this field exists
    # for is `journalctl PROXMOD_CRON_TYPE=acme-backup`, and a field on the start
    # record alone would answer it with a third of the run.
    is($start->{PROXMOD_CRON_TYPE}, 'acme-backup', 'the start record carries the type');
    is($finish->{PROXMOD_CRON_TYPE}, 'acme-backup', 'so does the finish record');
    is($output->[0]{PROXMOD_CRON_TYPE}, 'acme-backup', 'and so does every output line');

    # Absent rather than empty, so `journalctl PROXMOD_CRON_TYPE=` does not match
    # everything that ever ran.
    my $untyped = run_exec(['node', 'untyped-job', '--', perl_job(q{ exit(0) })]);
    ok(!exists one_event($untyped, 'start')->{PROXMOD_CRON_TYPE},
        'a run with no type has no type field at all');
};

subtest 'the wrapper never alters what the job returned' => sub {
    plan tests => 5;

    my $result = run_exec(['node', 'exit-three', '--', perl_job(q{ exit(3) })]);

    is($result->{exit}, 3, 'a job exiting 3 makes the wrapper exit 3');
    is($result->{signal}, 0, 'with no signal');

    my $finish = one_event($result, 'finish');
    is($finish->{PROXMOD_CRON_EXIT}, '3', 'the exit status is recorded');

    # Priority is how a failed run is found without knowing the job id.
    is($finish->{PRIORITY}, '3', 'and a non-zero exit is an error, not information');
    like($finish->{MESSAGE}, qr/exited 3/, 'the message says so in words');
};

subtest 'a killed job kills the wrapper, rather than exiting 0' => sub {
    plan tests => 5;

    my $result = run_exec(['node', 'killed', '--',
        perl_job(q{ $| = 1; print "starting\n"; kill(9, $$); sleep(30); })]);

    # cron, and every other tool on the host, decides whether a job succeeded
    # from the wait status. A wrapper that caught the signal and exited 0 would
    # make a SIGKILLed backup look like a clean success everywhere.
    is($result->{signal}, 9, 'the wrapper dies of the same signal the job did');
    is($result->{exit}, 0, 'and does not exit with a status of its own');

    my $finish = one_event($result, 'finish');
    is($finish->{PROXMOD_CRON_SIGNAL}, '9', 'the signal is recorded');
    like($finish->{MESSAGE}, qr/killed by signal 9/, 'and named in the message');

    is(scalar(@{ events($result, 'output') }), 1,
        'the output it managed to produce first is still captured');
};

subtest 'a job printing far past the cap still finishes' => sub {
    plan tests => 6;

    limits(max_lines => 5);

    my $result = run_exec(['node', 'chatty', '--',
        perl_job(q{ $| = 1; print "line $_\n" for 1 .. 5000; exit(0) })]);

    # This is the property the whole pump loop is shaped around. Once the cap is
    # reached the wrapper stops forwarding but keeps reading, because a full pipe
    # blocks the child forever. A wrapper that stopped reading would hang here —
    # and in production that hang would be a cron job that never returns.
    is($result->{exit}, 0, 'the job ran to completion');

    my $output = events($result, 'output');
    my @notice = grep { $_->{MESSAGE} =~ /output truncated/ } @$output;

    is(scalar(@notice), 1, 'exactly one truncation notice, not one per line past the cap');
    is(scalar(@$output), 6, 'and the cap is what bounds the forwarded lines');

    my $finish = one_event($result, 'finish');
    is($finish->{PROXMOD_CRON_TRUNCATED}, '1', 'the finish record flags the truncation');

    # Counted, not forwarded: the run log is capped but the count is honest, so
    # the UI can say "5000 lines, 5 shown" rather than claiming the job was quiet.
    is($finish->{PROXMOD_CRON_LINES}, '5000', 'while the line count is the real one');
    is($finish->{PROXMOD_CRON_EXIT}, '0', 'and the exit status is untouched by any of it');

    limits();
};

subtest 'a line with no end is cut rather than buffered forever' => sub {
    plan tests => 4;

    limits(max_line_bytes => 64);

    my $result = run_exec(['node', 'no-newline', '--',
        perl_job(q{ $| = 1; print "x" x 4096; exit(0) })]);

    is($result->{exit}, 0, 'the job completes');

    my $output = events($result, 'output');
    ok(scalar(@$output) >= 2, 'the unterminated output is emitted as several lines');

    # Without the cut, a job printing megabytes with no newline would grow the
    # wrapper's buffer without bound — the one way a log capture can take down
    # the host it is logging on.
    my @oversized = grep { length($_->{MESSAGE}) > 64 } @$output;
    is_deeply(\@oversized, [], 'none of them exceeds the configured line size');

    is(join('', map { $_->{MESSAGE} } @$output), 'x' x 4096,
        'and nothing the job wrote is lost in the cutting');

    limits();
};

subtest 'a run that is still going is skipped, and says so' => sub {
    plan tests => 5;

    my $path = ProxmodCron::Config::job_lock_path('node', 'slow-job');

    open(my $held, '>>', $path) or die "cannot open $path: $!\n";
    ok(flock($held, LOCK_EX | LOCK_NB), 'a previous run holds the job lock');

    my $marker = ProxmodCron::Config::state_dir() . '/should-not-exist';

    my $result = run_exec(['node', 'slow-job', '--',
        perl_job(qq{ open(my \$fh, '>', '$marker'); close(\$fh); })]);

    # Exit 0, because from cron's point of view nothing went wrong: the job is
    # already running. A non-zero exit would mail the administrator every minute
    # for the duration of a long backup.
    is($result->{exit}, 0, 'the wrapper exits cleanly rather than reporting a failure');
    ok(!-e $marker, 'the job did not run a second time');

    my $skipped = one_event($result, 'skipped');
    like($skipped->{MESSAGE}, qr/a previous run is still in progress/,
        'and the skip is recorded, because a silent skip is indistinguishable from a no-op');

    is(scalar(@{ events($result, 'start') }), 0, 'no start record was written for a run that did not start');

    close($held);
};

subtest 'the status cache is written for the grid to read' => sub {
    plan tests => 8;

    wipe_state();

    my $result = run_exec(['node', 'cached', '--',
        perl_job(q{ $| = 1; print "working\n"; print STDERR "trouble\n"; exit(2) })]);

    my $record = ProxmodCron::State::load()->{'node/cached'};

    ok($record, 'the run left a record behind');
    is($record->{exit}, 2, 'with the exit status');
    is($record->{state}, 'failed', 'summarised for the grid column');
    is($record->{run}, one_event($result, 'start')->{PROXMOD_CRON_RUN},
        'and the run id, so the row links to the right run in journald');
    ok(defined $record->{duration_ms}, 'the duration is there');
    is($record->{lines}, 2, 'and the line count');

    # The tail is what the failure tooltip shows. Without it the grid can say a
    # job failed but not why, which is the moment an administrator has to go
    # looking at journald by hand.
    is_deeply($record->{tail}, ['stdout: working', 'stderr: trouble'],
        'the output tail is kept, tagged by stream');

    # It is a cache and only a cache: journald has all of this, and losing the
    # file costs a reindex.
    is(scalar(keys %{ ProxmodCron::State::load() }), 1,
        'and it holds one record per job, not one per run');
};

subtest 'keep_output off records the run without recording what it printed' => sub {
    plan tests => 5;

    wipe_state();

    my $result = run_exec(['node', 'quiet', '--no-output', '--',
        perl_job(q{ $| = 1; print "secret\n" for 1 .. 50; exit(0) })]);

    is($result->{exit}, 0, 'the job runs normally');
    is(scalar(@{ events($result, 'output') }), 0, 'none of its output is journalled');

    my $finish = one_event($result, 'finish');
    ok($finish, 'but the run itself is still recorded');
    is($finish->{PROXMOD_CRON_LINES}, '50',
        'including how much it printed, which is the part that is not sensitive');

    # The setting exists for a job that prints things that should not spread to
    # everyone holding Sys.Syslog. A tail in the cache would defeat it.
    my $record = ProxmodCron::State::load()->{'node/quiet'};
    is_deeply($record->{tail}, [], 'and nothing it printed reaches the status cache');
};

subtest 'the argv is an argv, and the start record precedes the exec' => sub {
    plan tests => 6;

    my $marker = ProxmodCron::Config::state_dir() . '/argv.txt';
    unlink($marker);

    # Arguments a shell would mangle: a semicolon, a dollar, a glob, spaces. If
    # anything in the chain built a command string, this is where it shows.
    my @nasty = ('; touch /tmp/pwned', '$HOME', '*', 'two words');

    run_exec(['node', 'argv-job', '--',
        perl_job(qq{ open(my \$fh, '>', '$marker'); print {\$fh} join("|", \@ARGV); close(\$fh); }),
        @nasty]);

    is(ProxmodCronTest::slurp($marker), join('|', @nasty),
        'every argument reaches the job exactly as written');

    ok(!-e '/tmp/pwned', 'and nothing was interpreted on the way');

    # Fork before you log: a job that cannot even be executed still has to leave
    # a trace, or "the command was misspelled" and "cron never ran it" look
    # identical.
    my $result = run_exec(['node', 'missing-job', '--',
        ProxmodCron::Config::state_dir() . '/no-such-program']);

    is($result->{exit}, 127, 'a command that cannot be executed exits 127');
    ok(one_event($result, 'start'), 'the start record was written before the exec was attempted');

    my $finish = one_event($result, 'finish');
    is($finish->{PROXMOD_CRON_EXIT}, '127', 'and the failure is recorded as a finish');
    ok(scalar(@{ events($result, 'output') }) >= 1,
        "with the exec error itself captured as the job's output");
};

subtest 'run ids are unique, and bad arguments are refused' => sub {
    plan tests => 6;

    my @ids;
    for (1 .. 3) {
        my $result = run_exec(['node', 'rapid', '--', perl_job(q{ exit(0) })]);
        push @ids, one_event($result, 'start')->{PROXMOD_CRON_RUN};
    }

    my %seen = map { $_ => 1 } @ids;
    is(scalar(keys %seen), 3, 'three runs in quick succession get three run ids');

    # Sortable, so a run list is in order without parsing a timestamp out of a
    # record. The random half is what stops two jobs in the same millisecond
    # from colliding.
    is_deeply([sort @ids], \@ids, 'and they sort into the order they ran in');
    like($ids[0], qr/\A[0-9]{13}-[0-9a-f]{8}\z/, 'shaped as milliseconds and eight hex digits');

    my $errors = ProxmodCron::Config::state_dir() . '/usage.txt';

    # Both of these reach a lock path and a journal field, so neither may be
    # taken on trust.
    my $bad_scope = run_exec(['sideways', 'a-job', '--', '/bin/true'], stderr => $errors);
    is($bad_scope->{exit}, 2, 'an unknown scope is a usage error');
    like(ProxmodCronTest::slurp($errors), qr/invalid scope/, 'named in the message');

    my $bad_id = run_exec(['node', 'Not A Job Id', '--', '/bin/true'], stderr => $errors);
    is($bad_id->{exit}, 2, 'and so is a job id that is not one');
};
