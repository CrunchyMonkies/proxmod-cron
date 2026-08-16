package PVE::API2;

use strict;
use warnings;

use PVE::RESTHandler;

# A miniature of Proxmox's real API tree, big enough to register into and to
# get the routing wrong in the same ways the real one does.
#
# The mount points below are copied from pve-manager 9.1.1 rather than invented:
# PVE/API2.pm, PVE/API2/Nodes.pm, PVE/API2/Cluster.pm and (for the greedy case)
# PVE/API2/Storage/Status.pm. Proxmod::API's decisions about *where* it is safe
# to mount are only meaningful against the real shape.
#
# Registration in PVE::RESTHandler is process-global, so this tree is built by a
# function rather than at compile time: a test resets the registry and rebuilds.

our @CLASSES = qw(
    PVE::API2
    PVE::API2::Cluster
    PVE::API2::Nodes
    PVE::API2::Nodes::Nodeinfo
    PVE::API2::Storage::Config
    PVE::API2::Storage::Status
    PVE::API2::Storage::Content
    PVE::API2::Qemu
    PVE::API2::Hardware
);

{
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    for my $class (@CLASSES) {
        push @{"${class}::ISA"}, 'PVE::RESTHandler'
            if !grep { $_ eq 'PVE::RESTHandler' } @{"${class}::ISA"};
    }
}

sub _index_method {
    my ($class, %extra) = @_;
    return {
        name => 'index',
        path => '',
        method => 'GET',
        permissions => { user => 'all' },
        description => "Index of $class.",
        parameters => { additionalProperties => 0, properties => {} },
        returns => { type => 'array' },
        code => sub { return [] },
        %extra,
    };
}

sub _build_tree {
    PVE::RESTHandler::_reset();

    PVE::API2->register_method({ subclass => 'PVE::API2::Cluster', path => 'cluster' });
    PVE::API2->register_method({ subclass => 'PVE::API2::Nodes', path => 'nodes' });
    PVE::API2->register_method({ subclass => 'PVE::API2::Storage::Config', path => 'storage' });
    PVE::API2->register_method(_index_method('PVE::API2'));

    # /nodes/{node} — the level below this one is a regex, which is why nothing
    # may ever be registered as a sibling folder of {node}.
    PVE::API2::Nodes->register_method({
        subclass => 'PVE::API2::Nodes::Nodeinfo',
        path => '{node}',
    });
    PVE::API2::Nodes->register_method(_index_method('PVE::API2::Nodes'));

    # /nodes/{node}/* — a flat set of folders, and therefore somewhere a new
    # folder can be added.
    PVE::API2::Nodes::Nodeinfo->register_method({ subclass => 'PVE::API2::Qemu', path => 'qemu' });
    PVE::API2::Nodes::Nodeinfo->register_method(
        { subclass => 'PVE::API2::Hardware', path => 'hardware' });
    PVE::API2::Nodes::Nodeinfo->register_method(
        { subclass => 'PVE::API2::Storage::Status', path => 'storage' });
    PVE::API2::Nodes::Nodeinfo->register_method(_index_method('PVE::API2::Nodes::Nodeinfo'));

    PVE::API2::Cluster->register_method(_index_method('PVE::API2::Cluster'));
    PVE::API2::Qemu->register_method(_index_method('PVE::API2::Qemu'));
    PVE::API2::Hardware->register_method(_index_method('PVE::API2::Hardware'));
    PVE::API2::Storage::Config->register_method(_index_method('PVE::API2::Storage::Config'));

    # The worked failure case. fragmentDelimiter => '' makes everything after
    # 'content' collapse into a single path fragment, so a method registered
    # deeper in this subtree is unreachable no matter how it is spelled.
    PVE::API2::Storage::Status->register_method({
        subclass => 'PVE::API2::Storage::Content',
        fragmentDelimiter => '',
        path => '{storage}/content',
    });
    PVE::API2::Storage::Status->register_method(_index_method('PVE::API2::Storage::Status'));

    PVE::API2::Storage::Content->register_method(
        _index_method('PVE::API2::Storage::Content'));
    PVE::API2::Storage::Content->register_method(
        _index_method('PVE::API2::Storage::Content', name => 'info', path => '{volume}'));

    return;
}

1;
