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

use Fcntl qw(:mode);
use JSON::PP ();

use ProxmodCron::Config;
use ProxmodCron::JobType::Command;
use ProxmodCron::Registry;

# The definition store: what it accepts, what it refuses, and what it does with
# a file it cannot understand.
#
# Two properties here are load-bearing for everything else in the package:
#
#   load() never dies. A corrupt cluster file arriving over pmxcfs must not stop
#   this node's own jobs from rendering, so a parse failure yields an empty job
#   set and an `error` string rather than an exception in proxmod-cron-sync.
#
#   Nothing is laundered. Every value is rebuilt from a strict capture, and a
#   job with one field that cannot be described exactly is dropped whole. A job
#   definition becomes a command that runs as root; "mostly matched the pattern"
#   is not a standard to execute against.

plan tests => 12;

# The built-in type, so `type => 'command'` validates. Registration is
# process-global and nothing in this file changes it.
ProxmodCron::Registry::register('ProxmodCron::JobType::Command');

sub reload {
    my ($scope, $data) = @_;
    ProxmodCronTest::write_store($scope, $data);
    return ProxmodCron::Config::load($scope);
}

sub job {
    my (%over) = @_;
    return {
        type => 'command',
        schedule => '30 2 * * *',
        command => ['/usr/sbin/fstrim', '-a'],
        %over,
    };
}

# ---------------------------------------------------------------------------

subtest 'a missing store is the normal state of a fresh install' => sub {
    plan tests => 8;

    for my $scope (qw(node cluster)) {
        unlink(ProxmodCron::Config::file_for($scope));

        my $store = ProxmodCron::Config::load($scope);

        is_deeply($store->{jobs}, {}, "$scope: no file means no jobs");
        is($store->{error}, undef, "$scope: and no error — absence is not corruption");
        is($store->{mailto}, '', "$scope: mailto defaults to empty, which is what §4 renders");
        is($store->{version}, 1, "$scope: and the store version is stamped anyway");
    }
};

subtest 'round trip: what save writes, load reads back' => sub {
    plan tests => 5;

    my $written = {
        mailto => 'ops@example.com',
        max_lines => 500,
        jobs => {
            'nightly-trim' => job(comment => 'fstrim all mounts'),
            'weekly-report' => job(schedule => '@weekly', enabled => 0, track => 0),
        },
    };

    ProxmodCron::Config::save('node', $written);

    my $store = ProxmodCron::Config::load('node');

    is($store->{mailto}, 'ops@example.com', 'the store-level mailto survives');
    is($store->{max_lines}, 500, 'and the operational limits proxmod-cron-exec reads');
    is_deeply([sort keys %{ $store->{jobs} }], ['nightly-trim', 'weekly-report'],
        'both jobs came back');
    is_deeply($store->{jobs}{'nightly-trim'}{command}, ['/usr/sbin/fstrim', '-a'],
        'the command is still an array, element for element');
    is($store->{jobs}{'weekly-report'}{enabled}, 0,
        'and a false boolean is still false, not the string "false"');
};

subtest 'the file is 0600, because a job definition is a root command' => sub {
    plan tests => 3;

    my $file = ProxmodCron::Config::file_for('node');

    ProxmodCron::Config::save('node', { jobs => { a => job() } });

    my $mode = (stat($file))[2] & 07777;
    is(sprintf('%04o', $mode), '0600', 'the store is readable only by root');

    # A second write must not widen it. The atomic write creates a new inode
    # each time, so the mode is set on the temp file, not inherited — and
    # getting that wrong would only show up on the second save.
    ProxmodCron::Config::save('node', { jobs => { a => job(), b => job() } });
    is(sprintf('%04o', (stat($file))[2] & 07777), '0600',
        'and still is after being replaced');

    is_deeply([sort keys %{ ProxmodCron::Config::load('node')->{jobs} }], ['a', 'b'],
        'the replacement is the new content, not an append');
};

subtest 'the write is atomic and leaves nothing behind' => sub {
    plan tests => 3;

    my $file = ProxmodCron::Config::file_for('node');

    ProxmodCron::Config::save('node', { jobs => { a => job() } });

    my @tmp = glob("$file.tmp.*");
    is_deeply(\@tmp, [], 'no temp file survives a successful write');

    # An unchanged store must produce byte-identical output: this file lives on
    # pmxcfs in the cluster scope, and a write that differs only in key order
    # would replicate a no-op change to every node in the cluster.
    #
    # The comparison starts one round trip in, because load() materialises the
    # defaults — the first save after a hand-edited file legitimately grows an
    # `origin` and an `enabled`. It is the steady state that has to be stable.
    ProxmodCron::Config::save('node', ProxmodCron::Config::load('node'));
    my $first = ProxmodCronTest::slurp($file);

    ProxmodCron::Config::save('node', ProxmodCron::Config::load('node'));
    is(ProxmodCronTest::slurp($file), $first,
        'saving what was just loaded produces the same bytes');

    like($first, qr/"jobs"/, 'and it is JSON a person can read in an emergency');
};

