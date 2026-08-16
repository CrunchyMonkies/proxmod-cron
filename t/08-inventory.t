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

use File::Copy ();
use File::Path ();

use ProxmodCron::Config;
use ProxmodCron::Inventory;
use ProxmodCron::JobType::Command;
use ProxmodCron::Registry;
use ProxmodCron::Render;
use ProxmodCron::Sync;

# Read-only discovery of everything scheduled on the host.
#
# The fixtures under t/fixtures/inventory are copied from a stock Debian host,
# because the point of this view is the entries we did not create: an
# administrator asking "what runs at 03:00 on this box" is not asking about our
# rows. Three of them are deliberately broken in ways cron handles silently —
# a dot in a file name, a five-field line in /etc/cron.d, a minute of 99 — and
# saying so is the most useful thing the view does.
#
# Nothing here writes to any of it. The property that makes this extension safe
# to install is that it only ever writes the two files it generates, and the
# last subtest is the one that pins that.

plan tests => 9;

ProxmodCron::Registry::register('ProxmodCron::JobType::Command');

my $FIXTURES = "$FindBin::Bin/fixtures/inventory";
my $ROOT = ProxmodCron::Config::prefix();

# Copy the tree in, preserving the executable bit — run-parts cares about it,
# and a fixture that lost it would make the "not executable" note fire on a file
# that is fine.
sub install_fixtures {
    my @files = (
        'etc/crontab',
        'etc/cron.d/e2scrub_all',
        'etc/cron.d/php.backup',
        'etc/cron.d/zz-manual',
        'etc/cron.daily/apt-compat',
        'etc/cron.daily/logrotate',
        'etc/cron.weekly/man-db.dpkg-old',
        'var/spool/cron/crontabs/Not-A-User',
        'var/spool/cron/crontabs/backup',
        'var/spool/cron/crontabs/root',
    );

    for my $rel (@files) {
        my $src = "$FIXTURES/$rel";
        my $dst = "$ROOT/$rel";

        die "missing fixture $rel\n" if !-f $src;

        File::Path::make_path(($dst =~ m{\A(.*)/[^/]+\z})[0]);
        File::Copy::copy($src, $dst) or die "cannot copy $rel: $!\n";
        chmod((stat($src))[2] & 07777, $dst);
    }

    return;
}

install_fixtures();

my $ALL = ProxmodCron::Inventory::collect();

sub from {
    my ($source) = @_;
    return [grep { $_->{source} eq $source } @$ALL];
}

sub matching {
    my ($pattern, $entries) = @_;
    $entries ||= $ALL;
    return [grep { defined($_->{command}) && $_->{command} =~ $pattern } @$entries];
}

sub one {
    my ($pattern, $entries) = @_;
    my $found = matching($pattern, $entries);
    return @$found == 1 ? $found->[0] : undef;
}

# ---------------------------------------------------------------------------

subtest 'the system crontab, with its user column' => sub {
    plan tests => 6;

    my $entries = from('crontab');

    is(scalar(@$entries), 4, 'four job lines, and none of the comments or assignments');

    # Environment lines are not scheduled work. Listing MAILTO as a cron entry
    # would be noise in the one view whose value is that it is complete.
    is_deeply(matching(qr/SHELL|PATH|MAILTO/, $entries), [],
        'the environment assignments are not reported as jobs');

    my $hourly = one(qr/cron\.hourly/, $entries);
    ok($hourly, 'the run-parts hourly line is there');
    is($hourly->{schedule}, '17 * * * *', 'with its schedule');
    is($hourly->{user}, 'root', 'and its user, read from the sixth field');
    is($hourly->{owner}, 'system', 'attributed to the system');
};

