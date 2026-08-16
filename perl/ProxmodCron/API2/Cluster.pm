package ProxmodCron::API2::Cluster;

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

use ProxmodCron::API2::Common;
use ProxmodCron::Config;
use ProxmodCron::Registry;
use ProxmodCron::Spec;
use ProxmodCron::Sync;

# /cluster/proxmod/cron — the datacenter tab's backend.
#
# Cluster job definitions live in /etc/pve/proxmod/cron.cfg, which pmxcfs
# replicates, so a job created here appears on every node within a minute
# without anything being done on the other nodes. That is the claim the whole
# cluster scope rests on, and it is why every method here is protected: the
# store is under /etc/pve and pveproxy, as www-data, cannot write it.
#
# There is deliberately no run history in this tree. journald is per-node, so a
# cluster-wide history endpoint could only be a fiction assembled from guesses
# about which node ran what. The grid's status column comes from each node's own
# `jobs/{id}/status`, and the UI links to the owning node's Runs tab.

our $VERSION = '0.1.0';

my $SCOPE = 'cluster';

sub register {
    my ($api) = @_;

    $api->mount(scope => 'cluster', subclass => __PACKAGE__);

    _index($api);
    _jobs($api);
    _types($api);
    _permissions($api);

    return;
}

sub _ctx { return ProxmodCron::API2::Common::context(scope => $SCOPE) }

