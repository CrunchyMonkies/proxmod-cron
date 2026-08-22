package ProxmodCron::Spec;

use strict;
use warnings;

use POSIX qw(mktime);

# Cron schedule parsing and next-run calculation.
#
# This is our own parser rather than PVE::CalendarEvent because the two speak
# different languages: PVE's job scheduler uses systemd calendar syntax
# ("mon..fri *-*-* 02:30"), and this extension renders into real crontabs, which
# use Vixie cron's five-field syntax. Reusing PVE's would mean translating
# between them on every read and write, and the translation is not total.
#
# It is also one of the modules that must load with NO PVE modules present:
# proxmod-cron-sync calls it from cron, outside any daemon. Core Perl only.

our $VERSION = '202608.22.0';

# Nicknames cron itself understands. @reboot has no schedule at all, which is
# why next_run can return undef and every caller has to cope with that.
my $NICKNAMES = {
    '@yearly' => '0 0 1 1 *',
    '@annually' => '0 0 1 1 *',
    '@monthly' => '0 0 1 * *',
    '@weekly' => '0 0 * * 0',
    '@daily' => '0 0 * * *',
    '@midnight' => '0 0 * * *',
    '@hourly' => '0 * * * *',
    '@reboot' => undef,
};

my $MONTH_NAMES = {
    jan => 1, feb => 2, mar => 3, apr => 4, may => 5, jun => 6,
    jul => 7, aug => 8, sep => 9, oct => 10, nov => 11, dec => 12,
};

my $DOW_NAMES = {
    sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6,
};

# name, min, max, name map. Day-of-week allows 7 as a second spelling of Sunday,
# which is normalised away as soon as it is parsed.
my @FIELDS = (
    { name => 'minute', min => 0, max => 59 },
    { name => 'hour', min => 0, max => 23 },
    { name => 'day of month', min => 1, max => 31 },
    { name => 'month', min => 1, max => 12, names => $MONTH_NAMES },
    { name => 'day of week', min => 0, max => 7, names => $DOW_NAMES },
);

# Give up rather than spin. Four years covers every schedule that can ever
# match, including 29 February in a leap year reached from 1 March.
my $MAX_STEPS = 4 * 366 * 24 * 60;

=head2 parse($schedule)

Parse a schedule string into
C<< { reboot => 0|1, fields => [ {set=>{...}, restricted=>0|1}, ... ] } >>.

Dies with a message naming the offending field. The message is shown to the
user in the job editor, so it says what was wrong rather than just that
something was.

=cut

sub parse {
    my ($schedule) = @_;

    die "no schedule given\n" if !defined $schedule;

    my $trimmed = $schedule;
    $trimmed =~ s/\A\s+//;
    $trimmed =~ s/\s+\z//;

    die "no schedule given\n" if $trimmed eq '';

    if ($trimmed =~ /\A\@/) {
        my $nick = lc($trimmed);
        die "unknown schedule nickname '$trimmed'\n"
            if !exists $NICKNAMES->{$nick};

        return { reboot => 1, fields => undef } if !defined $NICKNAMES->{$nick};

        $trimmed = $NICKNAMES->{$nick};
    }

    my @parts = split(/\s+/, $trimmed);
    die "a cron schedule has 5 fields, got " . scalar(@parts) . "\n"
        if @parts != 5;

    my @fields;
    for my $i (0 .. 4) {
        push @fields, _parse_field($parts[$i], $FIELDS[$i]);
    }

    # 0 and 7 both mean Sunday. Fold before anyone compares against localtime's
    # wday, which only ever produces 0.
    my $dow = $fields[4];
    if (delete $dow->{set}->{7}) {
        $dow->{set}->{0} = 1;
    }

    return { reboot => 0, fields => \@fields };
}

sub _parse_field {
    my ($text, $spec) = @_;

    my $name = $spec->{name};
    my $set = {};

    # "restricted" is the whole reason day-of-month and day-of-week behave the
    # way they do below: cron treats a bare '*' as "no opinion", not as "every
    # value", and the two are only distinguishable here.
    my $restricted = ($text eq '*') ? 0 : 1;

    for my $item (split(/,/, $text, -1)) {
        die "empty entry in the $name field\n" if $item eq '';

        my ($range, $step) = split(m{/}, $item, 2);

        if (defined $step) {
            die "empty step in the $name field ('$item')\n" if $step eq '';
            die "step must be a positive number in the $name field ('$item')\n"
                if $step !~ /\A[0-9]+\z/ || $step == 0;
            $step = 0 + $step;
        } else {
            $step = 1;
        }

        my ($from, $to);

        if ($range eq '*') {
            ($from, $to) = ($spec->{min}, $spec->{max});
        } elsif ($range =~ m{\A(.+?)-(.+)\z}) {
            $from = _value($1, $spec);
            $to = _value($2, $spec);
        } else {
            $from = _value($range, $spec);
            # A bare value with a step means "from here to the end", which is
            # what cron does: 5/10 in the minute field is 5,15,25,35,45,55.
            $to = (defined $step && $step > 1) ? $spec->{max} : $from;
        }

        die "$name range runs backwards ('$item')\n" if $from > $to;

        for (my $v = $from; $v <= $to; $v += $step) {
            $set->{$v} = 1;
        }
    }

    die "the $name field matches nothing\n" if !%$set;

    return { set => $set, restricted => $restricted };
}

