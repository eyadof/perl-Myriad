package Myriad::Service::Config;

use strict;
use warnings;

our $CONFIG_REGISTRY;

use Future::AsyncAwait;
use Future::Utils qw(fmap0);

use Ryu::Observable;
use Log::Any qw($log);

use Myriad::Util::Secret;
use Myriad::Exception::Builder category => 'config';

declare_exception 'ConfigRequired' => (
    message => 'A required configueration key was not set'
);

declare_exception 'UnregisteredConfig' => (
    message => 'Config should be registered by calling "config" before usage'
);

sub config {
    my ($varname, %args) = @_;

    die 'config is required' unless $varname;
    my $caller = caller;

    my $observable = Ryu::Observable->new("");    
    my $default = $args{default};
    my $secure = $args{secure};

    if ($default) {
        # Really -_-
        if ($secure) {
            $default = Myriad::Util::Secret->new($default);
        }
        $observable->set_string($default);
    }

    $CONFIG_REGISTRY->{$caller}->{$varname} = {
        required => !$default,
        holder => $observable,
        secure => $secure,
    };

    $log->tracef("registered config %s for service %s", $varname, $caller);
}

sub import_into {
    my ($pkg, $caller) = @_;
    {
        no strict 'refs';
        *{"${caller}::config"} = $pkg->can('config');
    }
}

async sub resolve_config {
    my ($pkg, $service_name) = @_;
    my $service_configs = $CONFIG_REGISTRY->{$pkg};

    return unless $service_configs;

    # Priorities are:
    # - Storage instance config
    # - Storage Service config
    # - config from the file
    # - defaults that are set on declaration

    # TODO: Read the config from the file

    if (my $storage = $Myriad::Storage::STORAGE) {
        $log->trace("Going to lookup config from storage");
        await fmap0(async sub {
            my $key = shift;
            my $storage_key = "myriad.config.service.${service_name}/$key";
            my $meta = $service_configs->{$key};

            if(my $value = await $storage->get($storage_key)) {
                $value = Myriad::Util::Secret->new($value) if $meta->{secure};
                $log->tracef("found config %s for service %s in storage", $key, $service_name);
                
                $meta->{holder}->set($value);

                # look for future updates
                $meta->{sub} = $storage->observe($storage_key)->each(sub{
                    my $new_value = shift;
                    $new_value = Myriad::Util::Secret->new($new_value) if $meta->{secure};
                    $meta->{holder}->set($new_value);
                })->completed->on_fail(sub {
                    $log->warnf('No longer listening to updates on config %s - %s', $key, shift);
                });
            }
        }, foreach => [keys $service_configs->%*], concurrent => 8);
    } else {
        $log->warnf("No storage access is availeble while configuring service: %s", $service_name);
    }

    # Throw if any required key was not set
    # but will include all the missing ones in the message

    my $failure_reason = 'missing keys are: ';
    my $should_throw = 0;

    for my $key (keys $service_configs->%*) {
        if ($service_configs->{$key}->{required} && !$service_configs->{$key}->{holder}) {
            $should_throw = 1;
            $failure_reason .= "$key ";
        }
    }

    Myriad::Exception::Service::Config::ConfigRequired->throw(reason => $failure_reason) if $should_throw;

    $log->tracef("Config lookup for service %s is done", $service_name);
}

1;
