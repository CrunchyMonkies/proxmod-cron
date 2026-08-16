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
use ProxmodCron::Client;
use ProxmodCron::Config;
use ProxmodCron::JobType::Command;
use ProxmodCron::Registry;
use ProxmodCron::Store;

# §2.1 — origin, the second axis of authority.
#
# Permissions (§8, t/09-authz.t) answer "may this user?". Origin answers "may
# anyone, through this surface?". An action is offered only when both say yes,
# and the two are deliberately independent: this file gives its caller
# Sys.Modify on everything, so every refusal here is an origin refusal and
# nothing else. If a cell in the table below started passing because the user
# happened to hold a privilege, the test would be testing §8 twice and §2.1
# never.
#
# The rule the whole design turns on, stated once: a dynamically added entry is
# enable/disable only. The extension owns its schedule, its command and its
# existence; the administrator owns whether it runs.

my $NODE = 'ProxmodCron::API2::Node';
my $CLUSTER = 'ProxmodCron::API2::Cluster';
my $NODENAME = 'pve1';

open(my $null, '>', '/dev/null') or die "cannot open /dev/null: $!\n";
$Proxmod::Log::FH = $null;

{
    PVE::API2::_build_tree();
    Proxmod::API::_reset();

    my $api = Proxmod::API->new(id => 'cron', version => '0.1.0', daemon => 'pvedaemon');
    ProxmodCron::proxmod_register($api);
}

my $drain = ProxmodCronTest::journal_sink();

plan tests => 11;

ProxmodCron::Registry::register('ProxmodCron::JobType::Command');

# ---------------------------------------------------------------------------

# root@pam with Sys.Modify everywhere: the privilege half always says yes.
sub admin {
    return ProxmodCronTest::rpcenv('root@pam',
        '/' => ['Sys.Audit', 'Sys.Modify', 'Sys.Syslog'],
        "/nodes/$NODENAME" => ['Sys.Audit', 'Sys.Modify', 'Sys.Syslog'],
    );
}

sub reset_world {
    for my $scope (qw(cluster node)) {
        ProxmodCronTest::write_store($scope, { version => 1, jobs => {} });
    }

    Proxmod::Registry::_set('acme-backup');
    ProxmodCron::Store::_reset_owner_cache();

    admin();

    return;
}

sub cfg {
    my (%over) = @_;
    return {
        type => 'command',
        schedule => '30 3 * * *',
        command => ['/usr/lib/acme/backup'],
        %over,
    };
}

# The three origin states, planted directly in the store so each subtest starts
# from the state it is about rather than from a sequence of API calls.
sub plant {
    my ($scope, %opts) = @_;

    ProxmodCron::Store::create($scope, 'custom', cfg(comment => 'mine'));

    ProxmodCron::Store::create($scope, 'ext-owned', cfg(comment => 'theirs'),
        origin => 'extension', owner => 'acme-backup');

    ProxmodCron::Store::create($scope, 'ext-orphan', cfg(comment => 'abandoned'),
        origin => 'extension', owner => 'gone-away');

    return;
}

sub row {
    my ($class, $id, %param) = @_;

    my $rows = ProxmodCronTest::call($class, 'list_jobs', { %param });

    my ($row) = grep { $_->{id} eq $id } @$rows;

    return $row;
}

sub node_param {
    my (%over) = @_;
    return { node => $NODENAME, %over };
}

# ---------------------------------------------------------------------------

