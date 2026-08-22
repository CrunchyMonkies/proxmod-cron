package ProxmodCron::Client;

use strict;
use warnings;

use ProxmodCron::Config;
use ProxmodCron::Registry;
use ProxmodCron::Runs;
use ProxmodCron::State;
use ProxmodCron::Store;
use ProxmodCron::Sync;

# The documented surface for another extension's backend.
#
# Same locking and validation the REST layer uses (both go through
# ProxmodCron::Store), so a caller cannot corrupt a store by going around the
# API.
#
# THE CLIENT DOES NO ACL CHECKING. It runs inside pvedaemon as root and has no
# authenticated user to check against — it is the layer *below* authorization,
# the same relationship PVE::Jobs has to PVE::API2::Cluster::Jobs. A caller
# acting on behalf of a user must check first:
#
#     $rpcenv->check($authuser, "/nodes/$node", ['Sys.Modify']);
#     $cron->ensure('node', $id, $cfg);
#
# A plugin author who misses that has written a privilege escalation into an
# otherwise correct extension, which is why it is said here, in the first
# paragraph of the client section of docs/extension-api.md, and nowhere quietly.

our $VERSION = '202608.22.0';

=head2 new($api)

    my $cron = ProxmodCron::Client->new($api);   # $api is your Proxmod::API

Ownership comes from C<< $api->id >>, never from an argument. That is the whole
reason this is an object rather than a set of class methods: if the owner were a
parameter, one extension could claim another's jobs or forge C<origin: user>,
and §2.1's guarantees would rest on callers behaving.

Outside a daemon — a test, or a script — a plain extension id may be passed
instead.

=cut

sub new {
    my ($class, $api) = @_;

    my $id = ref($api) ? eval { $api->id } : $api;

    die "ProxmodCron::Client->new needs a Proxmod::API object or an extension id\n"
        if !defined $id || ref($id);

    my ($owner) = ($id =~ $ProxmodCron::Config::ID_PATTERN);

    die "'$id' is not a valid extension id\n" if !defined $owner;

    ProxmodCron::Registry::load_plugins();

    return bless { owner => $owner }, $class;
}

=head2 owner()

The extension id every write from this client is stamped with.

=cut

sub owner { $_[0]->{owner} }

=head2 list($scope, %opts)

Every job in the scope, as a list of C<< { id => …, %$job } >> sorted by id.
Reads are not filtered by owner: an extension may want to know what else is
scheduled, and the store is readable by root regardless. Pass C<< mine => 1 >>
for only this client's own jobs.

=cut

sub list {
    my ($self, $scope, %opts) = @_;

    $scope = $self->_scope($scope);

    my $store = ProxmodCron::Config::load($scope);

    my @jobs;
    for my $id (sort keys %{ $store->{jobs} || {} }) {
        my $job = ProxmodCron::Config::effective($scope, $store, $id);
        next if $opts{mine} && !$self->_owns($job);
        push @jobs, $job;
    }

    return \@jobs;
}

=head2 get($scope, $id)

One job with defaults applied, or undef.

=cut

sub get {
    my ($self, $scope, $id) = @_;

    $scope = $self->_scope($scope);

    my $store = ProxmodCron::Config::load($scope);

    return ProxmodCron::Config::effective($scope, $store, $id);
}

=head2 create($scope, $id, $cfg)

Create a job. Dies if the id is taken — an extension re-registering its job on
every daemon start wants ensure(), which is idempotent and is the method the
docs steer plugin authors toward.

=cut

sub create {
    my ($self, $scope, $id, $cfg) = @_;

    return ProxmodCron::Store::create($self->_scope($scope), $id, $cfg,
        $self->_stamp);
}

=head2 ensure($scope, $id, $cfg)

Create the job, or bring an existing one into line with C<$cfg>. The method to
call from your C<proxmod_register>.

B<It never overwrites C<enabled> on a job that already exists.> An extension
calls ensure() on every daemon start; if it wrote C<enabled> each time, an
administrator's decision to stop the job would be silently reverted within
seconds of the next restart, and the enable/disable split in §2.1 would be worth
nothing. Use set_enabled() when you genuinely mean to switch your own job back
on — it is deliberately separate and conspicuous.

