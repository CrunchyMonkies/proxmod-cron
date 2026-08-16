package ProxmodCron::Cluster;

use strict;
use warnings;

use JSON::PP ();
use POSIX ();

use ProxmodCron::Config;

# Is this node quorate, and who else is up.
#
# pmxcfs publishes /etc/pve/.members, which is exactly this and nothing else:
#
#   {"nodename":"pve1","version":10,
#    "cluster":{"name":"lab","version":3,"nodes":3,"quorate":1},
#    "nodelist":{"pve1":{"id":1,"online":1,"ip":"10.0.0.1"}, ...}}
#
# Reading it directly rather than calling PVE::Cluster::get_members is not a
# preference. This module is loaded by proxmod-cron-sync and proxmod-cron-exec,
# both of which run from cron under a bare perl with no PVE in @INC — the same
# constraint Config, Spec, Render, State and Sync are written to.
#
# TWO READERS, TWO PATHS. /etc/pve is 0750 root:www-data and a cron job may
# render with a non-root user, so the wrapper cannot count on reading .members
# at all. The root-owned sync anchor therefore copies the answer to
# /var/lib/proxmod/cron/cluster.json, mode 0644, once a minute, and status()
# prefers the authoritative file but falls back to that cache.
#
# EVERYTHING HERE FAILS CLOSED except the one case that must not: a host with no
# cluster filesystem is standalone and is its own quorum, and that is decided by
# whether /etc/pve exists as a directory — a stat any user may make — rather
# than by whether .members could be read, which a non-root user never can.

our $VERSION = '0.1.0';

our $CACHE_VERSION = 1;

# How old the cache may be before it stops being evidence of anything. A node
# whose sync anchor has been dead for ten minutes is a node that should not be
# acting on its last opinion of the cluster.
our $STALE_AFTER = 600;

# Rewrite the cache when its timestamp is older than this even if nothing
# changed, so a healthy node's cache is always comfortably inside the staleness
# window without a write every single minute.
our $REFRESH_AFTER = 300;

sub cache_file { return ProxmodCron::Config::state_dir() . '/cluster.json' }

=head2 nodename()

This node's short name. pmxcfs's own answer when it is available, and the short
hostname otherwise — PVE uses the short hostname, so a cluster job targeted at
'pve1' has to match what the API calls this node.

Defined here rather than in ProxmodCron::Sync because the wrapper needs it too
and must not load the renderer to get it.

=cut

sub nodename {
    my ($status) = @_;

    $status ||= status();

    return $status->{nodename} if defined $status->{nodename};

    my $name = (POSIX::uname())[1];

    $name = '' if !defined $name;
    $name =~ s/\..*\z//;

    my ($clean) = ($name =~ /\A([a-zA-Z0-9][a-zA-Z0-9-]{0,62})\z/);

    return $clean;
}

=head2 membership()

The cluster's state as pmxcfs reports it right now. Returns

    { known, standalone, quorate, nodename, nodes => { $name => { online, id } },
      source, reason }

C<known> is 0 when the question could not be answered — which is B<not> the same
as "not clustered", and is why the caller must not read C<quorate> without it.

=cut

sub membership {
    my $file = ProxmodCron::Config::members_file();

    my $raw = _slurp($file);

    if (!defined $raw) {
        # No cluster filesystem at all: an unclustered PVE host, or a test tree.
        # A single node is its own quorum, and saying otherwise would stop
        # cluster-scoped jobs on every standalone install in existence.
        return {
            known => 1,
            standalone => 1,
            quorate => 1,
            nodename => undef,
            nodes => {},
            source => 'standalone',
        } if !-d ProxmodCron::Config::pve_dir();

        # /etc/pve is there but we cannot read inside it. Almost always because
        # this process is not root. Not an answer, and not a licence to guess.
        return _unknown("cannot read $file: $!");
    }

    my $data = eval { JSON::PP->new->utf8->relaxed->decode($raw) };
    return _unknown("$file is not valid JSON") if !$data || ref($data) ne 'HASH';

    my ($nodename) = ((defined($data->{nodename}) ? $data->{nodename} : '')
        =~ /\A([a-zA-Z0-9][a-zA-Z0-9-]{0,62})\z/);

    my $cluster = $data->{cluster};

    # No 'cluster' key means pmxcfs is running in local mode: a real PVE host
    # that has not been joined to anything.
    return {
        known => 1,
        standalone => 1,
        quorate => 1,
        nodename => $nodename,
        nodes => {},
        source => 'members',
    } if !$cluster || ref($cluster) ne 'HASH';

    my %nodes;
    my $list = $data->{nodelist};
    if ($list && ref($list) eq 'HASH') {
        for my $name (keys %$list) {
            my ($clean) = ($name =~ /\A([a-zA-Z0-9][a-zA-Z0-9-]{0,62})\z/);
            next if !defined $clean;
            my $entry = $list->{$name};
            next if ref($entry) ne 'HASH';
            $nodes{$clean} = { online => $entry->{online} ? 1 : 0 };
            my ($id) = ((defined($entry->{id}) ? "$entry->{id}" : '') =~ /\A([0-9]{1,9})\z/);
            $nodes{$clean}->{id} = 0 + $id if defined $id;
        }
    }

    my $quorate = $cluster->{quorate} ? 1 : 0;

    return {
        known => 1,
        standalone => 0,
        quorate => $quorate,
        nodename => $nodename,
        nodes => \%nodes,
        source => 'members',
        ($quorate ? () : (reason => 'this node is not part of a quorate cluster')),
    };
}

=head2 status()