subtest 'the §2.1 table, every cell, on the node scope' => sub {
    plan tests => 14;

    # (origin state) x (edit, toggle, delete). Create is not in the table: it
    # takes no existing job, so origin has nothing to say about it.
    #
    # `refusal` is per state rather than shared, because the two refusing states
    # are refused for different reasons and an administrator needs to be told
    # which: one has an extension to go and use, the other has no such thing.
    my @table = (
        { id => 'custom',     edit => 1, toggle => 1, delete => 1,
          why => 'a job a person created is theirs to change' },
        { id => 'ext-owned',  edit => 0, toggle => 1, delete => 0,
          refusal => qr/managed by acme-backup/,
          why => 'a job an installed extension owns is enable/disable only' },
        { id => 'ext-orphan', edit => 0, toggle => 1, delete => 1,
          refusal => qr/no longer installed/,
          why => 'an orphan is still not editable, but it can be removed' },
    );

    for my $case (@table) {
        my $id = $case->{id};

        # Each action starts from a clean plant, so a refusal cannot be an
        # artefact of an earlier action in the same subtest having changed the
        # job or removed it.
        for my $action (qw(edit toggle delete)) {
            reset_world();
            plant('node');

            my $err;
            if ($action eq 'edit') {
                $err = ProxmodCronTest::refused($NODE, 'update_job',
                    node_param(id => $id, schedule => '@daily'));
            } elsif ($action eq 'toggle') {
                $err = ProxmodCronTest::refused($NODE, 'set_enabled',
                    node_param(id => $id, enabled => 0));
            } else {
                $err = ProxmodCronTest::refused($NODE, 'delete_job',
                    node_param(id => $id));
            }

            if ($case->{$action}) {
                is($err, undef, "$id: $action is permitted — $case->{why}");
            } else {
                like($err, $case->{refusal},
                    "$id: $action is refused, and the message says why");
            }
        }
    }

    reset_world();
    plant('node');

    # The refusal has to name the extension. "Permission denied" would send an
    # administrator to the ACL editor to fix something an ACL cannot fix.
    my $err = ProxmodCronTest::refused($NODE, 'update_job',
        node_param(id => 'ext-owned', schedule => '@daily'));
    like($err, qr/managed by acme-backup/, 'the refusal names the owning extension');
    like($err, qr/enable or disable it here/,
        'and tells the administrator what they can do instead');
    like($err, qr/use that extension/, 'and where to go for the rest');

    # The orphan's refusal cannot say "use that extension" — there isn't one.
    # It names the vanished owner, which is the only thing that explains the row,
    # and it points at the action that IS available.
    my $orphan_err = ProxmodCronTest::refused($NODE, 'update_job',
        node_param(id => 'ext-orphan', schedule => '@daily'));
    like($orphan_err, qr/created by gone-away, which is no longer installed/,
        'the orphan refusal names the extension that is gone');
    like($orphan_err, qr/enable, disable or remove it/,
        'and offers the three things that are still possible');
};

subtest 'the same table, unchanged, on the cluster scope' => sub {
    plan tests => 9;

    # Origin is a property of the job, not of where it is stored. A scope that
    # enforced it differently would be a hole reachable by creating the job in
    # the other one.
    my @table = (
        { id => 'custom',     edit => 1, toggle => 1, delete => 1 },
        { id => 'ext-owned',  edit => 0, toggle => 1, delete => 0,
          refusal => qr/managed by acme-backup/ },
        { id => 'ext-orphan', edit => 0, toggle => 1, delete => 1,
          refusal => qr/no longer installed/ },
    );

    for my $case (@table) {
        my $id = $case->{id};

        for my $action (qw(edit toggle delete)) {
            reset_world();
            plant('cluster');

            my $err;
            if ($action eq 'edit') {
                $err = ProxmodCronTest::refused($CLUSTER, 'update_job',
                    { id => $id, schedule => '@daily' });
            } elsif ($action eq 'toggle') {
                $err = ProxmodCronTest::refused($CLUSTER, 'set_enabled',
                    { id => $id, enabled => 0 });
            } else {
                $err = ProxmodCronTest::refused($CLUSTER, 'delete_job', { id => $id });
            }

            if ($case->{$action}) {
                is($err, undef, "cluster $id: $action is permitted");
            } else {
                like($err, $case->{refusal}, "cluster $id: $action is refused");
            }
        }
    }
};

subtest 'the row flags say exactly what the write methods will do' => sub {
    plan tests => 12;

    reset_world();
    plant('node');

    # The UI greys a button from these flags. If a flag and its method could
    # disagree, the disagreement would surface as a button that produces a 403 —
    # or, worse, one that is greyed out over an action the server would have
    # allowed. They are computed by one helper, and this asserts that by driving
    # both halves for every cell.
    my %expect = (
        custom     => { can_edit => 1, can_toggle => 1, can_delete => 1 },
        'ext-owned'  => { can_edit => 0, can_toggle => 1, can_delete => 0 },
        'ext-orphan' => { can_edit => 0, can_toggle => 1, can_delete => 1 },
    );

    for my $id (sort keys %expect) {
        my $row = row($NODE, $id, node => $NODENAME);

        for my $flag (sort keys %{ $expect{$id} }) {
            is($row->{$flag}, $expect{$id}{$flag}, "$id: $flag is $expect{$id}{$flag}");
        }

        is($row->{can_modify}, 1,
            "$id: the privilege half is satisfied, so every refusal above was an origin refusal");
    }
};

