#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Temp ();

use FindBin;
use lib "$FindBin::Bin/../perl", "$FindBin::Bin/lib";

# Every module compiles, plainly and under -T.
#
# The taint half is not a formality. pvedaemon and pveproxy run under -T, and
# the ways taint breaks a module are all load-time or first-call: `require` of a
# tainted string dies [PVE-F-042], readdir and glob results are tainted
# [PVE-F-041], and open() with an :encoding() layer refuses a tainted path
# outright [PVE-F-040]. A module that compiles under -T is not proof of
# correctness, but a module that does not is proof of a dead daemon.

my $perl_dir = "$FindBin::Bin/../perl";
my $lib_dir = "$FindBin::Bin/lib";

my @modules = _find_modules($perl_dir);

plan tests => 2 * scalar(@modules) + 3;

ok(scalar(@modules) >= 15, 'found the package modules to compile')
    or diag("only found: @modules");

for my $file (@modules) {
    my $rel = $file =~ s{^\Q$perl_dir\E/}{}r;

    _compiles([$perl_dir, $lib_dir], $file, "$rel compiles");
    _compiles([$perl_dir, $lib_dir], $file, "$rel compiles under -T", '-T');
}

# The PVE-free constraint, asserted rather than assumed.
#
# proxmod-cron-sync and proxmod-cron-exec are run by cron, outside any daemon,
# with no PVE modules installed on the far side of an upgrade that removed them.
# The modules they load must compile with only the package's own directory in
# @INC — no t/lib, so a PVE stub cannot quietly satisfy a dependency that would
# not exist in production.
my @pve_free = qw(
    ProxmodCron::Config ProxmodCron::Render ProxmodCron::Spec ProxmodCron::State
    ProxmodCron::Inventory ProxmodCron::Registry ProxmodCron::Journal
    ProxmodCron::Runs ProxmodCron::Sync ProxmodCron::Store ProxmodCron::Client
    ProxmodCron::JobType ProxmodCron::JobType::Command
);

my $out = _run([$perl_dir], ['-e', join('', map { "require $_; " } @pve_free) . 'print "ok"']);
is($out->{status}, 0, 'the exec-path modules load with no PVE at all')
    or diag($out->{stderr});

# And the other half of the same rule: the API2 layer is where PVE starts, so it
# must NOT load without it. If this passes with an empty @INC, something under
# ProxmodCron::API2 has been made PVE-free by accident and the boundary has
# moved without anyone deciding to move it.
my $api = _run([$perl_dir], ['-e', 'require ProxmodCron::API2::Common; print "ok"']);
isnt($api->{status}, 0, 'the API2 layer does not load without PVE');

sub _find_modules {
    my ($dir) = @_;

    my @found;
    my @stack = ($dir);

    while (my $d = shift @stack) {
        opendir(my $dh, $d) or die "cannot read $d: $!\n";
        for my $entry (sort readdir($dh)) {
            next if $entry =~ /\A\./;
            my $path = "$d/$entry";
            push(@stack, $path), next if -d $path;
            push @found, $path if $entry =~ /\.pm\z/;
        }
        closedir($dh);
    }

    return @found;
}

sub _run {
    my ($incs, $args) = @_;

    my @cmd = ($^X, (map { "-I$_" } @$incs), @$args);

    # List form, and the output captured through a temp file rather than
    # backticks: an interpolated command string would hand `-e 'require X;'` to
    # a shell, which is both wrong and the exact mistake this package refuses to
    # make in its own code.
    my $tmp = File::Temp->new(TEMPLATE => 'compile-XXXXXXXX', TMPDIR => 1);

    my $pid = fork();
    die "cannot fork: $!\n" if !defined $pid;

    if (!$pid) {
        open(STDOUT, '>&', $tmp) or exit 127;
        open(STDERR, '>&', $tmp) or exit 127;
        exec(@cmd) or exit 127;
    }

    waitpid($pid, 0);
    my $status = $?;

    return { status => $status, stderr => (slurp("$tmp") // '') };
}

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

sub _compiles {
    my ($incs, $file, $name, @flags) = @_;

    my $out = _run($incs, [@flags, '-c', $file]);

    ok($out->{status} == 0, $name) or diag($out->{stderr});

    return;
}
