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

use Fcntl ();
use Socket ();

use ProxmodCron::Config;
use ProxmodCron::Journal;

# The native journald protocol, in pure Perl.
#
# Two reasons this module exists rather than a call to `logger`: arbitrary
# indexed fields, which are what make `journalctl PROXMOD_CRON_JOB=…` an exact
# query instead of a grep, and no fork per entry, which is what makes
# line-by-line output capture affordable.
#
# Everything below is asserted against a real AF_UNIX SOCK_DGRAM socket in a
# temp directory. A mocked send() would prove the module builds a string; it
# would not prove the string is one journald would accept, and the wire format
# is the entire contract.

plan tests => 11;

# A socket of this test's own, rather than ProxmodCronTest::journal_sink, so the
# receiver can be closed and rebound underneath the module — which is what
# journald restarting looks like from here.
sub sink {
    my ($path) = @_;

    unlink($path);

    socket(my $sock, Socket::AF_UNIX(), Socket::SOCK_DGRAM(), 0)
        or die "cannot create a datagram socket: $!\n";
    bind($sock, Socket::pack_sockaddr_un($path)) or die "cannot bind $path: $!\n";

    my $flags = fcntl($sock, Fcntl::F_GETFL(), 0);
    fcntl($sock, Fcntl::F_SETFL(), $flags | Fcntl::O_NONBLOCK());

    $ProxmodCron::Journal::SOCKET_PATH = $path;
    ProxmodCron::Journal::reset();

    my $drain = sub {
        my @raw;
        while (1) {
            my $buf;
            last if !defined recv($sock, $buf, 256 * 1024, 0);
            last if !defined $buf || $buf eq '';
            push @raw, $buf;
        }
        return \@raw;
    };

    return ($sock, $drain);
}

sub parsed {
    my ($drain) = @_;
    return [map { ProxmodCronTest::_parse_journal_datagram($_) } @{ $drain->() }];
}

my $SOCK_PATH = ProxmodCron::Config::state_dir() . '/journal-test.sock';

# ---------------------------------------------------------------------------

subtest 'the two wire forms, byte for byte' => sub {
    plan tests => 7;

    # The simple form. Anything without a newline in it.
    is(ProxmodCron::Journal::_encode_field('MESSAGE', 'hello'), "MESSAGE=hello\n",
        'a plain value is KEY=value and a newline');
    is(ProxmodCron::Journal::_encode_field('PRIORITY', 6), "PRIORITY=6\n",
        'a number is stringified, not packed');
    is(ProxmodCron::Journal::_encode_field('MESSAGE', ''), "MESSAGE=\n",
        'an empty value is still a field');

    # The framed form. A value containing a newline cannot use KEY=value
    # unambiguously, so journald takes a length prefix instead: the key alone,
    # then 64 bits little-endian, then the raw bytes, then a newline.
    my $framed = ProxmodCron::Journal::_encode_field('MESSAGE', "two\nlines");
    is($framed, "MESSAGE\n" . pack('V V', 9, 0) . "two\nlines\n",
        'a value with a newline is length-framed');

    # The length is 64-bit, written as two 32-bit halves so the module does not
    # quietly require a 64-bit perl.
    my (undef, $header) = split(/\n/, $framed, 2);
    my ($lo, $hi) = unpack('V V', substr($framed, 8, 8));
    is($lo, 9, 'the low half is the byte count');
    is($hi, 0, 'and the high half is zero for anything of a sane size');

    # Bytes, not characters. journald counts bytes, and a wide string would go
    # out as latin-1 and come back as mojibake.
    my $wide = "caf\x{e9}\nsnack";
    utf8::upgrade($wide);
    my $encoded = ProxmodCron::Journal::_encode_field('MESSAGE', $wide);
    my ($elo) = unpack('V', substr($encoded, 8, 4));
    is($elo, 11, 'the framed length counts bytes, not characters');
};

