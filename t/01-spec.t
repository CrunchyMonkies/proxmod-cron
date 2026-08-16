#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use FindBin;
use lib "$FindBin::Bin/../perl", "$FindBin::Bin/lib";

use POSIX qw(strftime);

use ProxmodCron::Spec;

# The cron spec parser and next-run calculation.
#
# ProxmodCron::Spec is pure — no filesystem, no PVE, no prefix tree — so this
# file loads it directly. Every next-run assertion is made in a FIXED timezone,
# because "the next run of 30 2 * * *" is a different answer in every one of
# them, and a test that used the machine's would pass in Europe and fail in CI.
#
# Europe/Berlin specifically: it has both DST transitions in the year the
# fixtures use, and cron's behaviour across those transitions is the part of
# this module most likely to be wrong.

BEGIN {
    $ENV{TZ} = 'Europe/Berlin';
    POSIX::tzset();
}

# Local wall-clock time, formatted with its UTC offset, so an assertion says
# which side of a DST transition it landed on rather than comparing two epoch
# numbers neither of which a reader can check.
sub at {
    my ($t) = @_;
    return 'never' if !defined $t;
    return strftime('%Y-%m-%d %H:%M %z', localtime($t));
}

# A local time -> epoch, resolved by search rather than by mktime, because
# mktime's answer for a time that happens twice (or not at all) is
# implementation-defined and this file is about exactly those times.
sub epoch {
    my ($want) = @_;

    # 2023-12-01T00:00:00Z. Before every fixture in this file *in local time* —
    # starting at the fixtures' own new year would put 2024-01-01 00:00 Berlin
    # an hour behind the search and it would never be found.
    my $t = 1_701_388_800;
    my $end = $t + 5 * 366 * 24 * 3600;

    while ($t < $end) {
        return $t if strftime('%Y-%m-%d %H:%M', localtime($t)) eq $want;
        $t += 60;
    }

    die "no epoch second matches local time '$want'\n";
}

plan tests => 9;

# ---------------------------------------------------------------------------