subtest '/etc/cron.d, six fields and other packages' => sub {
    plan tests => 7;

    my $entries = from('cron.d');

    my $e2scrub = one(qr/e2scrub_all_cron.*\z/, [grep { $_->{schedule} eq '30 3 * * 0' } @$entries]);
    ok($e2scrub, "another package's file is listed");
    is($e2scrub->{user}, 'root', 'with the user from the sixth field');
    is($e2scrub->{owner}, 'system', 'and attributed to the system, not to us');
    like($e2scrub->{path}, qr{/etc/cron\.d/e2scrub_all\z}, 'with the file it came from');
    is($e2scrub->{line}, 1, 'and the line number in it');

    # A line cron would reject. Reporting it as a job with no schedule would be
    # worse than not reporting it: the administrator would think it runs.
    my ($undersized) = grep { ($_->{command} || '') =~ /no-user-column/ } @$entries;
    is($undersized, undef,
        'a five-field line in /etc/cron.d is not a job, and is not reported as one');

    my $nightly = one(qr{/usr/local/sbin/nightly}, $entries);
    is($nightly->{user}, 'root', 'while the well-formed line next to it is read normally');
};

subtest 'user crontabs, where the file name is the user' => sub {
    plan tests => 6;

    my $entries = from('user');

    is(scalar(@$entries), 3, 'three entries across two crontabs');

    my $rsync = one(qr/rsync-home/, $entries);
    is($rsync->{user}, 'backup', 'the user comes from the file name');
    is($rsync->{schedule}, '@daily', 'shorthand schedules are kept as written');
    ok(defined $rsync->{next_run}, 'and still resolve to a next run');

    # Five fields, not six: in a user crontab the fifth field is already the
    # command. Reading a user column here would silently drop the first word of
    # every command.
    my $weekday = one(qr/weekday-sync/, $entries);
    is($weekday->{command}, '/usr/local/bin/weekday-sync --quiet',
        'no user column is consumed from a user crontab');

    # crond will not run a crontab whose name is not a user name, so neither
    # will we claim it as one.
    is_deeply(matching(qr{/bin/true}, $entries), [],
        'a crontab whose name is not a valid user name is skipped');
};

subtest 'run-parts directories, listed with their nominal schedule' => sub {
    plan tests => 6;

    my $entries = from('run-parts');

    my $logrotate = one(qr/logrotate\z/, $entries);
    ok($logrotate, 'a daily script is listed');
    is($logrotate->{schedule}, '25 6 * * *', 'with the schedule Debian gives cron.daily');
    is($logrotate->{user}, 'root', 'run by root');
    is($logrotate->{nominal}, 1,
        'flagged nominal, because /etc/crontab is what really decides and may have been edited');
    ok(!$logrotate->{note}, 'and with nothing wrong with it');

    is($logrotate->{command}, "$ROOT/etc/cron.daily/logrotate",
        'the command is the script itself');
};

subtest 'the three silent failures are named' => sub {
    plan tests => 6;

    # A dot in the name. cron ignores the whole file: no error, no log line, the
    # job simply never runs. This is the single most useful thing the view says.
    my $php = one(qr{sessionclean}, $ALL);
    ok($php, 'a file cron ignores is still listed');
    like($php->{note}, qr/cron ignores this file/, 'with a note saying cron ignores it');
    like($php->{note}, qr/name contains a character/, 'and why');

    # Same rule, different program: run-parts applies it to the cron.* dirs.
    my $mandb = one(qr/man-db\.dpkg-old\z/, $ALL);
    like($mandb->{note}, qr/run-parts ignores this file/,
        'and run-parts ignores a dotted name in cron.weekly');

    # A script run-parts will skip because nobody chmod +x'd it.
    my $apt = one(qr/apt-compat\z/, $ALL);
    like($apt->{note}, qr/not executable/, 'a non-executable script is flagged');

    # A schedule cron will not accept.
    my $never = one(qr/never-runs/, $ALL);
    ok($never->{schedule_error}, 'and a line with an impossible minute carries the parse error');
};

subtest 'a percent is shown as the command that actually runs' => sub {
    plan tests => 3;

    # In a crontab '%' means "newline, everything after this is stdin". Showing
    # the raw text would be a lie about what runs; showing the escaped form would
    # be a lie about what the administrator wrote.
    my $dump = one(qr/dump/, $ALL);

    ok($dump, 'the line is listed');
    is($dump->{command}, '/usr/local/bin/dump --stamp %F',
        'the command is cut at the first unescaped percent, and the escaped one is unescaped');
    unlike($dump->{command}, qr/stdin/, 'so the stdin half is not shown as part of the command');
};

