package eventMacro::Condition::NpcMsgName;

use strict;

use base 'eventMacro::Condition::Base::MsgName';
use eventMacro::Condition::Base::Msg ();

sub _hooks {
	my ( $self ) = @_;
	my $hooks = $self->SUPER::_hooks;
	my @other_hooks = ('npc_talk');
	push(@{$hooks}, @other_hooks);
	return $hooks;
}

sub validate_condition {
	my ( $self, $callback_type, $callback_name, $args ) = @_;
	
	$self->{message} = undef;
	$self->{source} = undef;
	
        if ($callback_type eq 'hook') {
                $self->{message} = eventMacro::Condition::Base::Msg::normalize_text($args->{msg});
                $self->{source} = eventMacro::Condition::Base::Msg::normalize_text($args->{name});
        }
	return $self->SUPER::validate_condition( $callback_type, $callback_name, $args );
}

1;