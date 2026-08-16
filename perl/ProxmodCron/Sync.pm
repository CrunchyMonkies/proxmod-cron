package ProxmodCron::Sync;

use strict;
use warnings;

use Fcntl qw(O_WRONLY O_CREAT O_EXCL LOCK_EX LOCK_NB);
use POSIX ();

use ProxmodCron::Config;
use ProxmodCron::Registry;
use ProxmodCron::Render;
use ProxmodCron::State;

# Convergence: definitions -> the two generated /etc/cron.d files.
#
# This lives in a module rather than in proxmod-cron-sync because three callers
# need it and must not disagree: the cron anchor every minute, the REST layer
# after every write (so the UI is not a minute behind itself), and
# `proxmod-cronctl sync`.
#
# No PVE, and no proxmod: the anchor runs this from cron.

our $VERSION = '0.1.0';

=head2 run(%opts)

Render both scopes and write what changed. Options: C<wait> (block for the lock
instead of skipping), C<dry_run>.

Returns C<< { skipped, changed, results => { $scope => 'written'|'removed'|undef },
errors => [...] } >>. Never dies — a failure on one scope must not stop the
other, because the two stores are independent and a broken cluster file should
not take this node's own jobs down with it.

=cut

sub run {
    my (%opts) = @_;

    my $lock = _lock($opts{wait});

    # Another sync is already doing this work. Skipping is correct: cron runs
    # the anchor every minute and a backlog of waiting copies helps nobody.
    return { skipped => 1, changed => 0, results => {}, errors => [] } if !$lock;

    my @errors = ProxmodCron::Registry::load_plugins();

    my $nodename = nodename();

    my %results;
    my $changed = 0;
    my %live;

    for my $scope (@{ ProxmodCron::Config::scopes() }) {
        my $store = ProxmodCron::Config::load($scope);

        push @errors, $store->{error} if $store->{error};

        $live{ ProxmodCron::State::key($scope, $_) } = 1
            for keys %{ $store->{jobs} || {} };

        my $text = ProxmodCron::Render::render($scope, $store, $nodename);
        my $path = ProxmodCron::Render::path($scope);

        my $result = eval { apply($path, $text, dry_run => $opts{dry_run}) };
        if ($@) {
            my $why = $@;
            $why =~ s/\s+\z//;
            push @errors, $why;
            next;
        }

        $results{$scope} = $result;
        $changed++ if $result;
    }

    # Keep the derived cache from growing a record for every job that ever
    # existed. It is only an index; losing an entry costs a reindex.
    ProxmodCron::State::prune(\%live);

    return {
        skipped => 0,
        changed => $changed,
        results => \%results,
        errors => \@errors,
    };
}

=head2 apply($path, $text, %opts)

Write the rendered text, or remove the file when nothing renders. Returns
'written', 'removed', or undef for no change.

=cut

sub apply {
    my ($path, $text, %opts) = @_;

    my $current = _slurp($path);

    if (!defined $text) {
        return undef if !defined $current;
        return 'removed' if $opts{dry_run};
        unlink($path) or die "cannot remove $path: $!\n";
        return 'removed';
    }

    # The whole point of comparing: cron watches mtimes, and rewriting an
    # identical file every minute would make it reload every minute forever.
    return undef if defined($current) && $current eq $text;

    return 'written' if $opts{dry_run};

    ProxmodCron::Config::mkdir_p(ProxmodCron::Config::cron_d());

    # 0644 and root-owned. cron silently ignores a file in /etc/cron.d that is
    # group- or world-writable — a failure mode with no error message anywhere.
    my $tmp = "$path.tmp.$$";
    unlink($tmp);

    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644)
        or die "cannot create $tmp: $!\n";
    binmode($fh);
    print {$fh} $text or do { close($fh); unlink($tmp); die "cannot write $tmp: $!\n" };
    close($fh) or do { unlink($tmp); die "cannot write $tmp: $!\n" };

    chmod(0644, $tmp);

    rename($tmp, $path) or do { unlink($tmp); die "cannot replace $path: $!\n" };

    return 'written';
}

=head2 nodename()

This node's short name, without loading PVE::INotify. PVE uses the short
hostname and so do we: a cluster job targeted at 'pve1' has to match what the
API calls this node.

=cut

sub nodename {
    my $name = (POSIX::uname())[1];

    $name = '' if !defined $name;
    $name =~ s/\..*\z//;

    my ($clean) = ($name =~ /\A([a-zA-Z0-9][a-zA-Z0-9-]{0,62})\z/);

    return $clean;
}

sub _lock {
    my ($wait) = @_;

    my $dir = ProxmodCron::Config::state_dir();

    eval { ProxmodCron::Config::mkdir_p($dir) };
    die "cannot create $dir\n" if !-d $dir;

    my $path = ProxmodCron::Config::sync_lock_path();

    open(my $fh, '>>', $path) or die "cannot open $path: $!\n";

    my $flags = $wait ? LOCK_EX : (LOCK_EX | LOCK_NB);
    return undef if !flock($fh, $flags);

    # Returned so the handle outlives this sub; the lock is released when the
    # caller drops it or the process exits.
    return $fh;
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
