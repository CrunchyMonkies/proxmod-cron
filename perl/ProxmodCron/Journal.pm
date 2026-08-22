package ProxmodCron::Journal;

use strict;
use warnings;

use POSIX ();
use Socket qw(AF_UNIX SOCK_DGRAM SOL_SOCKET SO_SNDTIMEO);

# Structured journald entries, in pure Perl.
#
# Why not something simpler:
#
#   logger -t proxmod-cron      sets the syslog identifier and nothing else. No
#   systemd-cat -t proxmod-cron per-job field means no indexed query, and
#                               reading history back becomes text-grepping.
#
#   logger --journald           does take arbitrary fields, but it is a process
#                               per entry. For line-by-line output capture from
#                               a job that prints thousands of lines, that is
#                               thousands of forks.
#
# So we speak the native protocol: a datagram to /run/systemd/journal/socket
# containing KEY=value lines. That is what sd_journal_send does, and it is a
# stable, documented interface.
#
# Core Perl only, deliberately. This module is loaded inside pvedaemon AND by
# proxmod-cron-exec from cron with no PVE in scope, and it must compile under -T
# for both.

our $VERSION = '202608.22.0';

# Overridable so the tests can point at a socket in a temp directory. The
# environment override exists because proxmod-cron-exec is exercised as a real
# subprocess — a package variable cannot be handed across a fork+exec, and
# testing the wrapper any other way would mean not testing the wrapper. Guarded
# exactly as ProxmodCron::Config guards its prefix: honoured only when the
# process is not root, so it can never redirect a production entry.
our $SOCKET_PATH = '/run/systemd/journal/socket';

if ($> != 0 && defined $ENV{PROXMOD_CRON_TEST_SOCKET}) {
    my ($clean) = ($ENV{PROXMOD_CRON_TEST_SOCKET} =~ m{\A([\w./@+-]{1,107})\z});
    $SOCKET_PATH = $clean if defined $clean;
}

# Where the last-resort fallback writes. Tests localise it to capture.
our $FALLBACK_FH;

# One message per entry, capped. This keeps every datagram well inside the
# socket's size limit, which is what lets us skip implementing the memfd /
# SCM_RIGHTS large-payload path that sd_journal_send falls back to. A cron job
# whose single output line exceeds 16 KiB has bigger problems.
our $MAX_MESSAGE = 16 * 1024;

our $IDENTIFIER = 'proxmod-cron';

# A datagram socket nobody is reading fills up, and then send() blocks — with no
# timeout, forever. journald stopped while systemd still holds its socket is
# exactly that shape, and so is any process whose receive queue is short: a fresh
# network namespace caps AF_UNIX datagrams at ten (`net.unix.max_dgram_qlen`),
# not the host's 512. A cron job wedged inside a log write would hold its run
# lock and never finish, which is a far worse failure than a lost log line. So
# the send is bounded, and a socket that times out is abandoned for the rest of
# the process — if journald is not draining now it will not be draining for the
# next line either, and the ladder below is there for exactly this.
our $SEND_TIMEOUT = 2;

# Fixed 128-bit ids, one per event class. This is what makes a query exact:
# `journalctl MESSAGE_ID=<FINISH>` returns run completions and nothing else,
# with no guessing from message text. They are constants — never regenerate
# them, or every historical record stops matching.
our %MESSAGE_ID = (
    start => '7b1c9a3e5d244f6e8a0b1c2d3e4f5a6b',
    output => '2f8e6d4c1b3a4e5f9c8d7b6a5f4e3d2c',
    finish => '9c4d2e1f6a7b48c3b5d0e9f8a7c6b5d4',
    skipped => '4e7a1b8c2d3f49a5b6c7d8e9f0a1b2c3',
    change => '1d5f3b7c9e2a4d6f8b0c1e3a5d7f9b2e',
);

