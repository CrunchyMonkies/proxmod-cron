#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/../perl", "$FindBin::Bin/lib";

our $ROOT;

BEGIN {
    require ProxmodCronTest;
    $ROOT = ProxmodCronTest::prefix_tree();
}

use ProxmodCron::Config;
use ProxmodCron::JobType::Command;
use ProxmodCron::Registry;
use ProxmodCron::Render;
use ProxmodCron::Spec;

# The renderer: definitions in, the text of one /etc/cron.d file out.
#
# This is the file the rest of the package is judged by, because the rendered
# text IS the behaviour — there is no daemon interpreting these definitions, cron
# reads this and runs it as root. Three of cron's rules are silent when broken
# and are therefore asserted here rather than anywhere else:
#
#   * the command is handed to $SHELL, so every argv element is quoted
#   * '%' means "newline, rest is stdin", so an unescaped one truncates the job
#   * a file name containing '.' is ignored by cron, without a word anywhere
#
# The first subtest is a golden file. It is deliberately the widest assertion in
# the suite: a diff against it shows the whole file, which is what a reviewer
# needs to see when the rendering changes, rather than a list of substrings that
# each still pass while the file as a whole has become something else.

plan tests => 11;

ProxmodCron::Registry::register('ProxmodCron::JobType::Command');

ProxmodCronTest::register_type('acme-backup',
    title => 'Acme Backup',
    build => sub { ['/usr/lib/acme/backup', '--vmid', $_[0]->{vmid}] },
    privs => sub { [["/vms/$_[0]{vmid}", ['VM.Backup']]] },
);

my $GOLDEN = "$FindBin::Bin/fixtures/render/node.cron";

# Every path in the rendered text is under the disposable prefix, which changes
# on every run. Normalising it is what lets the golden file be a file.
sub normalise {
    my ($text) = @_;
    return undef if !defined $text;
    $text =~ s/\Q$ROOT\E/\@PREFIX\@/g;
    return $text;
}

sub render {
    my ($scope, $store, $node) = @_;
    return ProxmodCron::Render::render($scope, $store, $node);
}

sub job {
    my (%over) = @_;
    return {
        type => 'command',
        schedule => '30 2 * * *',
        command => ['/bin/true'],
        %over,
    };
}

sub one {
    my (%over) = @_;
    return { jobs => { 'only-job' => job(%over) } };
}

