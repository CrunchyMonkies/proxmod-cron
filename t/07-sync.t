#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/../perl", "$FindBin::Bin/lib";

BEGIN {
    require ProxmodCronTest;
    ProxmodCronTest::prefix_tree();
}

use Fcntl qw(LOCK_EX LOCK_NB);

use ProxmodCron::Config;
use ProxmodCron::JobType::Command;
use ProxmodCron::Registry;
use ProxmodCron::Render;
use ProxmodCron::State;
use ProxmodCron::Sync;

# Convergence: definitions -> /etc/cron.d.
#
# This is the loop that replaces a daemon. The anchor runs it every minute, the
# REST layer runs it after every write, and `proxmod-cronctl sync` runs it by
# hand — three callers that must agree, which is why it is a module and not
# inline in the script.
#
# Deliberately, this file loads no PVE module and does not load ProxmodCron.pm.
# Sync runs from cron, outside any daemon, and one accidental `use PVE::…` in
# anything it pulls in would turn every minute's anchor run into a failure that
# only shows up on a real host. Subtest 1 asserts that by inspecting %INC after
# a full run, which is a claim this file can only make honestly because it is
# not itself a PVE consumer.

plan tests => 11;

ProxmodCron::Registry::register('ProxmodCron::JobType::Command');

my $NODENAME = ProxmodCron::Sync::nodename();

sub cluster_path { return ProxmodCron::Render::path('cluster') }
sub node_path { return ProxmodCron::Render::path('node') }

sub cfg {
    my (%over) = @_;
    return {
        type => 'command',
        schedule => '30 3 * * *',
        command => ['/usr/sbin/fstrim', '-a'],
        %over,
    };
}

sub store {
    my (%jobs) = @_;
    return { version => 1, mailto => '', jobs => { %jobs } };
}

sub wipe {
    for my $scope (qw(cluster node)) {
        ProxmodCronTest::write_store($scope, store());
    }

    unlink($_) for (cluster_path(), node_path());

    ProxmodCron::State::replace({});

    return;
}

# Inode, not mtime. apply() writes a temp file and renames, so an unnecessary
# rewrite always changes the inode — while mtime has one-second granularity and
# would call two writes in the same second "unchanged".
sub inode {
    my ($path) = @_;
    my @st = stat($path);
    return @st ? $st[1] : undef;
}

# ---------------------------------------------------------------------------

subtest 'a full sync renders both scopes into the prefix tree' => sub {
    plan tests => 10;

    wipe();

    ProxmodCronTest::write_store('node', store(
        'node-trim' => cfg(comment => 'fstrim all mounts'),
    ));
    ProxmodCronTest::write_store('cluster', store(
        'cluster-report' => cfg(schedule => '@daily', nodes => [$NODENAME]),
    ));

    my $result = ProxmodCron::Sync::run();

    is($result->{skipped}, 0, 'the run was not skipped');
    is_deeply($result->{errors}, [], 'and reported nothing wrong');
    is($result->{results}{node}, 'written', 'the node file was written');
    is($result->{results}{cluster}, 'written', 'and so was the cluster file');
    is($result->{changed}, 2, 'which is two changes');

    like(ProxmodCronTest::slurp(node_path()), qr/# job: node-trim \(command\)/,
        'the node file has the node job in it');
    like(ProxmodCronTest::slurp(cluster_path()), qr/# job: cluster-report \(command\)/,
        'and the cluster file has the cluster job');

    # 0644, root-readable, not group- or world-writable. cron silently ignores a
    # file in /etc/cron.d that is writable by anyone but its owner, with no error
    # anywhere — so the mode is load-bearing rather than tidy.
    is(sprintf('%04o', (stat(node_path()))[2] & 07777), '0644',
        'the generated file is mode 0644');

    # A dot in the name makes cron ignore the file entirely. Same class of silent
    # failure, different rule.
    unlike(ProxmodCron::Render::filename('node'), qr/\./,
        'and its name contains no dot');

    # The constraint the whole module layout exists to satisfy.
    my @pve = sort grep { m{\APVE/} } keys %INC;
    is_deeply(\@pve, [], 'a full sync loaded no PVE module');
};

subtest 'a second run with nothing changed writes nothing at all' => sub {
    plan tests => 6;

    wipe();

    ProxmodCronTest::write_store('node', store('node-trim' => cfg()));

    ProxmodCron::Sync::run();

    my $first = inode(node_path());
    my $text = ProxmodCronTest::slurp(node_path());

    my $result = ProxmodCron::Sync::run();

    is($result->{changed}, 0, 'the second run changed nothing');
    is($result->{results}{node}, undef, 'and says so for the scope');
    is(inode(node_path()), $first, 'the file was not rewritten');
    is(ProxmodCronTest::slurp(node_path()), $text, 'and its content is identical');

    # This is why the comparison exists. cron watches mtimes; an unconditional
    # rewrite would make it reload every generated file once a minute, forever,
    # for the lifetime of the host.
    ProxmodCron::Sync::run() for 1 .. 3;
    is(inode(node_path()), $first, 'and stays unwritten however many times it runs');

    # A real change still gets through — an idempotence check that passed by
    # never writing anything would be worthless.
    ProxmodCronTest::write_store('node', store('node-trim' => cfg(schedule => '@hourly')));
    is(ProxmodCron::Sync::run()->{results}{node}, 'written',
        'while a changed definition is written immediately');
};

