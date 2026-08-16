package Proxmod::Registry;

use strict;
use warnings;

# STUB. ProxmodCron::Store::live_owners() consults proxmod's registry to decide
# whether an extension-owned job is orphaned, and orphaning is what makes such a
# job removable (§2.1). That is a rule worth testing, so the test needs to be
# able to say "this extension is loaded" and "now it is not".
#
# The real load() returns a list of manifest hashes; only `id` is read.

our @EXTENSIONS;

# proxmod-cronctl is tested as the script it is, so t/13 sets the loaded set
# through the environment: a package variable does not cross a fork+exec, and
# without this every extension-owned job would look orphaned in a subprocess.
if (defined $ENV{PROXMOD_CRON_TEST_EXTENSIONS}) {
    @EXTENSIONS = grep { length } split(/,/, $ENV{PROXMOD_CRON_TEST_EXTENSIONS});
}

sub load {
    my (%opt) = @_;

    return [map { { id => $_ } } @EXTENSIONS];
}

# Test-only. Note that ProxmodCron::Store caches the answer for
# $ProxmodCron::Store::OWNER_CACHE_TTL seconds, so a test that changes this must
# also call ProxmodCron::Store::_reset_owner_cache().
sub _set { @EXTENSIONS = @_; return }

1;
