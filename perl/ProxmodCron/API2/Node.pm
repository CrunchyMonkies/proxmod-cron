package ProxmodCron::API2::Node;

use strict;
use warnings;

use PVE::Exception qw(raise_perm_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Tools;

use base qw(PVE::RESTHandler);

use ProxmodCron::API2::Common;
use ProxmodCron::Config;
use ProxmodCron::Inventory;
use ProxmodCron::Registry;
use ProxmodCron::Runs;
use ProxmodCron::State;
use ProxmodCron::Sync;

# /nodes/{node}/proxmod/cron — the node tab's backend, and the only place run
# history lives.
#
# Two things make this tree different from the cluster one:
#
#   proxyto => 'node' on everything. The answer is about this machine — its
#   /etc/cron.d, its journal, its cron spool — so a request that arrives at the
#   wrong node must be forwarded, not answered locally about the wrong host.
#
#   Every run and log read is protected => 1, which is not the usual reason.
#   pveproxy runs as www-data and is not in the systemd-journal group, so an
#   unprotected history method would return an empty list that reads as "this
#   job has never run" rather than as a permissions problem.

our $VERSION = '0.1.0';

my $SCOPE = 'node';

sub register {
    my ($api) = @_;

    $api->mount(scope => 'node', subclass => __PACKAGE__);

    _index($api);
    _jobs($api);
    _delegated($api);
    _runs($api);
    _inventory($api);
    _permissions($api);

    return;
}

sub _ctx {
    my ($param) = @_;
    return ProxmodCron::API2::Common::context(scope => $SCOPE, node => $param->{node});
}

sub _node_param { return get_standard_option('pve-node') }

sub _id_param {
    return {
        type => 'string',
        description => 'Job id.',
        pattern => '[a-z0-9][a-z0-9_-]{0,63}',
        maxLength => 64,
    };
}

sub _run_param {
    return {
        type => 'string',
        description => 'Run id, as returned by the runs endpoint.',
        pattern => '[0-9]{1,20}-[0-9a-f]{8}',
        maxLength => 32,
    };
}

sub _index {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'index',
        path => '',
        method => 'GET',
        proxyto => 'node',
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
        description => 'Index of the node cron endpoints.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param() },
        },
        returns => {
            type => 'array',
            items => { type => 'object', properties => { subdir => { type => 'string' } } },
            links => [{ rel => 'child', href => '{subdir}' }],
        },
        code => sub {
            return [map { { subdir => $_ } }
                qw(jobs delegated-jobs runs journal inventory types permissions sync)];
        },
    );

    return;
}

