package ProxmodCron::State;

use strict;
use warnings;

use Fcntl qw(O_WRONLY O_CREAT O_EXCL LOCK_EX);
use JSON::PP ();

use ProxmodCron::Config;

# The last-run cache: /var/lib/proxmod/cron/last-run.json.
#
# It exists for exactly one reason. The job grid needs a last-result column for
# every row on every refresh, and deriving that from journald means either one
# journalctl per row or one broad query that cannot express "the newest finish
# per job". So proxmod-cron-exec writes the answer as it goes.
#
# It is a DERIVED INDEX and nothing more. journald is the store of record for
# every run and all captured output; `proxmod-cronctl reindex` rebuilds this
# file from it; deleting it costs a rebuild and nothing else. If the two ever
# disagree, journald wins.
#
# One consequence for the API layer: `tail` holds captured job output, which is
# Sys.Syslog-class data (see the plan's §8.2). A method that returns a record to
# a Sys.Audit-only caller must strip it. strip_output() below is that call, so
# there is one implementation of the rule.

our $VERSION = '202608.17.0';

our $TAIL_LINES = 20;

sub file { return ProxmodCron::Config::state_dir() . '/last-run.json' }

sub key {
    my ($scope, $id) = @_;
    return "$scope/$id";
}

=head2 load()

The whole cache, as C<< { "scope/id" => $record } >>. Never dies and never
reports an error: a missing or corrupt cache is a cache miss, which the UI
renders as "unknown", and that is the correct behaviour for a derived file.

=cut

sub load {
    my $path = file();

    open(my $fh, '<', $path) or return {};
    binmode($fh);
    local $/;
    my $raw = <$fh>;
    close($fh);

    return {} if !defined $raw || $raw !~ /\S/;

    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return {} if !$data || ref($data) ne 'HASH';

    my $jobs = $data->{jobs};
    return {} if !$jobs || ref($jobs) ne 'HASH';

    my %out;
    for my $k (keys %$jobs) {
        next if ref($jobs->{$k}) ne 'HASH';
        my ($clean) = ($k =~ m{\A((?:cluster|node)/[a-z0-9][a-z0-9_-]{0,63})\z});
        next if !defined $clean;
        $out{$clean} = _untaint_record($jobs->{$k});
    }

    return \%out;
}

sub _untaint_record {
    my ($record) = @_;

    my %out;

    for my $k (qw(run job scope state)) {
        next if !defined $record->{$k};
        my ($clean) = ("$record->{$k}" =~ /\A([\x20-\x7e]{0,128})\z/);
        $out{$k} = $clean if defined $clean;
    }

    for my $k (qw(started finished exit signal duration_ms lines)) {
        next if !defined $record->{$k};
        my ($clean) = ("$record->{$k}" =~ /\A(-?[0-9]{1,20})\z/);
        $out{$k} = 0 + $clean if defined $clean;
    }

    $out{truncated} = $record->{truncated} ? 1 : 0;

    if (ref($record->{tail}) eq 'ARRAY') {
        my @tail;
        for my $line (@{ $record->{tail} }) {
            next if ref($line);
            my ($clean) = ("$line" =~ /\A([^\0\n\r]{0,4096})\z/);
            push @tail, $clean if defined $clean;
        }
        $out{tail} = \@tail;
    }

    return \%out;
}

=head2 get($scope, $id)

One job's record, or undef.

=cut

sub get {
    my ($scope, $id) = @_;
    my $all = load();
    return $all->{ key($scope, $id) };
}

=head2 record($scope, $id, $record)

Merge one job's record into the cache, atomically, holding the cache lock.
Called by proxmod-cron-exec at the end of every run.

Read-modify-write under an exclusive lock because two jobs can finish in the
same second and the loser must not erase the winner.

=cut

sub record {
    my ($scope, $id, $record) = @_;

    my %copy = %$record;
    $copy{scope} = $scope;
    $copy{job} = $id;

    if (ref($copy{tail}) eq 'ARRAY' && @{ $copy{tail} } > $TAIL_LINES) {
        my @tail = @{ $copy{tail} };
        $copy{tail} = [splice(@tail, -$TAIL_LINES)];
    }

    return _with_lock(sub {
        my $all = load();
        $all->{ key($scope, $id) } = \%copy;
        _write($all);
        return 1;
    });
}

=head2 replace($all)

Replace the entire cache. This is what `proxmod-cronctl reindex` calls after
rebuilding from journald.

=cut

sub replace {
    my ($all) = @_;

    return _with_lock(sub {
        _write($all || {});
        return 1;
    });
}

=head2 prune($live)

Drop records for jobs that no longer exist. C<$live> is a hashref keyed the same
way as the cache.

=cut

sub prune {
    my ($live) = @_;

    return _with_lock(sub {
        my $all = load();
        my $changed = 0;
        for my $k (keys %$all) {
            next if $live->{$k};
            delete $all->{$k};
            $changed = 1;
        }
        _write($all) if $changed;
        return $changed;
    });
}

=head2 strip_output($record)

A copy of a record with the captured output removed, for a caller who may see
that a job failed but not what it printed. The one implementation of that rule.

=cut

sub strip_output {
    my ($record) = @_;

    return undef if !$record;

    my %out = %$record;
    delete $out{tail};

    return \%out;
}

sub _write {
    my ($all) = @_;

    my $json = JSON::PP->new->utf8->canonical->pretty->encode({
        version => 1,
        jobs => $all,
    });

    my $path = file();
    my $tmp = "$path.tmp.$$";

    unlink($tmp);

    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or die "cannot create $tmp: $!\n";
    binmode($fh);
    print {$fh} $json or do { close($fh); unlink($tmp); die "cannot write $tmp: $!\n" };
    close($fh) or do { unlink($tmp); die "cannot write $tmp: $!\n" };

    chmod(0600, $tmp);

    rename($tmp, $path) or do { unlink($tmp); die "cannot replace $path: $!\n" };

    return 1;
}

sub _with_lock {
    my ($code) = @_;

    my $dir = ProxmodCron::Config::state_dir();

    # The wrapper's whole job is to record that something ran. If the state
    # directory is missing we make it; if we cannot, we give up quietly rather
    # than failing the job that just succeeded.
    eval { ProxmodCron::Config::mkdir_p($dir) };
    return 0 if !-d $dir;

    my $path = "$dir/cache.lock";

    open(my $fh, '>>', $path) or return 0;
    flock($fh, LOCK_EX) or do { close($fh); return 0 };

    # A failure here is deliberately swallowed: this is a cache, and the caller
    # is usually proxmod-cron-exec finishing a job that worked.
    my $ok = eval { $code->(); 1 };

    close($fh);

    return $ok ? 1 : 0;
}

1;
