package ProxmodCron::Inventory;

use strict;
use warnings;

use ProxmodCron::Config;
use ProxmodCron::Render;
use ProxmodCron::Spec;

# Read-only discovery of everything scheduled on this host.
#
# This is what makes the extension a cron *manager* rather than a view of its
# own rows: an administrator asking "what runs on this box at 03:00" gets an
# answer that includes the things we did not create.
#
# Nothing here writes. User crontabs, /etc/crontab and the run-parts directories
# belong to other packages and to the users themselves, and the property that
# makes this extension safe to install is that it only ever writes the two files
# it generates.

our $VERSION = '202608.17.0';

# run-parts schedules as Debian's stock /etc/crontab defines them. Reported as
# nominal because an administrator may have changed that file — the run-parts
# lines themselves are also listed from /etc/crontab, so the truth is visible
# either way.
my %RUN_PARTS = (
    'cron.hourly' => '17 * * * *',
    'cron.daily' => '25 6 * * *',
    'cron.weekly' => '47 6 * * 7',
    'cron.monthly' => '52 6 1 * *',
);

# What cron itself accepts as a file name in /etc/cron.d and what run-parts
# accepts in the cron.* directories. A file outside this is silently ignored by
# cron, which is a spectacularly quiet way for a backup to stop happening, so we
# list it and say so.
my $VALID_NAME = qr/\A([a-zA-Z0-9_-]+)\z/;

=head2 collect()

Every cron entry on the host, as a list of records:

C<< { source, path, line, user, schedule, command, next_run, owner, note } >>

C<owner> is C<proxmod-cron> for lines in the files we generate and in the anchor
we ship, and C<system> for everything else. Foreign entries are never editable
through the API.

=cut

sub collect {
    my @entries;

    push @entries, _system_crontab();
    push @entries, _cron_d();
    push @entries, _user_crontabs();
    push @entries, _run_parts();

    return \@entries;
}

sub _prefixed {
    my ($path) = @_;
    return ProxmodCron::Config::prefix() . $path;
}

sub _system_crontab {
    my $path = _prefixed('/etc/crontab');

    my $lines = _read_lines($path);
    return () if !$lines;

    my @out;
    my $lineno = 0;

    for my $line (@$lines) {
        $lineno++;
        next if !_is_job_line($line);

        my $entry = _parse_line($line, 1);
        next if !$entry;

        $entry->{source} = 'crontab';
        $entry->{path} = $path;
        $entry->{line} = $lineno;
        $entry->{owner} = 'system';

        push @out, _finish($entry);
    }

    return @out;
}

sub _cron_d {
    my $dir = ProxmodCron::Config::cron_d();

    my @out;

    for my $name (_list_dir($dir)) {
        my $path = "$dir/$name";
        next if !-f $path;

        my $anchor = ($name eq ProxmodCron::Render::anchor_filename()) ? 1 : 0;

        my $ours = ($anchor
            || $name eq ProxmodCron::Render::filename('cluster')
            || $name eq ProxmodCron::Render::filename('node')) ? 1 : 0;

        my $note;
        # Ours, and the only entry here that is not a job. Said plainly, because
        # a line running every minute with no schedule anyone chose is exactly
        # the kind of thing an administrator reasonably wants explained.
        $note = 'the proxmod-cron anchor: it renders the generated files and'
            . ' is not a scheduled job' if $anchor;
        $note = "cron ignores this file: the name contains a character cron does not accept"
            if $name !~ $VALID_NAME;

        my $lines = _read_lines($path);
        next if !$lines;

        my $lineno = 0;
        for my $line (@$lines) {
            $lineno++;
            next if !_is_job_line($line);

            my $entry = _parse_line($line, 1);
            next if !$entry;

            $entry->{source} = 'cron.d';
            $entry->{path} = $path;
            $entry->{line} = $lineno;
            $entry->{owner} = $ours ? 'proxmod-cron' : 'system';
            $entry->{note} = $note if defined $note;

            push @out, _finish($entry);
        }
    }

    return @out;
}