sub _value {
    my ($text, $spec) = @_;

    my $name = $spec->{name};
    my $value;

    if ($text =~ /\A[0-9]+\z/) {
        $value = 0 + $text;
    } elsif ($spec->{names} && exists $spec->{names}->{ lc($text) }) {
        $value = $spec->{names}->{ lc($text) };
    } else {
        die "'$text' is not valid in the $name field\n";
    }

    die "$value is out of range in the $name field"
        . " ($spec->{min}-$spec->{max})\n"
        if $value < $spec->{min} || $value > $spec->{max};

    return $value;
}

=head2 validate($schedule)

Returns C<(1, undef)> or C<(0, $message)>. For callers that want to report a
bad schedule rather than die on one — the API layer and C<proxmod-cronctl
validate> both do.

=cut

sub validate {
    my ($schedule) = @_;

    my $parsed = eval { parse($schedule) };
    return (0, _clean_error($@)) if !$parsed;

    return (1, undef);
}

sub _clean_error {
    my ($err) = @_;
    my $msg = defined($err) ? "$err" : 'invalid schedule';
    $msg =~ s/\s+\z//;
    $msg =~ s/\s+at\s+\S+\s+line\s+\d+\.?\z//;
    return $msg;
}

=head2 next_run($schedule, $from)

The next epoch second at or after C<$from + 1 minute> that C<$schedule>
matches, in B<local time> — because that is what cron uses, and a schedule that
means 02:30 has to keep meaning 02:30 after a DST change.

Returns undef for C<@reboot>, and undef if nothing matches within four years
(31 February, say, which is a valid thing to write and never happens).

B<Across a DST transition this predicts the calendar, not Debian cron.> The two
differ on exactly two days a year, and only for a schedule whose hour field is
restricted:

=over

=item *

B<Spring forward.> A 02:30 job on the day 02:30 does not exist: this reports the
next day. Debian cron runs it immediately after the jump, at 03:00.

=item *

B<Fall back.> A 02:30 job on the day 02:30 happens twice: this reports both, an
hour apart in real time. Debian cron runs it once and skips the repeat.

=back

That is a deliberate limit, not an oversight. This function feeds the grid's
"next run" column and the editor's preview; it does not decide when anything
runs, because C<cron> does. Emulating cron's transition heuristics here would
put a second, subtly different scheduler in the code path that renders the UI,
and the failure mode of getting it wrong is a loop in a C<pvedaemon> worker —
which is why C<_advance> exists at all. The column being an hour out on two days
a year is the cheaper error.

=cut

sub next_run {
    my ($schedule, $from) = @_;

    my $parsed = ref($schedule) eq 'HASH' ? $schedule : parse($schedule);
    return undef if $parsed->{reboot};

    $from = time() if !defined $from;

    # Align to the start of the next minute. Every real timezone is offset from
    # UTC by a whole number of minutes, so this lands on a local minute
    # boundary too.
    my $t = $from - ($from % 60) + 60;

    my ($minute, $hour, $dom, $month, $dow) = @{ $parsed->{fields} };

    my $steps = 0;
    while ($steps++ < $MAX_STEPS) {
        my @lt = localtime($t);
        my ($lmin, $lhour, $lmday, $lmon, $lyear, $lwday) = @lt[1 .. 6];

        if (!$month->{set}->{ $lmon + 1 }) {
            $t = _advance($t, mktime(0, 0, 0, 1, $lmon + 1, $lyear));
            next;
        }

        if (!_day_matches($dom, $dow, $lmday, $lwday)) {
            $t = _advance($t, mktime(0, 0, 0, $lmday + 1, $lmon, $lyear));
            next;
        }

        if (!$hour->{set}->{$lhour}) {
            $t = _advance($t, mktime(0, 0, $lhour + 1, $lmday, $lmon, $lyear));
            next;
        }

        if (!$minute->{set}->{$lmin}) {
            $t = _advance($t, $t + 60);
            next;
        }

        return $t;
    }

    return undef;
}