sub _jobs {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'list_jobs',
        path => 'jobs',
        method => 'GET',
        proxyto => 'node',
        # protected: the status column comes from /var/lib/proxmod/cron, which
        # is root-owned.
        protected => 1,
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
        description => 'This node\'s cron jobs, plus the cluster jobs that'
            . ' target it. Cluster rows are read-only here.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param() },
        },
        returns => { type => 'array', items => { type => 'object' } },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::list_jobs(_ctx($param),
                include_cluster => 1, status => 1);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'get_job',
        path => 'jobs/{id}',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
        description => 'One node cron job.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param(), id => _id_param() },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::get_job(_ctx($param), $param->{id});
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'create_job',
        path => 'jobs',
        method => 'POST',
        proxyto => 'node',
        protected => 1,
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
        description => 'Create a node cron job. Always origin: user.',
        parameters => {
            additionalProperties => 1,
            properties => {
                node => _node_param(),
                id => _id_param(),
                %{ ProxmodCron::API2::Common::job_properties(scope => $SCOPE) },
            },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::create_job(_ctx($param), $param);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'update_job',
        path => 'jobs/{id}',
        method => 'PUT',
        proxyto => 'node',
        protected => 1,
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
        description => 'Update a node cron job. Refuses an enabled key — use'
            . ' the enabled endpoint.',
        parameters => {
            additionalProperties => 1,
            properties => {
                node => _node_param(),
                id => _id_param(),
                %{ ProxmodCron::API2::Common::job_properties(
                    scope => $SCOPE, optional => 1) },
            },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::update_job(_ctx($param),
                $param->{id}, $param);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'set_enabled',
        path => 'jobs/{id}/enabled',
        method => 'PUT',
        proxyto => 'node',
        protected => 1,
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
        description => 'Enable or disable a node cron job. Permitted whatever'
            . ' the job\'s origin — an administrator must always be able to'
            . ' stop a job without uninstalling what created it.',
        parameters => {
            additionalProperties => 0,
            properties => {
                node => _node_param(),
                id => _id_param(),
                enabled => { type => 'boolean', description => 'Whether the job runs.' },
            },
        },
        returns => { type => 'null' },
        code => sub {
            my ($param) = @_;
            ProxmodCron::API2::Common::set_job_enabled(_ctx($param),
                $param->{id}, $param->{enabled});
            return;
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'delete_job',
        path => 'jobs/{id}',
        method => 'DELETE',
        proxyto => 'node',
        protected => 1,
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
        description => 'Delete a node cron job.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param(), id => _id_param() },
        },
        returns => { type => 'null' },
        code => sub {
            my ($param) = @_;
            ProxmodCron::API2::Common::delete_job(_ctx($param), $param->{id});
            return;
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'run_job',
        path => 'jobs/{id}/run',
        method => 'POST',
        proxyto => 'node',
        protected => 1,
        # { user => 'all' } declaratively, because §8.2 makes this "Sys.Modify
        # OR delegated" and a delegated caller may hold nothing at all on the
        # node — a declarative Sys.Audit here would refuse them before the body
        # could grant. The gate is not weaker for it: the body's first act is
        # the same assert() the write methods use, and it demands Sys.Modify or
        # delegation before anything runs.
        permissions => { user => 'all' },
        description => 'Run a job now, out of schedule. Returns a UPID.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param(), id => _id_param() },
        },
        returns => { type => 'string' },
        code => sub {
            my ($param) = @_;
            return _run_now(_ctx($param), $param->{id});
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'job_status',
        path => 'jobs/{id}/status',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
        description => 'The job\'s last run, from the status cache. A cache —'
            . ' journald is the store of record, and an empty answer here means'
            . ' "no record", not "never ran".',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param(), id => _id_param() },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;

            my $ctx = _ctx($param);

            # Either store: the node grid lists the cluster jobs that target
            # this node too, and every one of those rows wants a status.
            my ($job, $scope) = _require_job($ctx, $param->{id});

            my $record = ProxmodCron::State::get($scope, $param->{id}) || {};

            # The cache carries an output tail for the failure tooltip, and a
            # tail is job output like any other. §8.2 gates output on
            # Sys.Syslog, so the same rule applies to the copy in the cache.
            $record = ProxmodCron::State::strip_output($record)
                if !eval { ProxmodCron::API2::Common::assert_output($ctx, $job) };

            return $record;
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'sync',
        path => 'sync',
        method => 'POST',
        proxyto => 'node',
        protected => 1,
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
        description => 'Render both scopes into /etc/cron.d now, instead of'
            . ' waiting for the next minute.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param() },
        },
        returns => { type => 'object' },
        code => sub {
            my $result = ProxmodCron::Sync::run(wait => 1);

            return {
                changed => $result->{changed},
                results => $result->{results},
                errors => $result->{errors},
            };
        },
    );

    return;
}

