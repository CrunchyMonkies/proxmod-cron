package ProxmodCron::API2::Common;

use strict;
use warnings;

use PVE::Exception qw(raise_perm_exc raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use ProxmodCron::Config;
use ProxmodCron::Lease;
use ProxmodCron::Registry;
use ProxmodCron::Spec;
use ProxmodCron::State;
use ProxmodCron::Store;

# The access-control model of §8, in one place.
#
# There are two halves to every answer:
#
#   the origin rule   — may ANYONE do this, through any surface?  (§2.1)
#   the privilege     — may THIS CALLER do it?                    (§8)
#
# The origin half lives in ProxmodCron::Store::capabilities. This module holds
# the privilege half and the AND of the two, and it is the only place either is
# combined. Both the flags returned to the UI and the enforcement in the write
# methods go through capabilities() and assert() below — so a row can never
# advertise an action that the write method would refuse, because there is no
# second implementation to drift from the first.
#
# This module DOES load PVE. It is reached only from inside pvedaemon/pveproxy;
# nothing under exec/ may use it.

our $VERSION = '202608.22.0';

my %ACTION_FLAG = (
    create => 'can_create',
    update => 'can_edit',
    delete => 'can_delete',
    toggle => 'can_toggle',
    run => 'can_run',
);

=head2 context(%args)

The request's authorization context: who is calling, and against which ACL path.
C<scope> is 'cluster' or 'node'; C<node> is required for the node scope.

=cut

sub context {
    my (%args) = @_;

    my $scope = $args{scope} || 'node';
    my $node = $args{node};

    die "the node scope needs a node\n" if $scope eq 'node' && !defined $node;

    my $rpcenv = PVE::RPCEnvironment::get();

    return {
        rpcenv => $rpcenv,
        user => $rpcenv->get_user(),
        scope => $scope,
        node => $node,
        # '/' for the cluster and '/nodes/{node}' for a node — both are paths
        # PVE's own check_path allowlist accepts. §8.1: there is no registration
        # hook for a custom ACL path, so there are no custom paths here.
        path => ($scope eq 'cluster') ? '/' : "/nodes/$node",
    };
}

=head2 may($ctx, $path, $privs)

One ACL check, in noerr form. Everything in this module that asks "may they?"
asks through here, so the answer never comes from a guess about roles.

=cut

sub may {
    my ($ctx, $path, $privs) = @_;

    $privs = [$privs] if !ref $privs;

    return $ctx->{rpcenv}->check($ctx->{user}, $path, $privs, 1) ? 1 : 0;
}

=head2 perms($ctx)

What this caller may do in this scope — the body of C<GET permissions>, and the
same values the write methods enforce with.

    { audit, modify, syslog, delegable_types }

=cut

sub perms {
    my ($ctx) = @_;

    return $ctx->{_perms} if $ctx->{_perms};

    ProxmodCron::Registry::load_plugins();

    my $perms = {
        scope => $ctx->{scope},
        audit => may($ctx, $ctx->{path}, ['Sys.Audit']),
        modify => may($ctx, $ctx->{path}, ['Sys.Modify']),
        # Gated separately from audit on purpose: run metadata is operational
        # status, run output is arbitrary text a root command printed. §8.2.
        syslog => may($ctx, $ctx->{path}, ['Sys.Syslog']),
    };

    # Which types this caller could create through the delegated tree. Computed
    # against an empty config, so it answers "is this type delegable to you at
    # all" rather than "for that particular object" — the editor uses it to fill
    # a combo, and the write path re-checks against the real config.
    my @delegable;
    for my $entry (@{ ProxmodCron::Registry::catalogue() }) {
        next if !$entry->{delegable};
        push @delegable, $entry->{type};
    }

    $perms->{delegable_types} = \@delegable;

    $ctx->{_perms} = $perms;

    return $perms;
}

=head2 delegation($ctx, $cfg)

Whether this caller satisfies the job's own C<required_privs>.

    { ok => 0|1, why => '...', privs => 'VM.Backup on /vms/101' }

B<An empty C<required_privs> means "not delegable", and is refused here.> That
is the structural rule from §8.3 and it is the first thing this sub does:
C<ProxmodCron::JobType::Command> declares no privileges because there is no ACL
path that honestly describes "runs anything as root", so a command job is
refused by the same line that refuses a plugin whose author forgot to declare
any — not by a check on the type name, which a new plugin would slip past.

=cut

sub delegation {
    my ($ctx, $cfg) = @_;

    my $type = $cfg && $cfg->{type};

    return { ok => 0, why => 'the job has no type' } if !defined $type;

    my $pairs = ProxmodCron::Registry::privs_for($type, $cfg);

    return {
        ok => 0,
        why => "job type '$type' is not delegable: managing one requires"
            . " Sys.Modify on $ctx->{path}",
    } if !$pairs || !@$pairs;

    my @needed;
    for my $pair (@$pairs) {
        my ($path, $privs) = @$pair;

        next if !defined $path;

        $privs = [$privs] if !ref $privs;

        push @needed, join(', ', @$privs) . " on $path";

        return {
            ok => 0,
            why => "requires " . join(', ', @$privs) . " on $path",
            privs => join('; ', @needed),
        } if !may($ctx, $path, $privs);
    }

    return { ok => 1, privs => join('; ', @needed) };
}

=head2 authorization($ctx, $job)

How this caller is authorized for this job: C<'modify'>, C<'delegated'>, or
undef. Sys.Modify on the scope root OR every declared privilege on every
declared path — §8.3.

=cut

sub authorization {
    my ($ctx, $job) = @_;

    return 'modify' if perms($ctx)->{modify};

    return 'delegated' if $job && delegation($ctx, $job)->{ok};

    return undef;
}

=head2 capabilities($ctx, $job, %opts)

The resolved flags for one job: the AND of the origin rule and this caller's
privileges. Every row returned by C<GET jobs> carries these, and every write
method asserts against the same values.

=cut

sub capabilities {
    my ($ctx, $job, %opts) = @_;

    my $origin = ProxmodCron::Store::capabilities($job || {}, %opts);
    my $auth = authorization($ctx, $job);
    my $may = $auth ? 1 : 0;

    return {
        %$origin,
        authorization => $auth,
        can_modify => $may,
        # Creation is not about an existing job, so the origin half has nothing
        # to say: a caller may create what they are authorized to create.
        can_create => $may,
        can_run => $may,
        can_toggle => ($origin->{can_toggle} && $may) ? 1 : 0,
        can_edit => ($origin->{can_edit} && $may) ? 1 : 0,
        can_delete => ($origin->{can_delete} && $may) ? 1 : 0,
    };
}

=head2 assert($ctx, $action, $job, %opts)

Authorize one mutation, or die 403 with a message that says which half refused.
Returns the capability hash on success.

The refusal is audited before it is raised. §8.6 records attempts, not only
successes: an attempt that was refused is the more interesting half of an
incident timeline.

=cut

sub assert {
    my ($ctx, $action, $job, %opts) = @_;

    my $flag = $ACTION_FLAG{$action} or die "unknown action '$action'\n";

    my $caps = capabilities($ctx, $job, %opts);

    return $caps if $caps->{$flag};

    my $id = $opts{id} || ($job && $job->{id}) || '-';

    # Which half said no. Saying "permission denied" when the real answer is
    # "this job belongs to an extension" sends the administrator to the ACL
    # editor to fix something an ACL cannot fix.
    my $why;
    if (!$caps->{can_modify}) {
        my $delegation = $job ? delegation($ctx, $job) : undef;

        $why = "$action requires Sys.Modify on $ctx->{path}";
        $why .= ", or " . $delegation->{why}
            if $delegation && $delegation->{why} && $delegation->{why} !~ /not delegable/;
    } elsif ($caps->{origin} eq 'extension' && !$caps->{orphaned}) {
        my $owner = $caps->{owner} || 'another extension';
        $why = "job '$id' is managed by $owner."
            . " You can enable or disable it here; to change or remove it, use that extension";
    } elsif ($caps->{origin} eq 'extension') {
        # An orphan, and the action was edit. This is the case an administrator
        # is most likely to be confused by — the extension that could explain
        # the job is gone — so the message has to name it and say what is left,
        # rather than falling through to a generic refusal that reads like a
        # bug in the grid.
        my $owner = $caps->{owner} || 'an extension';
        $why = "job '$id' was created by $owner, which is no longer installed."
            . " Its definition cannot be edited; you can enable, disable or remove it";
    } else {
        $why = "$action is not permitted on job '$id'";
    }

    audit($ctx, $action, $id, $job, outcome => 'refused', reason => $why);

    raise_perm_exc($why);
}

=head2 assert_output($ctx, $job)

Authorize reading a run's captured output — the one read in this extension that
is not gated on Sys.Audit.

Run metadata says a job ran at 02:30 and exited 1; that is operational status
and an auditor who can see the job should see whether it works. What the job
B<printed> is arbitrary text produced by a root command — a backup tool naming
shares, a script echoing a connection string, a failing command quoting the
argument that broke it. That is what Sys.Syslog exists to gate, and reading it
through our endpoint must not become a way around the privilege PVE would demand
for the same bytes at /nodes/{node}/journal.

The delegated carve-out is narrow and defensible: the caller already administers
the object the job is about, and it is their job's output.

=cut

sub assert_output {
    my ($ctx, $job) = @_;

    return 'syslog' if perms($ctx)->{syslog};

    return 'delegated' if $job && delegation($ctx, $job)->{ok};

    raise_perm_exc("reading job output requires Sys.Syslog on $ctx->{path}");
}

=head2 assert_read($ctx)

Sys.Audit on the scope, for the reads that have no per-row story to tell — the
inventory, the whole-journal view's metadata, the index.

=cut

sub assert_read {
    my ($ctx) = @_;

    return 1 if perms($ctx)->{audit};

    raise_perm_exc("this requires Sys.Audit on $ctx->{path}");
}

=head2 visible($ctx, $job, %opts)

Whether this caller may see a job — §8.4. Everything if they hold Sys.Audit on
the scope; otherwise only jobs whose own required_privs they satisfy. Filtering
rather than refusing, so a delegated user's grid shows their job instead of a
403.

C<< delegated => 1 >> drops the Sys.Audit shortcut: the delegated tree answers
the same question for everyone, so its response does not change shape depending
on who asked.

=cut

sub visible {
    my ($ctx, $job, %opts) = @_;

    return delegation($ctx, $job)->{ok} ? 1 : 0 if $opts{delegated};

    return 1 if perms($ctx)->{audit};

    # Sys.Modify without Sys.Audit is an odd role to build, but it is a legal
    # one, and someone who may create, edit and delete every job in the scope
    # gains nothing from being unable to see them. Without this, create_job
    # writes the job and then raises 403 reading it back — a mutation that
    # reports as a permission failure, which is the worst way to answer.
    return 1 if perms($ctx)->{modify};

    return delegation($ctx, $job)->{ok} ? 1 : 0;
}

=head2 job_view($ctx, $job, %opts)

One row as the API returns it: the job, its resolved capability flags, its next
run, and its last result from the §5.5 cache.

=cut

sub job_view {
    my ($ctx, $job, %opts) = @_;

    my $caps = capabilities($ctx, $job, %opts);

    my %row = (%$job, %$caps);

    $row{next_run} = ProxmodCron::Spec::next_run($job->{schedule});

    my ($ok, $why) = ProxmodCron::Spec::validate($job->{schedule});
    $row{schedule_error} = $why if !$ok;

    # The type may have been uninstalled under a job that is still scheduled.
    # Saying so is the point — the renderer has already turned it into a
    # disabled comment line, and the grid should not show it as healthy.
    $row{type_available} = ProxmodCron::Registry::lookup($job->{type}) ? 1 : 0;

    # Which node last claimed a scheduled run, for the jobs where that is a
    # question at all. Not gated on `status`: it is placement, not history —
    # available on every node from /etc/pve, and the same answer everywhere,
    # which is exactly what a per-node run record cannot be.
    if (($job->{run_on} || '') eq 'any') {
        my $holder = ProxmodCron::Lease::latest($job->{id});
        $row{last_holder} = $holder if $holder;
    }

    if ($opts{status}) {
        my $record = ProxmodCron::State::get($job->{scope}, $job->{id});

        # strip_output is the single implementation of "Sys.Audit sees status,
        # not output". The tail in the cache is job output like any other.
        $record = ProxmodCron::State::strip_output($record)
            if $record && !perms($ctx)->{syslog} && !delegation($ctx, $job)->{ok};

        $row{last_run} = $record;
    }

    return \%row;
}

=head2 audit($ctx, $action, $id, $job, %opts)

Record a mutation attempt — including the refused ones — through the two sinks
of §8.6. The privilege detail lives here rather than at the call sites so that
every path records the same fields.

=cut

sub audit {
    my ($ctx, $action, $id, $job, %opts) = @_;

    my $command = $opts{command};
    if (!defined($command) && $job && $job->{type}) {
        my $argv = eval { ProxmodCron::Registry::build_command($job->{type}, $job) };
        $command = join(' ', @$argv) if $argv && ref($argv) eq 'ARRAY';
    }

    my $authorization = $opts{authorization};
    $authorization = $job ? authorization($ctx, $job) : undef
        if !defined $authorization;

    ProxmodCron::Store::audit($ctx->{scope}, $id, $job, $action, {
        user => $ctx->{user},
        via => $opts{via} || 'api',
        authorization => $authorization || 'refused',
        privileges => $opts{reason} || $ctx->{path},
        outcome => $opts{outcome} || 'permitted',
        defined($command) ? (command => $command) : (),
    });

    return;
}

=head2 job_properties(%opts)

The parameter schema shared by create and update. C<< optional => 1 >> makes
every field optional, which is what an update wants.

C<additionalProperties> is left B<open> by the callers, because type-specific
keys are declared by the plugin and not by us. They are not unchecked: the
registry rejects unknown and malformed keys against the plugin's own property
schema, and ProxmodCron::Config::untaint_job rebuilds every value from a strict
capture before it reaches a store.

=cut

sub job_properties {
    my (%opts) = @_;

    my $optional = $opts{optional} ? 1 : 0;

    my %props = (
        type => {
            type => 'string',
            description => 'Job type id. See the `types` endpoint.',
            pattern => '[a-z0-9][a-z0-9_-]{0,63}',
            maxLength => 64,
            optional => $optional,
        },
        schedule => {
            type => 'string',
            description => 'A 5-field cron schedule, or @hourly, @daily,'
                . ' @weekly, @monthly, @yearly or @reboot.',
            maxLength => 256,
            optional => $optional,
        },
        comment => {
            type => 'string',
            description => 'A short note, rendered as a comment above the'
                . ' generated cron line.',
            maxLength => 512,
            optional => 1,
        },
        user => {
            type => 'string',
            description => 'The crontab user field. Requires Sys.Modify;'
                . ' a delegated caller gets the job type\'s own run_as.',
            pattern => '[a-z_][a-z0-9_-]{0,31}',
            maxLength => 32,
            optional => 1,
        },
        # No `enabled` property, deliberately. It is the one mutation permitted
        # on an extension-owned job and it has its own endpoint so that the rule
        # is enforced by routing (§7). Declaring it here would put it in the API
        # viewer and in every generated client as a field that always returns
        # 400 — worse than not offering it. A new job is created enabled;
        # job_config() still refuses the key explicitly, because create and
        # update leave additionalProperties open for plugin fields and an
        # undeclared `enabled` would otherwise be swallowed into them.
        track => {
            type => 'boolean',
            description => 'Wrap the job so its runs and output are recorded in'
                . ' the journal. Default true.',
            optional => 1,
        },
        keep_output => {
            type => 'boolean',
            description => 'Record the job\'s output, not only its start and'
                . ' finish. Default true.',
            optional => 1,
        },
    );

    if ($opts{scope} && $opts{scope} eq 'cluster') {
        $props{nodes} = {
            type => 'array',
            items => { type => 'string', maxLength => 63 },
            description => 'Which nodes render this job. Absent means every node.',
            optional => 1,
        };
        $props{run_on} = {
            type => 'string',
            enum => ['all', 'any'],
            description => 'all: every targeted node runs the job, each on its own'
                . ' schedule. any: exactly one targeted node runs it per scheduled'
                . ' time, chosen by racing for a lease, so the job moves to a'
                . ' surviving node when its usual one is down. any requires'
                . ' track: true, user root, and a real schedule.',
            optional => 1,
        };
    }

    return \%props;
}

=head2 job_config($param, %opts)

Turn request parameters into a job config: drop the routing parameters, refuse
the ones the server owns, and rebuild every value from a strict capture.

C<< type => … >> supplies the job type when the request did not carry one, which
is the normal case on a partial update. It is only used to find the plugin's
array-valued properties.

=cut

# One-element arrays arrive as scalars, and nothing further down can tell them
# apart from one. PVE's parameter parser builds an array only when a key
# repeats, so `nodes=pve1` and `command=/bin/true` reach a method as strings
# while `nodes=pve1&nodes=pve2` reaches it as a list — and a one-node job or a
# one-word command is not an edge case.
#
# The coercion belongs here, at the HTTP boundary, and not in
# ProxmodCron::Config: ProxmodCron::Client is in-process and does hand it real
# arrays, so relaxing the store's check would lose a real error for every
# in-process caller in order to fix a wire-format artefact.
sub _listify {
    my ($cfg, $type) = @_;

    my %array = (nodes => 1);

    my $class = defined($type) ? ProxmodCron::Registry::lookup($type) : undef;
    if ($class) {
        my $props = eval { $class->properties() } || {};
        for my $key (keys %$props) {
            my $spec = $props->{$key};
            $array{$key} = 1
                if ref($spec) eq 'HASH' && ($spec->{type} || '') eq 'array';
        }
    }

    for my $key (keys %array) {
        next if !defined $cfg->{$key};
        next if ref($cfg->{$key});
        $cfg->{$key} = [$cfg->{$key}];
    }

    return;
}

sub job_config {
    my ($param, %opts) = @_;

    my %cfg = %$param;

    delete $cfg{$_} for qw(node id);

    raise_param_exc({ enabled => "use the 'enabled' endpoint to enable or"
        . " disable a job; it is the one change permitted on an"
        . " extension-owned job" }) if exists $cfg{enabled};

    # §7: POST jobs ignores any origin or owner in the body and always writes
    # origin: user. The extension-owned origin is reachable only through
    # ProxmodCron::Client, in-process, which is what makes it mean anything.
    delete $cfg{$_} for qw(origin owner);

    _listify(\%cfg, defined($cfg{type}) ? $cfg{type} : $opts{type});

    my $id = $opts{id} || 'x';

    my $clean = ProxmodCron::Config::untaint_job($id, \%cfg,
        partial => $opts{partial} ? 1 : 0);

    raise_param_exc({ '' => 'the job definition contains a value this'
        . ' extension will not put in a crontab' }) if !$clean;

    delete $clean->{origin};
    delete $clean->{owner};

    return $clean;
}

=head2 assert_delegated_fields($ctx, $submitted, $baseline, %opts)

The three fields a delegated caller may not touch, from §8.3.

Setting the crontab user to root, or turning off run tracking, or switching a
job to type C<command>, is each a path to more than the delegation granted. The
refusal names the field, because "403" on a form with eight fields is not
actionable.

C<$submitted> is what the caller actually sent, B<not> the config after defaults
and pinning have been applied. Every job has a C<user>, so a check against the
defaulted config would refuse every delegated create ever made. C<$baseline> is
the value the server would use anyway — the stored job on update, the pinned and
defaulted config on create — because submitting a field at the value it already
has is not a change, and an editor that PUTs its whole form back would otherwise
be unusable for exactly the callers this subtree exists for.

C<< create => 1 >> exempts C<type>: naming the type is how a job is created. It
is frozen only once one exists, at which point changing it is a way to turn a
delegable job into arbitrary root execution.

=cut

sub assert_delegated_fields {
    my ($ctx, $submitted, $baseline, %opts) = @_;

    for my $field (qw(user track type)) {
        next if !exists $submitted->{$field};
        next if $opts{create} && $field eq 'type';

        my $now = $baseline ? $baseline->{$field} : undef;

        next if defined($now) && defined($submitted->{$field})
            && "$now" eq "$submitted->{$field}";

        raise_perm_exc("setting '$field' requires Sys.Modify on $ctx->{path}");
    }

    return 1;
}

=head2 list_jobs($ctx, %opts)

The rows for one scope. C<< include_cluster => 1 >> adds the cluster jobs that
target this node.

=cut

sub list_jobs {
    my ($ctx, %opts) = @_;

    ProxmodCron::Registry::load_plugins();

    my $live = ProxmodCron::Store::live_owners();

    my @rows;

    my $store = ProxmodCron::Config::load($ctx->{scope});
    for my $id (sort keys %{ $store->{jobs} }) {
        my $job = ProxmodCron::Config::effective($ctx->{scope}, $store, $id);
        next if !visible($ctx, $job, %opts);
        push @rows, job_view($ctx, $job, live => $live, status => $opts{status});
    }

    if ($opts{include_cluster}) {
        my $cluster = ProxmodCron::Config::load('cluster');

        for my $id (sort keys %{ $cluster->{jobs} }) {
            my $job = ProxmodCron::Config::effective('cluster', $cluster, $id);

            next if !ProxmodCron::Config::targets_node($job, $ctx->{node});
            next if !visible($ctx, $job, %opts);


            my $row = job_view($ctx, $job, live => $live, status => $opts{status});

            # Read-only from here, whatever the caller holds on this node.
            # Sys.Modify on /nodes/pve1 is not Sys.Modify on '/', and letting a
            # node endpoint write the cluster store would be a way to edit every
            # node's jobs with rights on one of them.
            $row->{managed_in} = 'cluster';
            $row->{$_} = 0 for qw(can_edit can_delete can_toggle);

            push @rows, $row;
        }
    }

    return \@rows;
}

=head2 get_job($ctx, $id, %opts)

One row, or a 404-shaped die.

=cut

sub get_job {
    my ($ctx, $id, %opts) = @_;

    ProxmodCron::Registry::load_plugins();

    my $store = ProxmodCron::Config::load($ctx->{scope});

    my $job = ProxmodCron::Config::effective($ctx->{scope}, $store, $id);

    die "no job named '$id' in the $ctx->{scope} scope\n" if !$job;

    raise_perm_exc("you may not see job '$id'") if !visible($ctx, $job, %opts);

    return job_view($ctx, $job, status => 1, %opts);
}

=head2 create_job($ctx, $param, %opts)

C<< delegated => 1 >> routes through §8.3's rules instead of Sys.Modify.

=cut

sub create_job {
    my ($ctx, $param, %opts) = @_;

    ProxmodCron::Registry::load_plugins();

    my $id = $param->{id};
    my $cfg = job_config($param, id => $id);

    if ($opts{delegated}) {
        # §8.3's first structural rule, and it has to be the first act: a type
        # whose required_privs is empty is refused here, before anything else in
        # this method can be reached. That is what makes the loose
        # `{ user => 'all' }` gate on this subtree safe — the path structurally
        # cannot create a command job, rather than relying on a later check
        # still being present after someone refactors around it.
        my $delegation = delegation($ctx, $cfg);
        raise_perm_exc($delegation->{why}) if !$delegation->{ok};

        pin_run_as($cfg);

        assert_delegated_fields($ctx, $param, $cfg, create => 1);
    }

    my $caps = assert($ctx, 'create', $cfg, id => $id);

    audit($ctx, 'create', $id, $cfg,
        authorization => $caps->{authorization}, via => $opts{delegated} ? 'delegated' : 'api');

    ProxmodCron::Store::create($ctx->{scope}, $id, $cfg,
        origin => 'user', audited => 1);

    return get_job($ctx, $id);
}

=head2 update_job($ctx, $id, $param, %opts)

=cut

sub update_job {
    my ($ctx, $id, $param, %opts) = @_;

    ProxmodCron::Registry::load_plugins();

    my $store = ProxmodCron::Config::load($ctx->{scope});
    my $existing = ProxmodCron::Config::effective($ctx->{scope}, $store, $id);

    die "no job named '$id' in the $ctx->{scope} scope\n" if !$existing;

    my $delta = job_config($param, id => $id, partial => 1,
        type => $existing->{type});

    if ($opts{delegated}) {
        # Three checks, in this order, and the order is the point.
        #
        # The stored job first, for the same reason as create: whether this
        # subtree may touch this job at all is the structural rule, and it has
        # to run before anything else rather than sit further down where a
        # refactor could reorder past it. It is also what refuses a caller who
        # holds nothing on the job they named.
        my $delegation = delegation($ctx, $existing);
        raise_perm_exc($delegation->{why}) if !$delegation->{ok};

        # Then the frozen fields, so a caller switching `type` is told which
        # field they may not set rather than the less useful truth that the type
        # they picked is not delegable.
        assert_delegated_fields($ctx, $param, $existing);

        # Then the submitted config. Checking only the stored one would let a
        # caller with rights on /vms/101 re-point that job at /vms/202 and then
        # edit it freely. §8.3.
        $delegation = delegation($ctx, { %$existing, %$delta });
        raise_perm_exc($delegation->{why}) if !$delegation->{ok};
    }

    my $caps = assert($ctx, 'update', $existing, id => $id);

    audit($ctx, 'update', $id, { %$existing, %$delta },
        authorization => $caps->{authorization}, via => $opts{delegated} ? 'delegated' : 'api');

    ProxmodCron::Store::update($ctx->{scope}, $id, $delta, audited => 1);

    return get_job($ctx, $id);
}

=head2 set_job_enabled($ctx, $id, $enabled)

The one mutation permitted on an extension-owned job, and the reason it has its
own endpoint rather than being a field on update: the rule is enforced by
routing, not by a conditional inside a general update handler.

=cut

sub set_job_enabled {
    my ($ctx, $id, $enabled) = @_;

    ProxmodCron::Registry::load_plugins();

    my $store = ProxmodCron::Config::load($ctx->{scope});
    my $existing = ProxmodCron::Config::effective($ctx->{scope}, $store, $id);

    die "no job named '$id' in the $ctx->{scope} scope\n" if !$existing;

    my $caps = assert($ctx, 'toggle', $existing, id => $id);

    audit($ctx, ($enabled ? 'enable' : 'disable'), $id, $existing,
        authorization => $caps->{authorization});

    ProxmodCron::Store::set_enabled($ctx->{scope}, $id, $enabled, audited => 1);

    return;
}

=head2 delete_job($ctx, $id, %opts)

=cut

sub delete_job {
    my ($ctx, $id, %opts) = @_;

    ProxmodCron::Registry::load_plugins();

    my $store = ProxmodCron::Config::load($ctx->{scope});
    my $existing = ProxmodCron::Config::effective($ctx->{scope}, $store, $id);

    die "no job named '$id' in the $ctx->{scope} scope\n" if !$existing;

    if ($opts{delegated}) {
        # The stored config, so a caller cannot delete a job for an object they
        # do not hold by submitting one they do.
        my $delegation = delegation($ctx, $existing);
        raise_perm_exc($delegation->{why}) if !$delegation->{ok};
    }

    my $caps = assert($ctx, 'delete', $existing, id => $id);

    audit($ctx, 'remove', $id, $existing,
        authorization => $caps->{authorization}, via => $opts{delegated} ? 'delegated' : 'api');

    ProxmodCron::Store::remove($ctx->{scope}, $id, audited => 1);

    return;
}

=head2 pin_run_as($cfg)

The crontab user comes from the job type, not from the caller. A plugin decides
what identity its work needs; a delegated caller does not get to choose one.

=cut

sub pin_run_as {
    my ($cfg) = @_;

    my $class = ProxmodCron::Registry::lookup($cfg->{type});

    $cfg->{user} = $class ? $class->run_as() : 'root';

    return $cfg;
}

1;
