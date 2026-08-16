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

use File::Path ();

use ProxmodCron::Config;    # rewrites $Registry::TYPES_DIR into the prefix tree
use ProxmodCron::JobType;
use ProxmodCron::Registry;
use ProxmodCron::Render;

# The job type registry: what may become a job type, what happens to a plugin
# that will not load, and what the rest of the package is told about either.
#
# Note what this file deliberately does NOT `use`: ProxmodCron::JobType::Command.
# The first subtest asserts that load_plugins() is what puts the built-in in the
# registry, and that assertion is only worth anything in a process where nothing
# else loaded the module first. Every later subtest re-registers it by hand after
# resetting, because a reset registry plus a module already in %INC is a state
# only a test can produce.
#
# The property this file exists to protect is in the last subtest: a job whose
# plugin is missing renders as a disabled comment naming the type. Not dropped —
# an administrator must still see that the job is defined — and never executed
# with a guessed command, because the guess would run as root.

plan tests => 10;

# Fixture plugin modules are written to disk and loaded by load_plugins the way
# a real one would be, rather than declared inline: the manifest -> require ->
# self-register path is most of what this module does, and an inline package
# skips all of it.
my $LIB = "$ROOT/lib";
File::Path::make_path($LIB);
unshift @INC, $LIB;

my $SERIAL = 0;

sub write_module {
    my ($package, $body) = @_;

    my $rel = $package;
    $rel =~ s{::}{/}g;

    my $path = "$LIB/$rel.pm";
    my $dir = $path;
    $dir =~ s{/[^/]+\z}{};
    File::Path::make_path($dir);

    open(my $fh, '>', $path) or die "cannot write $path: $!\n";
    print {$fh} "package $package;\nuse strict;\nuse warnings;\n$body\n1;\n";
    close($fh);

    return $package;
}

# A plugin exactly as docs/extension-api.md describes one.
sub write_plugin {
    my ($package, $type, %opts) = @_;

    my $privs = $opts{privs} || '';
    my $props = defined($opts{properties}) ? $opts{properties} : '{ vmid => { type => "integer" } }';

    return write_module($package, <<"PLUGIN");
use base qw(ProxmodCron::JobType);
use ProxmodCron::Registry;
sub type { '$type' }
sub title { '$type plugin' }
sub properties { return $props }
sub build_command { return ['/bin/true'] }
$privs
ProxmodCron::Registry->register(__PACKAGE__);
PLUGIN
}

sub manifest_dir {
    my (%files) = @_;

    $SERIAL++;
    my $dir = "$ROOT/types-$SERIAL";
    File::Path::make_path($dir);

    for my $name (sort keys %files) {
        open(my $fh, '>', "$dir/$name") or die "cannot write $dir/$name: $!\n";
        print {$fh} $files{$name};
        close($fh);
    }

    return $dir;
}

sub fresh {
    ProxmodCronTest::reset_registry();
    ProxmodCron::Registry::register('ProxmodCron::JobType::Command');
    return;
}

# Types declared inline, for the register() refusals only — none of these is a
# plugin anyone would write, which is the point of asserting they are refused.
{
    package TestType::BadId;
    our @ISA = ('ProxmodCron::JobType');
    sub type { 'Not A Valid Id' }
}
{
    package TestType::Impostor;
    our @ISA = ('ProxmodCron::JobType');
    sub type { 'command' }
}
{
    package TestType::Outsider;
    sub type { 'outsider' }
}
{
    package TestType::Exploding;
    our @ISA = ('ProxmodCron::JobType');
    sub type { 'exploding' }
    sub build_command { return ['/bin/true'] }
    sub required_privs { die "this plugin is broken\n" }
}
{
    package TestType::Confused;
    our @ISA = ('ProxmodCron::JobType');
    sub type { 'confused' }
    sub build_command { return ['/bin/true'] }
    sub required_privs { return '/vms/101' }
}
{
    package TestType::Rude;
    our @ISA = ('ProxmodCron::JobType');
    sub type { 'rude' }
    sub build_command { return $_[1]->{argv} }
}

# ---------------------------------------------------------------------------

