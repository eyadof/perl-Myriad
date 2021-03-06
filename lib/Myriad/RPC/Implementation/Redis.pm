package Myriad::RPC::Implementation::Redis;

use strict;
use warnings;

# VERSION
# AUTHORITY

use Role::Tiny::With;
with 'Myriad::Role::RPC';

use Myriad::Class extends => qw(IO::Async::Notifier);

use Future::Utils qw(fmap0);

use constant RPC_SUFFIX => '/rpc';
use Exporter qw(import);
our @EXPORT_OK = qw(stream_name_from_service);

=head1 NAME

Myriad::RPC::Implementation::Redis - microservice RPC Redis implementation.

=head1 DESCRIPTION

=cut

use Sys::Hostname qw(hostname);
use Scalar::Util qw(blessed);

use Myriad::Exception::InternalError;
use Myriad::RPC::Message;

has $redis;
method redis { $redis }

has $group_name;
method group_name { $group_name }

has $whoami;
method whoami { $whoami }

has $rpc_methods;

sub service_name_from_stream ($stream) {
    my $pattern = RPC_SUFFIX . '$';
    $stream =~ s/$pattern//;
    return $stream;
}

sub stream_name_from_service ($service) {
    return $service . RPC_SUFFIX;
}

method configure (%args) {
    $redis = delete $args{redis} if exists $args{redis};
    $whoami = hostname();
    $group_name = 'processors';
}

async method start () {
    return unless $rpc_methods;
    await fmap0 {
            my $stream = stream_name_from_service(shift);
            $self->redis->create_group($stream,$self->group_name);
    } foreach => [keys $rpc_methods->%*], concurrent => 8;

    await $self->listener;
}

method create_from_sink (%args) {
    my $sink   = $args{sink} // die 'need a sink';
    my $method = $args{method} // die 'need a method name';
    my $service = $args{service} // die 'need a service name';

    $rpc_methods->{$service}->{$method} = $sink;
}


async method stop () {
    $self->listener->cancel;
}

async method listener () {
    # ordering is not important
    my @streams = map {stream_name_from_service($_)} keys $rpc_methods->%*;
    my %stream_config = (
        group  => $self->group_name,
        client => $self->whoami
    );

    my $incoming_request = $self->redis->iterate(streams => \@streams, %stream_config);

    # xpending doesn't accept multiple streams like xreadgroup
    for my $stream (@streams) {
        $incoming_request->merge(
            $self->redis->pending(stream => $stream, %stream_config)
        );
    }

    try {
        await $incoming_request
            ->map(sub {
                my $item = $_;
                push $item->{data}->@*, ('transport_id', $item->{id});
                my $service = service_name_from_stream($item->{stream});
                try {
                    return { service => $service, message => Myriad::RPC::Message::from_hash($item->{data}->@*)};
                } catch ($error) {
                    use Data::Dumper;
                    warn Dumper($error);
                    $error = Myriad::Exception::InternalError->new($error) unless blessed($error) and $error->isa('Myriad::Exception');
                    return { service => $service, error => $error, id => $item->{id} }
                }
            })->map(async sub {
                if(my $error = $_->{error}) {
                    $log->tracef("error while parsing the incoming messages: %s", $error->message);
                    await $self->drop($_->{service}, $_->{id});
                } else {
                    my $message = $_->{message};
                    my $service  = $_->{service};
                    if (my $sink = $rpc_methods->{$service}->{$message->rpc}) {
                        $sink->emit($message);
                    } else {
                        my $error = Myriad::Exception::RPC::MethodNotFound->new(reason => "No such method: " . $message->rpc);
                        await $self->reply_error($service, $message, $error);
                    }
                }
            })->resolve->completed;
    } catch ($e) {
        $log->errorf("RPC listener stopped due to: %s", $e);
    }
}

async method reply ($service, $message) {
    my $stream = stream_name_from_service($service);
    try {
        await $self->redis->publish($message->who, $message->as_json);
        await $self->redis->ack($stream, $self->group_name, $message->transport_id);
    } catch ($e) {
        $log->warnf("Failed to reply to client due: %s", $e);
        return;
    }
}

async method reply_success ($service, $message, $response) {
    $message->response = { response => $response };
    await $self->reply($service, $message);
}

async method reply_error ($service, $message, $error) {
    $message->response = { error => { category => $error->category, message => $error->message, reason => $error->reason } };
    await $self->reply($service, $message);
}

async method drop ($service, $id) {
    $log->tracef("Going to drop message: %s", $id);
    my $stream = stream_name_from_service($service);
    await $self->redis->ack($stream, $self->group_name, $id);
}

async method has_pending_requests ($service) {
    my $stream = stream_name_from_service($service);
    my $stream_info = await $self->redis->pending_messages_info($stream, $self->group_name);
    if($stream_info->[0]) {
        for my $consumer ($stream_info->[3]->@*) {
            return $consumer->[1] if $consumer->[0] eq $self->whoami;
        }
    }

    return 0;
}

1;

=head1 AUTHOR

Deriv Group Services Ltd. C<< DERIV@cpan.org >>.

See L<Myriad/CONTRIBUTORS> for full details.

=head1 LICENSE

Copyright Deriv Group Services Ltd 2020-2021. Licensed under the same terms as Perl itself.