subtest 'a row says where a job came from, in words the grid can show' => sub {
    plan tests => 8;

    reset_world();
    plant('node');

    my $custom = row($NODE, 'custom', node => $NODENAME);
    is($custom->{origin}, 'user', 'a hand-made job is origin user');
    ok(!$custom->{owner}, 'and has no owner');
    is($custom->{orphaned}, 0, 'and is not an orphan');

    my $owned = row($NODE, 'ext-owned', node => $NODENAME);
    is($owned->{origin}, 'extension', 'an extension job is origin extension');
    is($owned->{owner}, 'acme-backup', 'and names its owner, which is the Source column');
    is($owned->{orphaned}, 0, 'and is not an orphan while that extension is installed');

    my $orphan = row($NODE, 'ext-orphan', node => $NODENAME);
    is($orphan->{owner}, 'gone-away', 'an orphan still names the extension that made it');
    is($orphan->{orphaned}, 1, 'and is flagged, so the grid can say so');
};

subtest 'orphaning is what unlocks removal, and it tracks the live registry' => sub {
    plan tests => 7;

    reset_world();
    plant('node');

    # While the owner is installed, the job is undeletable. This is the state
    # that would be permanent — with only hand-editing of the store as a fix —
    # if orphan detection did not exist.
    like(ProxmodCronTest::refused($NODE, 'delete_job', node_param(id => 'ext-owned')),
        qr/managed by acme-backup/, 'an installed extension owns its job');
    is(row($NODE, 'ext-owned', node => $NODENAME)->{can_delete}, 0,
        'and the row agrees');

    # apt remove the extension.
    Proxmod::Registry::_set();
    ProxmodCron::Store::_reset_owner_cache();

    my $row = row($NODE, 'ext-owned', node => $NODENAME);
    is($row->{orphaned}, 1, 'uninstalling the extension orphans its job');
    is($row->{can_delete}, 1, 'which is what makes Remove appear');
    is($row->{can_edit}, 0,
        'editing stays refused: nobody understands the job well enough to change it');

    is(ProxmodCronTest::refused($NODE, 'delete_job', node_param(id => 'ext-owned')), undef,
        'and the delete now goes through');

    # An orphan still runs. An extension being uninstalled is not a reason to
    # silently stop scheduled work an administrator may still depend on.
    is(row($NODE, 'ext-orphan', node => $NODENAME)->{enabled}, 1,
        'the remaining orphan is still enabled, and still renders');
};

subtest 'when the registry cannot be read, nothing is declared an orphan' => sub {
    plan tests => 3;

    reset_world();
    plant('node');

    # Guessing "gone" would offer a Remove button for a job whose owner is alive
    # and will recreate it on the next daemon start — a button that appears to
    # work and does nothing. Guessing "present" only withholds an action.
    no warnings 'redefine';
    local *Proxmod::Registry::load = sub { die "registry unavailable\n" };
    ProxmodCron::Store::_reset_owner_cache();

    my $row = row($NODE, 'ext-owned', node => $NODENAME);
    is($row->{orphaned}, 0, 'an unreadable registry means not orphaned, not orphaned-by-default');
    is($row->{can_delete}, 0, 'so Remove stays unavailable');

    like(ProxmodCronTest::refused($NODE, 'delete_job', node_param(id => 'ext-owned')),
        qr/managed by acme-backup/, 'and the write method refuses for the same reason');
};

