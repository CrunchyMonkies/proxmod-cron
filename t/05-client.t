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

use Proxmod::API ();
use Proxmod::Registry ();

use ProxmodCron::Client;
use ProxmodCron::Config;
use ProxmodCron::JobType::Command;
use ProxmodCron::Registry;
use ProxmodCron::State;
use ProxmodCron::Store;

# ProxmodCron::Client: the surface another extension's backend codes against.
#
# Two properties are the reason this file is long.
#
# Ownership is taken from the Proxmod::API object, never from an argument. If it
# were a parameter, one extension could claim another's jobs or forge
# `origin: user`, and every guarantee in §2.1 would rest on callers behaving.
#
# ensure() never writes `enabled` on a job that already exists. An extension
# calls ensure() from proxmod_register, which runs on every daemon start — so if
# it wrote `enabled`, an administrator's decision to stop a job would be
# reverted within seconds of the next restart, silently, and the one mutation
# §2.1 grants them would be worth nothing. That regression has its own subtest.

plan tests => 10;

ProxmodCron::Registry::register('ProxmodCron::JobType::Command');

# A real datagram socket, so Journal stays on its native path instead of forking
# /usr/bin/logger per audit record into the host's own journal.
my $drain = ProxmodCronTest::journal_sink();

# Both owners are installed as far as proxmod is concerned, so nothing here is
# orphaned by accident. t/05b-origin.t is where orphaning is the subject.
Proxmod::Registry::_set('acme-backup', 'other-ext');
ProxmodCron::Store::_reset_owner_cache();

sub client {
    my ($id) = @_;
    return ProxmodCron::Client->new(Proxmod::API->new(id => $id, version => '1.0'));
}