subtest 'an entry goes out and comes back with every field intact' => sub {
    plan tests => 8;

    my ($sock, $drain) = sink($SOCK_PATH);

    ok(ProxmodCron::Journal::send_entry({
        MESSAGE => 'nightly-trim finished',
        MESSAGE_ID => $ProxmodCron::Journal::MESSAGE_ID{finish},
        PROXMOD_CRON_JOB => 'nightly-trim',
        PROXMOD_CRON_SCOPE => 'node',
        PROXMOD_CRON_RUN => '1739000000000-a3f10b2c',
        PROXMOD_CRON_EVENT => 'finish',
        PROXMOD_CRON_EXIT => 0,
        PROXMOD_CRON_DURATION_MS => 1200,
    }), 'send_entry returns true');

    my $entries = parsed($drain);
    is(scalar(@$entries), 1, 'one datagram arrived');

    my $entry = $entries->[0];

    is($entry->{MESSAGE}, 'nightly-trim finished', 'the message survived');
    is($entry->{PROXMOD_CRON_JOB}, 'nightly-trim',
        'and the field almost every query starts from');
    is($entry->{PROXMOD_CRON_EXIT}, '0',
        'an exit of zero is sent, not dropped as false — it is the success case');
    is($entry->{PROXMOD_CRON_DURATION_MS}, '1200', 'and the duration');

    # Set on every entry so `journalctl -t proxmod-cron` works even for someone
    # who does not know the field names.
    is($entry->{SYSLOG_IDENTIFIER}, 'proxmod-cron', 'the identifier is added');

    my $multi = ProxmodCron::Journal::send_entry({
        MESSAGE => "line one\nline two",
        PROXMOD_CRON_EVENT => 'output',
    });
    is(parsed($drain)->[0]{MESSAGE}, "line one\nline two",
        'and a multi-line message round-trips through the framed form');

    close($sock);
};

subtest 'a bad field cannot take the entry down with it' => sub {
    plan tests => 6;

    my ($sock, $drain) = sink($SOCK_PATH);

    ProxmodCron::Journal::send_entry({
        MESSAGE => 'still arrives',
        'lower_case' => 'no',
        'HAS SPACE' => 'no',
        '_TRUSTED' => 'no',
        PROXMOD_CRON_JOB => undef,
        PROXMOD_CRON_SCOPE => 'node',
    });

    my $entry = parsed($drain)->[0];

    # journald rejects the whole datagram if any field name is malformed, so a
    # single programming error would silently lose the message it was attached
    # to. Dropping the field is the lesser loss.
    ok($entry, 'the entry still arrived');
    is($entry->{MESSAGE}, 'still arrives', 'with its message');
    ok(!exists $entry->{lower_case}, 'a lowercase field name is dropped');
    ok(!exists $entry->{'HAS SPACE'}, 'and one with a space');

    # Underscore-prefixed names are journald's own trusted fields. It would strip
    # ours anyway; refusing here makes the mistake visible instead of puzzling.
    ok(!exists $entry->{_TRUSTED}, 'and a reserved underscore-prefixed one');

    # Absent, not empty: `journalctl PROXMOD_CRON_JOB=` must not match every
    # entry that happened not to have a job.
    ok(!exists $entry->{PROXMOD_CRON_JOB}, 'an undefined value is left out entirely');

    close($sock);
};

subtest 'a long message is truncated, in bytes, with a marker' => sub {
    plan tests => 5;

    my ($sock, $drain) = sink($SOCK_PATH);

    ProxmodCron::Journal::send_entry({ MESSAGE => 'x' x (64 * 1024) });

    my $message = parsed($drain)->[0]{MESSAGE};

    cmp_ok(length($message), '<=', $ProxmodCron::Journal::MAX_MESSAGE,
        'the message fits the cap');
    like($message, qr/\[truncated by proxmod-cron\]\z/,
        'and says it was cut rather than pretending to be complete');

    # The cap is what lets this module skip sd_journal_send's memfd/SCM_RIGHTS
    # large-payload path: every datagram stays comfortably inside the socket's
    # size limit, so there is never a second code path to get wrong.
    ok(length($message) < 64 * 1024, 'which keeps the datagram inside the socket limit');

    # Bytes again. A cap counted in characters would let a UTF-8 message exceed
    # the byte limit by up to a factor of four.
    my $wide = "\x{263a}" x (16 * 1024);
    utf8::upgrade($wide);
    ProxmodCron::Journal::send_entry({ MESSAGE => $wide });
    cmp_ok(length(parsed($drain)->[0]{MESSAGE}), '<=', $ProxmodCron::Journal::MAX_MESSAGE,
        'a wide-character message is capped by bytes, not characters');

    ProxmodCron::Journal::send_entry({ MESSAGE => 'short' });
    is(parsed($drain)->[0]{MESSAGE}, 'short', 'while a short message is untouched');

    close($sock);
};

subtest 'priority defaults to info and is otherwise passed through' => sub {
    plan tests => 5;

    my ($sock, $drain) = sink($SOCK_PATH);

    ProxmodCron::Journal::send_entry({ MESSAGE => 'ordinary' });
    is(parsed($drain)->[0]{PRIORITY}, '6', 'an entry with no priority is info');

    # The mapping itself lives in proxmod-cron-exec, which knows what a stream
    # and an exit status mean. This module only has to carry what it is given.
    ProxmodCron::Journal::send_entry({ MESSAGE => 'from stderr', PRIORITY => 4 });
    is(parsed($drain)->[0]{PRIORITY}, '4', 'and a given priority is sent as given');

    ProxmodCron::Journal::send_entry({ MESSAGE => 'it failed', PRIORITY => 3 });
    is(parsed($drain)->[0]{PRIORITY}, '3', 'including error');

    is(ProxmodCron::Journal::LOG_ERR, 3, 'the constants are the syslog numbers');
    is(ProxmodCron::Journal::LOG_INFO, 6, 'as journald expects them');

    close($sock);
};