subtest 'POST jobs cannot mint an extension-owned job' => sub {
    plan tests => 6;

    reset_world();

    # The extension origin is what makes a job undeletable through the UI. If a
    # request body could claim it, any Sys.Modify holder could create a job that
    # nobody could remove — and any extension could be impersonated.
    my $created = ProxmodCronTest::call($NODE, 'create_job', node_param(
        id => 'planted', type => 'command', schedule => '@daily',
        command => ['/bin/true'], origin => 'extension', owner => 'acme-backup',
    ));

    is($created->{origin}, 'user', 'origin in the body is ignored');
    ok(!$created->{owner}, 'and so is owner');
    is($created->{can_delete}, 1, 'so the job the API just made is one the API can remove');

    my $stored = ProxmodCron::Config::load('node')->{jobs}->{planted};
    is($stored->{origin}, 'user', 'and that is what is on disk, not only in the response');
    ok(!$stored->{owner}, 'with no owner recorded');

    # The one route that does produce an extension-owned job is in-process,
    # which is exactly what makes the stamp mean something.
    my $client = ProxmodCron::Client->new('acme-backup');
    $client->create('node', 'from-client', cfg());
    is(ProxmodCron::Config::load('node')->{jobs}->{'from-client'}{origin}, 'extension',
        'ProxmodCron::Client is the only way in');
};

subtest 'enabled has one route, and PUT jobs/{id} is not it' => sub {
    plan tests => 8;

    reset_world();
    plant('node');

    # Not a validation nicety: `enabled` is the one mutation permitted on an
    # extension-owned job, and routing it separately is what enforces that. If
    # update accepted the key, the rule would live in a conditional inside a
    # general handler instead — one refactor from being lost.
    my $err = ProxmodCronTest::refused($NODE, 'update_job',
        node_param(id => 'custom', enabled => 0));
    ok($err, 'update refuses a job definition carrying enabled');
    like("$err", qr/enabled/, 'and names the offending field');
    like("$err", qr/'enabled' endpoint/, 'and points at the endpoint that does it');

    is(ProxmodCron::Config::load('node')->{jobs}{custom}{enabled}, 1,
        'the refused update changed nothing');

    # It is refused on an extension job too, even though the *value* would have
    # been permitted through the other endpoint — the field is refused by
    # routing, not by whether this particular change would have been allowed.
    like(ProxmodCronTest::refused($NODE, 'update_job',
            node_param(id => 'ext-owned', enabled => 0)),
        qr/enabled/, 'and refused on an extension job for the same reason');

    is(ProxmodCronTest::refused($NODE, 'set_enabled',
            node_param(id => 'ext-owned', enabled => 0)), undef,
        'the enabled endpoint accepts what update refused');
    is(ProxmodCron::Config::load('node')->{jobs}{'ext-owned'}{enabled}, 0,
        'and switched the job off');

    is(ProxmodCronTest::refused($NODE, 'set_enabled',
            node_param(id => 'ext-owned', enabled => 1)), undef,
        'and switches it back on');
};

subtest 'an administrator switching a job off is not undone by the next restart' => sub {
    plan tests => 4;

    reset_world();

    my $client = ProxmodCron::Client->new('acme-backup');

    # What an extension does from proxmod_register, on every daemon start.
    $client->ensure('node', 'acme-nightly', cfg(schedule => '30 3 * * *'));

    ProxmodCronTest::call($NODE, 'set_enabled', node_param(id => 'acme-nightly', enabled => 0));
    is(ProxmodCron::Config::load('node')->{jobs}{'acme-nightly'}{enabled}, 0,
        'the administrator stops the job through the UI');

    # pvedaemon restarts. This is verification step 14's regression, driven
    # through both surfaces at once: the API made the decision, the client is
    # what would revert it.
    $client->ensure('node', 'acme-nightly', cfg(schedule => '30 3 * * *'));

    is(ProxmodCron::Config::load('node')->{jobs}{'acme-nightly'}{enabled}, 0,
        'and it is still stopped after the extension registers again');

    # If this ever fails, §2.1 is worth nothing: the one mutation an
    # administrator is granted would be reverted within seconds of a restart,
    # silently, and their only remaining option would be uninstalling the
    # extension.
    $client->ensure('node', 'acme-nightly', cfg(schedule => '30 3 * * *', enabled => 1));
    is(ProxmodCron::Config::load('node')->{jobs}{'acme-nightly'}{enabled}, 0,
        'not even when the extension explicitly asks for enabled');

    ProxmodCronTest::call($NODE, 'set_enabled', node_param(id => 'acme-nightly', enabled => 1));
    is(ProxmodCron::Config::load('node')->{jobs}{'acme-nightly'}{enabled}, 1,
        'the administrator can start it again, which is the other half of owning the switch');
};

