package ProxmodCron::Runs;

use strict;
use warnings;

use Fcntl qw(LOCK_EX LOCK_NB LOCK_UN);
use JSON::PP ();
use POSIX ();

use ProxmodCron::Config;
use ProxmodCron::Journal;

# Reading run history back out of journald.
#
# This shells out to `journalctl -o json` with field matches rather than reusing
# PVE's /nodes/{node}/journal endpoint or PVE::Tools::dump_journal. PVE's
# endpoint is a mini-journalreader passthrough whose parameter set varies with
# the pve-manager version, and dump_journal only filters by unit. Neither can
# match on PROXMOD_CRON_JOB, which is the entire point. `journalctl -o json` is
# stable systemd surface present on every host.
#
# No PVE here either: proxmod-cronctl calls this directly.

our $VERSION = '202608.22.0';

our $JOURNALCTL = '/usr/bin/journalctl';

# Overridable so proxmod-cronctl can be tested as the script it is, against a
# stand-in journalctl in a temp directory — a package variable cannot be handed
# across a fork+exec. Guarded exactly as ProxmodCron::Config guards its prefix
# and ProxmodCron::Journal guards its socket: honoured only when the process is
# not root, so it can never redirect a production query into someone's $PATH.
if ($> != 0 && defined $ENV{PROXMOD_CRON_TEST_JOURNALCTL}) {
    my ($clean) = ($ENV{PROXMOD_CRON_TEST_JOURNALCTL} =~ m{\A(/[\w./@+-]{1,255})\z});
    $JOURNALCTL = $clean if defined $clean;
}

# Test seam. A coderef taking (\@args) and returning an arrayref of decoded
# entries, so the folding logic can be driven from fixtures with no journald.
our $RUNNER;

# Capturing, because this is used to untaint: a match with no group returns 1
# rather than the string it matched.
our $RUN_ID_PATTERN = qr/\A([0-9]{1,20}-[0-9a-f]{8})\z/;

my %EVENTS_FOR_HISTORY = map { $_ => 1 } qw(start finish skipped);

=head2 list(%opts)

Run records, newest first. Options: C<job>, C<scope>, C<since>, C<until>,
C<limit>.

Output records are excluded from this query on purpose: a job that prints
100 000 lines would otherwise make its own history unreadable. The history is
built from start, finish and skipped records only.

=cut

sub list {
    my (%opts) = @_;

    my @matches = _base_matches(%opts);
    push @matches, map { "PROXMOD_CRON_EVENT=$_" } sort keys %EVENTS_FOR_HISTORY;

    my @args = _time_args(%opts);

    # A generous entry cap rather than the caller's run limit: one run is up to
    # three entries, and journalctl's -n counts entries.
    my $limit = _positive($opts{limit}) || 100;
    push @args, '-n', ($limit * 4);

    my $entries = _query(\@matches, \@args);

    my $runs = fold($entries);

    # Newest first, and the caller's limit applied to runs rather than entries.
    my @sorted = sort { ($b->{started} || 0) <=> ($a->{started} || 0) } @$runs;
    @sorted = @sorted[0 .. $limit - 1] if @sorted > $limit;

    return \@sorted;
}

=head2 get($runid)

One run record, or undef.

=cut

sub get {
    my ($runid) = @_;

    my $run = _untaint_run_id($runid);
    return undef if !defined $run;

    my @matches = ('SYSLOG_IDENTIFIER=' . $ProxmodCron::Journal::IDENTIFIER,
        "PROXMOD_CRON_RUN=$run");
    push @matches, map { "PROXMOD_CRON_EVENT=$_" } sort keys %EVENTS_FOR_HISTORY;

    my $entries = _query(\@matches, ['-n', '16']);

    my $runs = fold($entries);

    return $runs->[0];
}

=head2 output($runid, %opts)

One run's captured output. Options: C<cursor> (resume after this journald
cursor), C<limit>.

Pagination is by cursor, not by offset. A live tail polls this while the run is
still going, and an offset would skip or repeat lines as new ones arrive between
polls.

Returns C<< { lines => [...], cursor => $last, done => 0|1 } >>. Each line
carries its C<seq>, and a line the journal lost entries in front of carries
C<gap>, the number missing. Entries dropped after the last surviving one cannot
be detected this way and are not reported.

=cut

