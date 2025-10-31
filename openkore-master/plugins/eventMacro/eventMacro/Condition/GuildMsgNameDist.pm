package eventMacro::Condition::GuildMsgNameDist;

use strict;
use Globals qw( $playersList );

use base 'eventMacro::Condition::Base::MsgNameDist';
use eventMacro::Condition::Base::Msg ();

sub _hooks {
	my ( $self ) = @_;
	my $hooks = $self->SUPER::_hooks;
	my @other_hooks = ('packet_guildMsg');
	push(@{$hooks}, @other_hooks);
	return $hooks;
}

sub _parse_syntax {
	my ( $self, $condition_code ) = @_;
	
	$self->{actorList} = \$playersList;
	
	$self->SUPER::_parse_syntax($condition_code);
}

sub validate_condition {
	my ( $self, $callback_type, $callback_name, $args ) = @_;
	
	$self->{message} = undef;
	$self->{source} = undef;
	
        if ($callback_type eq 'hook') {
                $self->{message} = eventMacro::Condition::Base::Msg::normalize_text($args->{Msg});
                $self->{source} = eventMacro::Condition::Base::Msg::normalize_text($args->{MsgUser});
        }
	
	return $self->SUPER::validate_condition( $callback_type, $callback_name, $args );
}

1;