subtest 'foreign cron entries are read-only in every direction' => sub {
    plan tests => 5;

    reset_world();

    # A line in another package's own cron file. Disabling it would mean
    # commenting out a line in a file we do not own, which that package's next
    # upgrade would undo — and it would break the property that makes this
    # extension safe to install at all.
    ProxmodCronTest::write_store('node', { version => 1, jobs => {} });

    my $foreign = ProxmodCron::Config::prefix() . '/etc/cron.d/zz-manual';
    open(my $fh, '>', $foreign) or die "cannot write $foreign: $!\n";
    print {$fh} "17 * * * *\troot\t/usr/local/sbin/somebody-elses-job\n";
    close($fh);

    my $entries = ProxmodCronTest::call($NODE, 'inventory', { node => $NODENAME });

    my ($entry) = grep { ($_->{command} || '') =~ /somebody-elses-job/ } @$entries;

    ok($entry, 'the entry appears in the inventory');
    is($entry->{owner}, 'system', 'attributed to the system, not to us');
    ok(!exists $entry->{can_toggle}, 'with no toggle flag, because there is no toggle');
    ok(!exists $entry->{can_delete}, 'and no delete flag');

    # It is not addressable as a job, which is the structural half of read-only:
    # there is no id that reaches it, so no write method can be pointed at it.
    like(ProxmodCronTest::refused($NODE, 'set_enabled',
            node_param(id => 'zz-manual', enabled => 0)),
        qr/no job named/, 'and it cannot be reached through the job endpoints at all');
};

subtest 'a one-element list is still a list, whatever the wire made of it' => sub {
    plan tests => 6;

    reset_world();

    # PVE's parameter parser builds an array only when a key repeats, so a
    # one-word command and a one-node target arrive as plain strings and are
    # indistinguishable from scalars by the time a method sees them. The store
    # is strict about this on purpose — ProxmodCron::Client hands it real
    # arrays — so the coercion happens once, at the API boundary.
    #
    # Without it, creating a job that runs a single binary on a single node
    # fails with "the job definition contains a value this extension will not
    # put in a crontab", which says nothing about what is wrong.
    ProxmodCronTest::call($NODE, 'create_job', node_param(
        id => 'one-word', type => 'command', schedule => '@daily',
        command => '/usr/sbin/fstrim'));

    my $job = ProxmodCronTest::call($NODE, 'get_job', node_param(id => 'one-word'));

    is_deeply($job->{command}, ['/usr/sbin/fstrim'], 'the scalar became a one-element argv');

    ProxmodCronTest::call($NODE, 'update_job', node_param(
        id => 'one-word', command => '/bin/true'));

    is_deeply(ProxmodCronTest::call($NODE, 'get_job', node_param(id => 'one-word'))->{command},
        ['/bin/true'],
        'and on an update, where the request carries no type to look the plugin up by');

    # A repeated key already arrives as a list and must pass through untouched.
    ProxmodCronTest::call($NODE, 'update_job', node_param(
        id => 'one-word', command => ['/usr/sbin/fstrim', '-a']));

    is_deeply(ProxmodCronTest::call($NODE, 'get_job', node_param(id => 'one-word'))->{command},
        ['/usr/sbin/fstrim', '-a'], 'a real list is left alone');

    # `nodes` is the same shape problem in the fields this extension declares
    # itself rather than in a plugin's.
    ProxmodCronTest::call($CLUSTER, 'create_job', {
        id => 'one-node', type => 'command', schedule => '@daily',
        command => ['/bin/true'], nodes => $NODENAME });

    is_deeply(ProxmodCronTest::call($CLUSTER, 'get_job', { id => 'one-node' })->{nodes},
        [$NODENAME], 'a single node target is a one-element list too');

    ProxmodCronTest::call($CLUSTER, 'update_job',
        { id => 'one-node', nodes => [$NODENAME, 'pve2'] });

    is_deeply(ProxmodCronTest::call($CLUSTER, 'get_job', { id => 'one-node' })->{nodes},
        [$NODENAME, 'pve2'], 'and two are two');

    # The coercion is not a licence to accept anything: it makes a scalar into a
    # list of one, and the list's own contents are checked as strictly as ever.
    like(ProxmodCronTest::refused($NODE, 'create_job', node_param(
            id => 'newline', type => 'command', schedule => '@daily',
            command => "/bin/true\nMAILTO=someone")),
        qr/will not put in a crontab/,
        'a value that cannot go in a crontab is still refused');
};
