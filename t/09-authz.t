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

use PVE::API2;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use Proxmod::API;
use Proxmod::Log;
use Proxmod::Registry;
use ProxmodCron;
use ProxmodCron::Config;
use ProxmodCron::Registry;
use ProxmodCron::Runs;
use ProxmodCron::State;
use ProxmodCron::Store;

# The §8 access-control model, driven through the real endpoints.
#
# Every call here goes through ProxmodCronTest::call, which runs the method's
# declarative `permissions` gate before its body — the order pvedaemon uses.
# Calling the body directly would prove only half of each endpoint, and would
# report a hole where production has a declarative check, or miss one where a
# body's assert() is the only thing standing between a caller and a root
# crontab.
#
# Each cell of §8.2 is asserted BOTH ways round. A test that only proves the
# grant path passes just as happily against code that grants everything.

my $NODE = 'ProxmodCron::API2::Node';
my $CLUSTER = 'ProxmodCron::API2::Cluster';
my $NODENAME = 'pve1';

# Proxmod::Log is the real module. Its output belongs in the daemon's stderr,
# not in the test's.
open(my $null, '>', '/dev/null') or die "cannot open /dev/null: $!\n";
$Proxmod::Log::FH = $null;

# Registration is process-global; build the tree once.
{
    PVE::API2::_build_tree();
    Proxmod::API::_reset();

    my $api = Proxmod::API->new(id => 'cron', version => '0.1.0', daemon => 'pvedaemon');
    ProxmodCron::proxmod_register($api);
}

# A real socket, so nothing here reaches the host's journal or forks a logger
# per audit record.
my $drain = ProxmodCronTest::journal_sink();

plan tests => 8;

# ---------------------------------------------------------------------------

# Three job types, chosen to cover the whole of §8.3:
#
#   command    — the built-in. Arbitrary root execution, no object it is
#                "about", and so no required_privs.
#   acme-vm    — a well-written plugin: names the VM its job is about.
#   forgetful  — a plugin whose author never wrote required_privs. It must be
#                refused by exactly the same rule that refuses `command`,
#                because a check on the type name would let this one through.
sub setup {
    ProxmodCronTest::reset_registry();

    ProxmodCron::Registry::register('ProxmodCron::JobType::Command');

    ProxmodCronTest::register_type('acme-vm',
        privs => sub {
            my ($cfg) = @_;
            my $vmid = defined($cfg->{vmid}) ? $cfg->{vmid} : 0;
            return [["/vms/$vmid", ['VM.Backup']]];
        },
        build => sub { my ($cfg) = @_; return ['/usr/bin/true', "$cfg->{vmid}"] },
    );

    ProxmodCronTest::register_type('forgetful');

    ProxmodCronTest::write_store('node', { version => 1, jobs => {} });
    ProxmodCronTest::write_store('cluster', { version => 1, jobs => {} });

    # Which extensions proxmod would load right now — what decides whether an
    # extension-owned job is orphaned.
    @Proxmod::Registry::EXTENSIONS = ('cron', 'acme-backup');
    ProxmodCron::Store::_reset_owner_cache();

    # No journal fixtures unless a subtest installs some, so a run history that
    # leaked in from a previous subtest cannot make a filtering assertion pass.
    $ProxmodCron::Runs::RUNNER = sub { [] };

    $drain->();

    return;
}

sub as {
    my ($user, %grants) = @_;
    return ProxmodCronTest::rpcenv($user, %grants);
}

my %USER = (
    admin => ['admin@pve', "/nodes/$NODENAME" => ['Sys.Audit', 'Sys.Modify']],
    auditor => ['auditor@pve', "/nodes/$NODENAME" => ['Sys.Audit']],
    syslogger => ['syslog@pve', "/nodes/$NODENAME" => ['Sys.Audit', 'Sys.Syslog']],
    vmowner => ['vm101@pve', '/vms/101' => ['VM.Backup']],
    nobody => ['nobody@pve'],
);

sub login { my ($who) = @_; return as(@{ $USER{$who} }) }

sub seed {
    my ($scope, $id, $cfg, %opts) = @_;

    return ProxmodCron::Store::create($scope, $id, {
        schedule => '30 3 * * *',
        %$cfg,
    }, %opts);
}

sub vm_job { my ($vmid) = @_; return { type => 'acme-vm', vmid => $vmid } }
sub cmd_job { return { type => 'command', command => ['/bin/true'] } }

# ---------------------------------------------------------------------------

