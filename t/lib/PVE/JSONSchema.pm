package PVE::JSONSchema;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(get_standard_option);

# STUB. Enough of Proxmox's PVE::JSONSchema for an example extension written
# the way a real one should be written to load in the unit tests.
#
# proxmod itself never calls into this: it hands a method's schema to
# register_method untouched and lets Proxmox validate against it. The stub
# exists so examples/ can use get_standard_option — which is what an extension
# author should reach for — instead of hand-rolling a node parameter and
# teaching the wrong habit.

my $standard_options = {
    'pve-node' => {
        description => "The cluster node name.",
        type => 'string',
        format => 'pve-node',
    },
    'pve-storage-id' => {
        description => "The storage identifier.",
        type => 'string',
        format => 'pve-storage-id',
    },
};

sub get_standard_option {
    my ($name, $base) = @_;

    my $std = $standard_options->{$name}
        or die "no such standard option '$name'\n";

    my $res = { %$std, %{ $base || {} } };

    return $res;
}

# proxmod's tests never exercise validation; a method's `code` is called
# directly. Fail loudly rather than silently accepting anything, so that a test
# which starts depending on real validation says so.
sub validate {
    die "PVE::JSONSchema::validate is not implemented in the test stub\n";
}

1;
