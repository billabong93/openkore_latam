#############################################################################
# badRobot plugin by revok/marcelofoxes
#
# Usage:
# attackAuto_steal <boolean flag>
#	1 : Don't check if we are kill stealing
#   0 or unset : Default OpenKore check
#
# itemsGatherAuto_steal <boolean flag>
#	1 : Don't check if the item is near a player (this check is to avoid looting)
#   0 or unset : Default OpenKore check
#																			
# You should not use or redistribute this code without permission.
#
# ATTENTION: This plugin is not affiliated nor have any relation with any
#            OpenKore or Ragnark Online related website.
#
#############################################################################
package badRobot;

use strict;
use Globals;
#use Log qw(message warning error debug);

use Log qw(message warning error debug);

use Misc;
use Settings;
use AI;
use Utils;
use Commands;
use Network;
use FileParsers;
use Field;
use Task::TalkNPC;
use Utils::Exceptions;

# Plugin
Plugins::register('badRobot', "we love to steal your monsters !");

my $orig_checkMonsterCleanness = \&Misc::checkMonsterCleanness;
my $orig_slave_checkMonsterCleanness = \&Misc::slave_checkMonsterCleanness;

my $checkMonsterCleanness = sub {
	return 1 if $config{attackAuto_steal};
	return $orig_checkMonsterCleanness->(@_);
};

*Misc::checkMonsterCleanness =
*AI::checkMonsterCleanness =
*AI::CoreLogic::checkMonsterCleanness =
*AI::Attack::checkMonsterCleanness =
*AI::Slave::checkMonsterCleanness = $checkMonsterCleanness;

*Misc::slave_checkMonsterCleanness =
*AI::Slave::slave_checkMonsterCleanness =
sub {
	return 1 if $config{attackAuto_steal};
	return $orig_slave_checkMonsterCleanness->(@_);
};

*AI::CoreLogic::processItemsGather =
sub {
	if (AI::action eq "items_gather" && AI::args->{suspended}) {
		AI::args->{ai_items_gather_giveup}{time} += time - AI::args->{suspended};
		delete AI::args->{suspended};
	}
	if (AI::action eq "items_gather" && !($items{AI::args->{ID}} && %{$items{AI::args->{ID}}})) {
		my $ID = AI::args->{ID};
		message sprintf("Failed to gather %s (%s) : Lost target\n", $items_old{$ID}{name}, $items_old{$ID}{binID}), "drop";
		AI::dequeue;

	} elsif (AI::action eq "items_gather") {
		my $ID = AI::args->{ID};
		my ($dist, $myPos);

		if ((positionNearPlayer($items{$ID}{pos}, 12)) && !$config{itemsGatherAuto_steal}) {
			message sprintf("Failed to gather %s (%s) : No looting!\n", $items{$ID}{name}, $items{$ID}{binID}), undef, 1;
			AI::dequeue;

		} elsif (timeOut(AI::args->{ai_items_gather_giveup})) {
			message sprintf("Failed to gather %s (%s) : Timeout\n", $items{$ID}{name}, $items{$ID}{binID}), undef, 1;
			$items{$ID}{take_failed}++;
			AI::dequeue;

		} elsif ($char->{sitting}) {
			AI::suspend();
			stand();

		} elsif (( $dist = distance($items{$ID}{pos}, ( $myPos = calcPosition($char) )) > 2 )) {
			if (!$config{itemsTakeAuto_new}) {
				my (%vec, %pos);
				getVector(\%vec, $items{$ID}{pos}, $myPos);
				moveAlongVector(\%pos, $myPos, \%vec, $dist - 1);
				$char->move(@pos{qw(x y)});
			} else {
				my $item = $items{$ID};
				my $pos = $item->{pos};
				message sprintf("Routing to (%s, %s) to take %s (%s), distance %s\n", $pos->{x}, $pos->{y}, $item->{name}, $item->{binID}, $dist);
				ai_route($field->baseName, $pos->{x}, $pos->{y}, maxRouteDistance => $config{'attackMaxRouteDistance'});
			}

		} else {
			AI::dequeue;
			take($ID);
		}
	}
};

1;
# i luv u mom
