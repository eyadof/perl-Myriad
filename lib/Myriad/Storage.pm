package Myriad::Storage;

use strict;
use warnings;

# VERSION
# AUTHORITY

no indirect qw(fatal);
use Scalar::Util qw(weaken);
use utf8;

=encoding utf8

=head1 NAME

Myriad::Storage - microservice Storage abstraction

=head1 SYNOPSIS

 my $storage = Myriad::Storage->new();

=head1 DESCRIPTION

=cut

use Myriad::Exception::Builder category => 'storage';

use Myriad::Role::Storage;

=head1 Exceptions

=head2 UnknownTransport

RPC transport does not exist.

=cut

declare_exception UnknownTransport => (
    message => 'Unknown transport'
);

sub new {
    my ($class, %args) = @_;
    my $transport = delete $args{transport};
    weaken(my $myriad = delete $args{myriad});
    # Passing args individually looks tedious but this is to avoid
    # L<IO::Async::Notifier> exception when it doesn't recognize the key.

    if ($transport eq 'redis') {
        require Myriad::Storage::Implementation::Redis;
        return Myriad::Storage::Implementation::Redis->new(
            redis   => $myriad->redis,
        );
    } elsif ($transport eq 'perl') {
        require Myriad::Storage::Implementation::Perl;
        return Myriad::Storage::Implementation::Perl->new();
    } else {
        Myriad::Exception::Storage::UnKnownTransport->throw();
    }
}

1;

__END__

=head1 AUTHOR

Deriv Group Services Ltd. C<< DERIV@cpan.org >>.

See L<Myriad/CONTRIBUTORS> for full details.

=head1 LICENSE

Copyright Deriv Group Services Ltd 2020-2021. Licensed under the same terms as Perl itself.