subtest 'the message ids are fixed constants, one per event class' => sub {
    plan tests => 4;

    my %ids = %ProxmodCron::Journal::MESSAGE_ID;

    is_deeply([sort keys %ids], [qw(change finish output skipped start)],
        'there is one id per event class');

    my @bad = grep { $ids{$_} !~ /\A[0-9a-f]{32}\z/ } sort keys %ids;
    is_deeply(\@bad, [], 'each is 128 bits of lowercase hex, which is what journald matches on');

    my %seen;
    $seen{ $ids{$_} }++ for keys %ids;
    is(scalar(keys %seen), scalar(keys %ids), 'and they are distinct');

    # This is the point of them: `journalctl MESSAGE_ID=<finish>` returns run
    # completions and nothing else, with no guessing from message text. They must
    # never be regenerated — every historical record would stop matching.
    is($ids{finish}, '9c4d2e1f6a7b48c3b5d0e9f8a7c6b5d4',
        'and finish is pinned, because regenerating one orphans every record already written');
};

subtest 'the degradation ladder, in order, and it never fails the job' => sub {
    plan tests => 8;

    # Rung one is gone: no socket at the path at all.
    unlink($SOCK_PATH);
    $ProxmodCron::Journal::SOCKET_PATH = "$SOCK_PATH.nothing-here";
    ProxmodCron::Journal::reset();

    my @logged;
    my $logger_result = 1;

    # The logger rung is stubbed rather than run. Running it would fork
    # /usr/bin/logger into the host's own journal from a unit test, and would
    # make the result depend on whether the machine runs systemd — so what is
    # asserted here is the ladder's order and its refusal to fail, with
    # _send_logger's own contract checked separately below.
    no warnings 'redefine';
    local *ProxmodCron::Journal::_send_logger = sub {
        push @logged, [@_];
        return $logger_result;
    };

    ok(ProxmodCron::Journal::send_entry({ MESSAGE => 'no socket', PRIORITY => 4 }),
        'a missing socket still returns success');
    is(scalar(@logged), 1, 'and the entry went to logger instead');
    is($logged[0][1], 'no socket', 'with the message');
    is($logged[0][0], 4, 'and the priority, so the severity is not lost with the fields');

    # Rung two fails too.
    $logger_result = 0;
    my $captured = '';
    open(my $fh, '>', \$captured) or die "cannot open a scalar handle: $!\n";
    local $ProxmodCron::Journal::FALLBACK_FH = $fh;

    ok(ProxmodCron::Journal::send_entry({ MESSAGE => 'nothing works' }),
        'and with logger gone as well it still returns success');

    # The whole reason for the ladder: this module records that a backup ran. A
    # missing socket must not turn a working backup into a failed one.
    ok(ProxmodCron::Journal::send_entry({}), 'an empty entry is not an error either');
    ok(ProxmodCron::Journal::send_entry(undef), 'nor is nothing at all');

    close($fh);

    # Where cron's own mail handling picks it up — the last place a message can
    # go that a human might still read.
    is($captured, "proxmod-cron: nothing works\nproxmod-cron: \n",
        'the message reached stderr, tagged so it is identifiable');
};

subtest 'logger is called with a list, and refuses what it cannot send' => sub {
    plan tests => 3;

    # No fork in either of these: both refuse before building a command. The
    # value of asserting them is that the refusal is what keeps a job's own
    # output away from a shell — @cmd is a list precisely because $message is
    # arbitrary text a root command printed.
    is(ProxmodCron::Journal::_send_logger(6, ''), 0, 'an empty message is not worth a fork');
    is(ProxmodCron::Journal::_send_logger(6, undef), 0, 'and neither is no message');

    # A priority journald would reject would make logger fail anyway; catching it
    # here means the entry falls to stderr rather than vanishing.
    is(ProxmodCron::Journal::_send_logger('urgent', 'hello'), 0,
        'a priority that is not a syslog number is refused');
};

subtest 'the socket is reconnected when journald restarts underneath us' => sub {
    plan tests => 4;

    my ($sock, $drain) = sink($SOCK_PATH);

    ProxmodCron::Journal::send_entry({ MESSAGE => 'before' });
    is(parsed($drain)->[0]{MESSAGE}, 'before', 'the first entry arrives');

    # journald restarting: the socket we are connected to goes away and a new one
    # appears at the same path. The cached handle now points at nothing.
    close($sock);
    my ($sock2, $drain2) = sink($SOCK_PATH);

    ProxmodCron::Journal::send_entry({ MESSAGE => 'after' });

    my $entries = parsed($drain2);
    is(scalar(@$entries), 1, 'the next entry is not lost');
    is($entries->[0]{MESSAGE}, 'after', 'it reaches the new socket');

    # Caching the handle is what makes per-line output capture cheap; dropping it
    # on failure is what stops the cache from turning one restart into permanent
    # silence.
    ProxmodCron::Journal::send_entry({ MESSAGE => 'and again' });
    is(parsed($drain2)->[0]{MESSAGE}, 'and again', 'and so does the one after that');

    close($sock2);
};