sub wipe {
    for my $scope (qw(cluster node)) {
        ProxmodCronTest::write_store($scope, { version => 1, jobs => {} });
    }
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

sub raw {
    my ($scope, $id) = @_;
    my $store = ProxmodCron::Config::load($scope);
    return $store->{jobs}->{$id};
}

sub dies {
    my ($code) = @_;
    return eval { $code->(); 1 } ? undef : $@;
}

# ---------------------------------------------------------------------------

subtest 'ownership comes from the API object, not from a parameter' => sub {
    plan tests => 6;

    my $api = Proxmod::API->new(id => 'acme-backup', version => '1.0');
    my $cron = ProxmodCron::Client->new($api);

    is($cron->owner(), 'acme-backup', 'the owner is read off the Proxmod::API object');

    # A plain id is accepted for a script or a test — but note what is NOT
    # accepted anywhere: a per-call owner argument. That is the whole reason
    # this is an object.
    is(ProxmodCron::Client->new('other-ext')->owner(), 'other-ext',
        'a bare extension id works outside a daemon');

    like(dies(sub { ProxmodCron::Client->new() }),
        qr/needs a Proxmod::API object or an extension id/,
        'and nothing at all is refused');
    like(dies(sub { ProxmodCron::Client->new('Not A Valid Id') }),
        qr/is not a valid extension id/, 'so is an id that is not an id');

    like(dies(sub { $cron->list('elsewhere') }), qr/scope must be/,
        'an unknown scope is refused rather than guessed at');
    like(dies(sub { $cron->list() }), qr/scope must be/, 'and so is no scope');
};

subtest 'create stamps the job and refuses a second one with the same id' => sub {
    plan tests => 7;

    wipe();
    my $cron = client('acme-backup');

    my $written = $cron->create('node', 'acme-nightly', cfg(comment => 'nightly'));

    is($written->{origin}, 'extension', 'a job created through the client is extension-owned');
    is($written->{owner}, 'acme-backup', 'and stamped with the calling extension');
    is($written->{comment}, 'nightly', 'the rest of the config is written as given');

    # Not is_deeply against the return value: Config::load applies the field
    # defaults on the way back out, so the stored job carries `keep_output` and
    # friends that the caller never wrote. What has to match is the part the
    # client decided.
    my $stored = raw('node', 'acme-nightly');
    is_deeply([@{$stored}{qw(origin owner type schedule comment)}],
        [qw(extension acme-backup command), '30 3 * * *', 'nightly'],
        'and that is what reached the store');

    # A forged stamp is the attack this closes: without it an extension could
    # write `origin: user` and produce a job an administrator would believe they
    # had created themselves, editable and deletable through the UI.
    my $forged = $cron->create('node', 'forged',
        cfg(origin => 'user', owner => 'someone-else'));
    is($forged->{origin}, 'extension', 'origin in the config is ignored');
    is($forged->{owner}, 'acme-backup', 'and so is owner');

    like(dies(sub { $cron->create('node', 'acme-nightly', cfg()) }),
        qr/a job named 'acme-nightly' already exists/,
        'creating over an existing id dies rather than overwriting it');
};

subtest 'ensure is the idempotent one, and it is what plugin authors are steered to' => sub {
    plan tests => 6;

    wipe();
    my $cron = client('acme-backup');

    my $first = $cron->ensure('node', 'acme-nightly', cfg());
    is($first->{origin}, 'extension', 'ensure creates when there is nothing there');
    is($first->{schedule}, '30 3 * * *', 'with the config it was given');

    my $second = $cron->ensure('node', 'acme-nightly',
        cfg(schedule => '45 4 * * *', comment => 'moved later'));
    is($second->{schedule}, '45 4 * * *', 'and updates the schedule when there is');
    is($second->{comment}, 'moved later', 'and the comment');

    is(scalar(@{ $cron->list('node') }), 1,
        'calling it twice leaves one job, which is what every daemon start depends on');

    # This is the call an extension makes from proxmod_register on every start.
    # If it could take over another extension's job, one restart would be enough.
    my $other = client('other-ext');
    like(dies(sub { $other->ensure('node', 'acme-nightly', cfg()) }),
        qr/job 'acme-nightly' is not managed by other-ext/,
        'and it refuses a job belonging to another extension');
};

subtest 'ensure never overwrites the administrator\'s enable switch' => sub {
    plan tests => 6;

    wipe();
    my $cron = client('acme-backup');

    # `enabled` at creation IS honoured — an extension may ship its job switched
    # off. What it may not do is keep asserting that value afterwards.
    my $created = $cron->create('node', 'acme-nightly', cfg(enabled => 0));
    is($created->{enabled}, 0, 'an extension may create its job disabled');

    $cron->set_enabled('node', 'acme-nightly', 1);
    is(raw('node', 'acme-nightly')->{enabled}, 1, 'and switch it on deliberately');

    # The administrator stops the job. Everything after this line is the
    # regression: their decision must survive.
    ProxmodCron::Store::set_enabled('node', 'acme-nightly', 0);
    is(raw('node', 'acme-nightly')->{enabled}, 0, 'an administrator switches it off');

    $cron->ensure('node', 'acme-nightly', cfg(enabled => 1, schedule => '5 5 * * *'));

    is(raw('node', 'acme-nightly')->{enabled}, 0,
        'ensure() leaves it off even when the config says on');
    is(raw('node', 'acme-nightly')->{schedule}, '5 5 * * *',
        'while still applying everything else in the same call');

    # The escape hatch exists, and it is deliberately a separate, conspicuous
    # call rather than a side effect of the one that runs on every start.
    $cron->set_enabled('node', 'acme-nightly', 1);
    is(raw('node', 'acme-nightly')->{enabled}, 1,
        'set_enabled() is how an extension genuinely re-enables its own job');
};

subtest 'update merges a delta into one of your own jobs and nothing else' => sub {
    plan tests => 8;

    wipe();
    my $cron = client('acme-backup');
    my $other = client('other-ext');

    $cron->create('node', 'mine', cfg(comment => 'first'));
    $other->create('node', 'theirs', cfg());
    ProxmodCron::Store::create('node', 'hand-made', cfg());

    my $updated = $cron->update('node', 'mine', { schedule => '15 1 * * *' });
    is($updated->{schedule}, '15 1 * * *', 'the delta is applied');
    is($updated->{comment}, 'first', 'and everything not in it is left alone');

    # undef clears a key, because JSON null arrives as undef and emptying an
    # optional field has to be expressible.
    my $cleared = $cron->update('node', 'mine', { comment => undef });
    ok(!exists $cleared->{comment}, 'an undefined value in the delta clears the key');

    # enabled has its own call. Routing enforces the §2.1 rule instead of a
    # conditional inside a general update path, where it would be one refactor
    # away from being lost.
    like(dies(sub { $cron->update('node', 'mine', { enabled => 0 }) }),
        qr/use set_enabled/, 'enabled in a delta is refused, and says what to call');

    my $stamped = $cron->update('node', 'mine', { origin => 'user', owner => 'other-ext' });
    is($stamped->{origin}, 'extension', 'origin is never taken from a delta');
    is($stamped->{owner}, 'acme-backup', 'and neither is owner');

    like(dies(sub { $cron->update('node', 'theirs', { schedule => '@daily' }) }),
        qr/not managed by acme-backup/, "another extension's job is refused");
    like(dies(sub { $cron->update('node', 'hand-made', { schedule => '@daily' }) }),
        qr/not managed by acme-backup/, 'and so is one an administrator created');
};

subtest 'set_enabled and delete stay inside the caller\'s own jobs' => sub {
    plan tests => 8;

    wipe();
    my $cron = client('acme-backup');
    my $other = client('other-ext');

    $cron->create('node', 'mine', cfg());
    $other->create('node', 'theirs', cfg());
    ProxmodCron::Store::create('node', 'hand-made', cfg());

    $cron->set_enabled('node', 'mine', 0);
    is(raw('node', 'mine')->{enabled}, 0, 'an extension can stop its own job');

    like(dies(sub { $cron->set_enabled('node', 'theirs', 0) }),
        qr/not managed by acme-backup/, "but not another extension's");
    like(dies(sub { $cron->set_enabled('node', 'hand-made', 0) }),
        qr/not managed by acme-backup/, 'and not an administrator\'s');
    like(dies(sub { $cron->set_enabled('node', 'no-such-job', 0) }),
        qr/no job named 'no-such-job'/, 'a job that does not exist says so');

    $cron->delete('node', 'mine');
    is(raw('node', 'mine'), undef, 'an extension can remove its own job');

    like(dies(sub { $cron->delete('node', 'theirs') }),
        qr/not managed by acme-backup/, "but not another extension's");
    ok(raw('node', 'theirs'), 'and the refused delete left it in place');

    like(dies(sub { $cron->delete('node', 'no-such-job') }),
        qr/no job named 'no-such-job'/, 'and a missing job is an error, not a no-op');
};

subtest 'reads are not filtered by owner unless you ask them to be' => sub {
    plan tests => 7;

    wipe();
    my $cron = client('acme-backup');
    my $other = client('other-ext');

    $cron->create('node', 'b-mine', cfg());
    $other->create('node', 'a-theirs', cfg());
    $cron->create('cluster', 'c-cluster', cfg());

    my $all = $cron->list('node');
    is_deeply([map { $_->{id} } @$all], ['a-theirs', 'b-mine'],
        'list returns every job in the scope, sorted, whoever owns it');

    # Not a permission boundary and not pretending to be one: the store is
    # readable by root regardless, and an extension may legitimately want to know
    # what else is scheduled before adding to it.
    my $mine = $cron->list('node', mine => 1);
    is_deeply([map { $_->{id} } @$mine], ['b-mine'], 'mine => 1 narrows it to your own');

    is($all->[0]{enabled}, 1, 'rows come back with defaults applied');
    is($all->[0]{user}, 'root', 'including the crontab user from the job type');

    is($cron->get('node', 'b-mine')->{owner}, 'acme-backup', 'get returns one job');
    is($cron->get('node', 'nothing-here'), undef, 'and undef for one that is not there');

    is_deeply([map { $_->{id} } @{ $cron->list('cluster') }], ['c-cluster'],
        'the two scopes are separate stores');
};

subtest 'a write renders immediately and is recorded where a query will find it' => sub {
    plan tests => 8;

    wipe();
    $drain->();

    my $cron = client('acme-backup');
    $cron->create('node', 'acme-nightly', cfg(track => 0));

    # The REST layer renders synchronously on every write so the UI is not a
    # minute behind itself. The client goes through the same code, so an
    # extension's job is live without waiting for the anchor either.
    my $rendered = ProxmodCronTest::slurp(ProxmodCron::Render::path('node'));
    like($rendered, qr/# job: acme-nightly \(command\) \[acme-backup\]/,
        'the generated cron.d file exists already');
    like($rendered, qr{^30 3 \* \* \*\troot\t/usr/lib/acme/backup$}m,
        'with the job in it');

    my ($entry) = grep { $_->{PROXMOD_CRON_EVENT} eq 'change' } @{ $drain->() };

    ok($entry, 'the mutation was recorded in the journal');
    is($entry->{PROXMOD_CRON_JOB}, 'acme-nightly',
        'under the same field the run records use, so the two interleave');
    is($entry->{PROXMOD_CRON_ACTOR}, 'acme-backup', 'attributed to the extension that made it');
    is($entry->{PROXMOD_CRON_VIA}, 'client', 'through the surface it came in on');
    # Not a PVE user, so not in the field that means one. `journalctl
    # PROXMOD_CRON_USER=root@pam` has to return that person's changes and not an
    # extension's, which it cannot do if an extension id is ever written here.
    ok(!exists $entry->{PROXMOD_CRON_USER},
        'and PROXMOD_CRON_USER is absent, because an extension is not a user');
    like($entry->{MESSAGE}, qr/create node job 'acme-nightly' by acme-backup via client/,
        'and the message says what happened, to what, by whom, through which surface');
};

subtest 'the read-back methods reach the right stores' => sub {
    plan tests => 6;

    wipe();
    my $cron = client('acme-backup');
    $cron->create('node', 'acme-nightly', cfg());

    ProxmodCron::State::record('node', 'acme-nightly', {
        run => '1739000000000-a3f10b2c', exit => 0, started => 1739000000,
    });

    my $status = $cron->status('node', 'acme-nightly');
    is($status->{run}, '1739000000000-a3f10b2c', 'status reads the derived cache');
    is($cron->status('node', 'never-run'), undef,
        'and a job with no record is undef, which means "nothing here", not "never ran"');

    # SYSLOG_IDENTIFIER is on every fixture because it is in every match Runs
    # builds — an entry without it is not ours, and journald ANDs across field
    # names.
    ProxmodCronTest::journal_runner([
        { SYSLOG_IDENTIFIER => 'proxmod-cron',
          PROXMOD_CRON_JOB => 'acme-nightly', PROXMOD_CRON_SCOPE => 'node',
          PROXMOD_CRON_RUN => 'r1', PROXMOD_CRON_EVENT => 'start',
          __REALTIME_TIMESTAMP => '1739000000000000' },
        { SYSLOG_IDENTIFIER => 'proxmod-cron',
          PROXMOD_CRON_JOB => 'acme-nightly', PROXMOD_CRON_SCOPE => 'node',
          PROXMOD_CRON_RUN => 'r1', PROXMOD_CRON_EVENT => 'finish',
          PROXMOD_CRON_EXIT => '0', PROXMOD_CRON_DURATION_MS => '1200',
          __REALTIME_TIMESTAMP => '1739000001200000' },
        { SYSLOG_IDENTIFIER => 'proxmod-cron',
          PROXMOD_CRON_JOB => 'somebody-else', PROXMOD_CRON_SCOPE => 'node',
          PROXMOD_CRON_RUN => 'r2', PROXMOD_CRON_EVENT => 'start',
          __REALTIME_TIMESTAMP => '1739000002000000' },
    ]);

    my $runs = $cron->runs('node', 'acme-nightly');
    is(scalar(@$runs), 1, 'runs asks journald for this job only');
    is($runs->[0]{run}, 'r1', 'and folds the entries into one run record');

    is_deeply($cron->types(), ProxmodCron::Registry::catalogue(),
        'types is the same catalogue the editor is built from, not a second copy');

    my $sync = $cron->sync();
    is_deeply($sync->{errors}, [], 'sync runs and reports nothing wrong');
};

subtest 'two extensions cannot reach each other, in any direction' => sub {
    plan tests => 6;

    wipe();
    my $a = client('acme-backup');
    my $b = client('other-ext');

    $b->create('node', 'theirs', cfg(comment => 'belongs to other-ext'));
    my $before = raw('node', 'theirs');

    # Every mutating method, one after another, against a job the caller does not
    # own. The point of running the whole set is that a single missed check is a
    # cross-extension takeover, and there is no partial version of that.
    like(dies(sub { $a->ensure('node', 'theirs', cfg()) }), qr/not managed by acme-backup/,
        'ensure is refused');
    like(dies(sub { $a->update('node', 'theirs', { schedule => '@daily' }) }),
        qr/not managed by acme-backup/, 'update is refused');
    like(dies(sub { $a->set_enabled('node', 'theirs', 0) }), qr/not managed by acme-backup/,
        'set_enabled is refused');
    like(dies(sub { $a->delete('node', 'theirs') }), qr/not managed by acme-backup/,
        'delete is refused');
    like(dies(sub { $a->create('node', 'theirs', cfg()) }), qr/already exists/,
        'and create cannot be used to replace it either');

    is_deeply(raw('node', 'theirs'), $before,
        'after all five, the job is byte-for-byte what its owner wrote');
};