# §8.3's delegated subtree. { user => 'all' } is the declarative gate because a
# delegated caller may hold nothing on this node; every body refuses a type with
# an empty required_privs as its first act, so this path structurally cannot
# create a command job.
sub _delegated {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'list_delegated',
        path => 'delegated-jobs',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        permissions => { user => 'all' },
        description => 'The node cron jobs the caller administers through their'
            . ' privileges on the objects those jobs are about.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param() },
        },
        returns => { type => 'array', items => { type => 'object' } },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::list_jobs(_ctx($param),
                delegated => 1, status => 1);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'get_delegated',
        path => 'delegated-jobs/{id}',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        permissions => { user => 'all' },
        description => 'One delegated node cron job.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param(), id => _id_param() },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::get_job(_ctx($param),
                $param->{id}, delegated => 1);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'create_delegated',
        path => 'delegated-jobs',
        method => 'POST',
        proxyto => 'node',
        protected => 1,
        permissions => { user => 'all' },
        description => 'Create a node cron job for an object you administer.'
            . ' The type must declare required_privs; command jobs are refused'
            . ' here, and so is any type whose plugin declares none.',
        parameters => {
            additionalProperties => 1,
            properties => {
                node => _node_param(),
                id => _id_param(),
                %{ ProxmodCron::API2::Common::job_properties(scope => $SCOPE) },
            },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::create_job(_ctx($param), $param,
                delegated => 1);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'update_delegated',
        path => 'delegated-jobs/{id}',
        method => 'PUT',
        proxyto => 'node',
        protected => 1,
        permissions => { user => 'all' },
        description => 'Update a delegated node cron job. The stored config is'
            . ' checked as well as the submitted one, so a job cannot be walked'
            . ' from an object you hold to one you do not.',
        parameters => {
            additionalProperties => 1,
            properties => {
                node => _node_param(),
                id => _id_param(),
                %{ ProxmodCron::API2::Common::job_properties(
                    scope => $SCOPE, optional => 1) },
            },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::update_job(_ctx($param),
                $param->{id}, $param, delegated => 1);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'delete_delegated',
        path => 'delegated-jobs/{id}',
        method => 'DELETE',
        proxyto => 'node',
        protected => 1,
        permissions => { user => 'all' },
        description => 'Delete a delegated node cron job.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param(), id => _id_param() },
        },
        returns => { type => 'null' },
        code => sub {
            my ($param) = @_;
            ProxmodCron::API2::Common::delete_job(_ctx($param), $param->{id},
                delegated => 1);
            return;
        },
    );

    return;
}