subtest 'the §8.2 matrix, granted and refused' => sub {
    # (endpoint, the privilege §8.2 names, the path it is named on). Each row is
    # driven twice: once holding exactly that privilege, once holding nothing.
    my @matrix = (
        [$NODE, 'index', { node => $NODENAME }, 'Sys.Audit'],
        [$NODE, 'list_jobs', { node => $NODENAME }, 'Sys.Audit'],
        [$NODE, 'inventory', { node => $NODENAME }, 'Sys.Audit'],
        [$NODE, 'journal_status', { node => $NODENAME }, 'Sys.Audit'],
        [$NODE, 'sync', { node => $NODENAME }, 'Sys.Modify'],
        [$NODE, 'journal', { node => $NODENAME }, 'Sys.Syslog'],
        [$NODE, 'create_job',
            { node => $NODENAME, id => 'made', %{ cmd_job() }, schedule => '@daily' },
            'Sys.Modify'],
        [$CLUSTER, 'index', {}, 'Sys.Audit'],
        [$CLUSTER, 'list_jobs', {}, 'Sys.Audit'],
        [$CLUSTER, 'create_job',
            { id => 'made', %{ cmd_job() }, schedule => '@daily' },
            'Sys.Modify'],
    );

    plan tests => 3 * scalar(@matrix);

    for my $row (@matrix) {
        my ($class, $name, $param, $priv) = @$row;
        my $path = ($class eq $CLUSTER) ? '/' : "/nodes/$NODENAME";
        my $label = "$name ($priv on $path)";

        setup();
        as('holder@pve', $path => [$priv]);
        ok(eval { ProxmodCronTest::call($class, $name, $param); 1 },
            "$label is permitted for a caller holding it")
            or diag("$@");

        setup();
        login('nobody');
        my $err = ProxmodCronTest::refused($class, $name, $param);
        ok($err, "$label is refused for a caller holding nothing");

        # A refusal that does not name the privilege sends an administrator to
        # guess at the role editor. Whether it came from the declarative gate or
        # from the body, the message has to say what to ask for.
        like("$err", qr/\Q$priv\E/, "$label names the privilege it wanted");
    }
};

subtest 'an empty required_privs means not delegable — for every type alike' => sub {
    plan tests => 9;

    setup();

    is_deeply(ProxmodCron::Registry::privs_for('command', {}), [],
        'the built-in command type declares no privileges');
    is_deeply(ProxmodCron::Registry::privs_for('forgetful', { vmid => 101 }), [],
        'a plugin whose author forgot required_privs declares none either');
    ok(scalar(@{ ProxmodCron::Registry::privs_for('acme-vm', { vmid => 101 }) }),
        'a plugin that declares them is the only one that does');

    login('vmowner');

    # Refused because the list is empty, not because the type is called
    # 'command'. The two rows below are the same assertion made twice, and the
    # second is the one that matters: a type name check would let it through.
    for my $type (qw(command forgetful)) {
        my $err = ProxmodCronTest::refused($NODE, 'create_delegated', {
            node => $NODENAME,
            id => "via-$type",
            type => $type,
            schedule => '@daily',
            $type eq 'command' ? (command => ['/bin/true']) : (vmid => 101),
        });

        ok($err, "the delegated tree refuses a '$type' job");
        like("$err", qr/not delegable/, "and says so in those words for '$type'");
    }

    my $store = ProxmodCron::Config::load('node');
    is_deeply([sort keys %{ $store->{jobs} }], [],
        'neither refusal left a job behind');

    ok(eval {
        ProxmodCronTest::call($NODE, 'create_delegated', {
            node => $NODENAME, id => 'mine', type => 'acme-vm',
            schedule => '@daily', vmid => 101,
        });
        1;
    }, 'the same caller may create a job for the VM they hold') or diag("$@");
};

subtest 'delegated writes are checked against the stored config too' => sub {
    plan tests => 7;

    setup();

    seed('node', 'mine', vm_job(101));
    seed('node', 'theirs', vm_job(202));

    login('vmowner');

    # Re-pointing. Checking only the submitted config would let a caller with
    # rights on 101 walk a job to 202 in one step; checking only the stored one
    # would let them walk it there and then edit it freely.
    my $err = ProxmodCronTest::refused($NODE, 'update_delegated',
        { node => $NODENAME, id => 'mine', vmid => 202 });
    ok($err, 'a delegated caller may not re-point their job at a VM they do not hold');
    like("$err", qr{/vms/202}, 'and the refusal names the VM they asked for');

    is(ProxmodCron::Config::load('node')->{jobs}{mine}{vmid}, 101,
        'the stored job is untouched');

    ok(ProxmodCronTest::refused($NODE, 'update_delegated',
        { node => $NODENAME, id => 'theirs', vmid => 101 }),
        'nor may they capture someone else\'s job by submitting one they hold');

    ok(ProxmodCronTest::refused($NODE, 'delete_delegated',
        { node => $NODENAME, id => 'theirs' }),
        'nor delete a job for a VM they do not hold');

    ok(ProxmodCron::Config::load('node')->{jobs}{theirs},
        'the other VM\'s job is still there');

    ok(eval { ProxmodCronTest::call($NODE, 'delete_delegated',
        { node => $NODENAME, id => 'mine' }); 1 },
        'they may delete their own') or diag("$@");
};

