package ProxmodCron::Lease;

use strict;
use warnings;

use Errno qw(EEXIST ENOENT EROFS EACCES EPERM);
use JSON::PP ();

use ProxmodCron::Config;

# Exactly one node runs a `run_on: any` job per scheduled tick.
#
#   /etc/pve/proxmod/cron-lease/<id>/               per job
#   /etc/pve/proxmod/cron-lease/<id>/<tick>/        the claim
#   /etc/pve/proxmod/cron-lease/<id>/<tick>/holder  who won, and how it went
#
# THE MKDIR IS THE CLAIM. /etc/pve is pmxcfs, where mkdir is an atomic
# cluster-wide test-and-set — it is the primitive PVE's own cfs_lock is built
# on. Every targeted node fires at the schedule and races; one gets 0, the rest
# get EEXIST. There is no leader to elect, no heartbeat to miss, and no list of
# live nodes to keep in step with reality: a node that is down simply does not
# enter the race.
#
# It is also the quorum guard of last resort. pmxcfs makes /etc/pve read-only
# the instant quorum is lost, so a partitioned node gets EROFS and cannot win —
# whatever ProxmodCron::Cluster thought.
#
# The tick, not the wall clock, is the unit. Two nodes fire the same job a
# fraction of a second apart at best; ProxmodCron::Spec::tick turns both of those
# instants into the one minute cron meant, which is the only value both nodes can
# agree on without talking to each other.
#
# A node that dies mid-run leaves its tick claimed and its holder saying
# 'running'. That is deliberate: nothing re-runs the tick. The next tick is a
# fresh directory and a fresh race, so a survivor picks the job up at its next
# scheduled time and nothing has run twice for one scheduled time — which is the
# property a backup or a migration needs and a timeout-and-take-over scheme
# cannot offer.
#
# No PVE here either: the wrapper calls this from cron.

our $VERSION = '0.1.0';

# Tick directories kept per job. Enough to answer "where did it run, and the
# time before that" and few enough that a per-minute job does not accumulate
# 1440 entries a day inside a filesystem with a 30 MB ceiling.
our $KEEP = 3;

sub root { return ProxmodCron::Config::lease_dir() }

=head2 job_dir($id) / tick_dir($id, $tick) / holder_file($id, $tick)

The three paths, built in one place. Both components are rebuilt from a strict
capture rather than interpolated: they reach mkdir and unlink under /etc/pve.

=cut

sub job_dir {
    my ($id) = @_;

    my ($clean) = ((defined($id) ? $id : '') =~ $ProxmodCron::Config::ID_PATTERN);
    die "invalid job id for a lease\n" if !defined $clean;

    return root() . "/$clean";
}

sub tick_dir {
    my ($id, $tick) = @_;

    my ($clean) = ((defined($tick) ? "$tick" : '') =~ /\A([0-9]{1,20})\z/);
    die "invalid tick for a lease\n" if !defined $clean;

    return job_dir($id) . "/$clean";
}

sub holder_file {
    my ($id, $tick) = @_;
    return tick_dir($id, $tick) . '/holder';
}

=head2 acquire($id, $tick, %opts)

Race for one tick. Returns C<($result, $why)>:

=over

=item C<won>

This node claimed the tick and must run the job.

=item C<taken>

Another node claimed it first. Do not run.

=item C<unavailable>

The claim could not be made at all — no quorum, no pmxcfs, or not root. Do not
run, and say which.

=back

C<node> names the holder written into the tick. Nothing reads it to make a
decision; it is there so the grid and the CLI can answer "which node ran this",
which is the first question anyone asks about a job that moves.

=cut

sub acquire {
    my ($id, $tick, %opts) = @_;

    my $dir = tick_dir($id, $tick);

    my ($result, $why) = _claim($dir);

    return ($result, $why) if $result ne 'won';

    note($id, $tick, {
        node => $opts{node},
        state => 'running',
        started => time(),
        run => $opts{run},
    });

    return ('won', undef);
}

sub _claim {
    my ($dir) = @_;

    # The mode is what we would choose, not what we get: pmxcfs ignores it and
    # imposes root:www-data 0755 on every directory under /etc/pve — verified on
    # a live cluster. That is the same exposure as cron.cfg sitting beside it,
    # which is right, since the lease says no more than the store already does.
    # The mode still matters off pmxcfs, where the tests run.
    return ('won', undef) if mkdir($dir, 0700);

    my $err = $!;

    return ('taken', undef) if $err == EEXIST;

    # First claim for this job, or the first since the lease tree was pruned
    # away. Build the parents and race once more — but only once, so a
    # permanently missing /etc/pve cannot turn into a loop.
    if ($err == ENOENT) {
        return ('unavailable', _why(ENOENT)) if !_make_parents($dir);

        return ('won', undef) if mkdir($dir, 0700);

        my $second = $!;
        return ('taken', undef) if $second == EEXIST;
        return ('unavailable', _why($second));
    }

    return ('unavailable', _why($err));
}

sub _make_parents {
    my ($dir) = @_;

    my $parent = $dir;
    $parent =~ s{/[^/]*\z}{};

    my @missing;
    my $walk = $parent;

    # Up to the mount point and no further. Creating /etc/pve itself would turn
    # "pmxcfs is not mounted" into a real directory on the root filesystem that
    # pmxcfs then cannot mount over.
    while ($walk ne '' && $walk ne '/' && !-d $walk) {
        return 0 if $walk eq ProxmodCron::Config::pve_dir();
        unshift @missing, $walk;
        $walk =~ s{/[^/]*\z}{};
    }

    return 0 if !-d ProxmodCron::Config::pve_dir();

    for my $step (@missing) {
        next if mkdir($step, 0700);
        return 0 if !-d $step;
    }

    return -d $parent ? 1 : 0;
}

