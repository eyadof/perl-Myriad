package Myriad::Subscription::Implementation::Redis;

# VERSION
# AUTHORITY

use Myriad::Class extends => qw(IO::Async::Notifier);

use JSON::MaybeUTF8 qw(:v1);
use Unicode::UTF8 qw(decode_utf8 encode_utf8);
use Myriad::Util::UUID;

use Role::Tiny::With;

with 'Myriad::Role::Subscription';

has $redis;

has $uuid;

# Group mapping
has $group = { };

has $queues = [ ];

has $should_shutdown = 0;
has $stopped;

BUILD {
    $uuid = Myriad::Util::UUID::uuid();
}

method configure (%args) {
    $redis = delete $args{redis} if exists $args{redis};
    $self->next::method(%args);
}

async method create_from_source (%args) {
    my $src = delete $args{source} or die 'need a source';
    my $service = delete $args{service} or die 'need a service';

    my $stream = $service . '/' . $args{channel};
    $src->each(sub {
        $log->tracef('sub has an event! %s', $_);
        $redis->xadd(
            encode_utf8($stream) => '*',
            data => encode_json_utf8($_),
        )->retain;
    });
    return;
}

method create_from_sink (%args) {
    my $sink = delete $args{sink} or die 'need a sink';
    my $remote_service = $args{from} || $args{service};
    my $stream = $remote_service . '/' . $args{channel};
    $log->tracef('created sub thing from sink');
    push $queues->@*, {
        key => $stream,
        client => $args{client},
        sink => $sink
    };
}

async method start {
    $stopped = $self->loop->new_future(label => 'subscription::redis::stopped');
    while (1) {
        if($queues->@*) {
            my $item = shift $queues->@*;
            push $queues->@*, $item;
            $log->tracef('Will readgroup on %s', $item);
            my $stream = $item->{key};
            my $sink = $item->{sink};
            my $client = $item->{client};
            unless(exists $group->{$stream}{$item->{client}}) {
                try {
                    $log->tracef('Creating new group for stream %s client %s', $stream, $item->{client});
                    await $redis->create_group($stream, $item->{client}, '0');
                } catch {
                    die $@ unless $@ =~ /^BUSYGROUP/;
                }
                $group->{$stream}{$item->{client}} = 1;
            }
            my ($streams) = await $redis->xreadgroup(
                BLOCK   => 2500,
                GROUP   => $client, $uuid,
                COUNT   => 10, # $self->batch_count,
                STREAMS => (
                    $stream, '>'
                )
            );
            $log->tracef('Read group %s', $streams);
            for my $delivery ($streams->@*) {
                my ($stream, $data) = $delivery->@*;
                for my $item ($data->@*) {
                    my ($id, $args) = $item->@*;
                    $log->tracef(
                        'Item from stream %s is ID %s and args %s',
                        $stream,
                        $id,
                        $args
                    );
                    if($args) {
                        push @$args, ("transport_id", $id);
                        $args->[1] = decode_json_utf8($args->[1]);
                        $sink->source->emit($args);
                        await $redis->ack($stream, $client, $id);
                    }
                }
            }
        } else {
            await $self->loop->delay_future(after => 1);
        }

        if($should_shutdown) {
            $stopped->done;
            last;
        }
    }
}

async method stop {
    $should_shutdown = 1;
    await $stopped;
}

1;

__END__

1;

