package ProxmodCron::Config;

use strict;
use warnings;

use Fcntl qw(O_WRONLY O_CREAT O_EXCL LOCK_EX LOCK_NB);
use File::Path ();
use JSON::PP ();

use ProxmodCron::Registry;
use ProxmodCron::Spec;

# The two definition stores.
#
# JSON rather than PVE::SectionConfig, and our own validation rather than
# PVE::JSONSchema, for one reason: proxmod-cron-sync loads this module from cron
# with no PVE in @INC. Every dependency here is core Perl.
#
# Strict on write, tolerant of unknown keys on read — a newer node in the
# cluster may write a field this one does not know about, and dropping the whole
# file over it would stop this node's jobs from rendering.

our $VERSION = '202608.22.0';

# Test override, guarded the same way proxmod's own does it: honoured only when
# the process is not root, so it can never be used to redirect a production
# write into someone's home directory.
my $PREFIX = ($> != 0 && defined $ENV{PROXMOD_CRON_TEST_PREFIX})
    ? _untaint_path($ENV{PROXMOD_CRON_TEST_PREFIX})
    : '';

our $CLUSTER_FILE = "$PREFIX/etc/pve/proxmod/cron.cfg";
our $NODE_FILE = "$PREFIX/etc/proxmod/cron.cfg";
our $STATE_DIR = "$PREFIX/var/lib/proxmod/cron";
our $CRON_D = "$PREFIX/etc/cron.d";

# The pmxcfs mount point and the two things under it that are not the store.
#
# They are named here rather than in the modules that use them for the same
# reason every other path is: one place decides, so the test prefix applies to
# all of them and a production path cannot be spelled out a second time slightly
# differently. PVE_DIR itself matters because its existence — not the
# readability of anything inside it — is how ProxmodCron::Cluster tells a host
# with no cluster filesystem from one whose /etc/pve it may not enter.
our $PVE_DIR = "$PREFIX/etc/pve";
our $MEMBERS_FILE = "$PVE_DIR/.members";
our $LEASE_DIR = "$PVE_DIR/proxmod/cron-lease";

our $STORE_VERSION = 1;

# The registry cannot compute this itself — it is loaded before this module and
# would have to read the environment a second time. One place decides.
$ProxmodCron::Registry::TYPES_DIR = "$PREFIX/usr/share/proxmod-cron/types.d"
    if $PREFIX ne '';

# Matches proxmod's own extension-id rule, so a job id is always safe in a
# filename, a URL path segment and a journal field value. The capture group is
# not decoration: this pattern is used to untaint, and a match with no group
# yields 1 rather than the string.
our $ID_PATTERN = qr/\A([a-z0-9][a-z0-9_-]{0,63})\z/;

my @SCOPES = qw(cluster node);

sub _untaint_path {
    my ($path) = @_;
    return '' if !defined $path;
    my ($clean) = ($path =~ m{\A([\w./@+-]{0,4096})\z});
    return defined($clean) ? $clean : '';
}

=head2 file_for($scope)

Where a scope's definitions live.

=cut

sub file_for {
    my ($scope) = @_;

    return $CLUSTER_FILE if $scope eq 'cluster';
    return $NODE_FILE if $scope eq 'node';

    die "unknown scope '$scope'\n";
}

sub scopes { return [@SCOPES] }

=head2 prefix()

The test prefix, or ''. Other modules build their own absolute paths from this
rather than reading the environment again, so there is one place that decides
whether the override is honoured.

=cut

sub prefix { return $PREFIX }

sub state_dir { return $STATE_DIR }

=head2 pve_dir() / members_file() / lease_dir()

The cluster filesystem, the membership file pmxcfs publishes, and the root of
the per-tick lease tree used by C<run_on: any> jobs.

=cut

sub pve_dir { return $PVE_DIR }

sub members_file { return $MEMBERS_FILE }

sub lease_dir { return $LEASE_DIR }

=head2 job_lock_path($scope, $id)

The per-job run lock. proxmod-cron-exec holds it for the life of a run;
ProxmodCron::Runs tests it to tell a job that is still running from one whose
node lost power mid-run. Both must agree on the path, so it is defined once.

=cut

sub job_lock_path {
    my ($scope, $id) = @_;
    return "$STATE_DIR/run-$scope-$id.lock";
}

sub sync_lock_path { return "$STATE_DIR/sync.lock" }

sub cron_d { return $CRON_D }

=head2 load($scope)