sub output {
    my ($runid, %opts) = @_;

    my $run = _untaint_run_id($runid);
    return { lines => [], cursor => undef, done => 1 } if !defined $run;

    my @matches = ('SYSLOG_IDENTIFIER=' . $ProxmodCron::Journal::IDENTIFIER,
        "PROXMOD_CRON_RUN=$run", 'PROXMOD_CRON_EVENT=output');

    my $limit = _positive($opts{limit}) || 500;

    my @args = ('-n', $limit);

    if (defined $opts{cursor}) {
        my $cursor = _untaint_cursor($opts{cursor});
        push @args, '--after-cursor', $cursor if defined $cursor;
    }

    my $entries = _query(\@matches, \@args);

    my @lines;
    my $last_cursor;
    my $prev_seq;

    for my $entry (@$entries) {
        my $seq = _int(_field($entry, 'PROXMOD_CRON_SEQ'));

        my $line = {
            stream => _field($entry, 'PROXMOD_CRON_STREAM') || 'stdout',
            priority => _field($entry, 'PRIORITY'),
            time => _usec($entry->{__REALTIME_TIMESTAMP}),
            text => _sanitise(_field($entry, 'MESSAGE')),
        };

        # Present only on lines this extension wrote rather than lines the job
        # did — currently just the truncation notice. The log view shows them;
        # the status cache's tail leaves them out.
        my $notice = _field($entry, 'PROXMOD_CRON_NOTICE');
        $line->{notice} = $notice if defined $notice;

        # The wrapper numbers every entry it sends, densely. A jump means
        # journald dropped what was between — rate limiting, most likely — and
        # saying so is the whole point: a run that lost its middle otherwise
        # comes back looking like a shorter run.
        #
        # Between two returned lines only, never before the first. The query is
        # `-n <limit>`, so the first page of a long run legitimately starts part
        # way through the sequence, and calling that a gap would put a false
        # 'lines missing' rule at the top of every long log.
        $line->{seq} = $seq if defined $seq;
        $line->{gap} = $seq - $prev_seq - 1
            if defined $seq && defined $prev_seq && $seq > $prev_seq + 1;

        # Unconditional, undef included: a run recorded before this field
        # existed has no sequence at all, and carrying the last seen number
        # across the hole would invent a gap out of nothing.
        $prev_seq = $seq;

        push @lines, $line;
        $last_cursor = $entry->{__CURSOR} if defined $entry->{__CURSOR};
    }

    return {
        lines => \@lines,
        cursor => $last_cursor,
        # Fewer than we asked for means we have caught up with the journal. The
        # caller polls again only if the run has no finish record yet.
        done => (scalar(@lines) < $limit) ? 1 : 0,
    };
}

=head2 journal(%opts)

Every proxmod-cron entry, runs and management actions interleaved — what the
node's Log tab shows. Options: C<since>, C<until>, C<limit>, C<cursor>, C<job>.

=cut

sub journal {
    my (%opts) = @_;

    my @matches = _base_matches(%opts);

    my $limit = _positive($opts{limit}) || 500;
    my @args = _time_args(%opts);
    push @args, '-n', $limit;

    if (defined $opts{cursor}) {
        my $cursor = _untaint_cursor($opts{cursor});
        push @args, '--after-cursor', $cursor if defined $cursor;
    }

    my $entries = _query(\@matches, \@args);

    my @out;
    my $last_cursor;

    for my $entry (@$entries) {
        push @out, {
            time => _usec($entry->{__REALTIME_TIMESTAMP}),
            priority => _field($entry, 'PRIORITY'),
            event => _field($entry, 'PROXMOD_CRON_EVENT'),
            job => _field($entry, 'PROXMOD_CRON_JOB'),
            scope => _field($entry, 'PROXMOD_CRON_SCOPE'),
            run => _field($entry, 'PROXMOD_CRON_RUN'),
            # actor is who, via is what kind. user is set only when the actor
            # really is a PVE user, so it is absent on everything an extension
            # did — which is why the Log tab shows actor and not user.
            actor => _field($entry, 'PROXMOD_CRON_ACTOR'),
            via => _field($entry, 'PROXMOD_CRON_VIA'),
            user => _field($entry, 'PROXMOD_CRON_USER'),
            message => _sanitise(_field($entry, 'MESSAGE')),
        };
        $last_cursor = $entry->{__CURSOR} if defined $entry->{__CURSOR};
    }

    return { entries => \@out, cursor => $last_cursor };
}

=head2 fold($entries)

Turn journal entries into run records. Pure, so the tests can drive it from
fixtures.

=cut

