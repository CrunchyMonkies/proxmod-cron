package ProxmodCron::Registry;

use strict;
use warnings;

# The job type plugin registry.
#
# Loads without PVE: proxmod-cron-sync looks types up and calls build_command()
# from cron. Validation here is therefore our own rather than
# PVE::JSONSchema's — the shapes we accept are a small subset, and depending on
# PVE would mean the renderer could not run.

our $VERSION = '0.1.0';

# Where plugin manifests live. One small JSON file per job type, naming the
# module to load:
#
#   /usr/share/proxmod-cron/types.d/acme-backup.json
#   { "type": "acme-backup", "module": "Acme::Backup::CronType" }
#
# This exists because proxmod-cron-sync runs from cron with no proxmod and no
# PVE loaded, and still has to call build_command(). It cannot ask proxmod's
# registry which extensions are present, so plugin authors declare the module
# in a file — the same shape as proxmod's own extensions.d, for the same reason.
#
# ProxmodCron::Config rewrites this when a test prefix is in effect.
our $TYPES_DIR = '/usr/share/proxmod-cron/types.d';

# Types this package ships itself.
my @BUILTIN = ('ProxmodCron::JobType::Command');

my %TYPES;
my $loaded = 0;

=head2 register($class)

Register a ProxmodCron::JobType subclass. Idempotent for the same class;
B<dies> if a different class claims a type id that is already taken, because
silently letting the second registration win would mean the rendered command
depends on module load order.

=cut

sub register {
    my ($self, $class) = @_;

    # Allow both ProxmodCron::Registry->register($c) and register($c).
    ($self, $class) = (__PACKAGE__, $self) if !defined $class;

    die "register() needs a class name\n" if !defined $class || $class eq '';
    die "$class is not a ProxmodCron::JobType\n"
        if !eval { $class->isa('ProxmodCron::JobType') };

    my $type = $class->type();

    die "job type id '$type' is not valid\n"
        if !defined $type || $type !~ /\A[a-z0-9][a-z0-9_-]{0,63}\z/;

    if (my $existing = $TYPES{$type}) {
        return $type if $existing eq $class;
        die "job type '$type' is already registered by $existing\n";
    }

    $TYPES{$type} = $class;

    return $type;
}

=head2 load_plugins(%opts)

Load the built-in types and every plugin declared under C<$TYPES_DIR>. Returns
the list of problems; an empty list means everything loaded.

Idempotent — the daemon calls it once at proxmod_register time and
proxmod-cron-sync calls it on every run, and neither should care which happened
first. Pass C<< force => 1 >> to rescan.

A plugin that fails to load is B<reported, not fatal>. Its jobs then render as
disabled comment lines naming the missing type (see ProxmodCron::Render), which
is the only honest outcome: we must not guess a command, and we must not
silently stop running everything else.

=cut

sub load_plugins {
    my (%opts) = @_;

    return () if $loaded && !$opts{force};
    $loaded = 1;

    my @errors;

    for my $class (@BUILTIN) {
        my $err = _load_class($class);
        push @errors, $err if defined $err;
    }

    my $dir = $opts{dir} || $TYPES_DIR;

    opendir(my $dh, $dir) or return @errors;

    my @names;
    while (defined(my $name = readdir($dh))) {
        # readdir results are tainted [PVE-F-041] and these become open() paths.
        my ($clean) = ($name =~ /\A([a-z0-9][a-z0-9_-]{0,63}\.json)\z/);
        push @names, $clean if defined $clean;
    }
    closedir($dh);

    for my $name (sort @names) {
        my $path = "$dir/$name";

        my $module = _module_from_manifest($path);
        if (!defined $module) {
            push @errors, "$path does not name a module";
            next;
        }

        my $err = _load_class($module);
        push @errors, "$path: $err" if defined $err;
    }

    return @errors;
}

