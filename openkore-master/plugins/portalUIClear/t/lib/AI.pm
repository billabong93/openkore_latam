package AI;
use strict;
use warnings;

my @queue;
my @args = ({});

sub is { return 0; }
sub args { return $args[0]; }
sub inQueue { return 0; }
sub action { return $queue[0] // ''; }
sub queue { my ($action, $arg) = @_; $queue[0] = $action; $args[0] = $arg || {}; }

1;