# The line cron would act on: the single uncommented, non-directive line.
sub cron_line {
    my ($text) = @_;
    my @lines = grep { /\S/ && !/\A#/ && !/\A(?:SHELL|PATH|MAILTO)=/ } split(/\n/, $text || '');
    return $lines[0];
}

# ---------------------------------------------------------------------------

subtest 'the whole file, against a golden fixture' => sub {
    plan tests => 2;

    my $store = {
        jobs => {
            'a-trim' => {
                type => 'command',
                schedule => '30 2 * * *',
                comment => 'fstrim all mounts',
                command => ['/usr/sbin/fstrim', '-a'],
            },
            'b-report' => {
                type => 'command',
                schedule => '*/15 * * * *',
                track => 0,
                comment => "everything awkward, in one argv",
                command => ['/usr/local/bin/report', '--label', 'monthly report',
                    "it's here", '50%', '$HOME', ''],
            },
            'c-weekly' => {
                type => 'command',
                schedule => '0 4 * * 0',
                enabled => 0,
                track => 0,
                comment => 'kept in the file so it is still visible',
                command => ['/usr/lib/acme/backup', '--full'],
            },
            'd-acme' => {
                type => 'acme-backup',
                origin => 'extension',
                owner => 'acme-backup',
                schedule => '@daily',
                vmid => 101,
            },
            'e-chatty' => {
                type => 'command',
                schedule => '@hourly',
                keep_output => 0,
                comment => 'tracked, but its output is not kept',
                command => ['/usr/bin/chatty'],
            },
            'f-orphan' => {
                type => 'gone-away',
                schedule => '0 5 * * *',
                comment => 'the plugin for this is not installed',
            },
        },
    };

    my $text = normalise(render('node', $store, 'pve1'));

    # PROXMOD_CRON_UPDATE_GOLDEN=1 rewrites the fixture. Reviewing the resulting
    # diff is the point of the fixture existing, so this is a convenience for
    # producing that diff, not a way to make a failure go away.
    if ($ENV{PROXMOD_CRON_UPDATE_GOLDEN}) {
        require File::Path;
        my $dir = $GOLDEN;
        $dir =~ s{/[^/]+\z}{};
        File::Path::make_path($dir);
        open(my $fh, '>', $GOLDEN) or die "cannot write $GOLDEN: $!\n";
        print {$fh} $text;
        close($fh);
        diag("rewrote $GOLDEN");
    }

    ok(-f $GOLDEN, 'the golden file exists');
    is($text, ProxmodCronTest::slurp($GOLDEN), 'the rendered file matches it exactly');
};

subtest 'the header says where the file came from and what is in it' => sub {
    plan tests => 9;

    my @lines = split(/\n/, render('node', one(), 'pve1'));

    is($lines[0], "# $ProxmodCron::Render::BANNER",
        'the first line says the file is generated and will be overwritten');
    is($lines[1], '# Source: ' . ProxmodCron::Config::file_for('node')
        . '   Scope: node   Node: pve1   Jobs: 1',
        'the second says which store it came from, for which node, and how many jobs');
    is($lines[2], 'SHELL=/bin/sh', 'the shell is stated rather than inherited');
    is($lines[3], "PATH=$ProxmodCron::Render::PATH",
        'and so is PATH, because cron\'s default is almost empty');

    # Cron's default is to mail a job's output to its user, which on a hypervisor
    # means mail nobody reads until the spool fills. Emptying it is only
    # defensible because proxmod-cron-exec captures that output into journald
    # instead — the two decisions are one decision.
    is($lines[4], 'MAILTO=""', 'output is not mailed by default');

    my $addressed = render('node', { %{ one() }, mailto => 'ops@example.com' }, 'pve1');
    like($addressed, qr/^MAILTO=ops\@example\.com$/m,
        'an administrator who does want the mail sets it on the store');

    # This line is read by cron itself. A newline in it would end the MAILTO
    # directive and start whatever came next, in a file that runs as root.
    for my $bad ("ops\@example.com\n0 * * * * root /bin/sh", 'not an address', '') {
        my $text = render('node', { %{ one() }, mailto => $bad }, 'pve1');
        like($text, qr/^MAILTO=""$/m,
            'anything that is not a plain address is dropped, not rendered');
    }
};

subtest 'quoting happens once, here, because cron hands the line to a shell' => sub {
    plan tests => 14;

    # Bare where it is unambiguously safe: the readability of the generated file
    # is the reason native cron was chosen as the engine, and a file where every
    # argument is quoted is a file nobody reads.
    my @bare = ('/usr/sbin/fstrim', '-a', '--label=value', 'a.b:c@d,e+f', '42');
    for my $arg (@bare) {
        is(ProxmodCron::Render::quote($arg), $arg, "'$arg' is left bare");
    }

    is(ProxmodCron::Render::quote(''), q{''}, 'an empty argument becomes a visible empty string');
    is(ProxmodCron::Render::quote(undef), q{''}, 'and so does an undefined one');
    is(ProxmodCron::Render::quote('two words'), q{'two words'}, 'a space is quoted');
    is(ProxmodCron::Render::quote('$HOME'), q{'$HOME'}, 'so is a variable the shell would expand');
    is(ProxmodCron::Render::quote('`id`'), q{'`id`'}, 'so is a command substitution');
    is(ProxmodCron::Render::quote('a;rm -rf /'), q{'a;rm -rf /'}, 'so is a command separator');
    is(ProxmodCron::Render::quote('a*b'), q{'a*b'}, 'so is a glob');

    # The one character single quotes cannot protect: close, escape, reopen.
    is(ProxmodCron::Render::quote("it's"), q{'it'\''s'}, 'a single quote is closed, escaped and reopened');
    is(ProxmodCron::Render::quote(q{'}), q{''\'''}, 'including one on its own');
};

subtest 'a % is escaped, after quoting, because cron reads the line first' => sub {
    plan tests => 4;

    is(ProxmodCron::Render::escape_percent('50%'), '50\\%', 'a bare % is escaped');
    is(ProxmodCron::Render::escape_percent('a%b%c'), 'a\\%b\\%c', 'every one of them');
    is(ProxmodCron::Render::escape_percent(''), '', 'and nothing happens to text without one');

    # Quoting does not protect a '%': cron splits the line on it before the shell
    # is involved, so a quoted one still truncates the command. This is the
    # assertion that fixes the ordering of the two transformations.
    my $line = cron_line(render('node', one(track => 0,
        command => ['/bin/echo', 'a % inside quotes']), 'pve1'));
    like($line, qr/'a \\% inside quotes'/,
        'a % inside a quoted argument is escaped too');
};

subtest 'a disabled job is commented out, not removed' => sub {
    plan tests => 5;

    my $text = render('node', one(enabled => 0, track => 0, comment => 'off for now'), 'pve1');

    like($text, qr/^# job: only-job \(command\) - off for now - DISABLED$/m,
        'the header says so');
    like($text, qr/^#30 2 \* \* \*\troot\t\/bin\/true$/m,
        'and the line is still there, behind a #');
    is(cron_line($text), undef, 'so cron acts on nothing');

    # Vanishing would be worse than useless: `cat /etc/cron.d/proxmod-cron-node`
    # is how an administrator checks what is defined, and a job that is defined
    # but absent from the file reads as a job that was never created.
    like($text, qr/Jobs: 1/, 'it still counts as a job');

    my $enabled = render('node', one(track => 0), 'pve1');
    like($enabled, qr/^30 2 \* \* \*\troot\t\/bin\/true$/m,
        'and the same job enabled renders the same line without the #');
};

subtest 'tracked jobs render through the wrapper, untracked ones do not' => sub {
    plan tests => 6;

    my $exec = $ProxmodCron::Render::EXEC;

    my $tracked = cron_line(render('node', one(), 'pve1'));
    is($tracked, "30 2 * * *\troot\t$exec node only-job --type command -- /bin/true",
        'the wrapper is given the scope, the job id and the type, then -- then the argv');

    my $quiet = cron_line(render('node', one(keep_output => 0), 'pve1'));
    is($quiet, "30 2 * * *\troot\t$exec node only-job --no-output --type command -- /bin/true",
        'keep_output: false is a flag to the wrapper, not a different code path');

    my $bare = cron_line(render('node', one(track => 0), 'pve1'));
    is($bare, "30 2 * * *\troot\t/bin/true",
        'an untracked job runs its command directly, with nothing in between');

    my $cluster = cron_line(render('cluster', one(), 'pve1'));
    like($cluster, qr/\Q$exec\E cluster only-job /,
        'the scope in the wrapper is the store the job came from');

    # The type is carried on the line so PROXMOD_CRON_TYPE describes the
    # definition that produced this argv, not whatever the store says by the time
    # the job runs.
    my $typed = cron_line(render('node', one(type => 'acme-backup',
        vmid => 101, command => undef), 'pve1'));
    like($typed, qr/\Qonly-job --type acme-backup --\E/,
        "the plugin type reaches the wrapper as the type it was rendered from");

    # The wrapper's arguments are quoted by the same code as the job's, so a job
    # id that needed quoting would still be one argument. Ids cannot contain a
    # space today; this asserts the rendering does not assume that.
    like($tracked, qr/\Q-- \E\/bin\/true\z/, 'the argv follows the -- unchanged');
};

subtest 'a cluster job carries its fire-time guards on the rendered line' => sub {
    plan tests => 8;

    my $exec = $ProxmodCron::Render::EXEC;

    # The rendered file is a statement about the last minute; quorum and
    # placement are questions about this one. So they cannot be answered here —
    # only delegated, which is what these flags are.
    my $guarded = cron_line(render('cluster', one(), 'pve1'));
    is($guarded, "30 2 * * *\troot\t$exec cluster only-job --type command"
        . ' --require-quorum -- /bin/true',
        'every cluster job asks the wrapper to check quorum before it runs');

    my $node = cron_line(render('node', one(), 'pve1'));
    unlike($node, qr/--require-quorum/,
        'a node job has no cluster to be quorate in and is not asked');

    my $once = cron_line(render('cluster', one(run_on => 'any'), 'pve1'));
    is($once, "30 2 * * *\troot\t$exec cluster only-job --type command"
        . " --require-quorum --once --schedule '30 2 * * *' -- /bin/true",
        'run_on: any adds the lease, with the schedule the tick is derived from');

    # The schedule travels on the line rather than being read back from the
    # store for the same reason the type does: the tick both nodes race for has
    # to come from the definition that produced this line.
    like($once, qr/--schedule '30 2 \* \* \*'/,
        'and it is quoted, because a cron spec is full of spaces and stars');

    is(cron_line(render('cluster', one(run_on => 'all'), 'pve1')), $guarded,
        "run_on: all is the default and renders exactly as an absent one does");

    # An untracked cluster job gains a wrapper it did not have before, because
    # the guard has to live somewhere. --no-record is what keeps everything else
    # about it the same: no run lock, no history, output straight to cron.
    my $untracked = cron_line(render('cluster', one(track => 0), 'pve1'));
    is($untracked, "30 2 * * *\troot\t$exec cluster only-job --type command"
        . ' --require-quorum --no-record -- /bin/true',
        'an untracked cluster job is guarded and otherwise left alone');

    unlike(cron_line(render('node', one(track => 0), 'pve1')), qr/\Q$exec\E/,
        'while an untracked node job still runs its command directly');

    # An operator who named a job and a node has already made the choice the
    # lease exists to make, so a manual run must not lose a race to a scheduled
    # tick happening on another node at the same moment.
    my $manual = ProxmodCron::Render::wrap(
        ProxmodCron::Config::effective('cluster', one(run_on => 'any'), 'only-job'),
        ['/bin/true'], manual => 1);
    ok(!grep({ $_ eq '--once' } @$manual),
        'a manual run keeps the quorum guard and drops the lease');
};

subtest 'a cluster job renders only on the nodes it targets' => sub {
    plan tests => 7;

    my $store = {
        jobs => {
            'everywhere' => job(track => 0),
            'targeted' => job(track => 0, nodes => ['pve1']),
            'all-keyword' => job(track => 0, nodes => ['all']),
            'empty-list' => job(track => 0, nodes => []),
            'elsewhere' => job(track => 0, nodes => ['pve9']),
        },
    };

    my $pve1 = render('cluster', $store, 'pve1');
    my $pve2 = render('cluster', $store, 'pve2');

    like($pve1, qr/# job: targeted /, 'a job naming this node renders on it');
    unlike($pve2, qr/# job: targeted /, 'and not on any other');

    # The permissive readings, all three of them: a cluster job with no targeting
    # is the common case, and one that silently ran nowhere would be a bug an
    # administrator could only find by waiting for it not to happen.
    like($pve2, qr/# job: everywhere /, 'no nodes key means every node');
    like($pve2, qr/# job: all-keyword /, "and so does 'all'");
    like($pve2, qr/# job: empty-list /, 'and so does an empty list');

    unlike($pve1, qr/# job: elsewhere /, 'a job naming only another node renders nowhere here');
    like($pve2, qr/Jobs: 3/, 'and the count in the header is what this node actually got');
};

subtest 'nothing to render is undef, which is the signal to remove the file' => sub {
    plan tests => 4;

    is(render('node', { jobs => {} }, 'pve1'), undef, 'an empty store renders nothing');
    is(render('node', {}, 'pve1'), undef, 'and so does a store with no jobs key at all');

    # An empty generated file left behind would say "proxmod-cron manages nothing
    # here", which is true, and would also stop the caller ever removing it.
    is(render('cluster', { jobs => { 'a' => job(nodes => ['pve9']) } }, 'pve1'), undef,
        'a store whose every job targets other nodes renders nothing on this one');

    ok(defined(render('cluster', { jobs => { 'a' => job(nodes => ['pve9']) } }, 'pve9')),
        'and the same store renders on the node it does target');
};

subtest 'the file name is one cron will actually read' => sub {
    plan tests => 5;

    for my $scope (qw(cluster node)) {
        my $name = ProxmodCron::Render::filename($scope);
        # A file in /etc/cron.d whose name contains a '.' is ignored, silently
        # and permanently. It is the single easiest way to ship a package whose
        # jobs never run and whose logs say nothing at all.
        unlike($name, qr/\./, "the $scope file name contains no dot");
        like($name, qr/\Aproxmod-cron-/, "and names this package, for $scope");
    }

    my $err = eval { ProxmodCron::Render::filename('nonsense'); 1 } ? undef : $@;
    like($err, qr/unknown scope 'nonsense'/, 'an unknown scope is refused, not guessed');
};

subtest 'summary shows the grid the same command cron was given' => sub {
    plan tests => 10;

    my $store = {
        jobs => {
            'good' => {
                type => 'command',
                schedule => '30 2 * * *',
                track => 0,
                command => ['/usr/local/bin/report', '--label', 'monthly report'],
                nodes => ['pve1'],
            },
            'not-here' => job(track => 0, nodes => ['pve9']),
            'broken-schedule' => job(track => 0, schedule => '99 * * * *'),
            'missing-plugin' => { type => 'gone-away', schedule => '0 5 * * *' },
        },
    };

    my $rows = ProxmodCron::Render::summary('cluster', $store, 'pve1');
    my %by_id = map { $_->{id} => $_ } @$rows;

    is(scalar(@$rows), 4, 'every job gets a row, including the ones that do not render here');

    # The command the UI shows and the command cron runs come out of the same
    # function. Anything else and the grid eventually starts describing a job
    # that no longer exists in that form.
    my ($line) = grep { /\A30 2/ } split(/\n/, render('cluster', $store, 'pve1'));
    like($line, qr/\Q$by_id{good}{command}\E\z/,
        'the summary command is the tail of the rendered line, character for character');

    is($by_id{good}{renders}, 1, 'a job targeting this node is marked as rendering');
    is($by_id{'not-here'}{renders}, 0, 'and one that does not, is not');
    ok($by_id{good}{next_run} > time(), 'a valid schedule gets a next run time');

    is($by_id{'broken-schedule'}{next_run}, undef, 'an invalid one does not');
    like($by_id{'broken-schedule'}{schedule_error}, qr/minute field/,
        'it gets the parser message instead, naming the field');

    like($by_id{'missing-plugin'}{unavailable}, qr/not registered/,
        'a job whose plugin is missing says why it has no command');
    ok(!exists $by_id{'missing-plugin'}{command},
        'and is given no command to display');

    is($by_id{good}{user}, 'root', 'the crontab user comes through for the grid too');
};