subtest 'the built-in arrives through the plugin path, not around it' => sub {
    plan tests => 6;

    is_deeply(ProxmodCron::Registry::types(), [],
        'the registry starts empty, so what follows is caused by load_plugins');

    my @errors = ProxmodCron::Registry::load_plugins(dir => manifest_dir());
    is_deeply(\@errors, [], 'loading with no plugin manifests reports nothing');

    is(ProxmodCron::Registry::lookup('command'), 'ProxmodCron::JobType::Command',
        'the built-in command type is registered');
    is_deeply(ProxmodCron::Registry::types(), ['command'],
        'and it is the only type until a plugin says otherwise');

    # The built-in going through require -> self-register, the same path a third
    # party's plugin takes, is what keeps that path working. If it were special
    # cased into %TYPES the first broken plugin would be the one to discover it.
    ok(exists $INC{'ProxmodCron/JobType/Command.pm'},
        'the module was require()d, not assumed');

    is_deeply(ProxmodCron::Registry::privs_for('command', {}), [],
        'and it declares no privileges, which is what makes it not delegable');
};

subtest 'register accepts a plugin and refuses everything else' => sub {
    plan tests => 11;

    fresh();

    my $plugin = write_plugin('TestPlugin::Register', 'register-me');
    require TestPlugin::Register;   # registers itself at load time

    is(ProxmodCron::Registry::lookup('register-me'), $plugin,
        'a plugin that registers itself is found by its type id');

    is(ProxmodCron::Registry->lookup('register-me'), $plugin,
        'lookup works as a method too, because plugin authors will write it both ways');
    is(ProxmodCron::Registry::lookup('nothing-like-this'), undef,
        'an unregistered type is undef, not an exception');
    is(ProxmodCron::Registry::lookup(undef), undef, 'and so is an undefined one');

    is(ProxmodCron::Registry::register($plugin), 'register-me',
        're-registering the same class is a no-op that returns the type id');
    is(ProxmodCron::Registry->register($plugin), 'register-me',
        'in either call form');

    my $err = eval { ProxmodCron::Registry::register('TestType::Outsider'); 1 } ? undef : $@;
    like($err, qr/is not a ProxmodCron::JobType/,
        'a class that is not a JobType subclass is refused');

    $err = eval { ProxmodCron::Registry::register('TestType::BadId'); 1 } ? undef : $@;
    like($err, qr/job type id 'Not A Valid Id' is not valid/,
        'and so is one whose type id is not an id');

    # Order-dependent behaviour is the thing to refuse here: if the second
    # registration silently won, the command a job renders would depend on which
    # extension's module happened to load first.
    $err = eval { ProxmodCron::Registry::register('TestType::Impostor'); 1 } ? undef : $@;
    like($err, qr/job type 'command' is already registered by ProxmodCron::JobType::Command/,
        'a second class claiming a taken id is refused, and the refusal names the incumbent');
    is(ProxmodCron::Registry::lookup('command'), 'ProxmodCron::JobType::Command',
        'the incumbent keeps the id');

    $err = eval { ProxmodCron::Registry::register(undef); 1 } ? undef : $@;
    like($err, qr/needs a class name/, 'register() with nothing to register says so');
};

subtest 'load_plugins reads manifests and ignores everything else in the directory' => sub {
    plan tests => 5;

    fresh();

    write_plugin('TestPlugin::Manifest', 'from-manifest');

    my $dir = manifest_dir(
        'from-manifest.json' => '{"type":"from-manifest","module":"TestPlugin::Manifest"}',
        # readdir hands back tainted names that become open() paths [PVE-F-041],
        # so the filter is a strict pattern rather than a suffix test. These three
        # are what that pattern is for.
        'notes.txt' => 'not a manifest',
        'Bad-Name.json' => '{"type":"x","module":"TestPlugin::Manifest"}',
        '.hidden.json' => '{"type":"x","module":"TestPlugin::Manifest"}',
    );

    my @errors = ProxmodCron::Registry::load_plugins(dir => $dir);
    is_deeply(\@errors, [], 'a directory of one good manifest and three non-manifests is clean');

    is(ProxmodCron::Registry::lookup('from-manifest'), 'TestPlugin::Manifest',
        'the manifest named a module, the module registered a type');
    is_deeply(ProxmodCron::Registry::types(), ['command', 'from-manifest'],
        'and nothing else was picked up');

    fresh();
    @errors = ProxmodCron::Registry::load_plugins(dir => "$ROOT/no-such-directory");
    is_deeply(\@errors, [],
        'a missing types.d is not an error: a host with no plugins is the normal case');
    is_deeply(ProxmodCron::Registry::types(), ['command'],
        'and the built-in still loaded, because it is loaded before the scan');
};