subtest 'delegated writes cannot touch user, track or type' => sub {
    # A value that differs from what the server would set anyway. 'root' would
    # not do for `user`: the type pins it to its run_as, which is 'root', and
    # submitting a field at the value it already has is deliberately permitted.
    my %frozen = (
        user => 'backup',
        track => 0,
        type => 'command',
    );

    plan tests => 2 * scalar(keys %frozen) + 3;

    setup();
    seed('node', 'mine', vm_job(101));
    login('vmowner');

    for my $field (sort keys %frozen) {
        my $err = ProxmodCronTest::refused($NODE, 'update_delegated', {
            node => $NODENAME, id => 'mine', $field => $frozen{$field},
        });

        ok($err, "a delegated caller may not set '$field'");

        # Naming the field, because a 403 on a form with eight of them is not
        # something a user can act on.
        like("$err", qr/'\Q$field\E'/, "and the refusal names '$field'");
    }

    # Submitting a field at its existing value is not a change and must not be
    # refused: an editor that PUTs the whole form back would otherwise be
    # unusable for exactly the callers this subtree exists for.
    my $job = ProxmodCron::Config::load('node')->{jobs}{mine};
    is($job->{user}, 'root', 'the job type pinned the crontab user to its run_as');

    ok(eval {
        ProxmodCronTest::call($NODE, 'update_delegated', {
            node => $NODENAME, id => 'mine', user => 'root', schedule => '@hourly',
        });
        1;
    }, 'resubmitting a frozen field unchanged is permitted') or diag("$@");

    is(ProxmodCron::Config::load('node')->{jobs}{mine}{schedule}, '@hourly',
        'and the rest of the update went through');
};

subtest 'reads filter rather than refuse, and each row says what it may do' => sub {
    plan tests => 10;

    setup();

    seed('node', 'anything', cmd_job());
    seed('node', 'vm101', vm_job(101));
    seed('node', 'vm202', vm_job(202));

    login('auditor');
    my $rows = ProxmodCronTest::call($NODE, 'list_jobs', { node => $NODENAME });
    is_deeply([sort map { $_->{id} } @$rows], [qw(anything vm101 vm202)],
        'Sys.Audit on the node sees every job on it');
    is_deeply([map { $_->{can_modify} } @$rows], [0, 0, 0],
        'and every row says it may not be modified');

    # The delegated tree answers the same question for everyone: it does not
    # widen for a caller who also happens to hold Sys.Audit.
    is_deeply(ProxmodCronTest::call($NODE, 'list_delegated', { node => $NODENAME }), [],
        'the delegated list is empty for an auditor who administers no VM');

    login('vmowner');

    # §Verification 16: the coarse tree is closed to a delegated caller
    # outright. They are not a partially-privileged auditor; they hold nothing
    # on this node at all.
    ok(ProxmodCronTest::refused($NODE, 'list_jobs', { node => $NODENAME }),
        'the coarse job list is refused to a caller with no node privileges');

    my $mine = ProxmodCronTest::call($NODE, 'list_delegated', { node => $NODENAME });
    is_deeply([map { $_->{id} } @$mine], ['vm101'],
        'the delegated list shows their job and nothing else');
    is($mine->[0]{can_modify}, 1, 'and says they may modify it');
    is($mine->[0]{authorization}, 'delegated', 'by delegation, not by Sys.Modify');

    ok(ProxmodCronTest::refused($NODE, 'get_delegated',
        { node => $NODENAME, id => 'vm202' }),
        'fetching another VM\'s job by id is refused, not merely filtered out');

    login('admin');
    my $all = ProxmodCronTest::call($NODE, 'list_jobs', { node => $NODENAME });
    is_deeply([map { $_->{can_modify} } @$all], [1, 1, 1],
        'Sys.Modify sees every row as modifiable');
    is_deeply([map { $_->{authorization} } @$all], [('modify') x 3],
        'and by the coarse privilege rather than by delegation');
};