subtest 'job_fields tags every entry about a job the same way' => sub {
    plan tests => 5;

    my $fields = ProxmodCron::Journal::job_fields({
        id => 'nightly-trim', scope => 'node', type => 'command', comment => 'ignored',
    });

    is_deeply($fields, {
        PROXMOD_CRON_JOB => 'nightly-trim',
        PROXMOD_CRON_SCOPE => 'node',
        PROXMOD_CRON_TYPE => 'command',
    }, 'the three fields every query needs, and nothing else');

    # A field the job does not have is absent rather than empty, for the same
    # reason an undefined value is dropped: an empty match would hit everything.
    is_deeply(ProxmodCron::Journal::job_fields({ id => 'x' }),
        { PROXMOD_CRON_JOB => 'x' }, 'a job with no scope yet gets no scope field');

    is_deeply(ProxmodCron::Journal::job_fields(undef), {}, 'and no job gets no fields');

    # This is §8.6's mechanism: management records and run records carry the same
    # PROXMOD_CRON_JOB, so one query interleaves "who changed it" with "how has
    # it run since".
    my ($sock, $drain) = sink($SOCK_PATH);

    my $job = { id => 'nightly-trim', scope => 'node', type => 'command' };
    ProxmodCron::Journal::send_entry({
        %{ ProxmodCron::Journal::job_fields($job) },
        MESSAGE => 'changed by root@pam', PROXMOD_CRON_EVENT => 'change',
    });
    ProxmodCron::Journal::send_entry({
        %{ ProxmodCron::Journal::job_fields($job) },
        MESSAGE => 'started', PROXMOD_CRON_EVENT => 'start',
    });

    my $entries = parsed($drain);
    is(scalar(@$entries), 2, 'both a change and a run record went out');
    is_deeply([map { $_->{PROXMOD_CRON_JOB} } @$entries], ['nightly-trim', 'nightly-trim'],
        'under one field, which is what makes them one timeline');

    close($sock);
};

subtest 'a receiver that stops reading is abandoned, not waited on forever' => sub {
    plan tests => 5;

    # The failure this guards against wedged the whole suite in CI and would
    # wedge a real cron job the same way: a datagram socket nobody is draining
    # fills up, and send() on it blocks with no timeout. journald stopped while
    # systemd still holds its socket looks exactly like this from here, and so
    # does any container, where a fresh network namespace caps the queue at ten
    # datagrams rather than the host's five hundred. A job blocked inside a log
    # write holds its run lock and never finishes — much worse than a lost line.
    my ($sock, $drain) = sink($SOCK_PATH);

    # Short, because the assertion is "it gave up", not "it gave up in exactly
    # two seconds", and the test should not spend the production timeout.
    local $ProxmodCron::Journal::SEND_TIMEOUT = 0.2;
    ProxmodCron::Journal::reset();

    my @logged;
    no warnings 'redefine';
    local *ProxmodCron::Journal::_send_logger = sub { push @logged, [@_]; return 1 };

    # Enough to overflow the shortest queue any of these environments imposes,
    # and never read back.
    my $start = time();
    ProxmodCron::Journal::send_entry({ MESSAGE => "filler $_" }) for 1 .. 40;
    my $elapsed = time() - $start;

    ok($elapsed < 10, "forty entries into a full socket took ${elapsed}s, not forever");

    # On a host with a long queue nothing overflows and the ladder is never
    # reached, which is also correct — so the claim is about what happens when
    # it *is* reached, not that it must be.
    my $received = scalar @{ $drain->() };
    ok($received + scalar(@logged) >= 40, 'and every entry either arrived or fell to the ladder');

  SKIP: {
        skip 'the queue never filled on this host', 3 if !@logged;

        ok(ProxmodCron::Journal::send_entry({ MESSAGE => 'after' }),
            'a send after the timeout still reports success');
        is(scalar(@logged), 41 - $received,
            'and goes straight down the ladder without paying the timeout again');

        # Reconnecting on the next entry would mean paying the timeout once per
        # line for the rest of the run. A receiver that was not draining a moment
        # ago will not be draining for the next line either.
        is($logged[-1][1], 'after', 'the abandoned socket is not retried');
    }

    close($sock);
    ProxmodCron::Journal::reset();
};