subtest 'the five fields, and what each accepts' => sub {
    my @ok = (
        ['*/15 * * * *', 'a step on a star'],
        ['0 0 * * *', 'plain values'],
        ['0,15,30,45 * * * *', 'a list'],
        ['0 9-17 * * *', 'a range'],
        ['0 9-17/2 * * *', 'a step on a range'],
        ['5/10 * * * *', 'a bare value with a step means "from here on"'],
        ['0 0 * jan,jul *', 'month names'],
        ['0 0 * * mon-fri', 'day names'],
        ['0 0 * * SUN', 'day names are case-insensitive'],
        ['  0 0 * * *  ', 'surrounding whitespace'],
        ["0\t0 * * *", 'a tab between fields'],
    );

    my @bad = (
        ['', 'no schedule given'],
        [undef, 'no schedule given'],
        ['* * * *', 'has 5 fields, got 4'],
        ['* * * * * *', 'has 5 fields, got 6'],
        ['60 * * * *', 'out of range in the minute field'],
        ['* 24 * * *', 'out of range in the hour field'],
        ['* * 0 * *', 'out of range in the day of month field'],
        ['* * * 13 *', 'out of range in the month field'],
        ['* * * * 8', 'out of range in the day of week field'],
        ['*/0 * * * *', 'step must be a positive number'],
        ['*/ * * * *', 'empty step'],
        ['10-5 * * * *', 'runs backwards'],
        ['1,,2 * * * *', 'empty entry'],
        ['banana * * * *', "'banana' is not valid"],
        ['* * * * mon-banana', "'banana' is not valid"],
        ['@nonsense', "unknown schedule nickname"],
    );

    plan tests => 2 * @ok + 2 * @bad;

    for my $row (@ok) {
        my ($spec, $why) = @$row;
        ok(eval { ProxmodCron::Spec::parse($spec); 1 }, "parses $why") or diag("$@");
        my ($valid) = ProxmodCron::Spec::validate($spec);
        ok($valid, "validate() agrees about $why");
    }

    for my $row (@bad) {
        my ($spec, $want) = @$row;
        my $label = defined($spec) ? "'$spec'" : 'undef';

        eval { ProxmodCron::Spec::parse($spec); 1 };
        like("$@", qr/\Q$want\E/, "$label is rejected, saying so");

        # validate() is the form the API and the CLI use, and it must report
        # the same reason rather than a generic "invalid schedule" — the
        # message ends up in the job editor under the field.
        my ($valid, $msg) = ProxmodCron::Spec::validate($spec);
        ok(!$valid && $msg =~ /\Q$want\E/, "validate() reports it too: " . ($msg // ''));
    }
};

subtest 'a step expands to the values cron would use' => sub {
    plan tests => 5;

    my $sorted = sub {
        my ($spec, $field) = @_;
        my $parsed = ProxmodCron::Spec::parse($spec);
        return [sort { $a <=> $b } keys %{ $parsed->{fields}[$field]{set} }];
    };

    is_deeply($sorted->('0,15,30,45 * * * *', 0), [0, 15, 30, 45], 'a list');
    is_deeply($sorted->('*/20 * * * *', 0), [0, 20, 40], 'a step on a star');
    is_deeply($sorted->('5/10 * * * *', 0), [5, 15, 25, 35, 45, 55],
        'a bare value with a step runs to the end of the field');
    is_deeply($sorted->('0 9-17/4 * * *', 1), [9, 13, 17], 'a step on a range');
    is_deeply($sorted->('0 0 * * 7', 4), [0], '7 is folded to 0, which is what localtime returns');
};

subtest 'the nicknames cron itself understands' => sub {
    my %same_as = (
        '@yearly' => '0 0 1 1 *',
        '@annually' => '0 0 1 1 *',
        '@monthly' => '0 0 1 * *',
        '@weekly' => '0 0 * * 0',
        '@daily' => '0 0 * * *',
        '@midnight' => '0 0 * * *',
        '@hourly' => '0 * * * *',
    );

    plan tests => scalar(keys %same_as) + 4;

    my $from = epoch('2024-06-15 12:00');

    for my $nick (sort keys %same_as) {
        is(at(ProxmodCron::Spec::next_run($nick, $from)),
            at(ProxmodCron::Spec::next_run($same_as{$nick}, $from)),
            "$nick is exactly '$same_as{$nick}'");
    }

    # @reboot has no schedule at all, and every caller has to cope with that
    # rather than render an empty next-run cell as an error.
    my $reboot = ProxmodCron::Spec::parse('@reboot');
    ok($reboot->{reboot}, '@reboot parses, and says it is one');
    is(ProxmodCron::Spec::next_run('@reboot', $from), undef, '@reboot has no next run');
    is_deeply(ProxmodCron::Spec::next_runs('@reboot', 3, $from), [],
        'and no preview to show either');

    is_deeply(ProxmodCron::Spec::nicknames(),
        [sort keys %{ { %same_as, '@reboot' => 1 } }],
        'nicknames() lists exactly what parse() accepts');
};

subtest 'next_run lands on the next matching minute, never the current one' => sub {
    plan tests => 4;

    # Called at 02:30 exactly, "30 2 * * *" means tomorrow. Returning now would
    # make the grid say a job is due when it has just run, and would make
    # next_runs() return the same second three times.
    my $now = epoch('2024-06-15 02:30');
    is(at(ProxmodCron::Spec::next_run('30 2 * * *', $now)), '2024-06-16 02:30 +0200',
        'a schedule matching the current minute means the next one');

    is(at(ProxmodCron::Spec::next_run('30 2 * * *', $now - 60)), '2024-06-15 02:30 +0200',
        'a minute earlier, it means today');

    # Not a minute boundary: the answer must not be seconds past the minute.
    is(at(ProxmodCron::Spec::next_run('* * * * *', $now + 17)), '2024-06-15 02:31 +0200',
        'a start time mid-minute still lands on the next minute boundary');

    is_deeply(
        [map { at($_) } @{ ProxmodCron::Spec::next_runs('0 */6 * * *', 3, $now) }],
        ['2024-06-15 06:00 +0200', '2024-06-15 12:00 +0200', '2024-06-15 18:00 +0200'],
        'next_runs walks forward without repeating itself');
};

subtest 'the two day fields OR together only when both are restricted' => sub {
    plan tests => 4;

    # Vixie cron's rule, and it surprises people: "30 2 13 * 5" is the 13th AND
    # every Friday, not Friday the 13th. Getting this backwards would silently
    # stop a job from running on most of the days its author intended.
    my $from = epoch('2024-09-01 00:00');

    is(at(ProxmodCron::Spec::next_run('30 2 13 * 5', $from)), '2024-09-06 02:30 +0200',
        'both restricted: the first Friday comes before the 13th');

    is(at(ProxmodCron::Spec::next_run('30 2 13 * *', $from)), '2024-09-13 02:30 +0200',
        'only the day of month restricted: Fridays have no say');

    is(at(ProxmodCron::Spec::next_run('30 2 * * 5', $from)), '2024-09-06 02:30 +0200',
        'only the day of week restricted: the 13th has no say');

    is(at(ProxmodCron::Spec::next_run('30 2 * * *', $from)), '2024-09-01 02:30 +0200',
        'neither restricted: every day');
};

subtest 'month ends and leap years' => sub {
    plan tests => 4;

    is(at(ProxmodCron::Spec::next_run('0 0 31 * *', epoch('2024-01-31 12:00'))),
        '2024-03-31 00:00 +0100',
        'the 31st skips February entirely');

    is(at(ProxmodCron::Spec::next_run('0 0 29 2 *', epoch('2024-01-01 00:00'))),
        '2024-02-29 00:00 +0100',
        '29 February exists in a leap year');

    is(at(ProxmodCron::Spec::next_run('0 0 29 2 *', epoch('2024-03-01 00:00'))),
        '2028-02-29 00:00 +0100',
        'and the next one is four years away, which is inside the search window');

    # A schedule that can be written and can never fire. Returning undef rather
    # than looping is what keeps this out of a pvedaemon worker that never
    # returns.
    is(ProxmodCron::Spec::next_run('0 0 30 2 *', epoch('2024-01-01 00:00')), undef,
        '30 February never happens, and the search gives up instead of spinning');
};

subtest 'daylight saving — spring forward' => sub {
    plan tests => 3;

    # 2024-03-31, Berlin: 02:00 CET becomes 03:00 CEST. Local times 02:00-02:59
    # do not exist that day.
    my $from = epoch('2024-03-30 12:00');

    # Debian cron would run this immediately after the jump, at 03:00. This
    # module predicts the calendar instead and reports the next day — the
    # divergence is documented on next_run and is deliberate: this function
    # feeds a column, it does not decide when anything runs.
    is(at(ProxmodCron::Spec::next_run('30 2 * * *', $from)), '2024-04-01 02:30 +0200',
        'a 02:30 job skips the day its 02:30 never happens');

    is(at(ProxmodCron::Spec::next_run('30 1 * * *', $from)), '2024-03-31 01:30 +0100',
        'the hour before still happens, in winter time');

    is(at(ProxmodCron::Spec::next_run('30 3 * * *', $from)), '2024-03-31 03:30 +0200',
        'and the hour after happens in summer time, half an hour after the jump');
};

subtest 'daylight saving — fall back' => sub {
    plan tests => 4;

    # 2024-10-27, Berlin: 03:00 CEST becomes 02:00 CET, so 02:30 happens twice,
    # an hour apart in real time.
    my $from = epoch('2024-10-26 12:00');

    my $first = ProxmodCron::Spec::next_run('30 2 * * *', $from);
    is(at($first), '2024-10-27 02:30 +0200',
        'the first 02:30 is the summer-time one');

    # 02:30 comes round twice, and this reports both: a distinct epoch second
    # with the same wall clock, an hour later in real time. Debian cron runs the
    # job once and skips the repeat, so the preview shows one occurrence cron
    # will not perform — the documented divergence on next_run, asserted here so
    # it stays a known limit rather than becoming a surprise.
    my $second = ProxmodCron::Spec::next_run('30 2 * * *', $first);
    is(at($second), '2024-10-27 02:30 +0100',
        'the repeated 02:30 is reported too, in winter time');

    is($second - $first, 3600,
        'an hour apart in real time, which is what makes them two answers and not one');

    is(at(ProxmodCron::Spec::next_run('30 2 * * *', $second)), '2024-10-28 02:30 +0100',
        'and then the following day — the walk never stalls on the repeated hour');
};

subtest 'next_run accepts an already-parsed schedule' => sub {
    plan tests => 2;

    # next_runs() parses once and loops, so the parsed form has to be accepted
    # where a string is. If it were not, the preview would re-parse per entry
    # and a malformed spec would die three times over.
    my $parsed = ProxmodCron::Spec::parse('0 4 * * *');
    my $from = epoch('2024-06-15 12:00');

    is(ProxmodCron::Spec::next_run($parsed, $from),
        ProxmodCron::Spec::next_run('0 4 * * *', $from),
        'a parsed schedule gives the same answer as its string');

    is(scalar @{ ProxmodCron::Spec::next_runs('0 4 * * *', 5, $from) }, 5,
        'next_runs returns as many as it was asked for');
};
