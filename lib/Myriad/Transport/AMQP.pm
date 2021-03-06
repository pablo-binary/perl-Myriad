package Myriad::Transport::AMQP;

use strict;
use warnings;

# VERSION
# AUTHORITY

use utf8;
use Object::Pad;

class Myriad::Transport::AMQP extends Myriad::Notifier;

use Future::AsyncAwait;
use Syntax::Keyword::Try;

use Net::Async::AMQP;

use Log::Any qw($log);

has $mq;

1;

=head1 AUTHOR

Deriv Group Services Ltd. C<< DERIV@cpan.org >>

=head1 LICENSE

Copyright Deriv Group Services Ltd 2020. Licensed under the same terms as Perl itself.