subtest 'a corrupt store fails soft — it does not take the renderer down' => sub {
    my @corrupt = (
        ['', 'is empty'],
        ["   \n", 'is empty'],
        ['{ "jobs": ', 'is not valid JSON'],
        ['[1, 2, 3]', 'is not valid JSON'],
        ['"just a string"', 'is not valid JSON'],
    );

    plan tests => 3 * @corrupt + 2;

    for my $row (@corrupt) {
        my ($content, $want) = @$row;

        my $store;
        my $lived = eval {
            ProxmodCronTest::write_store('cluster', $content);
            $store = ProxmodCron::Config::load('cluster');
            1;
        };

        ok($lived, "load() survives " . ($content =~ /\S/ ? "'$content'" : 'an empty file'));
        is_deeply($store->{jobs}, {}, 'and yields no jobs rather than half of them');
        like($store->{error}, qr/\Q$want\E/, "and says why: $want");
    }

    # The whole point of failing soft: the other store is unaffected.
    ProxmodCron::Config::save('node', { jobs => { survivor => job() } });
    ProxmodCronTest::write_store('cluster', '{ broken');

    is(ProxmodCron::Config::load('cluster')->{error} ? 1 : 0, 1,
        'the cluster store is still reported as broken');
    is_deeply([keys %{ ProxmodCron::Config::load('node')->{jobs} }], ['survivor'],
        'and the node store still renders its own jobs');
};

subtest 'one unreadable job is dropped, the rest of the file is kept' => sub {
    plan tests => 4;

    my $store = reload('node', {
        version => 1,
        jobs => {
            good => job(),
            'BAD ID' => job(),
            'bad-type' => { type => 'Not A Type', schedule => '@daily' },
            'not-a-hash' => 'nonsense',
            'bad-schedule' => { type => 'command', schedule => "two\nlines" },
        },
    });

    is_deeply([sort keys %{ $store->{jobs} }], ['good'],
        'only the job that could be described exactly is kept');

    # Named, not counted. An administrator whose job vanished needs to know
    # which one, and "4 jobs ignored" sends them to read the file by hand.
    like($store->{error}, qr/BAD ID/, 'the error names the bad id');
    like($store->{error}, qr/bad-schedule/, 'and the one with the bad schedule');
    unlike($store->{error}, qr/\bgood\b/, 'and does not name the one that was fine');
};

subtest 'unknown keys are tolerated on read — a newer node may have written them' => sub {
    plan tests => 3;

    # Forward compatibility across a cluster mid-upgrade: node B running a newer
    # version writes a key node A has never heard of, and node A must keep
    # rendering rather than dropping the job.
    my $store = reload('cluster', {
        version => 99,
        jobs => {
            'from-the-future' => job(retry_policy => 'exponential', jitter => 30),
        },
    });

    ok($store->{jobs}{'from-the-future'}, 'the job survives a key we do not know');
    is($store->{jobs}{'from-the-future'}{retry_policy}, 'exponential',
        'and the key is carried through, so a save does not silently drop it');
    is($store->{version}, 99, 'the version it was written with is preserved on read');
};