subtest 'GET permissions says exactly what the write methods enforce' => sub {
    my @cases = (
        { who => 'admin', audit => 1, modify => 1, syslog => 0 },
        { who => 'auditor', audit => 1, modify => 0, syslog => 0 },
        { who => 'syslogger', audit => 1, modify => 0, syslog => 1 },
        { who => 'vmowner', audit => 0, modify => 0, syslog => 0 },
        { who => 'nobody', audit => 0, modify => 0, syslog => 0 },
    );

    plan tests => 6 * scalar(@cases) + 1;

    for my $case (@cases) {
        setup();
        login($case->{who});

        my $perms = ProxmodCronTest::call($NODE, 'permissions', { node => $NODENAME });

        is($perms->{$_}, $case->{$_}, "$case->{who}: permissions says $_ = $case->{$_}")
            for qw(audit modify syslog);

        # The claim is not that the numbers look right, it is that they predict
        # the enforcement. Drive the endpoint each flag is about and compare.
        my $can_read = eval {
            ProxmodCronTest::call($NODE, 'list_jobs', { node => $NODENAME }); 1 } ? 1 : 0;
        is($can_read, $perms->{audit}, "$case->{who}: audit predicts GET jobs");

        my $can_write = eval {
            ProxmodCronTest::call($NODE, 'create_job', {
                node => $NODENAME, id => 'probe', schedule => '@daily', %{ cmd_job() },
            });
            1;
        } ? 1 : 0;
        is($can_write, $perms->{modify}, "$case->{who}: modify predicts POST jobs");

        my $can_log = eval {
            ProxmodCronTest::call($NODE, 'journal', { node => $NODENAME }); 1 } ? 1 : 0;
        is($can_log, $perms->{syslog}, "$case->{who}: syslog predicts GET journal");
    }

    setup();
    login('auditor');
    is_deeply(ProxmodCronTest::call($NODE, 'permissions',
            { node => $NODENAME })->{delegable_types},
        ['acme-vm'],
        'only the type that declares required_privs is offered as delegable');
};

subtest 'the can_* flags on a row match the write methods, origin by privilege' => sub {
    # §2.1 crossed with §8. The flags exist so the UI never re-derives the
    # rules; this asserts they cannot lie, by doing what each one advertises.
    my @origins = (
        { name => 'user', opts => {},
            expect => { can_toggle => 1, can_edit => 1, can_delete => 1 } },
        { name => 'extension', opts => { origin => 'extension', owner => 'acme-backup' },
            expect => { can_toggle => 1, can_edit => 0, can_delete => 0 } },
        { name => 'orphan', opts => { origin => 'extension', owner => 'gone-away' },
            expect => { can_toggle => 1, can_edit => 0, can_delete => 1 } },
    );

    my @callers = (
        { who => 'admin', privileged => 1 },
        { who => 'auditor', privileged => 0 },
    );

    my @actions = (
        ['can_toggle', 'set_enabled', { enabled => 0 }],
        ['can_edit', 'update_job', { schedule => '@hourly' }],
        ['can_delete', 'delete_job', {}],
    );

    plan tests => scalar(@origins) * scalar(@callers) * 2 * scalar(@actions);

    for my $origin (@origins) {
        for my $caller (@callers) {
            for my $action (@actions) {
                my ($flag, $method, $extra) = @$action;

                setup();
                seed('node', 'row', cmd_job(), %{ $origin->{opts} });

                login($caller->{who});

                # The flag as the grid would receive it. Read through
                # list_jobs, because that is the call the grid makes.
                my ($row) = grep { $_->{id} eq 'row' }
                    @{ ProxmodCronTest::call($NODE, 'list_jobs', { node => $NODENAME }) };

                my $want = ($origin->{expect}{$flag} && $caller->{privileged}) ? 1 : 0;

                is($row->{$flag}, $want,
                    "$origin->{name} + $caller->{who}: $flag is $want");

                my $did = eval {
                    ProxmodCronTest::call($NODE, $method,
                        { node => $NODENAME, id => 'row', %$extra });
                    1;
                } ? 1 : 0;

                is($did, $want,
                    "$origin->{name} + $caller->{who}: $method agrees with $flag");
            }
        }
    }
};