sub _index {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'index',
        path => '',
        method => 'GET',
        permissions => { check => ['perm', '/', ['Sys.Audit']] },
        description => 'Index of the cluster cron endpoints.',
        parameters => { additionalProperties => 0, properties => {} },
        returns => {
            type => 'array',
            items => { type => 'object', properties => { subdir => { type => 'string' } } },
            links => [{ rel => 'child', href => '{subdir}' }],
        },
        code => sub {
            return [map { { subdir => $_ } }
                qw(jobs delegated-jobs types permissions)];
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
        # The coarse tree is gated coarsely. A caller with no Sys.Audit reads
        # their own jobs through delegated-jobs instead of getting a filtered
        # view here — one tree, one rule, and no endpoint whose answer changes
        # shape depending on who asked.
        permissions => { check => ['perm', '/', ['Sys.Audit']] },
        description => 'Cluster cron jobs.',
        parameters => { additionalProperties => 0, properties => {} },
        returns => { type => 'array', items => { type => 'object' } },
        code => sub {
            return ProxmodCron::API2::Common::list_jobs(_ctx());
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'get_job',
        path => 'jobs/{id}',
        method => 'GET',
        permissions => { check => ['perm', '/', ['Sys.Audit']] },
        description => 'One cluster cron job.',
        parameters => {
            additionalProperties => 0,
            properties => { id => _id_param() },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::get_job(_ctx(), $param->{id});
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'create_job',
        path => 'jobs',
        method => 'POST',
        protected => 1,
        permissions => { check => ['perm', '/', ['Sys.Modify']] },
        description => 'Create a cluster cron job. Always origin: user —'
            . ' an origin or owner in the body is ignored.',
        parameters => {
            # Open, because type-specific keys are declared by the plugin. They
            # are validated by the registry against that plugin's schema and
            # rebuilt from strict captures before they reach the store.
            additionalProperties => 1,
            properties => {
                id => _id_param(),
                %{ ProxmodCron::API2::Common::job_properties(scope => $SCOPE) },
            },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::create_job(_ctx(), $param);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'update_job',
        path => 'jobs/{id}',
        method => 'PUT',
        protected => 1,
        permissions => { check => ['perm', '/', ['Sys.Modify']] },
        description => 'Update a cluster cron job. Refuses an enabled key —'
            . ' use the enabled endpoint.',
        parameters => {
            additionalProperties => 1,
            properties => {
                id => _id_param(),
                %{ ProxmodCron::API2::Common::job_properties(
                    scope => $SCOPE, optional => 1) },
            },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::update_job(_ctx(), $param->{id}, $param);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'set_enabled',
        path => 'jobs/{id}/enabled',
        method => 'PUT',
        protected => 1,
        permissions => { check => ['perm', '/', ['Sys.Modify']] },
        # Its own endpoint, taking exactly one boolean. This is the only
        # mutation permitted on an extension-owned job, and a separate path
        # means that fact is enforced by routing rather than by a conditional
        # inside a general update handler.
        description => 'Enable or disable a cluster cron job. Permitted'
            . ' whatever the job\'s origin.',
        parameters => {
            additionalProperties => 0,
            properties => {
                id => _id_param(),
                enabled => { type => 'boolean', description => 'Whether the job runs.' },
            },
        },
        returns => { type => 'null' },
        code => sub {
            my ($param) = @_;
            ProxmodCron::API2::Common::set_job_enabled(_ctx(), $param->{id},
                $param->{enabled});
            return;
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'delete_job',
        path => 'jobs/{id}',
        method => 'DELETE',
        protected => 1,
        permissions => { check => ['perm', '/', ['Sys.Modify']] },
        description => 'Delete a cluster cron job. Refused for a job owned by a'
            . ' loaded extension; permitted once that extension is gone.',
        parameters => {
            additionalProperties => 0,
            properties => { id => _id_param() },
        },
        returns => { type => 'null' },
        code => sub {
            my ($param) = @_;
            ProxmodCron::API2::Common::delete_job(_ctx(), $param->{id});
            return;
        },
    );

    _delegated($api);

    return;
}

# The delegated subtree, §8.3.
#
# Its declarative gate is { user => 'all' } because a delegated caller may hold
# nothing at all on the scope root. That loose gate is only safe because every
# body below refuses, as its first act, any type whose required_privs is empty —
# so this path structurally cannot create a command job, rather than relying on
# a later check being present.
sub _delegated {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'list_delegated',
        path => 'delegated-jobs',
        method => 'GET',
        permissions => { user => 'all' },
        description => 'The cluster cron jobs the caller administers through'
            . ' their own privileges on the objects those jobs are about.',
        parameters => { additionalProperties => 0, properties => {} },
        returns => { type => 'array', items => { type => 'object' } },
        code => sub {
            return ProxmodCron::API2::Common::list_jobs(_ctx(), delegated => 1);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'get_delegated',
        path => 'delegated-jobs/{id}',
        method => 'GET',
        permissions => { user => 'all' },
        description => 'One delegated cluster cron job.',
        parameters => {
            additionalProperties => 0,
            properties => { id => _id_param() },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::get_job(_ctx(), $param->{id},
                delegated => 1);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'create_delegated',
        path => 'delegated-jobs',
        method => 'POST',
        protected => 1,
        permissions => { user => 'all' },
        description => 'Create a cluster cron job for an object you administer.'
            . ' The job type must declare required_privs; command jobs are'
            . ' refused here.',
        parameters => {
            additionalProperties => 1,
            properties => {
                id => _id_param(),
                %{ ProxmodCron::API2::Common::job_properties(scope => $SCOPE) },
            },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::create_job(_ctx(), $param, delegated => 1);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'update_delegated',
        path => 'delegated-jobs/{id}',
        method => 'PUT',
        protected => 1,
        permissions => { user => 'all' },
        description => 'Update a delegated cluster cron job. The stored config'
            . ' is checked as well as the submitted one.',
        parameters => {
            additionalProperties => 1,
            properties => {
                id => _id_param(),
                %{ ProxmodCron::API2::Common::job_properties(
                    scope => $SCOPE, optional => 1) },
            },
        },
        returns => { type => 'object' },
        code => sub {
            my ($param) = @_;
            return ProxmodCron::API2::Common::update_job(_ctx(), $param->{id},
                $param, delegated => 1);
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'delete_delegated',
        path => 'delegated-jobs/{id}',
        method => 'DELETE',
        protected => 1,
        permissions => { user => 'all' },
        description => 'Delete a delegated cluster cron job.',
        parameters => {
            additionalProperties => 0,
            properties => { id => _id_param() },
        },
        returns => { type => 'null' },
        code => sub {
            my ($param) = @_;
            ProxmodCron::API2::Common::delete_job(_ctx(), $param->{id}, delegated => 1);
            return;
        },
    );

    return;
}

sub _types {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'types',
        path => 'types',
        method => 'GET',
        # Schemas only. Nothing here is host data, and the editor needs it
        # before it knows what the caller may create.
        permissions => { user => 'all' },
        description => 'Registered job types and their property schemas.',
        parameters => { additionalProperties => 0, properties => {} },
        returns => { type => 'array', items => { type => 'object' } },
        code => sub {
            ProxmodCron::Registry::load_plugins();
            return ProxmodCron::Registry::catalogue();
        },
    );

    $api->add_method(
        class => __PACKAGE__,
        name => 'schedule',
        path => 'schedule',
        method => 'GET',
        permissions => { user => 'all' },
        description => 'Validate a cron schedule and preview its next runs.'
            . ' Pure arithmetic on the submitted string; it reads nothing.',
        parameters => {
            additionalProperties => 0,
            properties => {
                schedule => {
                    type => 'string',
                    description => 'The schedule to check.',
                    maxLength => 256,
                },
                count => {
                    type => 'integer',
                    description => 'How many runs to preview.',
                    minimum => 1,
                    maximum => 10,
                    default => 3,
                    optional => 1,
                },
            },
        },
        returns => {
            type => 'object',
            properties => {
                valid => { type => 'boolean' },
                error => { type => 'string', optional => 1 },
                next => { type => 'array', items => { type => 'integer' } },
            },
        },
        code => sub {
            my ($param) = @_;

            my ($ok, $why) = ProxmodCron::Spec::validate($param->{schedule});

            return { valid => 0, error => $why, next => [] } if !$ok;

            return {
                valid => 1,
                next => ProxmodCron::Spec::next_runs($param->{schedule},
                    $param->{count} || 3),
            };
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
        permissions => { user => 'all' },
        description => 'What the caller may do in the cluster scope. Computed'
            . ' with the same helper the write methods enforce with, so the two'
            . ' cannot drift.',
        parameters => { additionalProperties => 0, properties => {} },
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
            return ProxmodCron::API2::Common::perms(_ctx());
        },
    );

    return;
}

sub _id_param {
    return {
        type => 'string',
        description => 'Job id.',
        pattern => '[a-z0-9][a-z0-9_-]{0,63}',
        maxLength => 64,
    };
}

1;