sub fold {
    my ($entries) = @_;

    my %runs;
    my @order;

    for my $entry (@$entries) {
        my $run = _field($entry, 'PROXMOD_CRON_RUN');
        next if !defined $run || $run eq '';

        my $event = _field($entry, 'PROXMOD_CRON_EVENT') || '';
        my $time = _usec($entry->{__REALTIME_TIMESTAMP});

        my $record = $runs{$run};
        if (!$record) {
            $record = $runs{$run} = {
                run => $run,
                job => _field($entry, 'PROXMOD_CRON_JOB'),
                scope => _field($entry, 'PROXMOD_CRON_SCOPE'),
                type => _field($entry, 'PROXMOD_CRON_TYPE'),
                lines => 0,
                truncated => 0,
            };
            push @order, $run;
        }

        $record->{cursor} = $entry->{__CURSOR} if defined $entry->{__CURSOR};

        # The wrapper's own reading of when the run began, on both its start and
        # its finish record. Preferred over journald's receive timestamp because
        # it is the number proxmod-cron-exec wrote into the status cache, and a
        # reindex that used the other clock would rebuild a cache that differs
        # from the original by a second for no reason a user could explain.
        my $stamped = _int(_field($entry, 'PROXMOD_CRON_STARTED'));

        if ($event eq 'start') {
            $record->{started} = defined($stamped) ? $stamped : $time;
            $record->{user} = _field($entry, 'PROXMOD_CRON_USER')
                if defined _field($entry, 'PROXMOD_CRON_USER');
        } elsif ($event eq 'finish') {
            $record->{started} = $stamped if defined $stamped;
            $record->{finished} = $time;
            $record->{exit} = _int(_field($entry, 'PROXMOD_CRON_EXIT'));
            $record->{signal} = _int(_field($entry, 'PROXMOD_CRON_SIGNAL'));
            $record->{duration_ms} = _int(_field($entry, 'PROXMOD_CRON_DURATION_MS'));
            $record->{lines} = _int(_field($entry, 'PROXMOD_CRON_LINES')) || 0;
            $record->{truncated} = _field($entry, 'PROXMOD_CRON_TRUNCATED') ? 1 : 0;
        } elsif ($event eq 'skipped') {
            $record->{started} = $time if !defined $record->{started};
            $record->{skipped} = 1;
            $record->{message} = _sanitise(_field($entry, 'MESSAGE'));
        }
    }

    my @out;
    for my $run (@order) {
        my $record = $runs{$run};

        # proxmod-cron-exec derives its cache's `finished` from its own start
        # time plus the duration it measured, so derive it the same way rather
        # than from when journald happened to receive the finish record. Done
        # here, not in the fold above, so it does not depend on the start and
        # finish entries arriving in either order.
        $record->{finished} = $record->{started} + int($record->{duration_ms} / 1000)
            if defined $record->{started} && defined $record->{duration_ms};

        $record->{state} = state_of($record);
        # A record with no start at all is an output or finish entry whose start
        # has aged out of the journal. Report it rather than hiding it — the
        # times are still real.
        $record->{started} = $record->{finished}
            if !defined $record->{started} && defined $record->{finished};
        push @out, $record;
    }

    return \@out;
}

=head2 state_of($record)

C<ok>, C<failed>, C<killed>, C<skipped>, C<running> or C<unknown>.

A start with no finish is only C<running> while its lock is still held. A node
that lost power mid-job must not show that job as running forever, which is
what a purely journal-based answer would give.

=cut

sub state_of {
    my ($record) = @_;

    return 'skipped' if $record->{skipped};

    if (defined $record->{finished}) {
        return 'killed' if $record->{signal};
        return 'ok' if defined($record->{exit}) && $record->{exit} == 0;
        return 'failed';
    }

    return 'unknown' if !defined $record->{job} || !defined $record->{scope};

    return lock_held($record->{scope}, $record->{job}) ? 'running' : 'unknown';
}

=head2 lock_held($scope, $id)

Whether a run of this job is in progress, tested by trying the lock and
immediately releasing it. Never blocks, and never leaves the lock held.

=cut

sub lock_held {
    my ($scope, $id) = @_;

    my $path = ProxmodCron::Config::job_lock_path($scope, $id);

    return 0 if !-e $path;

    open(my $fh, '<', $path) or return 0;

    my $got = flock($fh, LOCK_EX | LOCK_NB);
    flock($fh, LOCK_UN) if $got;
    close($fh);

    return $got ? 0 : 1;
}

=head2 persistent()

Whether journald is storing to disk, so history survives a reboot. Reported by
`proxmod-cronctl doctor` and shown once on the Runs tab — we check and warn,
we do not change it. Journald configuration belongs to the administrator.

=cut

