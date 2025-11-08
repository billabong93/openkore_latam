package AI;
use strict;
use warnings;

my @queue;
my @args = ({});

sub is { return 0; }
sub args {
    my ($index) = @_;
    $index //= 0;
    return $args[$index] // {};
}
sub inQueue { return 0; }
sub action { return $queue[0] // ''; }
sub queue {
    my ($action, $arg) = @_;
    $queue[0] = $action;
    $args[0] = $arg || {};
}
sub findAction { return undef; }
sub mapChanged { return; }
sub ai_route { return; }

1;