subtest 'a file is removed once its store has nothing for this node' => sub {
    plan tests => 6;

    wipe();

    ProxmodCronTest::write_store('node', store('node-trim' => cfg()));
    ProxmodCron::Sync::run();
    ok(-e node_path(), 'the file exists to start with');

    ProxmodCronTest::write_store('node', store());

    my $result = ProxmodCron::Sync::run();

    is($result->{results}{node}, 'removed', 'emptying the store removes the file');
    ok(!-e node_path(), 'and it is gone from disk');

    # Not an empty file: cron would read a file full of nothing but SHELL and
    # PATH every minute for no reason, and an administrator looking at
    # /etc/cron.d would see a job list that is a lie by omission.
    is(ProxmodCron::Sync::run()->{results}{node}, undef,
        'removing an already-absent file is not a change');

    # The other way a file stops applying: the job still exists, but no longer
    # targets this node. From this node's point of view the two are the same.
    ProxmodCronTest::write_store('cluster',
        store('elsewhere' => cfg(nodes => ['some-other-node'])));
    ProxmodCron::Sync::run();
    ok(!-e cluster_path(), 'a cluster job targeted elsewhere leaves no file here');

    ProxmodCronTest::write_store('cluster',
        store('elsewhere' => cfg(nodes => [$NODENAME, 'some-other-node'])));
    ProxmodCron::Sync::run();
    ok(-e cluster_path(), 'and adding this node to the target list brings it back');
};

subtest 'a sync already in progress is skipped, not queued' => sub {
    plan tests => 5;

    wipe();
    ProxmodCronTest::write_store('node', store('node-trim' => cfg()));

    # A separate open() is a separate open file description, so this conflicts
    # with Sync's own flock even in the same process — which is what makes the
    # contention testable without forking.
    my $path = ProxmodCron::Config::sync_lock_path();
    open(my $held, '>>', $path) or die "cannot open $path: $!\n";
    ok(flock($held, LOCK_EX | LOCK_NB), 'the lock is taken by something else');

    my $result = ProxmodCron::Sync::run();

    is($result->{skipped}, 1, 'the run reports itself skipped');
    is($result->{changed}, 0, 'having changed nothing');

    # Skipping is correct rather than merely convenient: the anchor fires every
    # minute, so a backlog of copies waiting on a lock would pile up behind one
    # slow run and then all do the same work.
    ok(!-e node_path(), 'and it did not write the file it would have written');

    close($held);

    is(ProxmodCron::Sync::run()->{results}{node}, 'written',
        'once the lock is free the next run does the work');
};

subtest 'a dry run reports what would happen and touches nothing' => sub {
    plan tests => 5;

    wipe();
    ProxmodCronTest::write_store('node', store('node-trim' => cfg()));

    my $result = ProxmodCron::Sync::run(dry_run => 1);

    is($result->{results}{node}, 'written', 'a dry run says the file would be written');
    ok(!-e node_path(), 'but does not write it');

    ProxmodCron::Sync::run();
    my $first = inode(node_path());

    ProxmodCronTest::write_store('node', store());

    is(ProxmodCron::Sync::run(dry_run => 1)->{results}{node}, 'removed',
        'and says a file would be removed');
    ok(-e node_path(), 'without removing it');
    is(inode(node_path()), $first, 'or replacing it');
};

subtest 'a broken store does not stop the other one from rendering' => sub {
    plan tests => 5;

    wipe();

    ProxmodCronTest::write_store('cluster', '{ this is not json');
    ProxmodCronTest::write_store('node', store('node-trim' => cfg()));

    my $result = ProxmodCron::Sync::run();

    is($result->{results}{node}, 'written',
        'the node scope rendered despite the cluster store being unreadable');
    like(ProxmodCronTest::slurp(node_path()), qr/node-trim/, 'with its job in it');

    is(scalar(@{ $result->{errors} }), 1, 'and the failure is reported once');
    like($result->{errors}[0], qr/not valid JSON/, 'saying what is wrong');
    like($result->{errors}[0], qr/cron\.cfg/, 'and which file to look at');
};