sub persistent {
    return -d(ProxmodCron::Config::prefix() . '/var/log/journal') ? 1 : 0;
}

sub _base_matches {
    my (%opts) = @_;

    my @matches = ('SYSLOG_IDENTIFIER=' . $ProxmodCron::Journal::IDENTIFIER);

    if (defined $opts{job}) {
        my ($job) = ($opts{job} =~ $ProxmodCron::Config::ID_PATTERN);
        return @matches if !defined $job;
        push @matches, "PROXMOD_CRON_JOB=$job";
    }

    if (defined $opts{scope}) {
        my ($scope) = ($opts{scope} =~ /\A(cluster|node)\z/);
        push @matches, "PROXMOD_CRON_SCOPE=$scope" if defined $scope;
    }

    return @matches;
}

sub _time_args {
    my (%opts) = @_;

    my @args;

    for my $key (qw(since until)) {
        next if !defined $opts{$key};
        # journalctl accepts a lot of forms; this is the subset we pass through,
        # and it reaches an exec argument list, so it is matched not filtered.
        my ($value) = ($opts{$key} =~ /\A(-?[0-9a-zA-Z:+ -]{1,64})\z/);
        push @args, "--$key", $value if defined $value;
    }

    return @args;
}

sub _query {
    my ($matches, $args) = @_;

    return $RUNNER->([@$args, @$matches]) if $RUNNER;

    my @cmd = ($JOURNALCTL, '-o', 'json', '--no-pager', @$args, '--', @$matches);

    my $out = _capture(\@cmd);
    return [] if !defined $out;

    my $json = JSON::PP->new->utf8;

    my @entries;
    for my $line (split(/\n/, $out)) {
        next if $line !~ /\S/;
        my $entry = eval { $json->decode($line) };
        next if !$entry || ref($entry) ne 'HASH';
        push @entries, $entry;
    }

    return \@entries;
}

# fork/exec with a list. No shell anywhere near a journalctl match built from a
# request parameter.
sub _capture {
    my ($cmd) = @_;

    pipe(my $reader, my $writer) or return undef;

    my $pid = fork();
    return undef if !defined $pid;

    if ($pid == 0) {
        close($reader);
        open(STDOUT, '>&', $writer) or POSIX::_exit(127);
        open(STDERR, '>', '/dev/null');
        close($writer);
        { exec { $cmd->[0] } @$cmd; }
        POSIX::_exit(127);
    }

    close($writer);

    local $/;
    my $out = <$reader>;
    close($reader);

    waitpid($pid, 0);

    return defined($out) ? $out : '';
}

# journalctl -o json renders a field that appeared more than once in an entry as
# an array, and a field with non-UTF-8 bytes as an array of byte values. Take the
# first usable scalar in both cases rather than stringifying a reference into the
# UI.
sub _field {
    my ($entry, $key) = @_;

    my $value = $entry->{$key};
    return undef if !defined $value;

    if (ref($value) eq 'ARRAY') {
        for my $item (@$value) {
            next if ref($item);
            return $item;
        }
        return undef;
    }

    return undef if ref($value);

    return $value;
}

sub _usec {
    my ($value) = @_;
    return undef if !defined $value;
    my ($clean) = ("$value" =~ /\A([0-9]{1,20})\z/);
    return undef if !defined $clean;
    return int($clean / 1_000_000);
}

sub _int {
    my ($value) = @_;
    return undef if !defined $value;
    my ($clean) = ("$value" =~ /\A(-?[0-9]{1,20})\z/);
    return undef if !defined $clean;
    return 0 + $clean;
}

sub _positive {
    my ($value) = @_;
    return undef if !defined $value;
    return undef if $value !~ /\A[0-9]{1,9}\z/ || $value == 0;
    return 0 + $value;
}

# Captured job output is the most attacker-influenced text in this extension and
# it is rendered in the hypervisor's admin interface. Control characters go here,
# HTML encoding happens in the frontend, and the view is a <pre>. All three.
sub _sanitise {
    my ($text) = @_;

    return '' if !defined $text;

    my $out = "$text";
    $out =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/?/g;

    return $out;
}

sub _untaint_run_id {
    my ($runid) = @_;
    return undef if !defined $runid;
    my ($clean) = ($runid =~ $RUN_ID_PATTERN);
    return $clean;
}

sub _untaint_cursor {
    my ($cursor) = @_;
    return undef if !defined $cursor;
    # journald cursors are 'x=hex;y=hex;...'.
    my ($clean) = ($cursor =~ /\A([a-z0-9=;_-]{1,512})\z/i);
    return $clean;
}

1;
