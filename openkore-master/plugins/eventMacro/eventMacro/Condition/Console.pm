package eventMacro::Condition::Console;

use strict;

use base 'eventMacro::Condition::Base::Msg';

sub _hooks {
        my ( $self ) = @_;
        my $hooks = $self->SUPER::_hooks;
        my @other_hooks = ('log');
        push(@{$hooks}, @other_hooks);
        return $hooks;
}

sub validate_condition {
        my ( $self, $callback_type, $callback_name, $args ) = @_;

        $self->{message} = undef;
        $self->{source} = undef;

        if ($callback_type eq 'hook') {
                $self->{message} = $args->{Msg};
                $self->{source} = $args->{Domain};
        }
        return $self->SUPER::validate_condition( $callback_type, $callback_name, $args );
}

sub get_new_variable_list {
        my ($self) = @_;
        my $new_variables = $self->SUPER::get_new_variable_list();

        $new_variables->{".".$self->{name}."LastDomain"} = $self->{source};

        return $new_variables;
}

1;