subtest 'a job whose plugin is missing renders as a comment, and is reported' => sub {
    plan tests => 4;

    wipe();

    ProxmodCronTest::write_store('node', store(
        'orphan-type' => { type => 'gone-away', schedule => '@daily' },
        'still-fine' => cfg(),
    ));

    ProxmodCron::Sync::run();

    my $text = ProxmodCronTest::slurp(node_path());

    like($text, qr/# UNAVAILABLE: job type 'gone-away' is not registered/,
        'the job with no plugin renders as a disabled comment naming the type');
    # [^#\n] rather than [^#]: a negated class matches a newline, so on a blank
    # line it would swallow the terminator and let .* run on into the comment
    # below — a pattern that "fails" on correct output.
    unlike($text, qr/^[^#\n].*gone-away/m, 'and never as an executable line');

    # Guessing a command for a job whose plugin is gone would be the one
    # unrecoverable mistake this renderer could make: it runs as root, every
    # minute, unattended.
    like($text, qr{^30 3 \* \* \*\troot\t.*fstrim}m,
        'while the job next to it still renders normally');

    is(ProxmodCron::Sync::run()->{changed}, 0,
        'and the file is stable across runs, missing plugin and all');
};

subtest 'the derived cache is pruned to jobs that still exist' => sub {
    plan tests => 4;

    wipe();

    ProxmodCronTest::write_store('node', store('keeper' => cfg()));

    ProxmodCron::State::record('node', 'keeper',
        { run => '1739000000000-a3f10b2c', exit => 0, started => 1739000000 });
    ProxmodCron::State::record('node', 'deleted-long-ago',
        { run => '1739000000000-b4e21c3d', exit => 1, started => 1739000000 });

    ProxmodCron::Sync::run();

    ok(ProxmodCron::State::get('node', 'keeper'),
        'a record for a job that still exists survives');
    is(ProxmodCron::State::get('node', 'deleted-long-ago'), undef,
        'and one for a job that does not is dropped');

    # It is only an index. Pruning it aggressively costs a reindex at worst,
    # while letting it grow a record per job that ever existed costs a file that
    # is read on every grid refresh.
    ProxmodCron::State::record('node', 'keeper',
        { run => '1739000009999-c5f32d4e', exit => 0, started => 1739000009 });
    ProxmodCron::Sync::run();
    is(ProxmodCron::State::get('node', 'keeper')->{run}, '1739000009999-c5f32d4e',
        'a fresh record for a live job is left alone');

    ProxmodCronTest::write_store('node', store());
    ProxmodCron::Sync::run();
    is(ProxmodCron::State::get('node', 'keeper'), undef,
        'and deleting the job drops its record on the next sync');
};

subtest 'apply() is the only thing that touches the file, and it is atomic' => sub {
    plan tests => 5;

    wipe();

    my $path = node_path() . '.probe';

    is(ProxmodCron::Sync::apply($path, undef), undef,
        'nothing to write and nothing there is not a change');

    is(ProxmodCron::Sync::apply($path, "one\n"), 'written', 'writing creates the file');
    is(ProxmodCron::Sync::apply($path, "one\n"), undef, 'the same text again is not a change');
    is(ProxmodCron::Sync::apply($path, "two\n"), 'written', 'different text is');

    # No temp file left behind on the happy path. One that survived would be
    # picked up by nothing — but it would sit in /etc/cron.d looking like a job
    # somebody meant to install.
    my $dir = ProxmodCron::Config::cron_d();
    opendir(my $dh, $dir) or die "cannot read $dir: $!\n";
    my @tmp = grep { /\.tmp\./ } readdir($dh);
    closedir($dh);
    is_deeply(\@tmp, [], 'and no temp file is left in the directory');

    unlink($path);
};

subtest 'the anchor script does the same thing, from a bare perl' => sub {
    plan tests => 6;

    wipe();
    ProxmodCronTest::write_store('node', store('node-trim' => cfg()));

    my $script = "$FindBin::Bin/../exec/proxmod-cron-sync";
    my $lib = "$FindBin::Bin/../perl";

    my $out = qx{PROXMOD_CRON_TEST_PREFIX='@{[ ProxmodCron::Config::prefix() ]}' $^X -I'$lib' '$script' --verbose 2>&1};
    my $status = $?;

    is($status, 0, 'the script exits 0');
    like($out, qr/^node: written$/m, 'and reports what it did');
    ok(-e node_path(), 'having written the file');

    $out = qx{PROXMOD_CRON_TEST_PREFIX='@{[ ProxmodCron::Config::prefix() ]}' $^X -I'$lib' '$script' --verbose 2>&1};
    like($out, qr/^node: unchanged$/m, 'a second run reports no change');

    # Exit status is what cron mails about. A store an administrator has to fix
    # by hand must not produce a mail every minute until they do — that buries
    # the one message that would have mattered.
    ProxmodCronTest::write_store('cluster', '{ not json either');
    $out = qx{PROXMOD_CRON_TEST_PREFIX='@{[ ProxmodCron::Config::prefix() ]}' $^X -I'$lib' '$script' 2>&1};
    $status = $?;

    is($status, 0, 'a broken store still exits 0');
    like($out, qr/proxmod-cron: .*not valid JSON/, 'while saying what is wrong on stderr');
};

subtest 'the node name is the short hostname, and nothing else' => sub {
    plan tests => 3;

    # PVE targets cluster jobs at short names, so a cluster job for 'pve1' has to
    # match what the API calls this node. Reading a FQDN here would silently make
    # every targeted cluster job render nowhere.
    my $name = ProxmodCron::Sync::nodename();

    ok(defined $name, 'a node name is available without loading PVE::INotify');
    unlike($name, qr/\./, 'with no domain part');
    like($name, qr/\A[a-zA-Z0-9][a-zA-Z0-9-]*\z/,
        'and untainted by pattern, because it is built into a file we write');
};
