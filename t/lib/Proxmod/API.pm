package Proxmod::API;

use strict;
use warnings;

use Proxmod::Log qw(log_debug log_info log_warn log_error);

our $VERSION = '0.2.0';

# The surface a backend extension codes against.
#
# Extensions do not call PVE::RESTHandler->register_method directly. They could
# — nothing stops them — but Proxmox's registration rules are unforgiving in
# ways that only show up as a dead daemon or a silently unreachable endpoint,
# and every one of those rules has a cheaper check available before the fact:
#
#   * register_method DIES on a duplicate path, and it dies at INIT time inside
#     pvedaemon. Two extensions choosing the same path, or one extension loaded
#     twice, would take the daemon down.
#   * A method with no `permissions` key is silently root@pam-only. That is not
#     an error, it is not logged, and it is the single most common way an
#     extension appears to work for its author and for nobody else.
#   * A level of the path tree holds EITHER named folders OR one {param} regex,
#     never both, and a subtree behind `fragmentDelimiter => ''` swallows every
#     remaining path fragment. Register in the wrong place and the route simply
#     never resolves.
#
# See docs/pve-facts.md [PVE-F-050] and [PVE-F-051] for the source these are
# read out of.
#
# THE NAMESPACE RULE. proxmod claims exactly one path segment from Proxmox —
# `proxmod` — under each scope it supports, and every extension lives beneath
# it, at its own extension id:
#
#     /nodes/{node}/proxmod/<id>/...
#     /cluster/proxmod/<id>/...
#
# That is what makes collisions between two extensions structurally impossible
# rather than a matter of good manners: ids are unique in the registry, so two
# extensions cannot be handed the same path. It also means a Proxmox upgrade
# that adds a new endpoint can only ever collide with the single name `proxmod`.

