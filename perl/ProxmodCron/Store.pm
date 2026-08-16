package ProxmodCron::Store;

use strict;
use warnings;

use ProxmodCron::Config;
use ProxmodCron::Journal;
use ProxmodCron::Registry;
use ProxmodCron::Sync;

# The mutation primitives: lock, validate, write, render, record.
#
# Three layers sit on top of this and must not each grow their own copy:
#
#   ProxmodCron::Client   another extension's backend  -> origin: extension
#   ProxmodCron::API2::*  an authenticated user        -> origin: user
#   proxmod-cronctl       an administrator at a shell  -> origin: user
#
# What differs between them is who is allowed to call and what origin gets
# stamped. What must not differ is the locking, the validation, the render that
# follows a write, and the audit record — so all four live here.
#
# This module does NO authorization. It runs as root with no authenticated user
# to check against; it is the layer below authorization, the same relationship
# PVE::Jobs has to PVE::API2::Cluster::Jobs. A caller acting on behalf of a user
# checks first.

our $VERSION = '0.1.0';

# Set by ProxmodCron.pm when it is running inside a daemon that has PVE::Cluster
# available. Takes ($code) and runs it under a cluster-wide lock. When unset the
# cluster store is serialised only node-locally, which is all a non-daemon
# caller can do anyway.
our $CLUSTER_LOCK;

# How long a live-owner lookup is trusted. Orphan detection scans proxmod's
# manifest directory, and GET jobs must not do that once per row.
our $OWNER_CACHE_TTL = 30;

my $owner_cache;
my $owner_cache_at = 0;

=head2 lock_scope($scope, $code)

Run C<$code> holding the right lock for the scope. The cluster store needs a
cluster-wide lock, because two nodes editing it at once is the ordinary case,
not the exotic one.

=cut

sub lock_scope {
    my ($scope, $code) = @_;

    return ProxmodCron::Config::lock($scope, $code) if $scope ne 'cluster';

    return ProxmodCron::Config::lock($scope, $code) if !$CLUSTER_LOCK;

    # Node-local lock inside the cluster lock: the cluster lock serialises
    # nodes, this serialises workers within this node.
    return $CLUSTER_LOCK->(sub { ProxmodCron::Config::lock($scope, $code) });
}

=head2 create($scope, $id, $cfg, %opts)

Create a job. Dies if the id is taken. C<%opts>: C<origin>, C<owner>, C<audit>.

=cut

sub create {
    my ($scope, $id, $cfg, %opts) = @_;

    my $written;

    lock_scope($scope, sub {
        my $store = ProxmodCron::Config::load($scope);

        die "a job named '$id' already exists in the $scope scope\n"
            if $store->{jobs}->{$id};

        $written = _stamp($cfg, %opts);

        _assert_valid($scope, $id, $written);

        $store->{jobs}->{$id} = $written;
        ProxmodCron::Config::save($scope, $store);
    });

    _after_write($scope, $id, $written, 'create', \%opts);

    return $written;
}

=head2 ensure($scope, $id, $cfg, %opts)

Create the job, or bring an existing one into line with C<$cfg>.

B<It never writes C<enabled> on a job that already exists.> This is the single
most important line in the module. An extension calls ensure() on every daemon
start; if it wrote C<enabled> each time, an administrator's decision to stop a
job would be silently reverted within seconds of the next restart, and the whole
enable/disable split would be worthless. An extension that genuinely needs to
re-enable its own job calls set_enabled(), which is deliberately separate and
conspicuous.

=cut

sub ensure {
    my ($scope, $id, $cfg, %opts) = @_;

    my $written;
    my $action;

    lock_scope($scope, sub {
        my $store = ProxmodCron::Config::load($scope);
        my $existing = $store->{jobs}->{$id};

        if (!$existing) {
            $action = 'create';
            $written = _stamp($cfg, %opts);
        } else {
            $action = 'update';

            _assert_owner($existing, $opts{owner}, $id);

            my %merged = (%$existing, %{ _stamp($cfg, %opts) });

            # The administrator's switch, preserved across every ensure().
            $merged{enabled} = $existing->{enabled};

            $written = \%merged;
        }

        _assert_valid($scope, $id, $written);

        $store->{jobs}->{$id} = $written;
        ProxmodCron::Config::save($scope, $store);
    });

    _after_write($scope, $id, $written, $action, \%opts);

    return $written;
}

=head2 update($scope, $id, $delta, %opts)

Merge C<$delta> into an existing job. C<enabled> is refused here: it has its own
call, so that the one mutation permitted on an extension-owned job is enforced
by routing rather than by a conditional buried in a general update path.

=cut