subtest 'untainting rebuilds every value, or refuses the job' => sub {
    my @refused = (
        ['a NUL in a command element', job(command => ["/bin/true\0-x"])],
        ['a newline in a command element', job(command => ["/bin/true\n-x"])],
        ['a newline in the schedule', job(schedule => "\@daily\n0 0 * * *")],
        ['a control character in the schedule', job(schedule => "0 2 * * *\t\x01")],
        ['a type that is not an id', job(type => '../../etc/passwd')],
        ['a user name that is not one', job(user => 'root; rm -rf /')],
        ['a nodes list that is not a list', job(nodes => 'pve1')],
        ['a node name with a slash', job(nodes => ['pve1/../pve2'])],
        ['an origin that is neither', job(origin => 'system')],
        ['a key name that is not an identifier', { %{ job() }, 'a key' => 1 }],
        ['a nested structure we cannot flatten', job(opts => { a => 1 })],
    );

    my @accepted = (
        ['a comment with quotes and a percent', job(comment => q{it's 50% done})],
        ['a nested list of argv elements', job(command => ['/bin/sh', '-c', 'echo hi'])],
        ['a JSON boolean', job(track => JSON::PP::false())],
        ['an empty command list', job(command => [])],
    );

    plan tests => @refused + 2 * @accepted;

    for my $row (@refused) {
        my ($why, $cfg) = @$row;
        is(ProxmodCron::Config::untaint_job('probe', $cfg), undef, "refused: $why");
    }

    for my $row (@accepted) {
        my ($why, $cfg) = @$row;
        my $clean = ProxmodCron::Config::untaint_job('probe', $cfg);
        ok($clean, "accepted: $why");

        # Rebuilt, not passed through: the cleaned value has to equal the input
        # rather than merely exist, or the untainter would be free to mangle
        # what it lets past.
        is_deeply($clean->{comment} // $clean->{command} // $clean->{track},
            $cfg->{comment} // $cfg->{command} // ($cfg->{track} ? 1 : 0),
            "and unchanged: $why");
    }
};

subtest 'a partial config leaves absent keys absent' => sub {
    plan tests => 5;

    # An update delta is not a whole job. If untaint_job filled in the defaults
    # here, a PUT that changed only the schedule would also reset `enabled`,
    # `user` and `track` to their defaults — silently re-enabling a job an
    # administrator had turned off.
    my $delta = ProxmodCron::Config::untaint_job('probe',
        { schedule => '@hourly' }, partial => 1);

    is_deeply([sort keys %$delta], ['schedule'], 'only the key that was supplied');
    is($delta->{schedule}, '@hourly', 'with its value');

    ok(!exists $delta->{enabled}, 'no defaulted enabled to overwrite the stored one');
    ok(!exists $delta->{user}, 'no defaulted user');

    # Without partial, the same input is a whole job and must be refused: it
    # has no type.
    is(ProxmodCron::Config::untaint_job('probe', { schedule => '@hourly' }), undef,
        'and the same input as a whole job is refused for having no type');
};

subtest 'validate_job reports every problem, not just the first' => sub {
    plan tests => 8;

    my $errors = ProxmodCron::Config::validate_job('Bad Id',
        { schedule => 'not a schedule', user => 'Root!', comment => "two\nlines" });

    like("@$errors", qr/job id 'Bad Id' is not valid/, 'the id');
    like("@$errors", qr/job has no type/, 'the missing type');
    like("@$errors", qr/schedule:/, 'the schedule, with the parser\'s own reason');
    like("@$errors", qr/user 'Root!'/, 'the user name');
    like("@$errors", qr/comment must not contain a newline/, 'the comment');

    is_deeply(ProxmodCron::Config::validate_job('fine', job()), [],
        'a valid job produces no errors at all');

    # §7: the server owns `origin`. A client that supplies one is told so
    # rather than having it quietly ignored, because a caller who thinks they
    # created an extension-owned job should find out here.
    like("@{ ProxmodCron::Config::validate_job('fine', job(origin => 'extension')) }",
        qr/'origin' is set by the server/, 'a client-supplied origin is refused');

    like("@{ ProxmodCron::Config::validate_job('fine', job(nodes => ['pve1']), scope => 'node') }",
        qr/only meaningful in the cluster scope/,
        "and 'nodes' in the node scope, where it would do nothing");
};

subtest 'effective() fills the defaults in exactly one place' => sub {
    plan tests => 7;

    my $store = reload('node', {
        jobs => {
            bare => { type => 'command', schedule => '@daily', command => ['/bin/true'] },
            off => job(enabled => 0, track => 0, keep_output => 0, user => 'backup'),
        },
    });

    my $bare = ProxmodCron::Config::effective('node', $store, 'bare');

    is($bare->{enabled}, 1, 'a job with no enabled key is enabled');
    is($bare->{track}, 1, 'and tracked');
    is($bare->{keep_output}, 1, 'and keeps its output');
    is($bare->{user}, 'root', "and runs as the type's run_as");
    is($bare->{id}, 'bare', 'the id is carried on the job, so a row knows its own name');

    my $off = ProxmodCron::Config::effective('node', $store, 'off');
    is_deeply([@{$off}{qw(enabled track keep_output user)}], [0, 0, 0, 'backup'],
        'an explicit false is not overwritten by the default');

    is(ProxmodCron::Config::effective('node', $store, 'absent'), undef,
        'and a job that is not there is undef, not an empty job');
};

subtest 'targets_node reads an absent list as every node' => sub {
    plan tests => 7;

    my $on = sub { ProxmodCron::Config::targets_node($_[0], 'pve1') ? 1 : 0 };

    is($on->({}), 1, 'no nodes key at all: every node');
    is($on->({ nodes => [] }), 1, 'an empty list: every node');
    is($on->({ nodes => ['all'] }), 1, "the literal 'all'");
    is($on->({ nodes => ['pve1'] }), 1, 'named');
    is($on->({ nodes => ['pve2', 'pve1'] }), 1, 'named among others');
    is($on->({ nodes => ['pve2'] }), 0, 'not named');

    # The permissive reading is deliberate: a cluster job with no targeting is
    # the common case, and reading it as "nowhere" would make it silently never
    # run — a failure with no error anywhere to find it by.
    is($on->({ nodes => 'pve1' }), 1, 'and a malformed list falls back to every node');
};