sub _runs {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'job_runs',
        path => 'jobs/{id}/runs',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        permissions => { user => 'all' },
        description => 'Run history for a job, from journald: when it ran, how'
            . ' long it took, how it exited. Metadata only — the output is a'
            . ' separate endpoint with a separate privilege.',
        parameters => {
            additionalProperties => 0,
            properties => {
                node => _node_param(),
                id => _id_param(),
                since => _since_param(),
                until => _until_param(),
                limit => _limit_param(),
            },
        },
        returns => { type => 'array', items => { type => 'object' } },
        code => sub {
            my ($param) = @_;

            my $ctx = _ctx($param);

            # Metadata is Sys.Audit, or delegation on this job — §8.2. An
            # auditor who can see the job should be able to see whether it
            # works.
            my ($job, $scope) = _require_job($ctx, $param->{id});

            return ProxmodCron::Runs::list(
                job => $param->{id},
                scope => $scope,
                since => $param->{since},
                until => $param->{until},
                limit => $param->{limit},
            );
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'get_run',
        path => 'runs/{runid}',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        permissions => { user => 'all' },
        description => 'One run\'s record.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param(), runid => _run_param() },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;

            my $ctx = _ctx($param);
            my $run = ProxmodCron::Runs::get($param->{runid});

            die "no run '$param->{runid}' in this node's journal\n" if !$run;

            _assert_run_visible($ctx, $run);

            return $run;
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'run_log',
        path => 'runs/{runid}/log',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        # Sys.Syslog, not Sys.Audit. What a job printed is arbitrary text a root
        # command produced — a backup tool naming shares, a script echoing a
        # connection string. Reading it here must not be a way around the
        # privilege PVE demands for the same bytes at /nodes/{node}/journal.
        # The check is in the body because the delegated carve-out needs the
        # job, which is only known once the run is looked up.
        permissions => { user => 'all' },
        description => 'One run\'s captured output. Requires Sys.Syslog on the'
            . ' node, or the privileges the job\'s own type declares.',
        parameters => {
            additionalProperties => 0,
            properties => {
                node => _node_param(),
                runid => _run_param(),
                cursor => {
                    type => 'string',
                    description => 'Resume after this journald cursor. Cursors,'
                        . ' not offsets, so a live tail cannot skip or repeat a'
                        . ' line as new ones arrive mid-poll.',
                    maxLength => 512,
                    optional => 1,
                },
                limit => _limit_param(),
            },
        },
        returns => {
            type => 'object',
            properties => {
                lines => { type => 'array', items => { type => 'object' } },
                cursor => { type => 'string', optional => 1 },
                # Whether this call caught up with the journal. The caller polls
                # again only while the run has no finish record yet.
                done => { type => 'boolean' },
            },
        },
        code => sub {
            my ($param) = @_;

            my $ctx = _ctx($param);
            my $run = ProxmodCron::Runs::get($param->{runid});

            die "no run '$param->{runid}' in this node's journal\n" if !$run;

            my $job = _job_of($ctx, $run);

            ProxmodCron::API2::Common::assert_output($ctx, $job);

            return ProxmodCron::Runs::output($param->{runid},
                cursor => $param->{cursor}, limit => $param->{limit});
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'journal',
        path => 'journal',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        # The whole proxmod-cron journal: every job's runs and every management
        # action, interleaved. There is no per-row story to tell here and no
        # subset that could be delegated, so it is Sys.Syslog outright.
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Syslog']] },
        description => 'Every proxmod-cron journal entry on this node — runs'
            . ' and management actions in one timeline.',
        parameters => {
            additionalProperties => 0,
            properties => {
                node => _node_param(),
                since => _since_param(),
                until => _until_param(),
                limit => _limit_param(),
                cursor => {
                    type => 'string',
                    description => 'Resume after this journald cursor.',
                    maxLength => 512,
                    optional => 1,
                },
            },
        },
        returns => {
            type => 'object',
            properties => {
                entries => { type => 'array', items => { type => 'object' } },
                cursor => { type => 'string', optional => 1 },
            },
        },
        code => sub {
            my ($param) = @_;

            return ProxmodCron::Runs::journal(
                since => $param->{since},
                until => $param->{until},
                limit => $param->{limit},
                cursor => $param->{cursor},
            );
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'journal_status',
        path => 'journal-status',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
        description => 'Whether this node\'s journal survives a reboot. If it'
            . ' does not, run history dies at reboot — which the Runs tab says'
            . ' once rather than leaving the user to discover it.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param() },
        },
        returns => {
            type => 'object',
            properties => { persistent => { type => 'boolean' } },
        },
        code => sub {
            return { persistent => ProxmodCron::Runs::persistent() };
        },
    );

    return;
}

sub _inventory {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'inventory',
        path => 'inventory',
        method => 'GET',
        proxyto => 'node',
        protected => 1,
        # Sys.Audit in full, with no per-row filtering: this lists every cron
        # entry on the host, including other packages', and there is no
        # per-entry story that could be delegated to anyone.
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
        description => 'Every cron entry on this host, from every source.'
            . ' Read-only: entries this extension does not own are never'
            . ' modified, including to disable them.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param() },
        },
        returns => { type => 'array', items => { type => 'object' } },
        code => sub {
            return ProxmodCron::Inventory::collect();
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'types',
        path => 'types',
        method => 'GET',
        # proxyto, even though this reads no host state: the answer is which
        # plugins are installed, and that is a property of a node. A cluster
        # where one node is mid-upgrade would otherwise offer a type the node
        # the job lands on cannot build.
        proxyto => 'node',
        permissions => { user => 'all' },
        description => 'Registered job types and their property schemas.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param() },
        },
        returns => { type => 'array', items => { type => 'object' } },
        code => sub {
            ProxmodCron::Registry::load_plugins();
            return ProxmodCron::Registry::catalogue();
        },
    );

    return;
}

sub _permissions {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'permissions',
        path => 'permissions',
        method => 'GET',
        # The ACL answer is cluster-wide, but delegable_types is not: it comes
        # from this node's plugin registry, and the UI fills a combo from it.
        proxyto => 'node',
        permissions => { user => 'all' },
        description => 'What the caller may do on this node. The UI disables'
            . ' what is not permitted; the server checks every call regardless.',
        parameters => {
            additionalProperties => 0,
            properties => { node => _node_param() },
        },
        returns => {
            type => 'object',
            properties => {
                scope => { type => 'string' },
                audit => { type => 'boolean' },
                modify => { type => 'boolean' },
                syslog => { type => 'boolean' },
                delegable_types => { type => 'array', items => { type => 'string' } },
            },
        },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::perms(_ctx($param));
        },
    );

    return;
}

