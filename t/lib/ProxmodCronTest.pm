package ProxmodCronTest;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
    prefix_tree
    cluster_members
    reset_registry
    rpcenv
    register_type
    call
    refused
    journal_sink
    journal_runner
    journalctl_stub
    filter_entries
    write_store
    read_file
    slurp
);

use File::Path ();
use File::Temp ();
use JSON::PP ();

# Shared setup for the test suite.
#
# The one thing every test has to get right is the prefix. ProxmodCron::Config
# reads PROXMOD_CRON_TEST_PREFIX once, at module load, and every other module
# builds its paths from Config::prefix() rather than from the environment. So a
# test must set the variable before the first `use ProxmodCron::Config`, which
# in practice means inside a BEGIN block:
#
#     BEGIN { require ProxmodCronTest; ProxmodCronTest::prefix_tree() }
#     use ProxmodCron::Config;
#
# Setting it afterwards silently does nothing, which is the sort of failure that
# passes locally and writes to /etc in CI — so prefix_tree() refuses to run as
# root, the same guard Config itself applies to honouring the variable at all.

our $TMPDIR;

# Create a disposable tree and point the package at it. Returns the root.
sub prefix_tree {
    die "the test suite must not run as root: it would write to real paths\n"
        if $> == 0;

    $TMPDIR = File::Temp->newdir('proxmod-cron-XXXXXXXX', TMPDIR => 1);

    my $root = "$TMPDIR";

    File::Path::make_path(
        "$root/etc/proxmod",
        "$root/etc/pve/proxmod",
        "$root/etc/cron.d",
        "$root/etc/cron.hourly",
        "$root/etc/cron.daily",
        "$root/etc/cron.weekly",
        "$root/etc/cron.monthly",
        "$root/var/lib/proxmod/cron",
        "$root/var/spool/cron/crontabs",
        "$root/usr/share/proxmod-cron/types.d",
    );

    $ENV{PROXMOD_CRON_TEST_PREFIX} = $root;

    # A tree with /etc/pve in it is a tree that claims pmxcfs is mounted, and a
    # mounted pmxcfs always publishes .members. Without one, every test looks
    # like a host whose cluster state cannot be read — which is a real fault, and
    # not the one any of these tests are about.
    #
    # The default is an unclustered PVE host: no 'cluster' key, which is what
    # pmxcfs writes in local mode. No 'nodename' either, so ProxmodCron::Cluster
    # falls back to this machine's hostname and node targeting keeps working.
    cluster_members(root => $root);

    return $root;
}

# Write /etc/pve/.members. With no arguments: a standalone node. With
# C<nodes>, a cluster:
#
#     cluster_members(quorate => 0, nodes => { pve1 => 1, pve2 => 0 })
sub cluster_members {
    my (%opt) = @_;

    my $root = $opt{root} || $ENV{PROXMOD_CRON_TEST_PREFIX};

    my %body = (version => 1);
    $body{nodename} = $opt{nodename} if defined $opt{nodename};

    if ($opt{nodes}) {
        my $id = 0;
        $body{cluster} = {
            name => ($opt{name} || 'test'),
            quorate => (exists $opt{quorate} ? ($opt{quorate} ? 1 : 0) : 1),
            nodes => scalar(keys %{ $opt{nodes} }),
        };
        $body{nodelist} = {
            map { $_ => { id => ++$id, online => ($opt{nodes}->{$_} ? 1 : 0) } }
                keys %{ $opt{nodes} }
        };
    }

    File::Path::make_path("$root/etc/pve");

    open(my $fh, '>', "$root/etc/pve/.members") or die "cannot write .members: $!";
    print {$fh} JSON::PP->new->canonical->encode(\%body);
    close($fh);

    return "$root/etc/pve/.members";
}

# Forget every job type, including the built-in. Registration is process-global,
# so a test that registers a fixture type has to start from a clean registry or
# it inherits whatever ran before it in the same file.
sub reset_registry {
    require ProxmodCron::Registry;
    require ProxmodCron::Store;

    ProxmodCron::Registry::_reset();
    ProxmodCron::Store::_reset_owner_cache();

    return;
}