What a caller should act on: C<membership()> when it could be read, the cache
when it could not, and an unknown — which counts as not quorate — when neither
is available or the cache is stale.

=cut

sub status {
    my $direct = membership();
    return $direct if $direct->{known};

    my $cached = cache_load();
    return _unknown($direct->{reason} . ', and there is no membership cache')
        if !$cached;

    my $age = time() - $cached->{updated};

    # Backwards in time. A clock that jumped is not a reason to distrust the
    # cache; a clock that jumped forward by more than the window would be, and
    # that is caught by the ordinary test below.
    $age = 0 if $age < 0;

    return _unknown("the membership cache is ${age}s old:"
        . ' proxmod-cron-sync is not running on this node')
        if $age > $STALE_AFTER;

    return { %$cached, known => 1, source => 'cache', age => $age };
}

=head2 quorate()

Returns C<(1, undef)> when this node may act on cluster-scoped configuration, and
C<(0, $why)> when it may not. The one place the rule lives, so the wrapper, the
CLI and the API cannot each read C<status()> slightly differently.

=cut

sub quorate {
    my ($status) = @_;

    $status ||= status();

    return (1, undef) if $status->{known} && $status->{quorate};

    return (0, $status->{reason} || 'the cluster state is unknown');
}

=head2 cache_load()

The cached membership, or undef when there is none or it cannot be trusted.
Never dies: this is a cache, and a corrupt one is a cache miss.

=cut

sub cache_load {
    my $raw = _slurp(cache_file());
    return undef if !defined $raw || $raw !~ /\S/;

    my $data = eval { JSON::PP->new->utf8->decode($raw) };
    return undef if !$data || ref($data) ne 'HASH';

    my ($updated) = ((defined($data->{updated}) ? "$data->{updated}" : '')
        =~ /\A([0-9]{1,20})\z/);
    return undef if !defined $updated;

    my ($nodename) = ((defined($data->{nodename}) ? $data->{nodename} : '')
        =~ /\A([a-zA-Z0-9][a-zA-Z0-9-]{0,62})\z/);

    my %nodes;
    if (ref($data->{nodes}) eq 'HASH') {
        for my $name (keys %{ $data->{nodes} }) {
            my ($clean) = ($name =~ /\A([a-zA-Z0-9][a-zA-Z0-9-]{0,62})\z/);
            next if !defined $clean;
            next if ref($data->{nodes}->{$name}) ne 'HASH';
            $nodes{$clean} = { online => $data->{nodes}->{$name}->{online} ? 1 : 0 };
        }
    }

    return {
        standalone => $data->{standalone} ? 1 : 0,
        quorate => $data->{quorate} ? 1 : 0,
        nodename => $nodename,
        nodes => \%nodes,
        updated => 0 + $updated,
        ($data->{quorate} ? () : (reason => 'the last known cluster state was not quorate')),
    };
}

=head2 cache_write($membership)

Refresh the cache from a membership reading. Called by ProxmodCron::Sync, which
is the only thing in the package that runs as root every minute.

Writes when the content changed or when the stored timestamp is older than
C<$REFRESH_AFTER> — the same "do not rewrite an unchanged file" discipline the
renderer applies, with the addition that this file's freshness is itself part of
its meaning.

Returns 'written' or undef. Never dies: a cache that could not be written must
not stop the sync that was about to render two cron files.

=cut

sub cache_write {
    my ($membership) = @_;

    return undef if !$membership || !$membership->{known};

    my $now = time();

    my %body = (
        version => $CACHE_VERSION,
        standalone => $membership->{standalone} ? 1 : 0,
        quorate => $membership->{quorate} ? 1 : 0,
        nodes => {
            map { $_ => { online => $membership->{nodes}->{$_}->{online} ? 1 : 0 } }
                keys %{ $membership->{nodes} || {} }
        },
    );

    $body{nodename} = $membership->{nodename} if defined $membership->{nodename};

    my $existing = cache_load();

    if ($existing) {
        my $same = _same_state($existing, \%body);
        return undef if $same && ($now - $existing->{updated}) < $REFRESH_AFTER
            && $existing->{updated} <= $now;
    }

    my $json = JSON::PP->new->utf8->canonical->pretty->encode({
        %body, updated => $now,
    });

    my $ok = eval {
        ProxmodCron::Config::mkdir_p(ProxmodCron::Config::state_dir());
        # 0644, unlike every other file this package writes: the whole point is
        # that a wrapper running as a non-root job user can read it. It holds
        # node names and up/down flags, which /etc/pve/.members would give the
        # same reader on any cluster they can already log into.
        ProxmodCron::Config::write_atomic(cache_file(), $json, 0644);
        1;
    };

    return $ok ? 'written' : undef;
}

sub _same_state {
    my ($existing, $body) = @_;

    return 0 if $existing->{standalone} != $body->{standalone};
    return 0 if $existing->{quorate} != $body->{quorate};

    my $have = $existing->{nodes} || {};
    my $want = $body->{nodes} || {};

    return 0 if scalar(keys %$have) != scalar(keys %$want);

    for my $name (keys %$want) {
        return 0 if !$have->{$name};
        return 0 if $have->{$name}->{online} != $want->{$name}->{online};
    }

    return 1;
}

sub _unknown {
    my ($reason) = @_;

    return {
        known => 0,
        standalone => 0,
        quorate => 0,
        nodename => undef,
        nodes => {},
        source => 'unknown',
        reason => $reason,
    };
}

sub _slurp {
    my ($path) = @_;

    open(my $fh, '<', $path) or return undef;
    binmode($fh);
    local $/;
    my $content = <$fh>;
    close($fh);

    return defined($content) ? $content : '';
}

1;
