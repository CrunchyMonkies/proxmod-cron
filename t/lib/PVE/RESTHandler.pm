package PVE::RESTHandler;

use strict;
use warnings;

# A test double for Proxmox's PVE::RESTHandler.
#
# PROVENANCE. register_method(), map_path_to_methods() and find_handler() below
# are copied from pve-manager 9.1.1's libpve-common-perl
# (/usr/share/perl5/PVE/RESTHandler.pm), with only the syslog call replaced.
# They are not a reimplementation and must not be "improved": the whole point of
# this file is that Proxmod::API's tests run against Proxmox's real registration
# rules, including the ones that make it die. Those rules are the reason
# Proxmod::API exists, so a friendlier stub would test nothing.
#
# Re-derive after a PVE upgrade with:
#   scripts/extract-pve-source.sh --iso <iso> --cat libpve-common-perl \
#       ./usr/share/perl5/PVE/RESTHandler.pm
#
# Everything else here (handle, the accessors, _reset) is deliberately a stub:
# proxmod does not exercise PVE's JSON Schema validation or its CLI formatting,
# and pulling those in would drag most of libpve-common-perl into a unit test.

my $method_registry = {};
my $method_by_name = {};
my $method_path_lookup = {};

# The real one calls syslog('err', ...) from map_path_to_methods' error path.
our @ERRORS;

sub register_method {
    my ($self, $info) = @_;

    my $match_re = [];
    my $match_name = [];

    my $errprefix;

    my $method;
    if ($info->{subclass}) {
        $errprefix = "register subclass $info->{subclass} at ${self}/$info->{path} -";
        $method = 'SUBCLASS';
    } else {
        $errprefix = "register method ${self}/$info->{path} -";
        $info->{method} = 'GET' if !$info->{method};
        $method = $info->{method};

        # apply default value
        $info->{allowtoken} = 1 if !defined($info->{allowtoken});
    }

    $method_path_lookup->{$self} = {} if !defined($method_path_lookup->{$self});
    my $path_lookup = $method_path_lookup->{$self};

    die "$errprefix no path" if !defined($info->{path});

    foreach my $comp (split(/\/+/, $info->{path})) {
        die "$errprefix path compoment has zero length\n" if $comp eq '';
        my ($name, $regex);
        if ($comp =~ m/^\{([\w-]+)(?::(.*))?\}$/) {
            $name = $1;
            $regex = $2 ? $2 : '\S+';
            push @$match_re, $regex;
            push @$match_name, $name;
        } else {
            $name = $comp;
            push @$match_re, $name;
            push @$match_name, undef;
        }

        if ($regex) {
            $path_lookup->{regex} = {} if !defined($path_lookup->{regex});

            my $old_name = $path_lookup->{regex}->{match_name};
            die "$errprefix found changed regex match name\n"
                if defined($old_name) && ($old_name ne $name);
            my $old_re = $path_lookup->{regex}->{match_re};
            die "$errprefix found changed regex\n"
                if defined($old_re) && ($old_re ne $regex);
            $path_lookup->{regex}->{match_name} = $name;
            $path_lookup->{regex}->{match_re} = $regex;

            die "$errprefix path match error - regex and fixed items\n"
                if defined($path_lookup->{folders});

            $path_lookup = $path_lookup->{regex};

        } else {
            $path_lookup->{folders}->{$name} = {} if !defined($path_lookup->{folders}->{$name});

            die "$errprefix path match error - regex and fixed items\n"
                if defined($path_lookup->{regex});

            $path_lookup = $path_lookup->{folders}->{$name};
        }
    }

    die "$errprefix duplicate method definition\n"
        if defined($path_lookup->{$method});

    if ($method eq 'SUBCLASS') {
        foreach my $m (qw(GET PUT POST DELETE)) {
            die "$errprefix duplicate method definition SUBCLASS and $m\n" if $path_lookup->{$m};
        }
    }
    $path_lookup->{$method} = $info;

    $info->{match_re} = $match_re;
    $info->{match_name} = $match_name;

    $method_by_name->{$self} = {} if !defined($method_by_name->{$self});

    if ($info->{name}) {
        die "$errprefix method name already defined\n"
            if defined($method_by_name->{$self}->{ $info->{name} });

        $method_by_name->{$self}->{ $info->{name} } = $info;
    }

    push @{ $method_registry->{$self} }, $info;
}

sub map_path_to_methods {
    my ($class, $stack, $uri_param, $pathmatchref) = @_;

    my $path_lookup = $method_path_lookup->{$class};

    if (defined($pathmatchref)) {
        $$pathmatchref = '' if !$$pathmatchref;
    }

    while (defined(my $comp = shift @$stack)) {
        return undef if !$path_lookup; # not registerd?
        if ($path_lookup->{regex}) {
            my $name = $path_lookup->{regex}->{match_name};
            my $regex = $path_lookup->{regex}->{match_re};

            return undef if $comp !~ m/^($regex)$/;
            $uri_param->{$name} = $1;
            $path_lookup = $path_lookup->{regex};
            $$pathmatchref .= '/{' . $name . '}' if defined($pathmatchref);
        } elsif ($path_lookup->{folders}) {
            $path_lookup = $path_lookup->{folders}->{$comp};
            $$pathmatchref .= '/' . $comp if defined($pathmatchref);
        } else {
            die "internal error";
        }

        return undef if !$path_lookup;

        if (my $info = $path_lookup->{SUBCLASS}) {
            $class = $info->{subclass};

            my $fd = $info->{fragmentDelimiter};

            if (defined($fd)) {
                # we only support the empty string '' (match whole URI)
                die "unsupported fragmentDelimiter '$fd'"
                    if $fd ne '';

                $stack = [join('/', @$stack)] if scalar(@$stack) > 1;
            }
            $path_lookup = $method_path_lookup->{$class};
        }
    }

    return undef if !$path_lookup;

    return ($class, $path_lookup);
}

sub find_handler {
    my ($class, $method, $path, $uri_param, $pathmatchref) = @_;

    my $stack = [grep { length($_) > 0 } split('\/+', $path)]; # skip empty fragments

    my ($handler_class, $path_info);
    eval {
        ($handler_class, $path_info) =
            $class->map_path_to_methods($stack, $uri_param, $pathmatchref);
    };
    my $err = $@;
    push(@ERRORS, $err) if $err;

    return undef if !($handler_class && $path_info);

    my $method_info = $path_info->{$method};

    return undef if !$method_info;

    return ($handler_class, $method_info);
}

sub method_attributes {
    my ($self) = @_;
    return $method_registry->{$self};
}

sub map_method_by_name {
    my ($self, $name) = @_;
    my $info = $method_by_name->{$self}->{$name};
    die "no such method '${self}::$name'\n" if !$info;
    return $info;
}

# STUB. The real handle() validates $param against the method's JSON Schema,
# untaints it, and optionally validates the result. proxmod never reaches that
# code, so the tests only need the call itself.
sub handle {
    my ($self, $info, $param) = @_;
    die "Method lookup failed\n" if !($info->{name} && $info->{code});
    return $info->{code}->($param);
}

# Test-only. Registration is process-global in the real RESTHandler too, so each
# test that builds a tree has to start from a clean one.
sub _reset {
    $method_registry = {};
    $method_by_name = {};
    $method_path_lookup = {};
    @ERRORS = ();
    return;
}

1;