subtest 'our own generated file is attributed to us' => sub {
    plan tests => 5;

    ProxmodCronTest::write_store('node', { version => 1, jobs => {
        'node-trim' => { type => 'command', schedule => '30 2 * * *',
            command => ['/usr/sbin/fstrim', '-a'], track => 0 },
    } });
    ProxmodCron::Sync::run();

    my $entries = ProxmodCron::Inventory::collect();

    my $ours = one(qr/fstrim/, $entries);
    ok($ours, 'the job we render shows up in the inventory like any other');
    is($ours->{owner}, 'proxmod-cron', 'attributed to this extension');
    is($ours->{source}, 'cron.d', 'from where it actually is');

    # The attribution is what the UI uses to decide a row is not foreign. A
    # generated file that read as `system` would make our own jobs look
    # untouchable in the very grid that manages them.
    my ($foreign) = grep { $_->{owner} eq 'system' } @{ from('cron.d') };
    ok($foreign, 'while other packages\' files in the same directory stay system');

    is(scalar(@{ matching(qr/fstrim/, [grep { $_->{owner} eq 'system' } @$entries]) }), 0,
        'and nothing of ours is attributed to the system');
};

subtest 'nothing that cannot be turned into a path is opened' => sub {
    plan tests => 3;

    # readdir results are tainted and are concatenated into paths this module
    # opens. Untainting is by pattern-and-rebuild, so a name that does not match
    # is dropped rather than laundered.
    my $dir = ProxmodCron::Config::cron_d();

    for my $name ('.hidden-job', '-leading-dash', 'space name') {
        my $path = "$dir/$name";
        open(my $fh, '>', $path) or die "cannot write $path: $!\n";
        print {$fh} "0 0 * * *\troot\t/usr/local/sbin/should-not-appear-$name\n";
        close($fh);
    }

    my $entries = ProxmodCron::Inventory::collect();

    is_deeply(matching(qr/should-not-appear/, $entries), [],
        'files whose names do not untaint are not read');

    # And the ones that do untaint are still read, so the pattern is not simply
    # rejecting everything.
    ok(scalar(@{ from('cron.d') }), 'while the rest of the directory still is');

    unlink("$dir/$_") for ('.hidden-job', '-leading-dash', 'space name');

    # A directory that is not there at all is the normal state on a host with no
    # user crontabs, and is not an error.
    File::Path::remove_tree("$ROOT/var/spool/cron/crontabs");
    my $after = ProxmodCron::Inventory::collect();
    is_deeply([grep { $_->{source} eq 'user' } @$after], [],
        'and a missing directory yields nothing rather than dying');
};

subtest 'collecting the inventory changes nothing on disk' => sub {
    plan tests => 3;

    install_fixtures();

    my @paths = (
        "$ROOT/etc/crontab",
        "$ROOT/etc/cron.d/zz-manual",
        "$ROOT/etc/cron.daily/logrotate",
    );

    my %before = map { $_ => [ProxmodCronTest::slurp($_), (stat($_))[1, 2]] } @paths;

    ProxmodCron::Inventory::collect() for 1 .. 3;

    my $identical = 1;
    for my $path (@paths) {
        my @now = (ProxmodCronTest::slurp($path), (stat($path))[1, 2]);
        $identical = 0 if "@now" ne "@{ $before{$path} }";
    }

    ok($identical, 'content, inode and mode are untouched after three collections');

    # The claim in full: the only paths this package ever writes are the two it
    # generates. Everything else in /etc/cron.d belongs to whoever installed it,
    # and a sync must leave it exactly where it is.
    ProxmodCron::Sync::run();

    ok(-e "$ROOT/etc/cron.d/zz-manual", "a hand-written file survives a sync");
    is(ProxmodCronTest::slurp("$ROOT/etc/cron.d/zz-manual"), $before{"$ROOT/etc/cron.d/zz-manual"}[0],
        'unchanged, byte for byte');
};