# Package name pattern. Every value that reaches `require` or a method call must
# survive this, because a module name can arrive from a manifest read off disk
# and is therefore tainted [PVE-F-042].
my $RE_PACKAGE = qr/\A([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)\z/;

our $SEGMENT = 'proxmod';

# `probe` is `prefix` with the {param} components replaced by literals, so it
# can be pushed through find_handler to ask what a real request would resolve
# to. The value is arbitrary; it only has to match the parameter's regex, which
# for a bare {node} is \S+.
our %SCOPES = (
    node => {
        parent => 'PVE::API2::Nodes::Nodeinfo',
        root => 'Proxmod::API::Node',
        prefix => "/nodes/{node}/$SEGMENT",
        probe => "/nodes/proxmod-probe/$SEGMENT",
        params => {
            node => { type => 'string', description => 'The cluster node name.' },
        },
    },
    cluster => {
        parent => 'PVE::API2::Cluster',
        root => 'Proxmod::API::Cluster',
        prefix => "/cluster/$SEGMENT",
        probe => "/cluster/$SEGMENT",
        params => {},
    },
);

# The API tree root, and the class every path walk starts from.
our $ROOT_CLASS = 'PVE::API2';

# scope => 1 once the root class exists and is mounted into PVE's tree.
my %root_ready;

# scope => { id => { subclass, path } }. Process-global on purpose: PVE's own
# registration is, and this is what lets one extension's mount be reported as a
# conflict with another's rather than as a mysterious die.
my %mounts;

# "class method path" => full path, for idempotent re-registration.
my %methods;

sub _reset {
    %root_ready = ();
    %mounts = ();
    %methods = ();
    return;
}

sub scopes { return sort keys %SCOPES }

# Everything registered so far, for the root index and for proxmod-verify.
sub registrations {
    my @out;
    for my $scope (sort keys %mounts) {
        for my $id (sort keys %{ $mounts{$scope} }) {
            push @out, { scope => $scope, id => $id, %{ $mounts{$scope}{$id} } };
        }
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# The proxmod root classes
# ---------------------------------------------------------------------------

# Created at runtime rather than as .pm files with `use base 'PVE::RESTHandler'`,
# because that would make Proxmod::API unloadable outside a PVE daemon — and
# proxmod-verify, the test suite and `perl -c` all load it there.
sub _ensure_root {
    my ($scope) = @_;

    my $spec = $SCOPES{$scope}
        or die "unknown scope '$scope' (known: " . join(', ', scopes()) . ")\n";

    return $spec->{root} if $root_ready{$scope};

    die "PVE::RESTHandler is not loaded; this is not a Proxmox daemon\n"
        if !PVE::RESTHandler->can('register_method');

    my $parent = $spec->{parent};
    die "$parent is not available in this process, so scope '$scope' cannot be used\n"
        if !$parent->can('register_method');

    my $root = $spec->{root};

    {
        no strict 'refs'; ## no critic (ProhibitNoStrict)
        push @{"${root}::ISA"}, 'PVE::RESTHandler'
            if !grep { $_ eq 'PVE::RESTHandler' } @{"${root}::ISA"};
    }

    # Registered before the mount, so that the moment the mount lands the path
    # already resolves to something.
    $root->register_method({
        name => 'index',
        path => '',
        method => 'GET',
        # Any authenticated user may ask which extensions exist. This lists
        # names and versions only; the extensions' own endpoints do their own
        # access control, which is where it belongs.
        permissions => { user => 'all' },
        description => 'Index of proxmod extensions registered at this level.',
        parameters => {
            additionalProperties => 0,
            properties => { %{ $spec->{params} } },
        },
        returns => {
            type => 'array',
            items => {
                type => 'object',
                properties => { subdir => { type => 'string' } },
            },
            links => [{ rel => 'child', href => '{subdir}' }],
        },
        code => sub {
            my $out = [];
            for my $id (sort keys %{ $mounts{$scope} || {} }) {
                push @$out, {
                    subdir => $id,
                    handler => $mounts{$scope}{$id}{subclass},
                };
            }
            return $out;
        },
    });

    $parent->register_method({ subclass => $root, path => $SEGMENT });

    $root_ready{$scope} = 1;

    # Did the mount actually land where we think it did? If Proxmox ever moves
    # this parent, or another framework has already claimed the name, this is
    # where it shows up — as a warning in the journal rather than as an endpoint
    # that quietly 404s.
    my ($resolved) = _resolve('GET', $spec->{probe});
    if (!defined $resolved) {
        log_warn("scope '$scope': mounted $root under $parent, but $spec->{probe}"
            . ' does not resolve; endpoints in this scope will not be reachable');
    } elsif ($resolved ne $root) {
        log_warn("scope '$scope': $spec->{probe} resolves to $resolved, not $root;"
            . ' something else has claimed this path');
    } else {
        log_debug("scope '$scope': $spec->{prefix} is served by $root");
    }

    return $root;
}

# What does a real request to this path land on? Returns the handler class and
# the method info hash PVE would dispatch to, or nothing.
#
# The info hash is the same reference that was handed to register_method, which
# makes it an exact identity check rather than a description that can match by
# accident. That distinction is load-bearing: inside a subtree with
# `fragmentDelimiter => ''` a deeper path resolves to the RIGHT class and the
# WRONG method [PVE-F-051], and comparing class names alone would call that
# healthy.
sub _resolve {
    my ($method, $path) = @_;

    my ($class, $info);
    local $@;
    eval {
        local $SIG{__DIE__} = 'DEFAULT';
        ($class, $info) = $ROOT_CLASS->find_handler($method, $path, {});
        1;
    };

    return ($class, $info);
}

# ---------------------------------------------------------------------------
# The extension-facing object
# ---------------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;

    my $id = $args{id};
    die "Proxmod::API->new: an extension id is required\n"
        if !defined $id || $id eq '';

    return bless {
        id => $id,
        version => $args{version},
        daemon => $args{daemon},
        # subclass => probe path, so add_method can check its own routes.
        probes => {},
    }, $class;
}

sub id { return $_[0]->{id} }
sub daemon { return $_[0]->{daemon} }

# Give this extension its own subtree of the API. Returns the path it was given.
# Idempotent: mounting the same class in the same scope twice is a no-op, and
# mounting a *different* class over it is an error rather than a silent win.
sub mount {
    my ($self, %args) = @_;

    my $id = $self->{id};
    my $scope = defined $args{scope} ? $args{scope} : 'node';

    my $spec = $SCOPES{$scope}
        or die "mount: unknown scope '$scope' (known: " . join(', ', scopes()) . ")\n";

    my $subclass = $args{subclass};
    die "mount: a subclass is required\n" if !defined $subclass || $subclass eq '';

    my ($clean) = ($subclass =~ $RE_PACKAGE);
    die "mount: '$subclass' is not a valid package name\n" if !defined $clean;
    $subclass = $clean; # untainted [PVE-F-042]

    die "mount: $subclass is not loaded, or is not a PVE::RESTHandler subclass\n"
        if !$subclass->can('register_method');

    if (my $prev = $mounts{$scope} && $mounts{$scope}{$id}) {
        die "mount: $spec->{prefix}/$id is already served by $prev->{subclass}\n"
            if $prev->{subclass} ne $subclass;
        log_debug("$id: already mounted at $prev->{path}");
        return $prev->{path};
    }

    my $root = _ensure_root($scope);

    # From here on PVE's registry is being mutated, so everything that can be
    # checked has been checked already.
    $root->register_method({ subclass => $subclass, path => $id });

    my $path = "$spec->{prefix}/$id";
    $mounts{$scope}{$id} = { subclass => $subclass, path => $path };
    $self->{probes}{$subclass} = "$spec->{probe}/$id";

    log_info("$id: mounted $subclass at $path");

    return $path;
}

# Register one endpoint. Takes PVE::RESTHandler->register_method's info hash,
# plus a `class` naming the handler class it belongs to.
sub add_method {
    my ($self, %args) = @_;

    my $id = $self->{id};

    my $class = delete $args{class};
    die "add_method: a class is required\n" if !defined $class || $class eq '';

    my ($clean) = ($class =~ $RE_PACKAGE);
    die "add_method: '$class' is not a valid package name\n" if !defined $clean;
    $class = $clean;

    die "add_method: $class is not loaded, or is not a PVE::RESTHandler subclass\n"
        if !$class->can('register_method');

    die "add_method: a name is required\n"
        if !defined $args{name} || $args{name} eq '';
    die "add_method: a path is required (use '' for the subtree root)\n"
        if !defined $args{path};
    die "add_method: code must be a CODE reference\n"
        if ref($args{code}) ne 'CODE';

    $args{method} = 'GET' if !defined $args{method};
    die "add_method: '$args{method}' is not an HTTP method PVE dispatches\n"
        if $args{method} !~ m/\A(?:GET|POST|PUT|DELETE)\z/;

    _check_permissions($id, \%args);

    # Registration is process-global, and register_method dies on a duplicate.
    # An extension listed twice, or a module loaded under two names, must not be
    # able to take pvedaemon down over it.
    my $key = join(' ', $class, $args{method}, $args{path});
    if (exists $methods{$key}) {
        log_debug("$id: $args{method} $class/$args{path} is already registered");
        return $methods{$key};
    }

    # Keep the exact reference: register_method decorates it in place, and the
    # post-check below compares against what find_handler hands back.
    my $info = {%args};
    $class->register_method($info);
    $methods{$key} = 1;

    my $probe = $self->{probes}{$class};
    if (!defined $probe) {
        # A class the extension mounted somewhere of its own accord, or nested
        # under one it did mount. Nothing to check against, so say so once
        # rather than pretending the route was verified.
        log_debug("$id: registered $args{method} $class/$args{path};"
            . ' not checking the live route, this class was not mounted by proxmod');
        return 1;
    }

    my $full = join('/', $probe, $args{path});
    $full =~ s{/+\z}{};
    $methods{$key} = $full;

    # The post-check. Everything above is about registration succeeding; this is
    # about the endpoint being reachable, which is a different question — a path
    # behind a greedy `fragmentDelimiter => ''` subtree registers perfectly and
    # then never resolves [PVE-F-051].
    my ($resolved, $resolved_info) = _resolve($args{method}, $full);
    if (!defined $resolved) {
        log_warn("$id: registered $args{method} $args{path} on $class, but a request"
            . " to it does not resolve to any handler; the endpoint is unreachable");
    } elsif ($resolved ne $class) {
        log_warn("$id: registered $args{method} $args{path} on $class, but a request"
            . " to it resolves to $resolved; the endpoint is shadowed");
    } elsif (!defined $resolved_info || $resolved_info != $info) {
        my $other = (defined $resolved_info && defined $resolved_info->{name})
            ? $resolved_info->{name} : 'something else';
        log_warn("$id: registered $args{method} $args{path} on $class, but a request"
            . " to it is answered by '$other' on the same class; the endpoint is shadowed");
    } else {
        log_debug("$id: $args{method} $args{path} on $class is reachable");
    }

    return $full;
}

# A method with no `permissions` key is not an error to Proxmox — it is a
# working endpoint that only root@pam may call, with nothing said about it
# anywhere [PVE-F-050]. proxmod makes the choice explicit instead: pass
# `permissions => undef` and you get PVE's root-only default, deliberately.
sub _check_permissions {
    my ($id, $args) = @_;

    die "add_method: every method must carry a 'permissions' key."
        . " Pass `permissions => undef` for root\@pam-only, `{ user => 'all' }`"
        . " for any authenticated user, or `{ check => [...] }` for an ACL check.\n"
        if !exists $args->{permissions};

    my $perm = $args->{permissions};
    return if !defined $perm;

    die "add_method: 'permissions' must be a hash reference or undef\n"
        if ref($perm) ne 'HASH';

    die "add_method: 'permissions' needs a 'user' or a 'check'\n"
        if !defined $perm->{user} && !defined $perm->{check};

    if (defined $perm->{user}) {
        die "add_method: permissions user '$perm->{user}' is not one PVE understands"
            . " ('all' or 'world')\n"
            if $perm->{user} !~ m/\A(?:all|world)\z/;

        # 'world' means the endpoint is reachable with no login at all. PVE uses
        # it for the ticket endpoint. An extension almost never wants it, and if
        # it does, an administrator should be able to find out from the journal.
        log_warn("$id: $args->{name} is registered with permissions user => 'world';"
            . ' it can be called without authenticating')
            if $perm->{user} eq 'world';
    }

    return;
}

# Would a request to this path reach this class? Exposed because an extension
# that mounts something itself, or nests subclasses, can check its own work —
# and because proxmod-verify replays the same question against a live daemon.
sub assert_route {
    my ($self, $method, $path, $expect) = @_;

    my ($resolved) = _resolve($method, $path);

    return (1, "$method $path is served by $expect")
        if defined $resolved && defined $expect && $resolved eq $expect;

    return (0, "$method $path does not resolve to any handler")
        if !defined $resolved;

    return (0, "$method $path is served by $resolved, not $expect");
}

1;