# A scripted PVE::RPCEnvironment. Grants are (path => [privs]).
#
#     my $env = rpcenv('alice@pve', '/vms/101' => ['VM.Backup']);
sub rpcenv {
    my ($user, %grants) = @_;

    require PVE::RPCEnvironment;

    PVE::RPCEnvironment::_reset();

    my $env = PVE::RPCEnvironment::get();
    $env->set_user($user);

    for my $path (sort keys %grants) {
        $env->grant($user, $path, @{ $grants{$path} });
    }

    return $env;
}

# Define a job type inline. Saves each test file hand-rolling a package, and
# means the delegation rules are exercised against a plugin that looks like one
# an extension author would actually write.
#
#     register_type('acme-backup', privs => sub { [["/vms/$_[0]{vmid}", ['VM.Backup']]] });
sub register_type {
    my ($type, %args) = @_;

    require ProxmodCron::JobType;
    require ProxmodCron::Registry;

    my $package = 'ProxmodCronTest::Type::' . ($type =~ s/[^a-z0-9]/_/gr);

    my $properties = $args{properties} || { vmid => { type => 'integer' } };
    my $build = $args{build} || sub { ['/bin/true'] };
    my $privs = $args{privs};
    my $run_as = $args{run_as} || 'root';

    # Redefinition is normal here, not a mistake: a test that resets the registry
    # between subtests re-registers the same fixture type into the same package,
    # and the warning would bury the assertions it sits between.
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    no warnings 'redefine';
    @{"${package}::ISA"} = ('ProxmodCron::JobType');
    *{"${package}::type"} = sub { $type };
    *{"${package}::title"} = sub { $args{title} || $type };
    *{"${package}::properties"} = sub { $properties };
    *{"${package}::build_command"} = sub { my ($c, $cfg) = @_; return $build->($cfg) };
    *{"${package}::run_as"} = sub { $run_as };
    *{"${package}::required_privs"} = sub { my ($c, $cfg) = @_; return $privs->($cfg) }
        if $privs;
    use strict 'refs';

    ProxmodCron::Registry::register($package);

    return $package;
}

# Call a registered API method the way pvedaemon would: the declarative
# `permissions` gate first, then the body.
#
# Calling $info->{code} directly would prove only half of each endpoint. In
# production the permissions hash is enforced by pve-http-server before the body
# is entered, so a method whose body forgot its assert() would still be refused
# there — and a test that skips that step would report a hole that does not
# exist, or miss one that does. Both halves, in the production order.
sub call {
    my ($class, $name, $param) = @_;

    require PVE::RPCEnvironment;

    $param ||= {};

    my $info = $class->map_method_by_name($name);
    my $rpcenv = PVE::RPCEnvironment::get();

    $rpcenv->check_api2_permissions($info->{permissions}, $rpcenv->get_user(), $param);

    return $class->handle($info, $param);
}

# Call and expect a refusal. Returns the exception, so a test can assert on the
# message — "403" alone does not tell an administrator which privilege to ask
# for, and a refusal whose message names the wrong thing is its own bug.
sub refused {
    my ($class, $name, $param) = @_;

    my $result = eval { call($class, $name, $param) };

    return undef if !$@;

    return $@;
}

# A throwaway journald socket in the prefix tree, and a reader for what lands in
# it. Returns a coderef that drains and returns the datagrams received so far.
#
# Every test wants this, not only t/10-journal.t. Without it ProxmodCron::Journal
# finds no socket, falls down its degradation ladder to /usr/bin/logger, and
# forks a process per entry — which makes the suite slow, makes it write to the
# host's real journal, and makes a test that asserts on a run's output depend on
# whether the machine happens to run systemd. A real socket keeps the native
# path under test, which is the path production uses.
sub journal_sink {
    require Socket;
    require ProxmodCron::Journal;
    require ProxmodCron::Config;

    my $path = ProxmodCron::Config::state_dir() . '/journal.sock';

    unlink($path);

    socket(my $sock, Socket::AF_UNIX(), Socket::SOCK_DGRAM(), 0)
        or die "cannot create a datagram socket: $!\n";
    bind($sock, Socket::pack_sockaddr_un($path))
        or die "cannot bind $path: $!\n";

    # Non-blocking, so draining an empty socket returns instead of hanging a
    # test that expected an entry which was never sent.
    require Fcntl;
    my $flags = fcntl($sock, Fcntl::F_GETFL(), 0);
    fcntl($sock, Fcntl::F_SETFL(), $flags | Fcntl::O_NONBLOCK());

    $ProxmodCron::Journal::SOCKET_PATH = $path;

    # Not optional. The module connects once and caches the handle, so without
    # this a second journal_sink() in the same process keeps sending into the
    # first test's socket — or into a path that no longer exists, which puts it
    # on the fallback ladder with no visible failure.
    ProxmodCron::Journal::reset();

    my @held;
    my $sweep = sub {
        while (1) {
            my $buf;
            last if !defined recv($sock, $buf, 256 * 1024, 0);
            last if !defined $buf || $buf eq '';
            push @held, _parse_journal_datagram($buf);
        }
        return;
    };

    # A socket nobody reads is a socket that fills, and a full AF_UNIX datagram
    # queue makes send() block — which is how the whole suite deadlocks in a
    # container, where a fresh network namespace caps the queue at ten datagrams
    # instead of the host's five hundred. Most tests here call journal_sink()
    # only to keep entries off the real journal and never drain it, so the queue
    # is emptied after every send instead of when someone remembers to ask. The
    # datagram still crosses a real socket, which is the point of using one.
    _wrap_journal_send($sweep);

    return sub {
        $sweep->();
        my @entries = @held;
        @held = ();
        return \@entries;
    };
}