sub _module_from_manifest {
    my ($path) = @_;

    open(my $fh, '<', $path) or return undef;
    binmode($fh);
    local $/;
    my $raw = <$fh>;
    close($fh);

    return undef if !defined $raw;

    require JSON::PP;
    my $data = eval { JSON::PP->new->utf8->relaxed->decode($raw) };
    return undef if !$data || ref($data) ne 'HASH';

    my $module = $data->{module};
    return undef if !defined $module;

    # Untaint by pattern and rebuild. `require` of a tainted string dies
    # outright under -T [PVE-F-042], and this string came off the filesystem.
    my ($clean) = ($module =~ /\A([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)\z/);

    return $clean;
}

sub _load_class {
    my ($class) = @_;

    # Already loaded B<and> registered: nothing to do. Both halves matter. "The
    # package exists" is not the same as "the type can be looked up" — a module
    # can be in %INC having failed to register — and treating the first as the
    # second would make a rescan report a plugin as fine when the previous scan
    # reported that it never registered. `proxmod-cronctl doctor` is the caller
    # that would then say the host is healthy because it asked twice.
    my $known = eval { $class->type() };
    return undef
        if defined($known) && defined($TYPES{$known}) && $TYPES{$known} eq $class;

    my $file = $class;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    my $ok = eval { require $file; 1 };
    return "cannot load $class: " . _clean_error($@) if !$ok;

    # A plugin registers itself when its module loads. One that does not is a
    # plugin that would never be found, so say so rather than leaving the
    # author to wonder why their type never appears.
    return "$class loaded but did not register a job type"
        if !eval { $class->isa('ProxmodCron::JobType') };

    my $type = eval { $class->type() };
    return "$class did not register itself with ProxmodCron::Registry"
        if !defined $type || !$TYPES{$type};

    return undef;
}

sub _clean_error {
    my ($err) = @_;
    my $msg = defined($err) ? "$err" : 'unknown error';
    $msg =~ s/\s+\z//;
    $msg =~ s/\n.*\z//s;
    return $msg;
}

=head2 lookup($type)

The class for a type id, or undef.

=cut

sub lookup {
    my ($self, $type) = @_;
    ($self, $type) = (__PACKAGE__, $self) if !defined $type;

    return undef if !defined $type;
    return $TYPES{$type};
}

=head2 types()

Every registered type id, sorted.

=cut

sub types {
    return [sort keys %TYPES];
}

=head2 catalogue()

What the API's `types` endpoint returns: enough for the editor to build a form
without knowing anything about the plugin.

=cut

sub catalogue {
    my @out;

    for my $type (sort keys %TYPES) {
        my $class = $TYPES{$type};

        push @out, {
            type => $type,
            title => scalar($class->title()),
            iconCls => scalar($class->icon_cls()),
            description => scalar($class->description()),
            properties => $class->properties(),
            run_as => scalar($class->run_as()),
            # The editor uses this to keep `command` out of the type combo for a
            # delegated user, matching what the server would enforce anyway.
            #
            # required_privs is called with an empty config, because there is no
            # job yet — so a plugin that reaches into $cfg without checking will
            # warn, and one that dies will die. It must not take the whole types
            # endpoint with it: one careless plugin would then empty every other
            # plugin's editor. eval, and fall back to the restrictive answer.
            delegable => _delegable($class),
        };
    }

    return \@out;
}

sub _delegable {
    my ($class) = @_;

    my $privs = eval { $class->required_privs({}) };
    return 0 if !$privs || ref($privs) ne 'ARRAY';

    return @$privs ? 1 : 0;
}

=head2 validate($type, $cfg)

Check a job's type-specific keys against the plugin's property schema. Returns
the list of problems; empty means valid.

Unknown keys are rejected rather than ignored: a typo in a property name would
otherwise be silently dropped and the job would run with a default the user did
not choose.

=cut

sub validate {
    my ($self, $type, $cfg) = @_;
    ($self, $type, $cfg) = (__PACKAGE__, $self, $type) if ref($type) eq 'HASH';

    my @errors;

    my $class = lookup($type);
    if (!$class) {
        return ["unknown job type '" . (defined($type) ? $type : '') . "'"];
    }

    my $props = $class->properties() || {};

    # Keys every job has, whatever its type. The type's own properties are
    # checked against the schema; these are checked by ProxmodCron::Config.
    my %common = map { $_ => 1 } qw(
        type origin owner enabled schedule user comment nodes track keep_output
    );

    for my $key (sort keys %$cfg) {
        next if $common{$key};
        push @errors, "unknown property '$key' for job type '$type'"
            if !exists $props->{$key};
    }

    for my $key (sort keys %$props) {
        my $spec = $props->{$key};
        my $value = $cfg->{$key};

        if (!defined $value) {
            push @errors, "missing required property '$key'"
                if !$spec->{optional} && !exists $spec->{default};
            next;
        }

        push @errors, _check_value($key, $value, $spec);
    }

    return [grep { defined } @errors];
}

sub _check_value {
    my ($key, $value, $spec) = @_;

    my $type = $spec->{type} || 'string';

    if ($type eq 'array') {
        return "'$key' must be a list" if ref($value) ne 'ARRAY';
        return "'$key' must not be empty" if !@$value && !$spec->{optional};

        my @errors;
        my $items = $spec->{items} || {};
        my $i = 0;
        for my $item (@$value) {
            push @errors, _check_value("$key\[$i]", $item, $items);
            $i++;
        }
        return grep { defined } @errors;
    }

    return "'$key' must be a single value" if ref($value);

    if ($type eq 'integer' || $type eq 'number') {
        my $pattern = $type eq 'integer' ? qr/\A-?[0-9]+\z/ : qr/\A-?[0-9]+(?:\.[0-9]+)?\z/;
        return "'$key' must be a $type" if $value !~ $pattern;
        return "'$key' is below the minimum $spec->{minimum}"
            if defined $spec->{minimum} && $value < $spec->{minimum};
        return "'$key' is above the maximum $spec->{maximum}"
            if defined $spec->{maximum} && $value > $spec->{maximum};
        return undef;
    }

    if ($type eq 'boolean') {
        return "'$key' must be a boolean" if $value !~ /\A(?:0|1|)\z/;
        return undef;
    }

    return "'$key' is longer than $spec->{maxLength} characters"
        if defined $spec->{maxLength} && length($value) > $spec->{maxLength};
    return "'$key' is shorter than $spec->{minLength} characters"
        if defined $spec->{minLength} && length($value) < $spec->{minLength};

    if (defined $spec->{pattern}) {
        my $re = $spec->{pattern};
        return "'$key' does not match the required format" if $value !~ /$re/;
    }

    if ($spec->{enum}) {
        my %ok = map { $_ => 1 } @{ $spec->{enum} };
        return "'$key' must be one of: " . join(', ', @{ $spec->{enum} })
            if !$ok{$value};
    }

    return undef;
}

=head2 privs_for($type, $cfg)

The ACL requirements for a job, or an empty list when the type is not delegable
or is not registered at all.

An unregistered type returning "not delegable" matters: a job whose plugin
failed to load must not become I<more> manageable than one whose plugin worked.

=cut

sub privs_for {
    my ($self, $type, $cfg) = @_;
    ($self, $type, $cfg) = (__PACKAGE__, $self, $type) if ref($type) eq 'HASH';

    my $class = lookup($type);
    return [] if !$class;

    my $privs = eval { $class->required_privs($cfg || {}) };
    return [] if !$privs || ref($privs) ne 'ARRAY';

    return $privs;
}

=head2 build_command($type, $cfg)

The argv for a job. Dies with a message naming the type when the plugin is
missing, so the renderer can turn that into a disabled, commented line rather
than guessing a command.

=cut

sub build_command {
    my ($self, $type, $cfg) = @_;
    ($self, $type, $cfg) = (__PACKAGE__, $self, $type) if ref($type) eq 'HASH';

    my $class = lookup($type);
    die "job type '" . (defined($type) ? $type : '') . "' is not registered\n"
        if !$class;

    my $argv = $class->build_command($cfg);

    die "job type '$type' did not return a command\n"
        if !$argv || ref($argv) ne 'ARRAY' || !@$argv;

    for my $arg (@$argv) {
        die "job type '$type' returned an undefined argument\n" if !defined $arg;
        # A NUL or a newline cannot survive a crontab line, and a command that
        # silently loses part of itself is worse than one that refuses to run.
        die "job type '$type' returned an argument containing a newline or NUL\n"
            if $arg =~ /[\0\n]/;
    }

    return $argv;
}

=head2 _reset()

Forget every registration. Tests only.

=cut

sub _reset { %TYPES = (); $loaded = 0; return }

1;