use constant {
    LOG_ERR => 3,
    LOG_WARNING => 4,
    LOG_NOTICE => 5,
    LOG_INFO => 6,
    LOG_DEBUG => 7,
};

my $sock;
my $sock_failed = 0;

=head2 send($fields)

Submit one entry. C<$fields> is a hashref; C<MESSAGE> is expected, everything
else is passed through as a journal field.

B<Always returns true.> A logging failure must never become a job failure — the
whole point of this module is to record that a backup ran, and turning a working
backup into a failed one because a socket was missing would be a poor trade. The
degradation ladder is: native socket, then C<logger>, then stderr (where cron's
own mail handling picks it up).

=cut

sub send_entry {
    my ($fields) = @_;

    return 1 if !$fields || ref($fields) ne 'HASH';

    my %entry = %$fields;

    $entry{SYSLOG_IDENTIFIER} = $IDENTIFIER if !defined $entry{SYSLOG_IDENTIFIER};
    $entry{PRIORITY} = LOG_INFO if !defined $entry{PRIORITY};

    my $message = defined($entry{MESSAGE}) ? $entry{MESSAGE} : '';
    $message = _truncate($message);
    $entry{MESSAGE} = $message;

    my $payload = '';
    for my $key (sort keys %entry) {
        # A malformed field name would make journald reject the whole datagram,
        # taking the message with it. Skipping one bad field is better than
        # losing the entry, and it is a programming error either way.
        next if !_valid_field_name($key);
        next if !defined $entry{$key};
        $payload .= _encode_field($key, $entry{$key});
    }

    return 1 if $payload eq '';

    return 1 if _send_native($payload);

    return 1 if _send_logger($entry{PRIORITY}, $message);

    my $fh = $FALLBACK_FH || \*STDERR;
    print {$fh} "$IDENTIFIER: $message\n";

    return 1;
}

# Kept as an alias because `send` is a Perl builtin and calling a sub of that
# name needs an ampersand or parens everywhere. The explicit name is clearer at
# every call site anyway.
sub send { return send_entry(@_) }    ## no critic

sub _truncate {
    my ($value) = @_;

    return '' if !defined $value;

    # Work in bytes from here on: journald counts bytes, and a wide string
    # would be sent as latin-1 by send() and arrive as mojibake.
    my $bytes = $value;
    utf8::encode($bytes) if utf8::is_utf8($bytes);

    return $bytes if length($bytes) <= $MAX_MESSAGE;

    my $keep = $MAX_MESSAGE - 32;
    return substr($bytes, 0, $keep) . "\n[truncated by proxmod-cron]";
}

# Journal field names are uppercase alphanumerics and underscores. Names
# starting with an underscore are reserved for journald's own trusted fields —
# it would strip ours anyway, so refusing here makes the mistake visible.
sub _valid_field_name {
    my ($name) = @_;

    return 0 if !defined $name;
    return 0 if length($name) > 64;
    return $name =~ /\A[A-Z][A-Z0-9_]*\z/ ? 1 : 0;
}

# Two wire forms. A value with no newline is "KEY=value\n". A value containing a
# newline cannot use that form unambiguously, so it becomes "KEY\n", a 64-bit
# little-endian length, the raw bytes, and a newline.
sub _encode_field {
    my ($key, $value) = @_;

    my $bytes = defined($value) ? "$value" : '';
    utf8::encode($bytes) if utf8::is_utf8($bytes);

    return "$key=$bytes\n" if index($bytes, "\n") < 0;

    my $len = length($bytes);

    # Built from two 32-bit halves rather than pack('Q<') so this does not
    # depend on a 64-bit perl.
    my $header = pack('V V', $len % 4294967296, int($len / 4294967296));

    return $key . "\n" . $header . $bytes . "\n";
}