# Installed once per process. A second journal_sink() replaces the sweep rather
# than stacking another wrapper on top of the first.
our $JOURNAL_SWEEP;

sub _wrap_journal_send {
    my ($sweep) = @_;

    my $already = defined $JOURNAL_SWEEP;
    $JOURNAL_SWEEP = $sweep;
    return if $already;

    my $inner = \&ProxmodCron::Journal::_send_native;

    no strict 'refs';       ## no critic
    no warnings 'redefine'; ## no critic
    *ProxmodCron::Journal::_send_native = sub {
        my $sent = $inner->(@_);
        $JOURNAL_SWEEP->() if $JOURNAL_SWEEP;
        return $sent;
    };

    return;
}

# The native protocol, read back: KEY=value\n for a simple value, or KEY\n, a
# 64-bit little-endian length, the raw bytes and \n for one containing a newline.
sub _parse_journal_datagram {
    my ($buf) = @_;

    my %fields;
    my $pos = 0;
    my $len = length($buf);

    while ($pos < $len) {
        my $nl = index($buf, "\n", $pos);
        last if $nl < 0;

        my $line = substr($buf, $pos, $nl - $pos);

        if ($line =~ /\A([^=]+)=(.*)\z/s) {
            $fields{$1} = $2;
            $pos = $nl + 1;
            next;
        }

        # Framed value: the key alone, then 8 bytes of length. Read as two
        # 32-bit halves, the same way Journal writes it, so this does not
        # quietly need a 64-bit perl that the module itself does not.
        my ($lo, $hi) = unpack('V V', substr($buf, $nl + 1, 8));
        my $size = $lo + $hi * 4294967296;
        $fields{$line} = substr($buf, $nl + 9, $size);
        $pos = $nl + 9 + $size + 1;
    }

    return \%fields;
}

# Stand in for journalctl, from a list of entries as `journalctl -o json` would
# have decoded them.
#
# It filters the way journald does rather than returning everything: different
# field names AND together, repeats of one field OR. ProxmodCron::Runs builds
# every query out of those two rules, so a runner that ignored the matches would
# make a query that selects the wrong entries look correct.
sub journal_runner {
    my ($entries) = @_;

    require ProxmodCron::Runs;

    $ProxmodCron::Runs::RUNNER = sub { return filter_entries($entries, $_[0]) };

    return;
}