subtest 'run metadata is Sys.Audit; run output is Sys.Syslog, or delegation' => sub {
    my $MINE = '1739000000000-a3f10b2c';
    my $THEIRS = '1739000001000-b4e21c3d';

    # journalctl -o json, as ProxmodCron::Runs decodes it.
    my @entries = (
        _entry($MINE, 'vm101', 'start', 1739000000000000),
        _entry($MINE, 'vm101', 'output', 1739000000100000,
            MESSAGE => 'backing up 101', PROXMOD_CRON_STREAM => 'stdout'),
        _entry($MINE, 'vm101', 'finish', 1739000000900000,
            PROXMOD_CRON_EXIT => 0, PROXMOD_CRON_DURATION_MS => 900),
        _entry($THEIRS, 'vm202', 'start', 1739000001000000),
        _entry($THEIRS, 'vm202', 'output', 1739000001100000,
            MESSAGE => 'backing up 202', PROXMOD_CRON_STREAM => 'stdout'),
        _entry($THEIRS, 'vm202', 'finish', 1739000001900000,
            PROXMOD_CRON_EXIT => 1, PROXMOD_CRON_DURATION_MS => 900),
    );

    plan tests => 14;

    setup();
    ProxmodCronTest::journal_runner(\@entries);

    seed('node', 'vm101', vm_job(101));
    seed('node', 'vm202', vm_job(202));

    # The status cache carries an output tail for the failure tooltip. A tail is
    # job output like any other, so the same rule has to apply to the copy.
    ProxmodCron::State::record('node', 'vm101', {
        run => $MINE, exit => 0, state => 'ok', tail => ['backing up 101'],
    });

    login('auditor');

    my $runs = ProxmodCronTest::call($NODE, 'job_runs', { node => $NODENAME, id => 'vm101' });
    is(scalar(@$runs), 1, 'Sys.Audit alone reads the run history');
    is($runs->[0]{exit}, 0, 'including how the run exited');

    ok(eval { ProxmodCronTest::call($NODE, 'get_run',
        { node => $NODENAME, runid => $MINE }); 1 },
        'and one run\'s record') or diag("$@");

    my $err = ProxmodCronTest::refused($NODE, 'run_log',
        { node => $NODENAME, runid => $MINE });
    ok($err, 'but not what the run printed');
    like("$err", qr/Sys\.Syslog/, 'and the refusal names Sys.Syslog, not Sys.Audit');

    my $status = ProxmodCronTest::call($NODE, 'job_status',
        { node => $NODENAME, id => 'vm101' });
    is($status->{state}, 'ok', 'the status cache is readable with Sys.Audit');
    ok(!exists $status->{tail}, 'with the output tail stripped out of it');

    login('syslogger');

    my $log = ProxmodCronTest::call($NODE, 'run_log', { node => $NODENAME, runid => $MINE });
    is_deeply([map { $_->{text} } @{ $log->{lines} }], ['backing up 101'],
        'Sys.Syslog reads the output');
    ok(exists ProxmodCronTest::call($NODE, 'job_status',
        { node => $NODENAME, id => 'vm101' })->{tail},
        'and the tail in the status cache with it');

    login('vmowner');

    # The delegated carve-out: they already administer the object the job is
    # about, and it is their job's output.
    ok(eval { ProxmodCronTest::call($NODE, 'job_runs',
        { node => $NODENAME, id => 'vm101' }); 1 },
        'a delegated caller reads their own job\'s history without Sys.Audit')
        or diag("$@");

    is_deeply([map { $_->{text} } @{ ProxmodCronTest::call($NODE, 'run_log',
            { node => $NODENAME, runid => $MINE })->{lines} }],
        ['backing up 101'],
        'and its output without Sys.Syslog');

    ok(ProxmodCronTest::refused($NODE, 'run_log', { node => $NODENAME, runid => $THEIRS }),
        'but not the output of a job for a VM they do not hold');

    ok(ProxmodCronTest::refused($NODE, 'job_runs', { node => $NODENAME, id => 'vm202' }),
        'nor its history');

    login('nobody');
    ok(ProxmodCronTest::refused($NODE, 'run_log', { node => $NODENAME, runid => $MINE }),
        'and a caller holding nothing reads no output at all');
};

sub _entry {
    my ($run, $job, $event, $usec, %extra) = @_;

    return {
        __CURSOR => "s=test;i=$usec",
        __REALTIME_TIMESTAMP => "$usec",
        SYSLOG_IDENTIFIER => 'proxmod-cron',
        PROXMOD_CRON_RUN => $run,
        PROXMOD_CRON_JOB => $job,
        PROXMOD_CRON_SCOPE => 'node',
        PROXMOD_CRON_TYPE => 'acme-vm',
        PROXMOD_CRON_EVENT => $event,
        MESSAGE => "$event $job",
        %extra,
    };
}