sub update {
    my ($scope, $id, $delta, %opts) = @_;

    die "use set_enabled() to enable or disable a job\n"
        if exists $delta->{enabled};

    my $written;

    lock_scope($scope, sub {
        my $store = ProxmodCron::Config::load($scope);

        my $existing = $store->{jobs}->{$id}
            or die "no job named '$id' in the $scope scope\n";

        _assert_owner($existing, $opts{owner}, $id) if $opts{owner};

        my %merged = (%$existing, %$delta);

        # A delta value of undef clears the key, which is how the API empties an
        # optional field. JSON null arrives as undef, so the two are one thing.
        delete $merged{$_} for grep { !defined $merged{$_} } keys %merged;

        # Origin, owner and enabled are never taken from a delta. Origin and
        # owner are set once, at creation, by the layer that knows who is
        # calling; enabled has its own call.
        for my $key (qw(origin owner enabled)) {
            if (defined $existing->{$key}) {
                $merged{$key} = $existing->{$key};
            } else {
                delete $merged{$key};
            }
        }

        _assert_valid($scope, $id, \%merged);

        $store->{jobs}->{$id} = \%merged;
        ProxmodCron::Config::save($scope, $store);

        $written = \%merged;
    });

    _after_write($scope, $id, $written, 'update', \%opts);

    return $written;
}

=head2 set_enabled($scope, $id, $enabled, %opts)

Switch a job on or off. The one mutation that is permitted on a job whatever its
origin: an administrator must always be able to stop a job without uninstalling
the extension that created it.

=cut

sub set_enabled {
    my ($scope, $id, $enabled, %opts) = @_;

    my $value = $enabled ? 1 : 0;
    my $written;

    lock_scope($scope, sub {
        my $store = ProxmodCron::Config::load($scope);

        my $existing = $store->{jobs}->{$id}
            or die "no job named '$id' in the $scope scope\n";

        $existing->{enabled} = $value;
        ProxmodCron::Config::save($scope, $store);

        $written = $existing;
    });

    _after_write($scope, $id, $written, ($value ? 'enable' : 'disable'), \%opts);

    return $written;
}

=head2 remove($scope, $id, %opts)

Delete a job.

=cut

sub remove {
    my ($scope, $id, %opts) = @_;

    my $removed;

    lock_scope($scope, sub {
        my $store = ProxmodCron::Config::load($scope);

        $removed = delete $store->{jobs}->{$id}
            or die "no job named '$id' in the $scope scope\n";

        _assert_owner($removed, $opts{owner}, $id) if $opts{owner};

        ProxmodCron::Config::save($scope, $store);
    });

    _after_write($scope, $id, $removed, 'remove', \%opts);

    return $removed;
}

=head2 capabilities($job, %opts)

The origin half of the §2.1 table: what may be done to this job through any
surface, before anyone asks who is asking.

    { origin, owner, orphaned, can_toggle, can_edit, can_delete }

The privilege half is ANDed on by the API layer. There is exactly one
implementation of each half, and the write methods consult the same helpers, so
a row can never advertise an action the enforcement would refuse.

=cut

sub capabilities {
    my ($job, %opts) = @_;

    my $origin = $job->{origin} || 'user';

    return {
        origin => 'user',
        orphaned => 0,
        can_toggle => 1,
        can_edit => 1,
        can_delete => 1,
    } if $origin ne 'extension';

    my $owner = $job->{owner};

    # An extension that is no longer installed cannot be asked to remove its own
    # job. Without this the row would be permanently undeletable and the only
    # fix would be hand-editing the store.
    my $orphaned = (!defined($owner) || !owner_live($owner, %opts)) ? 1 : 0;

    return {
        origin => 'extension',
        owner => $owner,
        orphaned => $orphaned,
        # The rule the whole design turns on: a dynamically added entry is
        # enable/disable only. The extension owns its schedule and its
        # existence; the administrator owns whether it runs.
        can_toggle => 1,
        can_edit => 0,
        can_delete => $orphaned,
    };
}

=head2 owner_live($id, %opts)

Whether an owning extension is still installed and enabled.

Defaults to B<true> when proxmod's registry cannot be consulted — outside a
daemon, say. Guessing "gone" would offer a Remove button for a job whose owner
is alive and would recreate it, which is worse than offering nothing.

=cut

sub owner_live {
    my ($id, %opts) = @_;

    my $live = $opts{live} || live_owners();

    return 1 if !defined $live;

    return $live->{$id} ? 1 : 0;
}

=head2 live_owners()

The set of extension ids proxmod would load right now, or undef when that
cannot be determined. Cached briefly: this scans a manifest directory, and
GET jobs must not do that once per row.

=cut

sub live_owners {
    my $now = time();

    return $owner_cache if $owner_cache && ($now - $owner_cache_at) < $OWNER_CACHE_TTL;

    my $exts = eval {
        require Proxmod::Registry;
        Proxmod::Registry::load();
    };

    return undef if !$exts || ref($exts) ne 'ARRAY';

    $owner_cache = { map { $_->{id} => 1 } @$exts };
    $owner_cache_at = $now;

    return $owner_cache;
}