Read a store. B<Never dies.> Returns
C<< { version, mailto, jobs => {...}, error => $msg } >>, where C<error> is set
and C<jobs> is empty if the file could not be read or parsed.

Fail-soft is the point: a corrupt cluster file arriving over pmxcfs must not
stop this node's own jobs from rendering. The error is reported through the API
and by C<proxmod-cronctl doctor> rather than by taking the renderer down.

=cut

sub load {
    my ($scope) = @_;

    my $file = file_for($scope);
    my $empty = { version => $STORE_VERSION, mailto => '', jobs => {} };

    my $raw = _slurp($file);

    # A missing store is the normal state of a fresh install, not an error.
    return $empty if !defined $raw;

    return { %$empty, error => "$file is empty" } if $raw !~ /\S/;

    my $data = eval { JSON::PP->new->utf8->relaxed->decode($raw) };
    if (!$data || ref($data) ne 'HASH') {
        my $why = $@ || 'not a JSON object';
        $why =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*\z//;
        $why =~ s/\s+\z//;
        return { %$empty, error => "$file is not valid JSON: $why" };
    }

    my $jobs = $data->{jobs};
    $jobs = {} if !$jobs || ref($jobs) ne 'HASH';

    my $store = {
        version => $data->{version} || $STORE_VERSION,
        mailto => defined($data->{mailto}) ? $data->{mailto} : '',
        jobs => {},
    };

    # Store-level operational limits, read by proxmod-cron-exec. They live in
    # the node store because they are about this node's journald, not about the
    # jobs themselves.
    for my $key (qw(max_lines max_line_bytes)) {
        next if !defined $data->{$key};
        my ($value) = ("$data->{$key}" =~ /\A([0-9]{1,9})\z/);
        $store->{$key} = 0 + $value if defined $value && $value > 0;
    }

    my @rejected;
    for my $id (sort keys %$jobs) {
        my $cfg = $jobs->{$id};

        if (ref($cfg) ne 'HASH') {
            push @rejected, $id;
            next;
        }

        # Untaint on the way in. Everything here came off the filesystem, and
        # inside pvedaemon that means it is tainted; a job id reaches a filename
        # and a journal field, and a schedule reaches a crontab line.
        my $clean = _untaint_job($id, $cfg);
        if (!$clean) {
            push @rejected, $id;
            next;
        }

        $store->{jobs}->{ $clean->{id} } = $clean->{cfg};
    }

    $store->{error} = 'ignored malformed job definitions: ' . join(', ', @rejected)
        if @rejected;

    return $store;
}

=head2 untaint_job($id, $cfg, %opts)

The cleaned job, or undef if any part of it could not be described exactly.

The REST layer runs incoming parameters through this as well as the loader
running stored ones through it, so there is one definition of what a job may
contain. Pass C<< partial => 1 >> for an update delta, where a key that was not
supplied must stay absent rather than being filled with a default that would
then overwrite the stored value.

=cut

sub untaint_job {
    my ($id, $cfg, %opts) = @_;

    my $clean = _untaint_job($id, $cfg, %opts);

    return $clean ? $clean->{cfg} : undef;
}

