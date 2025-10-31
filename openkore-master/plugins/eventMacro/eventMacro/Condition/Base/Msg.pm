package eventMacro::Condition::Base::Msg;

use strict;

use base 'eventMacro::Conditiontypes::RegexConditionEvent';
use I18N qw(bytesToString);

sub normalize_text {
        my ($text) = @_;
        return unless defined $text;
        return bytesToString($text);
}

sub set_message_and_source {
        my ($self, $message, $source) = @_;
        $self->{message} = normalize_text($message);
        $self->{source}  = normalize_text($source);
}

sub _hooks {
        [];
}

sub validate_condition {
        my ( $self, $callback_type, $callback_name, $args ) = @_;

        if ($callback_type eq 'hook') {
                return $self->SUPER::validate_condition( $self->validator_check($self->{message}) );
        } elsif ($callback_type eq 'variable') {
                $self->update_validator_var($callback_name, $args);
        }
}

sub get_new_variable_list {
        my ($self) = @_;
        my $new_variables;

        $new_variables->{".".$self->{name}."Last"."Name"} = $self->{source};
        $new_variables->{".".$self->{name}."Last"."Msg"} = $self->{message};

        return $new_variables;
}

1;