sub _socket {
    return undef if $sock_failed;
    return $sock if $sock;

    my $path = $SOCKET_PATH;

    # Untaint: this is a package constant or a test override, but it reaches
    # sockaddr_un inside a daemon running under -T either way.
    my ($clean) = ($path =~ m{\A([\w./@+-]{1,107})\z});
    if (!defined $clean) {
        $sock_failed = 1;
        return undef;
    }

    my $fh;
    if (!socket($fh, AF_UNIX, SOCK_DGRAM, 0)) {
        $sock_failed = 1;
        return undef;
    }

    my $addr = Socket::pack_sockaddr_un($clean);
    if (!connect($fh, $addr)) {
        close($fh);
        $sock_failed = 1;
        return undef;
    }

    # struct timeval, whose members are time_t and suseconds_t — 'l!' is the
    # native long both are on every platform this package runs on. A kernel that
    # refuses the option is not a reason to give up logging; it only means the
    # send is unbounded again, which is where we started.
    my $timeout = $SEND_TIMEOUT;
    $timeout = 0 if !defined $timeout || $timeout < 0;
    setsockopt($fh, SOL_SOCKET, SO_SNDTIMEO,
        pack('l!l!', int($timeout), int(($timeout - int($timeout)) * 1_000_000)));

    $sock = $fh;
    return $sock;
}

sub _send_native {
    my ($payload) = @_;

    my $fh = _socket();
    return 0 if !$fh;

    for my $attempt (1, 2) {
        my $sent = CORE::send($fh, $payload, 0);
        return 1 if defined $sent;

        # EAGAIN here is SO_SNDTIMEO expiring, which means the receiver's queue
        # stayed full for the whole timeout. Retrying would just spend the
        # timeout again, so stop using this socket entirely and let the caller
        # fall down the ladder for every remaining entry.
        my $err = $!;
        if ($err == POSIX::EAGAIN() || $err == POSIX::EWOULDBLOCK()) {
            close($fh);
            undef $sock;
            $sock_failed = 1;
            return 0;
        }

        # ENOBUFS means journald is momentarily behind rather than gone. One
        # retry is worth it; a loop here would block the job.
        last if $attempt == 2;

        # Anything else: drop the cached handle so the next entry reconnects,
        # in case journald was restarted underneath us.
        close($fh);
        undef $sock;
        $fh = _socket();
        return 0 if !$fh;
    }

    return 0;
}

sub _send_logger {
    my ($priority, $message) = @_;

    return 0 if !defined $message || $message eq '';

    my $prio = defined($priority) ? $priority : LOG_INFO;
    return 0 if $prio !~ /\A[0-7]\z/;

    # A list, never a string: $message is a job's own output and would be a root
    # command injection through a shell.
    my @cmd = ('/usr/bin/logger', '-t', $IDENTIFIER, '-p', "user.$prio", '--', $message);

    my $pid = fork();
    return 0 if !defined $pid;

    if ($pid == 0) {
        # No PATH search, no shell, and stdout/stderr closed so a failing logger
        # cannot pollute the job's own output.
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        { exec { $cmd[0] } @cmd; }
        POSIX::_exit(127);
    }

    waitpid($pid, 0);

    return ($? == 0) ? 1 : 0;
}

=head2 reset()

Forget the cached socket. For the tests, and for anything that changes
C<$SOCKET_PATH> after the first send.

=cut

sub reset {
    close($sock) if $sock;
    undef $sock;
    $sock_failed = 0;
    return;
}

=head2 job_fields($job)

The common field set for a job, so every caller tags entries the same way. A
field the job does not have is simply absent rather than empty, which keeps
`journalctl PROXMOD_CRON_TYPE=` from matching everything.

=cut

sub job_fields {
    my ($job) = @_;

    my $fields = {};
    return $fields if !$job;

    $fields->{PROXMOD_CRON_JOB} = $job->{id} if defined $job->{id};
    $fields->{PROXMOD_CRON_SCOPE} = $job->{scope} if defined $job->{scope};
    $fields->{PROXMOD_CRON_TYPE} = $job->{type} if defined $job->{type};

    return $fields;
}

1;