sub _why {
    my ($err) = @_;

    local $! = $err;

    return 'the cluster filesystem is read-only, so this node is not quorate'
        if $err == EROFS;

    return 'the lease needs a write inside /etc/pve, which only root may make'
        if $err == EACCES || $err == EPERM;

    return 'the cluster filesystem is not mounted' if $err == ENOENT;

    return "the lease could not be claimed: $!";
}

=head2 note($id, $tick, $fields)

Merge fields into a tick's holder record. Only the node that won the tick calls
this, so no locking is involved — and a failure is swallowed, because the claim
is the mkdir and this file is what the claim is B<about>, not the claim itself.

=cut

sub note {
    my ($id, $tick, $fields) = @_;

    my $path = eval { holder_file($id, $tick) };
    return 0 if !defined $path;

    my $existing = holder($id, $tick) || {};

    my %merged = (%$existing, %$fields);
    delete $merged{$_} for grep { !defined $merged{$_} } keys %merged;

    my $ok = eval {
        ProxmodCron::Config::write_atomic($path,
            JSON::PP->new->utf8->canonical->encode(\%merged), 0600);
        1;
    };

    return $ok ? 1 : 0;
}

=head2 holder($id, $tick)

One tick's holder record, or undef. Fail-soft in every direction: this is
reporting, and a lease written by a newer node must not break an older one's
grid.

=cut

sub holder {
    my ($id, $tick) = @_;

    my $path = eval { holder_file($id, $tick) };
    return undef if !defined $path;

    open(my $fh, '<', $path) or return undef;
    binmode($fh);
    local $/;
    my $raw = <$fh>;
    close($fh);

    return undef if !defined $raw || $raw !~ /\S/;

    my $data = eval { JSON::PP->new->utf8->relaxed->decode($raw) };
    return undef if !$data || ref($data) ne 'HASH';

    my %out;

    for my $key (qw(node state run)) {
        next if !defined $data->{$key} || ref($data->{$key});
        my ($clean) = ("$data->{$key}" =~ /\A([\x20-\x7e]{0,128})\z/);
        $out{$key} = $clean if defined $clean;
    }

    for my $key (qw(started finished exit signal duration_ms)) {
        next if !defined $data->{$key} || ref($data->{$key});
        my ($clean) = ("$data->{$key}" =~ /\A(-?[0-9]{1,20})\z/);
        $out{$key} = 0 + $clean if defined $clean;
    }

    return \%out;
}

=head2 ticks($id)

The claimed ticks for one job, newest first.

=cut

sub ticks {
    my ($id) = @_;

    my $dir = eval { job_dir($id) };
    return [] if !defined $dir;

    opendir(my $dh, $dir) or return [];
    my @ticks;
    while (defined(my $entry = readdir($dh))) {
        my ($clean) = ($entry =~ /\A([0-9]{1,20})\z/);
        next if !defined $clean;
        push @ticks, 0 + $clean;
    }
    closedir($dh);

    return [sort { $b <=> $a } @ticks];
}

=head2 latest($id)

The newest claimed tick and its holder, as C<< { tick, node, state, ... } >>, or
undef. What the datacenter grid shows for a job that moves.

=cut

sub latest {
    my ($id) = @_;

    my $ticks = ticks($id);
    return undef if !@$ticks;

    my $tick = $ticks->[0];

    return { %{ holder($id, $tick) || {} }, tick => $tick };
}

=head2 prune($live, %opts)

Drop what is no longer interesting: every tick beyond the newest C<$KEEP> for a
job that still exists, and everything belonging to a job that does not. C<$live>
is a hashref of the cluster job ids that are still defined.

Idempotent, and silent about failures. Every node runs this every minute from
the sync anchor, so all but one of them will find the work already done — and on
a node that has lost quorum every removal fails, which is correct: pruning is
housekeeping, not something worth reporting as a fault.

Returns the number of tick directories removed.

=cut

sub prune {
    my ($live, %opts) = @_;

    my $keep = defined($opts{keep}) ? $opts{keep} : $KEEP;

    my $root = root();

    opendir(my $dh, $root) or return 0;
    my @jobs;
    while (defined(my $entry = readdir($dh))) {
        my ($clean) = ($entry =~ $ProxmodCron::Config::ID_PATTERN);
        next if !defined $clean;
        next if !-d "$root/$clean";
        push @jobs, $clean;
    }
    closedir($dh);

    my $removed = 0;

    for my $id (@jobs) {
        my $ticks = ticks($id);

        my @doomed = ($live && $live->{$id})
            ? (@$ticks > $keep ? @{$ticks}[$keep .. $#$ticks] : ())
            : @$ticks;

        for my $tick (@doomed) {
            $removed++ if _remove_tick($id, $tick);
        }

        # An empty directory for a job that is gone. Left behind it would be
        # resurrected as an empty shell by every future prune.
        rmdir(job_dir($id)) if !$live || !$live->{$id};
    }

    return $removed;
}

sub _remove_tick {
    my ($id, $tick) = @_;

    my $dir = tick_dir($id, $tick);

    # One level deep by construction: a tick directory holds the holder file and
    # nothing else. Walking it explicitly rather than reaching for remove_tree
    # keeps a recursive delete rooted in /etc/pve out of the package.
    if (opendir(my $dh, $dir)) {
        while (defined(my $entry = readdir($dh))) {
            next if $entry eq '.' || $entry eq '..';
            my ($clean) = ($entry =~ /\A([\w.-]{1,64})\z/);
            next if !defined $clean;
            unlink("$dir/$clean");
        }
        closedir($dh);
    }

    return rmdir($dir) ? 1 : 0;
}

1;