# Rebuild a job from strict captures. Anything that does not match is dropped
# rather than laundered — a job we cannot describe exactly is a job we should
# not be executing as root.
sub _untaint_job {
    my ($id, $cfg, %opts) = @_;

    my $partial = $opts{partial} ? 1 : 0;

    my ($clean_id) = ($id =~ $ID_PATTERN);
    return undef if !defined $clean_id;

    my %out;

    if (!$partial || defined $cfg->{type}) {
        my ($type) = (($cfg->{type} || '') =~ /\A([a-z0-9][a-z0-9_-]{0,63})\z/);
        return undef if !defined $type;
        $out{type} = $type;
    }

    if (!$partial || defined $cfg->{schedule}) {
        my ($schedule) = (($cfg->{schedule} || '') =~ /\A([\x20-\x7e]{1,256})\z/);
        return undef if !defined $schedule;
        $out{schedule} = $schedule;
    }

    if (!$partial || defined $cfg->{origin}) {
        my ($origin) = (($cfg->{origin} || 'user') =~ /\A(user|extension)\z/);
        return undef if !defined $origin;
        $out{origin} = $origin;
    }

    if (defined $cfg->{owner}) {
        my ($owner) = ($cfg->{owner} =~ $ID_PATTERN);
        return undef if !defined $owner;
        $out{owner} = $owner;
    }

    if (!$partial || defined $cfg->{user}) {
        my ($user) = ((defined($cfg->{user}) ? $cfg->{user} : 'root')
            =~ /\A([a-z_][a-z0-9_-]{0,31})\z/);
        return undef if !defined $user;
        $out{user} = $user;
    }

    if (defined $cfg->{comment}) {
        # Comments render into the cron file as a comment line, so a newline
        # would let one break out of it.
        my ($comment) = ($cfg->{comment} =~ /\A([^\0\n\r]{0,512})\z/);
        $out{comment} = defined($comment) ? $comment : '';
    }

    for my $key (qw(enabled track keep_output)) {
        next if $partial && !defined $cfg->{$key};
        $out{$key} = _bool($cfg->{$key}, 1);
    }

    if (defined $cfg->{nodes}) {
        return undef if ref($cfg->{nodes}) ne 'ARRAY';
        my @nodes;
        for my $node (@{ $cfg->{nodes} }) {
            my ($clean) = (($node || '') =~ /\A([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)\z/);
            return undef if !defined $clean;
            push @nodes, $clean;
        }
        $out{nodes} = \@nodes;
    }

    # 'all' is the absent value as well as the default, so a store written by an
    # older version reads back as exactly what it meant.
    if (defined $cfg->{run_on}) {
        my ($run_on) = ((ref($cfg->{run_on}) ? '' : $cfg->{run_on}) =~ /\A(all|any)\z/);
        return undef if !defined $run_on;
        $out{run_on} = $run_on;
    }

    # Type-specific keys. The plugin's schema decides what they mean; this only
    # decides that they cannot carry a NUL or a newline into an argv.
    my %known = map { $_ => 1 } qw(
        type schedule origin owner user comment enabled track keep_output nodes
        run_on
    );

    for my $key (sort keys %$cfg) {
        next if $known{$key};

        my ($clean_key) = ($key =~ /\A([a-zA-Z_][a-zA-Z0-9_]{0,63})\z/);
        return undef if !defined $clean_key;

        my $value = $cfg->{$key};
        my $clean_value = _untaint_value($value);
        return undef if !defined $clean_value;

        $out{$clean_key} = $clean_value;
    }

    return { id => $clean_id, cfg => \%out };
}

sub _untaint_value {
    my ($value) = @_;

    return '' if !defined $value;

    if (ref($value) eq 'ARRAY') {
        my @out;
        for my $item (@$value) {
            my $clean = _untaint_value($item);
            return undef if !defined $clean;
            push @out, $clean;
        }
        return \@out;
    }

    return undef if ref($value) && !JSON::PP::is_bool($value);

    my $scalar = JSON::PP::is_bool($value) ? ($value ? 1 : 0) : "$value";

    my ($clean) = ($scalar =~ /\A([^\0\n\r]{0,4096})\z/);
    return $clean;
}

sub _bool {
    my ($value, $default) = @_;

    return $default ? 1 : 0 if !defined $value;
    return $value ? 1 : 0 if JSON::PP::is_bool($value);
    return 0 if $value eq '' || $value eq '0' || lc("$value") eq 'false';
    return 1;
}

=head2 validate_job($id, $cfg, %opts)

Every problem with a job definition, as a list of strings. Empty means valid.

Used by the REST layer before a write and by C<proxmod-cronctl validate>, so a
bad definition is refused at the boundary rather than discovered by the renderer
at 02:30.

=cut

sub validate_job {
    my ($id, $cfg, %opts) = @_;

    my @errors;

    push @errors, "job id '$id' is not valid (lowercase letters, digits,"
        . " '-' and '_', starting with a letter or digit, up to 64 characters)"
        if !defined $id || $id !~ $ID_PATTERN;

    return \@errors if !$cfg || ref($cfg) ne 'HASH';

    push @errors, 'job has no type' if !defined $cfg->{type};

    my ($schedule_ok, $schedule_why) = ProxmodCron::Spec::validate($cfg->{schedule});
    push @errors, "schedule: $schedule_why" if !$schedule_ok;

    push @errors, "user '$cfg->{user}' is not a valid user name"
        if defined $cfg->{user} && $cfg->{user} !~ /\A[a-z_][a-z0-9_-]{0,31}\z/;

    push @errors, 'comment must not contain a newline'
        if defined $cfg->{comment} && $cfg->{comment} =~ /[\n\r]/;

    if (defined $cfg->{nodes}) {
        if (ref($cfg->{nodes}) ne 'ARRAY') {
            push @errors, "'nodes' must be a list of node names";
        } else {
            push @errors, "'nodes' is only meaningful in the cluster scope"
                if ($opts{scope} || '') eq 'node';
        }
    }

    push @errors, @{ _validate_run_on($cfg, %opts) } if defined $cfg->{run_on};

    push @errors, "'origin' is set by the server and cannot be supplied"
        if $cfg->{origin} && !$opts{allow_origin};

    if (defined $cfg->{type}) {
        push @errors, @{ ProxmodCron::Registry::validate($cfg->{type}, $cfg) };
    }

    return \@errors;
}

# What 'run_on: any' needs, each refused with the reason rather than just the
# rule. They are all surprising, and an administrator who is told
# "run_on: any needs user: root" and nothing else has to go and find out why.
#
# The defaults matter here: a job that says nothing about track or user still
# has an effective value for both, and checking only what was written would let
# a job through whose type defaults to track: false.
sub _validate_run_on {
    my ($cfg, %opts) = @_;

    my $run_on = ref($cfg->{run_on}) ? '' : $cfg->{run_on};

    return ["'run_on' must be 'all' or 'any'"]
        if $run_on ne 'all' && $run_on ne 'any';

    return [] if $run_on eq 'all';

    my @errors;

    push @errors, "'run_on: any' is only meaningful in the cluster scope"
        if ($opts{scope} || '') eq 'node';

    my $class = ProxmodCron::Registry::lookup($cfg->{type});

    push @errors, "'run_on: any' needs track: true, because the run record is the"
        . ' only thing that says which node ran it'
        if !_track_for($cfg, $class);

    push @errors, "'run_on: any' needs user: root, because claiming the lease is a"
        . ' write inside /etc/pve and no other user may make one'
        if _user_for($cfg, $class) ne 'root';

    # A bad schedule is already reported by the caller; saying so twice helps
    # nobody. @reboot is a valid schedule and still cannot work here: there is no
    # scheduled time for two nodes to agree on, so both would run it.
    my $parsed = eval { ProxmodCron::Spec::parse($cfg->{schedule}) };
    push @errors, "'run_on: any' needs a real schedule: \@reboot has no scheduled"
        . ' time for the nodes to agree on, so every node would run it'
        if $parsed && $parsed->{reboot};

    return \@errors;
}

# The effective value of the two keys whose default comes from the job type.
# Shared by effective() and the run_on rules above so the two cannot disagree
# about what an absent key means.
sub _track_for {
    my ($cfg, $class) = @_;

    return $cfg->{track} ? 1 : 0 if defined $cfg->{track};

    return ($class && !$class->track_default()) ? 0 : 1;
}

sub _user_for {
    my ($cfg, $class) = @_;

    return $cfg->{user} if $cfg->{user};

    return $class ? $class->run_as() : 'root';
}

=head2 save($scope, $store)

Write a store atomically. Mode 0600 — a job definition is a command that runs as
root, so the file is as sensitive as the commands in it.

This does I<not> take the lock itself: a caller doing read-modify-write must
hold it across both halves, so taking it here would either be redundant or, on a
second open of the same file, deadlock against the caller's own handle. Use
lock() around the whole sequence.

=cut

sub save {
    my ($scope, $store) = @_;

    my $file = file_for($scope);

    my $out = {
        version => $STORE_VERSION,
        mailto => defined($store->{mailto}) ? $store->{mailto} : '',
        jobs => $store->{jobs} || {},
    };

    for my $key (qw(max_lines max_line_bytes)) {
        $out->{$key} = 0 + $store->{$key} if $store->{$key};
    }

    # canonical => sorted keys, so an unchanged store produces a byte-identical
    # file and pmxcfs does not replicate a no-op change across the cluster.
    my $json = JSON::PP->new->utf8->pretty->canonical->encode($out);

    mkdir_p(_dirname($file));
    _write_atomic($file, $json, 0600);

    return 1;
}

=head2 lock($scope, $code)

Run C<$code> holding this scope's exclusive lock. The lock lives under
/var/lib/proxmod/cron rather than next to the config, because the cluster config
is on pmxcfs and flock semantics there are not something to rely on.

Note this is a I<node-local> lock. Cross-node serialisation for the cluster
store is pmxcfs's job and is taken by the API layer, which is the only caller
that has PVE::Cluster available.

=cut

sub lock {
    my ($scope, $code) = @_;

    my $dir = $STATE_DIR;
    mkdir_p($dir);

    my $path = "$dir/$scope.lock";

    open(my $fh, '>>', $path) or die "cannot open lock $path: $!\n";

    my $ok = 0;
    for (1 .. 50) {
        if (flock($fh, LOCK_EX | LOCK_NB)) {
            $ok = 1;
            last;
        }
        select(undef, undef, undef, 0.1);
    }

    if (!$ok) {
        close($fh);
        die "timed out waiting for the $scope lock\n";
    }

    my @result = eval { $code->() };
    my $err = $@;

    close($fh);

    die $err if $err;

    return wantarray ? @result : $result[0];
}

sub _slurp {
    my ($path) = @_;

    # Bytes, not characters: open() with an :encoding layer cannot open a
    # tainted path inside a daemon under -T [PVE-F-040]. Decode afterwards.
    open(my $fh, '<', $path) or return undef;
    binmode($fh);
    local $/;
    my $content = <$fh>;
    close($fh);

    return defined($content) ? $content : '';
}

=head2 write_atomic($path, $content, $mode)

Write a file by creating a temporary beside it and renaming over the target, so
a reader never sees a half-written file and a crash never leaves one behind.
Public because ProxmodCron::Cluster writes its cache the same way and a second
implementation of this is a second thing to get subtly wrong.

=cut

sub write_atomic { return _write_atomic(@_) }

sub _write_atomic {
    my ($path, $content, $mode) = @_;

    my $tmp = "$path.tmp.$$";

    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, $mode)
        or die "cannot create $tmp: $!\n";
    binmode($fh);

    print {$fh} $content
        or do { close($fh); unlink($tmp); die "cannot write $tmp: $!\n" };

    close($fh)
        or do { unlink($tmp); die "cannot write $tmp: $!\n" };

    chmod($mode, $tmp);

    rename($tmp, $path)
        or do { unlink($tmp); die "cannot replace $path: $!\n" };

    return 1;
}

