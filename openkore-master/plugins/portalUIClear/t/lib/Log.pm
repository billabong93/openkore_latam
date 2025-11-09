package Log;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(message warning error);

my @hooks;

sub addHook {
    my ($func) = @_;
    push @hooks, $func;
    return $#hooks;
}

sub delHook {
    my ($id) = @_;
    delete $hooks[$id] if defined $id;
}

sub message { }
sub warning { }
sub error { }

1;