# Run a job out of schedule, through the same wrapper cron uses. Going through
# proxmod-cron-exec rather than running the argv directly is what makes a manual
# run appear in the same history, with the same fields, as a scheduled one.
sub _run_now {
    my ($ctx, $id) = @_;

    my ($job, $scope) = _require_job($ctx, $id);

    my $caps = ProxmodCron::API2::Common::assert($ctx, 'run', $job, id => $id);

    my $argv = ProxmodCron::Registry::build_command($job->{type}, $job);

    ProxmodCron::API2::Common::audit($ctx, 'run', $id, $job,
        authorization => $caps->{authorization}, command => join(' ', @$argv));

    my $exec = ProxmodCron::Config::prefix() . '/usr/lib/proxmod-cron/proxmod-cron-exec';

    my @cmd = ($exec, $scope, $id);
    push @cmd, '--no-output' if !$job->{keep_output};
    push @cmd, '--', @$argv;

    # fork_worker, not a blocking call: pvedaemon runs three workers, and a
    # protected method that blocks for the length of a backup would take a third
    # of the host's privileged API capacity with it.
    return $ctx->{rpcenv}->fork_worker('proxmodcronrun', $id, $ctx->{user}, sub {
        PVE::Tools::run_command(\@cmd);
    });
}

# The job named by an id, in whichever store holds it, having checked that this
# caller may see it. Every per-job endpoint on this tree starts here, so a job
# that is not visible reads as absent rather than as a differently-shaped error.
sub _require_job {
    my ($ctx, $id) = @_;

    my ($job, $scope) = _find_job($ctx, $id);

    die "no job named '$id' on this node\n" if !$job;

    raise_perm_exc("you may not see job '$id'")
        if !ProxmodCron::API2::Common::visible($ctx, $job);

    return ($job, $scope);
}

# A run id names a job that may live in either store. Look in the node store
# first, then in the cluster store for a job that targets this node.
sub _find_job {
    my ($ctx, $id) = @_;

    # Config::effective fills a job's defaults from its type's plugin, so the
    # registry has to be loaded before either store is read.
    ProxmodCron::Registry::load_plugins();

    my $node_store = ProxmodCron::Config::load('node');
    my $job = ProxmodCron::Config::effective('node', $node_store, $id);

    return ($job, 'node') if $job;

    my $cluster = ProxmodCron::Config::load('cluster');
    $job = ProxmodCron::Config::effective('cluster', $cluster, $id);

    return (undef, undef)
        if !$job || !ProxmodCron::Config::targets_node($job, $ctx->{node});

    return ($job, 'cluster');
}

# The job a run belonged to, or undef if its definition is gone. A run whose job
# has since been deleted still has a history, and the answer for it is
# Sys.Syslog with no delegated carve-out — there is nothing left to delegate
# against, and guessing would be the wrong way to be generous.
sub _job_of {
    my ($ctx, $run) = @_;

    return undef if !$run || !$run->{job};

    my ($job) = _find_job($ctx, $run->{job});

    return $job;
}

sub _assert_run_visible {
    my ($ctx, $run) = @_;

    return 1 if ProxmodCron::API2::Common::perms($ctx)->{audit};

    my $job = _job_of($ctx, $run);

    return 1 if $job && ProxmodCron::API2::Common::delegation($ctx, $job)->{ok};

    raise_perm_exc("reading run history requires Sys.Audit on $ctx->{path}");
}

sub _since_param {
    return {
        type => 'string',
        description => 'Start of the window, in journalctl syntax'
            . ' (for example -7d or "2026-08-01 00:00:00").',
        maxLength => 64,
        optional => 1,
    };
}

sub _until_param {
    return {
        type => 'string',
        description => 'End of the window, in journalctl syntax.',
        maxLength => 64,
        optional => 1,
    };
}

sub _limit_param {
    return {
        type => 'integer',
        description => 'Maximum entries to return.',
        minimum => 1,
        maximum => 10000,
        optional => 1,
    };
}

1;