# Always move forward. mktime normalises out-of-range components for us, but
# around a DST transition it can hand back a time at or before where we started
# — and a loop that does not advance is a hung pvedaemon worker, which is a
# considerably worse bug than a schedule that fires a minute late.
sub _advance {
    my ($now, $candidate) = @_;

    return $now + 60 if !defined $candidate || $candidate <= $now;
    return $candidate;
}

# Vixie cron's rule, and it surprises people: when BOTH day fields are
# restricted the job runs when EITHER matches, not both. "30 2 13 * 5" is the
# 13th and every Friday, not Friday the 13th. When only one is restricted, only
# that one has a say.
sub _day_matches {
    my ($dom, $dow, $mday, $wday) = @_;

    my $dom_ok = $dom->{set}->{$mday} ? 1 : 0;
    my $dow_ok = $dow->{set}->{$wday} ? 1 : 0;

    return $dom_ok || $dow_ok if $dom->{restricted} && $dow->{restricted};
    return $dow_ok if $dow->{restricted};
    return $dom_ok if $dom->{restricted};
    return 1;
}

=head2 next_runs($schedule, $count, $from)

The next C<$count> run times, for the editor's live preview. Stops early rather
than padding if the schedule runs out.

=cut

sub next_runs {
    my ($schedule, $count, $from) = @_;

    $count = 3 if !defined $count;
    $from = time() if !defined $from;

    my $parsed = ref($schedule) eq 'HASH' ? $schedule : parse($schedule);
    return [] if $parsed->{reboot};

    my @out;
    my $t = $from;
    for (1 .. $count) {
        $t = next_run($parsed, $t);
        last if !defined $t;
        push @out, $t;
    }

    return \@out;
}

=head2 matches($schedule, $when)

Whether C<$schedule> matches the minute containing epoch second C<$when>. The
same three rules C<next_run> searches with, asked about one instant instead —
including Vixie's day-field rule, which is why both go through C<_day_matches>
rather than each having an opinion.

Always false for C<@reboot>: it matches no minute, it matches a boot.

=cut

sub matches {
    my ($schedule, $when) = @_;

    my $parsed = ref($schedule) eq 'HASH' ? $schedule : parse($schedule);
    return 0 if $parsed->{reboot};

    $when = time() if !defined $when;

    my ($minute, $hour, $dom, $month, $dow) = @{ $parsed->{fields} };

    my @lt = localtime($when);
    my ($lmin, $lhour, $lmday, $lmon, $lyear, $lwday) = @lt[1 .. 6];

    return 0 if !$month->{set}->{ $lmon + 1 };
    return 0 if !_day_matches($dom, $dow, $lmday, $lwday);
    return 0 if !$hour->{set}->{$lhour};
    return 0 if !$minute->{set}->{$lmin};

    return 1;
}

=head2 tick($schedule, $now)

The scheduled minute this run belongs to, as an epoch second: the most recent
minute at or before C<$now> that C<$schedule> matches, searched back at most
C<$TICK_LOOKBACK> minutes.

This is what makes a cluster-wide lease possible. Two nodes firing the same job
do so a fraction of a second apart at best, and the lease has to be a claim on
the same thing on both — so it is keyed by the time cron I<meant>, not by the
time either process happened to start. The lookback covers a node whose wrapper
was not scheduled until after the minute rolled over, which is the only way a
correct clock lands on the wrong minute.

Falls back to the current minute when nothing matches within the lookback — a
DST transition, where Debian cron and this parser disagree by design (see
C<next_run>), or C<@reboot>. Two nodes then derive different ticks and both may
run, which is the same thing that happens today and is why C<run_on: any>
refuses C<@reboot> outright.

=cut

our $TICK_LOOKBACK = 2;

sub tick {
    my ($schedule, $now) = @_;

    my $parsed = ref($schedule) eq 'HASH' ? $schedule : parse($schedule);

    $now = time() if !defined $now;

    # Every real timezone is a whole number of minutes from UTC, so truncating
    # the epoch second lands on a local minute boundary too.
    my $minute = $now - ($now % 60);

    return $minute if $parsed->{reboot};

    for my $back (0 .. $TICK_LOOKBACK) {
        my $candidate = $minute - $back * 60;
        return $candidate if matches($parsed, $candidate);
    }

    return $minute;
}

=head2 nicknames()

The nicknames this parser accepts, for the editor's preset list and for the
documentation to stay in step with the code.

=cut

sub nicknames {
    return [sort keys %$NICKNAMES];
}

1;
