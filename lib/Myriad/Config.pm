package Myriad::Config;

use strict;
use warnings;

# VERSION
# AUTHORITY

use Object::Pad;

class Myriad::Config;

no indirect qw(fatal);

use utf8;

=encoding utf8

=head1 NAME

Myriad::Config

=head1 DESCRIPTION

Configuration support.

=cut

use feature qw(current_sub);

use Getopt::Long qw(GetOptionsFromArray);
use Config::Any;
use YAML::XS;
use List::Util qw(pairmap);
use Ryu::Observable;
use Log::Any qw($log);

=head1 PACKAGE VARIABLES

=head2 DEFAULTS

The C<< %DEFAULTS >> hash provides base values that will be used if no other
configuration file, external storage or environment variable provides an
alternative.

=cut

# Default values

our %DEFAULTS;

UNITCHECK {
    %DEFAULTS = (
        config_path => 'config.yml',
        redis_uri   => 'redis://localhost:6379',
        log_level   => 'info',
    );
    no strict 'refs';
    for my $k (keys %DEFAULTS) {
        *$k = sub { shift->key($k) };
    }
}

=head2 SHORTCUTS_FOR

The C<< %SHORTCUTS_FOR >> hash allows commandline shortcuts for common parameters.

=cut

our %SHORTCUTS_FOR = (
    config_path => [qw(c)],
);

# Our configuration so far. Populated via L</BUILD>,
# can be updated by other mechanisms later.
has $config;

BUILD (%args) {
    $config //= {};

    # Parameter order in decreasing order of preference:
    # - commandline parameter
    # - environment
    # - config file
    # - defaults
    $log->tracef('Defaults %s, shortcuts %s, args %s', \%DEFAULTS, \%SHORTCUTS_FOR, \%args);
    if($args{commandline}) {
        GetOptionsFromArray(
            $args{commandline},
            $config,
            map {
                join('|', $_, ($SHORTCUTS_FOR{$_} || [])->@*) . '=s',
            } sort keys %DEFAULTS,
        ) or die pod2usage(1);
    }

    $config->{$_} //= $ENV{'MYRIAD_' . uc($_)} for grep { exists $ENV{'MYRIAD_' . uc($_)} } keys %DEFAULTS;

    $config->{config_path} //= $DEFAULTS{config_path};
    if(defined $config->{config_path} and -r $config->{config_path}) {
        my ($override) = Config::Any->load_files({
            files   => [ $config->{config_path} ],
            use_ext => 1
        })->@*;
        $log->debugf('override is %s', $override);
        my %expanded = (sub {
            my ($item, $prefix) = @_;
            my $code = __SUB__;
            $log->tracef('Checking %s with prefix %s', $item, $prefix);
            pairmap {
                ref($b)
                ? $code->(
                    $b,
                    join('_', $prefix // (), $a),
                )
                : ($a => $b)
            } %$item
        })->($override);
        $config->{$_} //= $expanded{$_} for sort keys %expanded;
    }

    $config->{$_} //= $DEFAULTS{$_} for keys %DEFAULTS;

    $config->{$_} = Ryu::Observable->new($config->{$_}) for keys %$config;
    $log->debugf("Config is %s", $config);
}

method key($key) { return $config->{$key} // die 'unknown config key ' . $key }

1;

=head1 AUTHOR

Deriv Group Services Ltd. C<< DERIV@cpan.org >>.

See L<Myriad/CONTRIBUTORS> for full details.

=head1 LICENSE

Copyright Deriv Group Services Ltd 2020. Licensed under the same terms as Perl itself.