# journald's own selection rules, applied to a fixture: different field names
# AND together, repeats of one field OR, --after-cursor resumes, and -n counts
# entries from the end.
#
# Shared by journal_runner and journalctl_stub rather than written twice. The
# stub is a separate process and cannot see the coderef, but it can call this —
# and a second copy of these rules would be a second thing to get wrong.
sub filter_entries {
    my ($entries, $args) = @_;

    my %want;
    my $after;
    my $limit;

    for (my $i = 0; $i < @$args; $i++) {
        my $arg = $args->[$i];

        if ($arg eq '--after-cursor') { $after = $args->[++$i]; next }
        if ($arg eq '-n') { $limit = $args->[++$i]; next }

        push @{ $want{$1} }, $2 if $arg =~ /\A([A-Z_][A-Z0-9_]*)=(.*)\z/s;
    }

    my @out;
    ENTRY: for my $entry (@$entries) {
        for my $key (sort keys %want) {
            my $have = defined($entry->{$key}) ? $entry->{$key} : '';
            next ENTRY if !grep { $_ eq $have } @{ $want{$key} };
        }
        push @out, $entry;
    }

    if (defined $after) {
        my $from = 0;
        for my $i (0 .. $#out) {
            next if !defined $out[$i]{__CURSOR} || $out[$i]{__CURSOR} ne $after;
            $from = $i + 1;
            last;
        }
        @out = @out[$from .. $#out];
    }

    # -n counts from the end, as journalctl's does.
    @out = @out[-$limit .. -1] if defined($limit) && @out > $limit;

    return \@out;
}

# A stand-in journalctl on disk, for testing proxmod-cronctl as the script it
# is. A package variable cannot cross a fork+exec, so the CLI's subprocess finds
# this through PROXMOD_CRON_TEST_JOURNALCTL — the same root-guarded seam
# ProxmodCron::Runs honours in production, where it is never set.
#
# Returns the path to the argv log, so a test can assert on how the CLI called it.
sub journalctl_stub {
    my ($entries) = @_;

    require ProxmodCron::Config;
    require ProxmodCron::Runs;

    my $dir = ProxmodCron::Config::state_dir();
    my $lib = __FILE__;
    $lib =~ s{/ProxmodCronTest\.pm\z}{};

    my $fixture = "$dir/journal-fixture.json";
    my $argv_log = "$dir/journalctl-argv.txt";
    my $path = "$dir/journalctl";

    open(my $fh, '>', $fixture) or die "cannot write $fixture: $!\n";
    print {$fh} JSON::PP->new->utf8->canonical->encode($entries || []);
    close($fh) or die "cannot write $fixture: $!\n";

    my $body = <<'SCRIPT';
my $log;
if (open($log, '>>', $ARGV_LOG)) {
    print {$log} join("\n", @ARGV), "\n--\n";
    close($log);
}

open(my $in, '<', $FIXTURE) or exit(1);
my $raw = do { local $/; <$in> };
close($in);

my $entries = JSON::PP->new->utf8->decode($raw);

my $json = JSON::PP->new->utf8->canonical;
print $json->encode($_), "\n" for @{ ProxmodCronTest::filter_entries($entries, \@ARGV) };
SCRIPT

    # The two paths are baked into the program rather than passed as arguments:
    # the CLI controls this program's argv, and anything we appended there would
    # be read by the CLI's own parser as a journalctl match.
    my $header = "#!$^X\n"
        . "use strict;\nuse warnings;\n"
        . 'use lib ' . _quote($lib) . ";\n"
        . "use JSON::PP ();\nuse ProxmodCronTest;\n"
        . 'my $FIXTURE = ' . _quote($fixture) . ";\n"
        . 'my $ARGV_LOG = ' . _quote($argv_log) . ";\n";

    open(my $out, '>', $path) or die "cannot write $path: $!\n";
    print {$out} $header, $body;
    close($out) or die "cannot write $path: $!\n";

    chmod(0755, $path);

    unlink($argv_log);

    $ProxmodCron::Runs::JOURNALCTL = $path;
    $ENV{PROXMOD_CRON_TEST_JOURNALCTL} = $path;

    return $argv_log;
}

sub _quote {
    my ($text) = @_;
    my $out = $text;
    $out =~ s/(['\\])/\\$1/g;
    return "'$out'";
}

# Write a store directly, bypassing validation — for testing what happens when
# something already on disk is not what this version would have written.
sub write_store {
    my ($scope, $data) = @_;

    require ProxmodCron::Config;

    my $file = ProxmodCron::Config::file_for($scope);
    my $json = ref($data)
        ? JSON::PP->new->utf8->canonical->pretty->encode($data)
        : $data;

    open(my $fh, '>', $file) or die "cannot write $file: $!\n";
    print {$fh} $json;
    close($fh) or die "cannot write $file: $!\n";

    return $file;
}

sub slurp {
    my ($path) = @_;

    open(my $fh, '<', $path) or return undef;
    local $/;
    my $content = <$fh>;
    close($fh);

    return $content;
}

*read_file = \&slurp;

1;
