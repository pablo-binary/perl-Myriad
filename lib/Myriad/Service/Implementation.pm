package Myriad::Service::Implementation;

use strict;
use warnings;

# VERSION
# AUTHORITY

use Object::Pad;
use Future;
use Future::AsyncAwait;
use Syntax::Keyword::Try;

use Myriad::RPC::Implementation::Redis;
use Myriad::Exception;

class Myriad::Service::Implementation extends IO::Async::Notifier;

use utf8;

=encoding utf8

=head1 NAME

Myriad::Service - microservice coördination

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

use Log::Any qw($log);
use List::Util qw(min);
use Myriad::Service::Attributes;

# Only defer up to this many seconds between batch iterations
use constant MAX_EXPONENTIAL_BACKOFF => 2;

sub MODIFY_CODE_ATTRIBUTES {
    my ($class, $code, @attrs) = @_;
    Myriad::Service::Attributes->apply_attributes(
        class => $class,
        code => $code,
        attributes => \@attrs
    );
}

=head1 ATTRIBUTES

These methods return instance variables.

=head2 ryu

Provides a common L<Ryu::Async> instance.

=cut

has $ryu;

method ryu () { $ryu }

=head2 redis

The L<Myriad::Storage> instance.

=cut

has $redis;
method redis () { $redis }

=head2 myriad

The L<Myriad> instance which owns this service. Stored internally as a weak reference.

=cut

has $myriad;
method myriad () { $myriad }

=head2 service_name

The name of the service, defaults to the package name.

=cut

has $service_name;
method service_name () { $service_name //= lc(ref($self) =~ s{::}{_}gr) }

has $rpc;

=head1 METHODS

=head2 configure

Populate internal configuration.

=cut

method configure(%args) {
    $redis = delete $args{redis} if exists $args{redis};
    $service_name = delete $args{name} if exists $args{name};
    Scalar::Util::weaken($myriad = delete $args{myriad}) if exists $args{myriad};
    $self->next::method(%args);
}

=head2 _add_to_loop

Apply this service to the current event loop.

This will trigger a number of actions:

=over 4

=item * initial startup

=item * first diagnostics check

=item * if successful, batch and subscription registration will occur

=back

=cut

has %active_batch;
has %rpc_map;

method _add_to_loop($loop) {
    $self->add_child(
        $ryu = Ryu::Async->new
    );

    $self->add_child(
        $rpc = Myriad::RPC::Implementation::Redis->new(redis => $redis, service => ref($self), ryu => $ryu)
    );

    if (my $rpc_calls = Myriad::Registry->rpc_for(ref($self))) {
        foreach my $method (keys $rpc_calls->%*) {
            my $code = $rpc_calls->{$method};
            my $src = $ryu->source(lable => "rpc:$method");
            $rpc_map{$method} = [
                $src,
                $self->setup_rpc($code, $src)
            ];
        }

        $self->setup_default_routes();
        $rpc->{rpc_map} = \%rpc_map;
    }

    if (my $batches = Myriad::Registry->batches_for(ref($self))) {
        for my $k (keys $batches->%*) {
            $log->tracef('Starting batch process %s for %s', $k, ref($self));
            my $code = $batches->{$k};
            my $src = $self->ryu->source(label => 'batch:' . $k);
            $active_batch{$k} = [
                $src,
                $self->process_batch($k, $code, $src)
            ];
        }
    }

    $self->next::method($loop);
}

method setup_rpc($code, $src) {
    $src->map(async sub {
        my $message = shift;
        try {
            my $data = await $self->$code($message->args->%*);
            await $rpc->reply_success($message, $data);
        } catch ($e) {
            await $rpc->reply_error($message, $e);
        }
    })->resolve->retain();
}


=head1 ASYNC METHODS

=cut

async method process_batch($k, $code, $src) {
    my $backoff;
    $log->tracef('Start batch processing for %s', $k);
    while (1) {
        await $src->unblocked;
        my $data = await $self->$code;
        if ($data->@*) {
            $backoff = 0;
            $src->emit($_) for $data->@*;
            # Defer next processing, give other events a chance
            await $self->loop->delay_future(after => 0);
        }
        else {
            $backoff = min(MAX_EXPONENTIAL_BACKOFF, ($backoff || 0.02) * 2);
            $log->tracef('Batch for %s returned no results, delaying for %dms before retry', $k, $backoff * 1000.0);
            await $self->loop->delay_future(
                after => $backoff
            );
        }
    }
}


method setup_default_routes() {
    my $error_src = $ryu->source(label => "rpc:__ERROR");
    $rpc_map{__ERROR} = [
        $error_src,
        async sub {
            await $rpc->reply_error($_->{message}, $_->{error});
        }];


    my $dead_src = $ryu->source(lable => "rpc:__DEAD_MSG");

    $rpc_map{__DEAD_MSG} = [
        $dead_src,
        async sub {
            await $rpc->drop(@_);
        }];

    for my $key (qw /__ERROR __DEAD_MSG/) {
        $rpc_map{$key}->[0]->map(async sub {
           try {
               await $rpc_map{$key}->[1]($_);
           } catch ($e) {
               $log->warnf("Failed to handle RPC error $key due: %s", $e);
           }
        })->resolve->retain();
    }
}

=head2 startup

Start the service and perform any operation needed before announcing the service as ready to start

=cut

async method startup {
    await $rpc->start();
};

=head2 diagnostics

Runs any internal diagnostics.

=cut

async method diagnostics {
    return;
}

=head2 shutdown

Gracefully shut down the service by

- stop accepting more requests

- finish the pending requests

=cut

async method shutdown {
    try {
        await Future->wait_any($self->loop->timeout_future(after => 30), $rpc->stop);
    } catch ($error) {
        $log->warnf("Failed to stop accepting requests we might end up with unfinished requests due: %s", $error);
    }

    try {
        await Future->wait_any($self->loop->timeout_future(after => 60 * 3), (async sub {
            while ( await $rpc->has_pending_requests ) {
                await $self->loop->delay_future(after => 30);
            }
        })->());
    } catch ($error) {
        $log->warnf("Failed to wait for all requests to finish due: %s, unclean shutdown", $error);
    }
}

1;

=head1 AUTHOR

Deriv Group Services Ltd. C<< DERIV@cpan.org >>.

See L<Myriad/CONTRIBUTORS> for full details.

=head1 LICENSE

Copyright Deriv Group Services Ltd 2020. Licensed under the same terms as Perl itself.