sub mkdir_p {
    my ($dir) = @_;

    return 1 if -d $dir;

    eval { File::Path::make_path($dir, { mode => 0700 }) };

    die "cannot create $dir: $@\n" if !-d $dir;

    return 1;
}

sub _dirname {
    my ($path) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]*\z}{};
    return $dir eq '' ? '/' : $dir;
}

=head2 effective($scope, $store, $id)

A job with its defaults filled in, as the renderer and the API both want it.
One place decides what C<track> defaults to so the two can never disagree.

=cut

sub effective {
    my ($scope, $store, $id) = @_;

    my $cfg = $store->{jobs}->{$id};
    return undef if !$cfg;

    my $class = ProxmodCron::Registry::lookup($cfg->{type});

    my %job = (
        %$cfg,
        id => $id,
        scope => $scope,
        origin => $cfg->{origin} || 'user',
        enabled => defined($cfg->{enabled}) ? ($cfg->{enabled} ? 1 : 0) : 1,
        user => _user_for($cfg, $class),
    );

    $job{track} = _track_for($cfg, $class);

    $job{keep_output} = defined($cfg->{keep_output}) ? ($cfg->{keep_output} ? 1 : 0) : 1;

    # Cluster only, and absent means 'all' — which is what every job written
    # before this key existed meant and still means. A node-scoped job has no
    # run_on at all rather than a defaulted one: there is nothing for it to
    # choose between, and an inert field in every node job's API row would only
    # invite somebody to set it.
    $job{run_on} = (($cfg->{run_on} || '') eq 'any') ? 'any' : 'all'
        if $scope eq 'cluster';

    return \%job;
}

=head2 targets_node($job, $nodename)

Whether a cluster job renders on this node. An absent or empty C<nodes> list, or
one containing 'all', means every node — the permissive reading, because a
cluster job with no targeting is the common case and should not silently run
nowhere.

This is about B<rendering>, not about running. A C<run_on: any> job renders on
every node it targets and then races for the tick lease at fire time, so this
answers "may this node be a candidate", not "will this node run it".

=cut

sub targets_node {
    my ($job, $nodename) = @_;

    my $nodes = $job->{nodes};
    return 1 if !$nodes || ref($nodes) ne 'ARRAY' || !@$nodes;

    for my $node (@$nodes) {
        return 1 if $node eq 'all';
        return 1 if defined($nodename) && $node eq $nodename;
    }

    return 0;
}

1;