sub _reset_owner_cache { $owner_cache = undef; $owner_cache_at = 0; return }

sub _stamp {
    my ($cfg, %opts) = @_;

    my %job = %$cfg;

    delete $job{origin};
    delete $job{owner};

    if (($opts{origin} || 'user') eq 'extension') {
        die "an extension-owned job needs an owner\n" if !defined $opts{owner};
        $job{origin} = 'extension';
        $job{owner} = $opts{owner};
    } else {
        $job{origin} = 'user';
    }

    return \%job;
}

# An extension may only touch its own jobs. Without this, one extension could
# quietly take over another's schedule.
sub _assert_owner {
    my ($job, $owner, $id) = @_;

    return if !defined $owner;

    die "job '$id' is not managed by $owner\n"
        if ($job->{origin} || 'user') ne 'extension'
        || !defined($job->{owner})
        || $job->{owner} ne $owner;

    return;
}

sub _assert_valid {
    my ($scope, $id, $cfg) = @_;

    my $errors = ProxmodCron::Config::validate_job($id, $cfg,
        scope => $scope, allow_origin => 1);

    die "job '$id' is not valid: " . join('; ', @$errors) . "\n" if @$errors;

    return;
}

# Render immediately rather than waiting for the next anchor run, so the UI is
# not a minute behind itself, and record the change where a query will find it.
sub _after_write {
    my ($scope, $id, $job, $action, $opts) = @_;

    # The REST layer records the attempt *before* it acts, because §8.6 wants
    # the refused attempts too and those never reach here. It sets `audited` so
    # the same mutation is not written to the journal twice under two different
    # attributions.
    _audit($scope, $id, $job, $action, $opts->{audit}) if !$opts->{audited};

    my $result = eval { ProxmodCron::Sync::run() };

    return if !$result;

    ProxmodCron::Journal::send_entry({
        PROXMOD_CRON_JOB => $id,
        PROXMOD_CRON_SCOPE => $scope,
        PROXMOD_CRON_EVENT => 'change',
        MESSAGE_ID => $ProxmodCron::Journal::MESSAGE_ID{change},
        PRIORITY => 4,
        MESSAGE => "sync after $action of $scope job '$id': $_",
    }) for @{ $result->{errors} || [] };

    return;
}

=head2 audit($scope, $id, $job, $action, $audit)

Record a mutation. Two sinks, deliberately:

Proxmod::Log is what a human reads in `journalctl -u pvedaemon`; its 'proxmod:'
prefix is the framework's contract and proxmod-verify greps for it.

The journal 'change' record carries the same PROXMOD_CRON_JOB field the run
records carry, so `journalctl PROXMOD_CRON_JOB=nightly-trim` answers the
question that actually gets asked during an incident: who last changed this job,
and how has it run since. Management history and execution history interleave in
one timeline because they share one field.

Neither sink can serve the other's purpose. Collapsing them would mean either
breaking proxmod-verify or giving up the indexed query.

Never a ticket, password, token or key in either — the journal is readable by
anyone with Sys.Syslog or shell access, which is more people than the API is.

=cut

sub audit {
    my ($scope, $id, $job, $action, $audit) = @_;
    return _audit($scope, $id, $job, $action, $audit);
}

sub _audit {
    my ($scope, $id, $job, $action, $audit) = @_;

    $audit ||= {};

    my $who = $audit->{user} || $audit->{owner} || 'root';
    my $via = $audit->{via} || 'store';

    my @parts = ("$action $scope job '$id' by $who via $via");

    push @parts, "type=$job->{type}" if $job && $job->{type};
    push @parts, "schedule=$job->{schedule}" if $job && $job->{schedule};
    push @parts, 'enabled=' . ($job->{enabled} ? 1 : 0) if $job && exists $job->{enabled};
    push @parts, "authorization=$audit->{authorization}" if $audit->{authorization};
    push @parts, "privileges=$audit->{privileges}" if $audit->{privileges};
    push @parts, "outcome=$audit->{outcome}" if $audit->{outcome};
    push @parts, "command=$audit->{command}" if $audit->{command};

    my $message = join(' ', @parts);

    eval {
        require Proxmod::Log;
        Proxmod::Log::log_info("cron: $message");
    };

    ProxmodCron::Journal::send_entry({
        PROXMOD_CRON_JOB => $id,
        PROXMOD_CRON_SCOPE => $scope,
        PROXMOD_CRON_EVENT => 'change',
        PROXMOD_CRON_USER => $who,
        MESSAGE_ID => $ProxmodCron::Journal::MESSAGE_ID{change},
        PRIORITY => ($audit->{outcome} && $audit->{outcome} eq 'refused') ? 4 : 5,
        MESSAGE => $message,
    });

    return;
}

1;