subtest 'a plugin that will not load is reported, never fatal' => sub {
    plan tests => 8;

    fresh();

    write_module('TestPlugin::NotAJobType', 'sub hello { 1 }');
    write_module('TestPlugin::Silent', <<'SILENT');
use base qw(ProxmodCron::JobType);
sub type { 'silent' }
sub build_command { return ['/bin/true'] }
SILENT
    write_plugin('TestPlugin::Survivor', 'survivor');

    my $dir = manifest_dir(
        'a-not-json.json' => 'this is not json at all {',
        'b-no-module.json' => '{"type":"b"}',
        'c-bad-module.json' => '{"type":"c","module":"Foo; system(q{rm -rf /})"}',
        'd-missing.json' => '{"type":"d","module":"TestPlugin::DoesNotExist"}',
        'e-not-a-type.json' => '{"type":"e","module":"TestPlugin::NotAJobType"}',
        'f-silent.json' => '{"type":"f","module":"TestPlugin::Silent"}',
        'g-survivor.json' => '{"type":"g","module":"TestPlugin::Survivor"}',
    );

    my @errors = ProxmodCron::Registry::load_plugins(dir => $dir);

    is(scalar(@errors), 6, 'six broken manifests, six errors, and no exception');

    like($errors[0], qr{a-not-json\.json does not name a module},
        'a manifest that is not JSON is reported by path');
    like($errors[1], qr{b-no-module\.json does not name a module},
        'and so is one with no module key');
    # The module name off disk is interpolated into require(), so it is untainted
    # by matching a module-name pattern and rebuilding. Anything else is not a
    # module name we failed to load, it is a string we refuse to treat as one.
    like($errors[2], qr{c-bad-module\.json does not name a module},
        'a module name that is not a module name is refused before require sees it');
    like($errors[3], qr{d-missing\.json: cannot load TestPlugin::DoesNotExist},
        'a module that is not installed is reported by name');
    like($errors[4], qr{e-not-a-type\.json: TestPlugin::NotAJobType loaded but did not register a job type},
        'a module that is not a plugin at all is told apart from one that is broken');
    like($errors[5], qr{f-silent\.json: TestPlugin::Silent did not register itself},
        'and a plugin that forgot its register() call is told what it forgot');

    # The reason none of the above is fatal: one bad plugin must not take the
    # host's cron with it.
    is(ProxmodCron::Registry::lookup('survivor'), 'TestPlugin::Survivor',
        'the good plugin in the same directory registered anyway');
};

subtest 'load_plugins is idempotent, and a rescan tells the same story twice' => sub {
    plan tests => 6;

    fresh();

    write_plugin('TestPlugin::First', 'first-plugin');
    write_plugin('TestPlugin::Second', 'second-plugin');

    my $dir = manifest_dir(
        'first.json' => '{"type":"first-plugin","module":"TestPlugin::First"}',
    );

    ProxmodCron::Registry::load_plugins(dir => $dir);
    ok(ProxmodCron::Registry::lookup('first-plugin'), 'the first scan registered the plugin');

    open(my $fh, '>', "$dir/second.json") or die $!;
    print {$fh} '{"type":"second-plugin","module":"TestPlugin::Second"}';
    close($fh);

    # The daemon calls this once; proxmod-cron-sync calls it every minute. The
    # second caller must not pay for a directory scan it does not need.
    my @errors = ProxmodCron::Registry::load_plugins(dir => $dir);
    is_deeply(\@errors, [], 'a repeat call is quiet');
    is(ProxmodCron::Registry::lookup('second-plugin'), undef,
        'and does not rescan, which is what makes it cheap');

    @errors = ProxmodCron::Registry::load_plugins(dir => $dir, force => 1);
    is_deeply(\@errors, [], 'force rescans without complaining about the already-loaded plugin');
    is(ProxmodCron::Registry::lookup('second-plugin'), 'TestPlugin::Second',
        'and picks up the new manifest');

    # A broken plugin that is broken in a way that leaves the module loaded must
    # keep being reported. Reporting it once and then going quiet would mean
    # `proxmod-cronctl doctor` calls the host healthy by asking a second time.
    write_module('TestPlugin::StillSilent', <<'SILENT');
use base qw(ProxmodCron::JobType);
sub type { 'still-silent' }
sub build_command { return ['/bin/true'] }
SILENT

    my $broken = manifest_dir(
        'still-silent.json' => '{"type":"still-silent","module":"TestPlugin::StillSilent"}',
    );

    my @first = ProxmodCron::Registry::load_plugins(dir => $broken, force => 1);
    my @again = ProxmodCron::Registry::load_plugins(dir => $broken, force => 1);
    is_deeply(\@again, \@first, 'the same unregistered plugin is reported on every rescan');
};

