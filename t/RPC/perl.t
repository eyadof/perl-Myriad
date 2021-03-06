use strict;
use warnings;

use Ryu::Async;
use IO::Async::Loop;
use Future::AsyncAwait;

use Test::More;
use Test::MemoryGrowth;

use Syntax::Keyword::Try;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => 'info';

# Myriad::RPC should be included to load exceptions
use Myriad::RPC;
use Myriad::Transport::Perl;
use Myriad::RPC::Implementation::Perl;

my $loop = IO::Async::Loop->new;

my $message_args = {
    rpc        => 'test',
    message_id => 1,
    who        => 'client',
    deadline   => time,
    args       => '{}',
    stash      => '{}',
    trace      => '{}'
};

$loop->add(my $ryu = Ryu::Async->new);
$loop->add(my $transport = Myriad::Transport::Perl->new());
$loop->add(my $rpc = Myriad::RPC::Implementation::Perl->new(transport => $transport));

isa_ok($rpc, 'IO::Async::Notifier');

my $sink = $ryu->sink(label=> 'rpc::test');

$sink->source->map(async sub {
    await $rpc->reply_success('test::service', shift, {ok => 1});
})->resolve()->completed->retain();

$rpc->create_from_sink(method => 'test', sink => $sink, service => 'test::service');
$rpc->start()->retain;

subtest 'it should return method not found' => sub {
    (async sub {

        my $response = $loop->new_future;
        $message_args->{rpc} = 'not_found';

        my $sub  = await $transport->subscribe('client');
        await $transport->add_to_stream('test::service', $message_args->%*);
        await $sub->take(1)->each(sub {
            my $message = shift;
            like($message, qr/Method not found/, 'rpc not found was returned');
        })->completed;

    })->()->get();
};

subtest 'it should propagate the message correctly' => sub {
    (async sub {
        $message_args->{rpc} = 'test';

        my $sub = await $transport->subscribe('client');
        my $id =    await $transport->add_to_stream('test::service', $message_args->%*);
        await $sub->take(1)->each(sub {
            my $message = shift;
            like($message, qr{\\"ok\\":1}, 'message has been propagated correctly');
        })->completed;
    })->()->get;
};

subtest 'it should shutdown cleanly' => sub {
    (async sub {
        my $f = await $rpc->stop;
        ok($f, 'it should stop');
    })->()->get();
};

done_testing;

