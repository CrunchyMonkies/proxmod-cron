package ProxmodCron::JobType;

use strict;
use warnings;

# Base class for a job type plugin. Subclass it, implement type() and
# build_command(), call ProxmodCron::Registry->register(__PACKAGE__).
#
# The contract is deliberately small: a plugin turns a validated config into an
# B<argv>, and that argv is rendered straight into the crontab line. It does not
# get a run() method, because then the effective command would live in Perl and
# /etc/cron.d would show an opaque dispatcher. Everything an administrator sees
# with `cat` should be the truth, and this is the interface that keeps it so.
#
# Loads without PVE — proxmod-cron-sync calls build_command() from cron.

our $VERSION = '0.1.0';

=head2 type()

The job type id, as stored in the config and named by the API. Required.

=cut

sub type { die "job type plugin " . (ref($_[0]) || $_[0]) . " does not implement type()\n" }

=head2 title()

Human-readable name for the editor's type combo. Defaults to the id.

=cut

sub title { my ($class) = @_; return $class->type() }

=head2 icon_cls()

Font Awesome class for the editor and the grid. Optional.

=cut

sub icon_cls { return 'fa fa-cog' }

=head2 description()

One line, shown in the editor under the type combo and in the API schema.

=cut

sub description { return '' }

=head2 properties()

JSON-Schema-shaped property definitions for this type's own config keys, in the
form PVE::JSONSchema uses. The frontend builds a form from this when the plugin
has not registered a JS form of its own, so a backend-only plugin still gets a
working editor.

=cut

sub properties { return {} }

=head2 build_command($cfg)

The whole contract: return an arrayref argv. Called from cron with no PVE
loaded, so it must not reach for PVE::Cluster or the RPC environment.

=cut

sub build_command {
    my ($class, $cfg) = @_;
    die "job type plugin " . (ref($class) || $class)
        . " does not implement build_command()\n";
}

=head2 required_privs($cfg)

Which object this job is I<about>, as C<[[$acl_path, [$privs]], ...]>. Every
pair must pass for a delegated caller to manage the job.

B<An empty list means "not delegable"> — the job is reachable only through the
coarse tree, gated on Sys.Modify. That is the default, and it is the safe
default: a plugin author who forgets this method gets the restrictive answer,
not the permissive one.

=cut

sub required_privs { return [] }

=head2 run_as()

The crontab user field. Fixed by the plugin, never taken from the caller, so a
delegated user cannot escalate by asking for root.

=cut

sub run_as { return 'root' }

=head2 track_default()

Whether runs of this type are captured into journald unless the job says
otherwise. A type whose command is already chatty every minute can turn this
off; almost none should.

=cut

sub track_default { return 1 }

1;