subtest 'the catalogue tells the editor enough to build a form' => sub {
    plan tests => 9;

    fresh();

    # `vmid // 0` is not decoration: catalogue() asks every plugin for its
    # required_privs with an EMPTY config, because at that point there is no job.
    # A plugin author who does not expect that is the case two assertions below.
    write_plugin('TestPlugin::Catalogue', 'acme-backup',
        properties => '{ vmid => { type => "integer", description => "which guest" } }',
        privs => 'sub required_privs { my ($c, $cfg) = @_; my $id = $cfg->{vmid} // 0; return [["/vms/$id", ["VM.Backup"]]] }',
    );
    require TestPlugin::Catalogue;

    my $catalogue = ProxmodCron::Registry::catalogue();

    is_deeply([map { $_->{type} } @$catalogue], ['acme-backup', 'command'],
        'every registered type, sorted, so the combo has a stable order');

    my ($acme) = grep { $_->{type} eq 'acme-backup' } @$catalogue;
    my ($command) = grep { $_->{type} eq 'command' } @$catalogue;

    is($acme->{title}, 'acme-backup plugin', 'the plugin supplies its own title');
    is_deeply($acme->{properties}, { vmid => { type => 'integer', description => 'which guest' } },
        'and its property schema, which is what the form is built from');
    is($acme->{run_as}, 'root', 'the crontab user is the plugin\'s, not the caller\'s');

    # The editor filters the type combo for a delegated user with this flag. It
    # is advisory — the server refuses a command job on the delegated tree
    # regardless — but a combo offering a type that cannot be created is a
    # support ticket waiting to happen.
    is($acme->{delegable}, 1, 'a type declaring required_privs is offered to a delegated user');
    is($command->{delegable}, 0, 'the command type never is');
    is($command->{iconCls}, 'fa fa-terminal', 'and the icon comes from the plugin too');

    # One careless plugin must not empty every other plugin's editor, so the
    # delegable probe falls back to the restrictive answer rather than
    # propagating. This is the types endpoint: it is called to draw a form.
    ProxmodCron::Registry::register('TestType::Exploding');
    my $survived = eval { ProxmodCron::Registry::catalogue() };
    my ($exploding) = grep { $_->{type} eq 'exploding' } @{ $survived || [] };
    ok($exploding, 'a plugin that dies when asked does not take the catalogue with it');
    is($exploding->{delegable}, 0, 'it is simply listed as not delegable');
};