=cut

sub ensure {
    my ($self, $scope, $id, $cfg) = @_;

    return ProxmodCron::Store::ensure($self->_scope($scope), $id, $cfg,
        $self->_stamp);
}

=head2 update($scope, $id, $delta)

Merge C<$delta> into one of B<your own> jobs. Dies on a job owned by another
extension, and on a job an administrator created.

=cut

sub update {
    my ($self, $scope, $id, $delta) = @_;

    return ProxmodCron::Store::update($self->_scope($scope), $id, $delta,
        $self->_stamp);
}

=head2 set_enabled($scope, $id, $enabled)

Switch one of your own jobs on or off.

Think before calling this on a schedule rather than in response to something the
administrator did: it is the one call that can undo their decision, and doing it
on every start is exactly what ensure() refuses to do for you.

=cut

sub set_enabled {
    my ($self, $scope, $id, $enabled) = @_;

    $scope = $self->_scope($scope);

    my $job = $self->get($scope, $id)
        or die "no job named '$id' in the $scope scope\n";

    die "job '$id' is not managed by $self->{owner}\n" if !$self->_owns($job);

    return ProxmodCron::Store::set_enabled($scope, $id, $enabled, $self->_stamp);
}

=head2 delete($scope, $id)

Remove one of your own jobs.

Uninstalling your extension does not need this: a job whose owner is no longer
loaded is flagged orphaned and becomes removable through the UI. Calling delete
from a shutdown path would instead throw away an administrator's configuration
every time the daemon restarted.

=cut

sub delete {
    my ($self, $scope, $id) = @_;

    return ProxmodCron::Store::remove($self->_scope($scope), $id, $self->_stamp);
}

=head2 status($scope, $id)

The last run of a job, from the §5.5 cache: run id, timestamps, exit status and
a short output tail. Cheap enough for a grid column, and only a cache — undef
means "no record here", not "never ran".

=cut

sub status {
    my ($self, $scope, $id) = @_;

    return ProxmodCron::State::get($self->_scope($scope), $id);
}

=head2 runs($scope, $id, %opts)

Run history from journald. Options: C<since>, C<until>, C<limit>.

=cut

sub runs {
    my ($self, $scope, $id, %opts) = @_;

    return ProxmodCron::Runs::list(%opts, job => $id, scope => $self->_scope($scope));
}

=head2 log($runid, %opts)

One run's captured output. Options: C<cursor>, C<limit>.

Note the audience this reaches: anything a job prints is in the journal, which
is readable by any Sys.Syslog holder and by anyone with shell access — wider
than the API. Do not print secrets from a job and then expect this to be the
only way back to them.

=cut

sub log {
    my ($self, $runid, %opts) = @_;

    return ProxmodCron::Runs::output($runid, %opts);
}

=head2 sync()

Render both scopes now. The write methods already do this, so this is for the
case where something else changed the store underneath you.

=cut

sub sync {
    my ($self) = @_;

    return ProxmodCron::Sync::run();
}

=head2 types()

The registered job types, exactly as the REST `types` endpoint returns them —
one implementation, so a plugin author testing against the client sees what the
editor will see.

=cut

sub types {
    my ($self) = @_;

    ProxmodCron::Registry::load_plugins();

    return ProxmodCron::Registry::catalogue();
}

sub _stamp {
    my ($self) = @_;

    return (origin => 'extension', owner => $self->{owner},
        audit => { owner => $self->{owner}, via => 'client' });
}

sub _owns {
    my ($self, $job) = @_;

    return 0 if ($job->{origin} || 'user') ne 'extension';
    return 0 if !defined $job->{owner};

    return $job->{owner} eq $self->{owner} ? 1 : 0;
}

sub _scope {
    my ($self, $scope) = @_;

    die "scope must be 'cluster' or 'node'\n"
        if !defined $scope || ($scope ne 'cluster' && $scope ne 'node');

    return $scope;
}

1;
