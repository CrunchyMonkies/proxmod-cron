package ProxmodCron;

use strict;
use warnings;

use ProxmodCron::API2::Cluster;
use ProxmodCron::API2::Node;
use ProxmodCron::Config;
use ProxmodCron::JobType::Command;
use ProxmodCron::Registry;
use ProxmodCron::Store;

# The entry point Proxmod::Backend calls, once per daemon, with an API object
# scoped to this extension.
#
# Everything here runs inside proxmod's own eval, so anything that dies costs
# this extension and nothing else. That is licence to fail loudly about our own
# registration — but not licence to be careless about what we touch on the way,
# because the daemon this runs inside is pvedaemon.
#
# This module is the only one in the package that may assume PVE. Config,
# Render, Spec, State, Registry, Journal, Runs, Sync, Store and Client are all
# loaded by proxmod-cron-sync from cron under a bare perl with no PVE at all,
# and the ProxmodCron::API2::* modules below are the boundary where that stops.

our $VERSION = '202608.22.0';

sub proxmod_register {
    my ($api) = @_;

    # The built-in type. Registered here rather than at module load so the
    # registry is empty in tests until something asks for it, and so this is the
    # one place the type set is assembled.
    ProxmodCron::Registry::register('ProxmodCron::JobType::Command');

    # Plugin types contributed by other extensions. A plugin whose module fails
    # to load is logged and skipped — its jobs then render as disabled comment
    # lines naming the missing type, which is the renderer's job, not ours.
    eval { ProxmodCron::Registry::load_plugins() };
    _log_warn("loading job type plugins failed: $@") if $@;

    _install_cluster_lock();

    ProxmodCron::API2::Cluster::register($api);
    ProxmodCron::API2::Node::register($api);

    return;
}

# Serialise cluster-store writes across nodes.
#
# /etc/pve is a shared filesystem, so two administrators on two nodes can
# read-modify-write the same cron.cfg in the same second and one of them
# silently loses a job. flock does not help: it is local to a node. cfs_lock_file
# is pmxcfs's own cluster-wide lock and is the only thing that does.
#
# It is installed as a coderef rather than called directly from Store so that
# Store stays PVE-free — the same split the rest of the package observes. When
# PVE::Cluster is not available (a single-node install without a cluster
# filesystem, or a test run), Store falls back to its local flock, which is
# correct for exactly that case.
#
# cfs_lock_domain, not cfs_lock_file: the latter dies "unknown file" for
# anything not passed to cfs_register_file, and we deliberately read
# /etc/pve/proxmod/cron.cfg as bytes rather than registering a parser with
# pmxcfs. A named domain lock is the cluster-wide mutex without the file
# registration, which is exactly what is wanted here.
sub _install_cluster_lock {
    my $ok = eval {
        require PVE::Cluster;
        PVE::Cluster->import();
        PVE::Cluster->can('cfs_lock_domain') ? 1 : 0;
    };

    if (!$ok) {
        _log_warn("PVE::Cluster unavailable, cluster store writes use a local lock only");
        return;
    }

    $ProxmodCron::Store::CLUSTER_LOCK = sub {
        my ($code) = @_;

        my $result = PVE::Cluster::cfs_lock_domain('proxmod-cron', 10, $code);

        # cfs_lock_domain reports failure in $@ rather than by dying, and a
        # write that silently did not happen is the worst outcome available
        # here.
        die $@ if $@;

        return $result;
    };

    return;
}

sub _log_warn {
    my ($message) = @_;

    # Proxmod::Log is the framework's sink; it prefixes 'proxmod:' which
    # proxmod-verify greps for. If it is somehow not loadable we are inside a
    # daemon with no safe alternative, so the message is dropped rather than
    # written somewhere it does not belong.
    eval { require Proxmod::Log; Proxmod::Log::log_warn("cron: $message") };

    return;
}

1;

__END__

=head1 NAME

ProxmodCron - cron management for Proxmox VE, as a proxmod extension

=head1 DESCRIPTION

Job definitions live in two stores: F</etc/pve/proxmod/cron.cfg> for the cluster
and F</etc/proxmod/cron.cfg> for this node. They are rendered into real
F</etc/cron.d> files by C<proxmod-cron-sync>, which the package's own cron
anchor runs every minute, and executed by cron itself. There is no daemon and no
timer; what an administrator sees with C<cat> is what runs.

Runs and their captured output are recorded in journald as structured entries
with indexed C<PROXMOD_CRON_*> fields, by C<proxmod-cron-exec>. journald is the
store of record; F</var/lib/proxmod/cron/last-run.json> is a rebuildable cache
for the grid's status column and nothing more.

=head1 SEE ALSO

L<ProxmodCron::Client> for the interface other extensions use, and
F<docs/extension-api.md> for the contract in full — including the paragraph on
authorization, which a caller acting on behalf of a user must not skip.

=cut