subtest 'validate checks a job against its plugin schema' => sub {
    plan tests => 22;

    fresh();

    write_plugin('TestPlugin::Schema', 'schema-test', properties => <<'PROPS');
{
    target   => { type => 'string', maxLength => 8, minLength => 2 },
    count    => { type => 'integer', minimum => 1, maximum => 10 },
    ratio    => { type => 'number', optional => 1 },
    full     => { type => 'boolean', optional => 1, default => 0 },
    mode     => { type => 'string', optional => 1, enum => ['fast', 'slow'] },
    name     => { type => 'string', optional => 1, pattern => '\A[a-z]+\z' },
    hosts    => { type => 'array', optional => 1, items => { type => 'string', maxLength => 4 } },
}
PROPS
    require TestPlugin::Schema;

    my %base = (target => 'pbs', count => 3);

    is_deeply(ProxmodCron::Registry::validate('nope', {}),
        ["unknown job type 'nope'"],
        'an unknown type is one clear problem, not a schema walk over nothing');
    is_deeply(ProxmodCron::Registry::validate(undef, {}),
        ["unknown job type ''"],
        'and so is no type at all');

    is_deeply(ProxmodCron::Registry::validate('schema-test', {%base}), [],
        'the minimum valid config passes');
    is_deeply(ProxmodCron::Registry->validate('schema-test', {%base}), [],
        'as a method too');

    # The keys every job has are ProxmodCron::Config's business, not the
    # plugin's, and a plugin must not have to list them to avoid "unknown
    # property" on every job it ever validates.
    is_deeply(ProxmodCron::Registry::validate('schema-test', {
        %base, type => 'schema-test', origin => 'user', owner => 'acme',
        enabled => 1, schedule => '@daily', user => 'root', comment => 'hi',
        nodes => ['pve1'], track => 1, keep_output => 0,
    }), [], 'the common job keys are never reported as unknown properties');

    # A typo in a property name would otherwise be dropped silently and the job
    # would run with a default nobody chose.
    is_deeply(ProxmodCron::Registry::validate('schema-test', {%base, targt => 'pbs'}),
        ["unknown property 'targt' for job type 'schema-test'"],
        'a misspelled property is refused rather than ignored');

    is_deeply(ProxmodCron::Registry::validate('schema-test', {count => 3}),
        ["missing required property 'target'"],
        'a required property with no default must be present');
    is_deeply(ProxmodCron::Registry::validate('schema-test', {%base, full => undef}), [],
        'a property with a default is not required');
    is_deeply(ProxmodCron::Registry::validate('schema-test', {%base, ratio => undef}), [],
        'nor is an optional one');

    my @bad = (
        [{count => 'three'}, qr/'count' must be a integer/, 'a non-numeric integer'],
        [{count => '3.5'}, qr/'count' must be a integer/, 'a fractional integer'],
        [{count => 0}, qr/'count' is below the minimum 1/, 'below the minimum'],
        [{count => 99}, qr/'count' is above the maximum 10/, 'above the maximum'],
        [{ratio => 'x'}, qr/'ratio' must be a number/, 'a non-numeric number'],
        [{full => 'yes'}, qr/'full' must be a boolean/, 'a boolean that is not 0 or 1'],
        [{target => 'p'}, qr/'target' is shorter than 2/, 'a string under minLength'],
        [{target => 'far too long'}, qr/'target' is longer than 8/, 'a string over maxLength'],
        [{name => 'Bad Name'}, qr/'name' does not match the required format/, 'a string failing its pattern'],
        [{mode => 'medium'}, qr/'mode' must be one of: fast, slow/, 'a value outside the enum'],
        [{hosts => 'pve1'}, qr/'hosts' must be a list/, 'a scalar where a list belongs'],
        [{hosts => ['toolong']}, qr/'hosts\[0\]' is longer than 4/, 'a bad list element, reported by index'],
        [{target => ['pbs']}, qr/'target' must be a single value/, 'a list where a scalar belongs'],
    );

    for my $case (@bad) {
        my ($delta, $re, $what) = @$case;
        my $errors = ProxmodCron::Registry::validate('schema-test', {%base, %$delta});
        like(join('; ', @$errors), $re, "refuses $what");
    }
};

subtest 'privs_for is restrictive when it cannot be sure' => sub {
    plan tests => 6;

    fresh();

    write_plugin('TestPlugin::Privs', 'privs-test',
        privs => 'sub required_privs { my ($c, $cfg) = @_; return [["/vms/$cfg->{vmid}", ["VM.Backup"]]] }',
    );
    require TestPlugin::Privs;

    ProxmodCron::Registry::register('TestType::Exploding');
    ProxmodCron::Registry::register('TestType::Confused');

    is_deeply(ProxmodCron::Registry::privs_for('privs-test', {vmid => 101}),
        [['/vms/101', ['VM.Backup']]],
        'a delegable plugin names the object its job is about');
    is_deeply(ProxmodCron::Registry->privs_for('privs-test', {vmid => 101}),
        [['/vms/101', ['VM.Backup']]], 'as a method too');

    # Every one of the following returns the empty list, which the API layer
    # reads as "not delegable". That direction is the whole point: a job whose
    # plugin is missing or broken must not become MORE manageable than one whose
    # plugin works.
    is_deeply(ProxmodCron::Registry::privs_for('command', {}), [],
        'the built-in declares nothing, so only Sys.Modify can manage it');
    is_deeply(ProxmodCron::Registry::privs_for('never-installed', {}), [],
        'an unregistered type is not delegable');
    is_deeply(ProxmodCron::Registry::privs_for('exploding', {}), [],
        'a plugin whose required_privs dies is not delegable');
    is_deeply(ProxmodCron::Registry::privs_for('confused', {}), [],
        'nor is one that returns something other than a list of pairs');
};