sub _user_crontabs {
    my $dir = _prefixed('/var/spool/cron/crontabs');

    my @out;

    for my $name (_list_dir($dir)) {
        my $path = "$dir/$name";
        next if !-f $path;

        # The file name is the user; a crontab file whose name is not a user
        # name is not something crond will run.
        my ($user) = ($name =~ /\A([a-z_][a-z0-9_-]{0,31})\z/);
        next if !defined $user;

        my $lines = _read_lines($path);
        next if !$lines;

        my $lineno = 0;
        for my $line (@$lines) {
            $lineno++;
            next if !_is_job_line($line);

            # No user column in a user crontab: the fifth field is already the
            # command.
            my $entry = _parse_line($line, 0);
            next if !$entry;

            $entry->{user} = $user;
            $entry->{source} = 'user';
            $entry->{path} = $path;
            $entry->{line} = $lineno;
            $entry->{owner} = 'system';

            push @out, _finish($entry);
        }
    }

    return @out;
}

sub _run_parts {
    my @out;

    for my $dirname (sort keys %RUN_PARTS) {
        my $dir = _prefixed("/etc/$dirname");

        for my $name (_list_dir($dir)) {
            my $path = "$dir/$name";
            next if !-f $path;

            my $entry = {
                source => 'run-parts',
                path => $path,
                line => 0,
                user => 'root',
                schedule => $RUN_PARTS{$dirname},
                command => $path,
                owner => 'system',
                nominal => 1,
            };

            $entry->{note} = 'run-parts ignores this file: the name contains'
                . ' a character it does not accept'
                if $name !~ $VALID_NAME;

            $entry->{note} = 'not executable, so run-parts will not run it'
                if !-x $path;

            push @out, _finish($entry);
        }
    }

    return @out;
}

# A line that defines a job, as opposed to a comment, a blank or an environment
# assignment. Environment lines are deliberately not reported: they are not
# scheduled work, and listing MAILTO as a cron entry would be noise.
sub _is_job_line {
    my ($line) = @_;

    return 0 if $line =~ /\A\s*\z/;
    return 0 if $line =~ /\A\s*#/;
    return 0 if $line =~ /\A\s*[A-Za-z_][A-Za-z0-9_]*\s*=/;

    return 1;
}

sub _parse_line {
    my ($line, $has_user) = @_;

    my $text = $line;
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;

    my ($schedule, $rest);

    if ($text =~ /\A(\@[a-zA-Z]+)\s+(.*)\z/) {
        ($schedule, $rest) = ($1, $2);
    } else {
        my @parts = split(/\s+/, $text, 6);
        return undef if @parts < 6;
        $schedule = join(' ', @parts[0 .. 4]);
        $rest = $parts[5];
    }

    my $user;
    if ($has_user) {
        return undef if !defined $rest;
        my @parts = split(/\s+/, $rest, 2);
        return undef if @parts < 2;
        ($user, $rest) = @parts;
    }

    return {
        schedule => $schedule,
        user => $user,
        command => $rest,
    };
}

sub _finish {
    my ($entry) = @_;

    # A '%' in a crontab command means "newline, rest is stdin". Showing the
    # escaped form would be a lie about what runs, so unescape for display and
    # cut at the first unescaped one, which is where the command actually ends.
    if (defined $entry->{command}) {
        my ($command) = split(/(?<!\\)%/, $entry->{command}, 2);
        $command = '' if !defined $command;
        $command =~ s/\\%/%/g;
        $entry->{command} = $command;
    }

    my ($ok, $why) = ProxmodCron::Spec::validate($entry->{schedule});
    if ($ok) {
        my $next = eval { ProxmodCron::Spec::next_run($entry->{schedule}) };
        $entry->{next_run} = $next if defined $next;
    } else {
        $entry->{schedule_error} = $why;
    }

    return $entry;
}

sub _read_lines {
    my ($path) = @_;

    # Bytes, never an :encoding layer: open() cannot open a tainted path with
    # one inside a daemon under -T, and every path here came off the filesystem.
    open(my $fh, '<', $path) or return undef;
    binmode($fh);
    my @lines = <$fh>;
    close($fh);

    chomp @lines;

    return \@lines;
}

# readdir results are tainted, and these names are concatenated into paths that
# get opened. Untaint by pattern and rebuild; anything that does not match is
# dropped rather than laundered.
sub _list_dir {
    my ($dir) = @_;

    opendir(my $dh, $dir) or return ();

    my @names;
    while (defined(my $name = readdir($dh))) {
        next if $name eq '.' || $name eq '..';

        my ($clean) = ($name =~ /\A([A-Za-z0-9][A-Za-z0-9._-]{0,254})\z/);
        next if !defined $clean;

        push @names, $clean;
    }

    closedir($dh);

    return sort @names;
}

1;