subtest 'build_command refuses to produce a command it cannot stand behind' => sub {
    plan tests => 7;

    fresh();
    ProxmodCron::Registry::register('TestType::Rude');

    is_deeply(ProxmodCron::Registry::build_command('command', {command => ['/bin/echo', 'hi']}),
        ['/bin/echo', 'hi'], 'the built-in returns its argv');
    is_deeply(ProxmodCron::Registry->build_command('command', {command => ['/bin/true']}),
        ['/bin/true'], 'as a method too');

    my $err = eval { ProxmodCron::Registry::build_command('gone', {}); 1 } ? undef : $@;
    like($err, qr/job type 'gone' is not registered/,
        'a missing plugin dies naming the type, so the renderer can say which one');

    $err = eval { ProxmodCron::Registry::build_command('rude', {argv => []}); 1 } ? undef : $@;
    like($err, qr/did not return a command/, 'an empty argv is not a command');

    $err = eval { ProxmodCron::Registry::build_command('rude', {argv => ['/bin/x', undef]}); 1 } ? undef : $@;
    like($err, qr/undefined argument/, 'an undefined element is refused');

    # A newline ends the crontab line and a NUL ends the string. Either one means
    # cron runs something shorter than what the plugin asked for, silently — so
    # the job is refused rather than truncated.
    $err = eval { ProxmodCron::Registry::build_command('rude', {argv => ["/bin/x\nMAILTO=x"]}); 1 } ? undef : $@;
    like($err, qr/newline or NUL/, 'a newline cannot survive a crontab line, so it is refused');

    $err = eval { ProxmodCron::Registry::build_command('rude', {argv => ["/bin/x\0y"]}); 1 } ? undef : $@;
    like($err, qr/newline or NUL/, 'and neither can a NUL');
};

subtest 'a missing plugin renders as a disabled comment, never as a guess' => sub {
    plan tests => 9;

    fresh();

    my $store = {
        mailto => '',
        jobs => {
            'good-job' => {
                type => 'command',
                schedule => '30 2 * * *',
                command => ['/usr/sbin/fstrim', '-a'],
                track => 0,
            },
            'orphan-job' => {
                type => 'acme-backup',
                schedule => '0 3 * * *',
                comment => 'the plugin for this is not installed',
                track => 0,
            },
        },
    };

    my @lines = ProxmodCron::Render::render_job(
        ProxmodCron::Config::effective('node', $store, 'orphan-job'));

    like($lines[0], qr/^# job: orphan-job \(acme-backup\)/,
        'the job keeps its header, so it is still visible in the file');
    like($lines[1], qr/^# UNAVAILABLE: job type 'acme-backup' is not registered/,
        'and gains one naming the type that is missing');
    is_deeply([grep { /\S/ && !/^#/ } @lines], [],
        'and produces no executable line at all');

    my $text = ProxmodCron::Render::render('node', $store, 'pve1');

    like($text, qr/^30 2 \* \* \*\t/m,
        'the job whose plugin exists still renders');
    like($text, qr/^# UNAVAILABLE: /m, 'the one whose plugin does not is commented');
    unlike($text, qr/^0 3 \* \* \*/m, 'and never reaches cron');

    # The job is still counted. Dropping it from the header would make the file
    # agree with itself while disagreeing with the store, which is the version of
    # this bug that is hardest to notice.
    like($text, qr/Jobs: 2/, 'both jobs are counted in the banner');

    my $rows = ProxmodCron::Render::summary('node', $store, 'pve1');
    my ($row) = grep { $_->{id} eq 'orphan-job' } @$rows;

    like($row->{unavailable}, qr/not registered/,
        'the grid is told why the row has no command');
    ok(!exists $row->{command},
        'and is given no command to show, rather than a plausible-looking one');
};
