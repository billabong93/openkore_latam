package Network::Receive::ROla;

use strict;
use base qw(Network::Receive::ServerType0);
use Globals qw($char $messageSender);
use I18N qw(bytesToString);
use Log qw(debug);

sub new {
	my ($class) = @_;
	my $self = $class->SUPER::new(@_);
	
    my %packets = (
        '0C32' => ['account_server_info', 'v a4 a4 a4 a4 a26 C x17 a*', [qw(len sessionID accountID sessionID2 lastLoginIP lastLoginTime accountSex serverInfo)]],
        '0C05' => ['received_characters_info', 'v C5 x20', [qw(len normal_slot premium_slot billing_slot producible_slot valid_slot)]],
        
        '009D' => ['item_exists', 'a4 v C v3 C2', [qw(ID nameID identified x y amount subx suby)]],
        '0ADD' => ['item_appeared', 'a4 V v C v2 C2 v C v', [qw(ID nameID type identified x y subx suby amount show_effect effect_type)]],
        '01C8' => ['item_used', 'a2 v a4 v C', [qw(ID itemID actorID remaining success)]],
        '00A1' => ['item_disappeared', 'a4', [qw(ID)]],

        '09FD' => ['actor_moved', 'v C a4 a4 v3 V v2 V2 v V v6 a4 a2 v V C2 a6 C2 v2 V2 C v Z*', [qw(len object_type ID charID walk_speed opt1 opt2 option type hair_style weapon shield lowhead tick tophead midhead hair_color clothes_color head_dir costume guildID emblemID manner opt3 stance sex coords xSize ySize lv font maxHP HP isBoss opt4 name)]],
        '09FE' => ['actor_connected', 'v C a4 a4 v3 V v2 V2 v7 a4 a2 v V C2 a3 C2 v2 V2 C v Z*', [qw(len object_type ID charID walk_speed opt1 opt2 option type hair_style weapon shield lowhead tophead midhead hair_color clothes_color head_dir costume guildID emblemID manner opt3 stance sex coords xSize ySize lv font maxHP HP isBoss opt4 name)]],
        '09FF' => ['actor_exists', 'v C a4 a4 v3 V v2 V2 v7 a4 a2 v V C2 a3 C3 v2 V2 C v Z*', [qw(len object_type ID charID walk_speed opt1 opt2 option type hair_style weapon shield lowhead tophead midhead hair_color clothes_color head_dir costume guildID emblemID manner opt3 stance sex coords xSize ySize act lv font maxHP HP isBoss opt4 name)]],

        '08C8' => ['actor_action', 'a4 a4 a4 V3 x v C V', [qw(sourceID targetID tick src_speed dst_speed damage div type dual_wield_damage)]],
        '02E1' => ['actor_action', 'a4 a4 a4 V3 v C V', [qw(sourceID targetID tick src_speed dst_speed damage div type dual_wield_damage)]],
        '008A' => ['actor_action', 'a4 a4 a4 V2 v2 C v', [qw(sourceID targetID tick src_speed dst_speed damage div type dual_wield_damage)]],
        '009C' => ['actor_look_at', 'a4 v C', [qw(ID head body)]],
        '0088' => ['actor_movement_interrupted', 'a4 v2', [qw(ID x y)]],
        '0080' => ['actor_died_or_disappeared', 'a4 C', [qw(ID type)]],

        '0A37' => ['inventory_item_added', 'a2 v V C3 a16 V C2 a4 v a25 C v', [qw(ID amount nameID identified broken upgrade cards type_equip type fail expire unknown options favorite viewID)]],

        '0A0A' => ['storage_item_added', 'a2 V V C4 a16 a25', [qw(ID amount nameID type identified broken upgrade cards options)]],
        '00F4' => ['storage_item_added', 'a2 V v C3 a8', [qw(ID amount nameID identified broken upgrade cards)]],

        '0A0B' => ['cart_item_added', 'a2 V V C4 a16 a25', [qw(ID amount nameID type identified broken upgrade cards options)]],
    
        '0095' => ['actor_info', 'a4 Z24', [qw(ID name)]],

        '0194' => ['character_name', 'a4 Z24', [qw(ID name)]], # 30
        '01B0' => ['monster_typechange', 'a4 C V', [qw(ID type nameID)]], # 11

        '0977' => ['monster_hp_info', 'a4 V V', [qw(ID hp hp_max)]],

        '007F' => ['received_sync', 'V', [qw(time)]],
        '0A30' => ['actor_info', 'a4 Z24 Z24 Z24 Z24 V', [qw(ID name partyName guildName guildTitle titleID)]],
        '0ADF' => ['actor_info', 'a4 a4 Z24 Z24', [qw(ID charID name prefix_name)]],
        '0195' => ['actor_info', 'a4 Z24 Z24 Z24 Z24', [qw(ID name partyName guildName guildTitle)]], # 102
        '0196' => ['actor_status_active', 'v a4 C', [qw(type ID flag)]],
        '043F' => ['actor_status_active', 'v a4 C V4', [qw(type ID flag tick unknown1 unknown2 unknown3)]],
		'0983' => ['actor_status_active', 'v a4 C V5', [qw(type ID flag total tick unknown1 unknown2 unknown3)]],
		'0984' => ['actor_status_active', 'a4 v V5', [qw(ID type total tick unknown1 unknown2 unknown3)]],
        '0086' => ['actor_display', 'a4 a6 V', [qw(ID coords tick)]],

        '0087' => ['character_moves', 'a4 a6', [qw(move_start_time coords)]],

        '07FB' => ['skill_cast', 'a4 a4 v5 V C', [qw(sourceID targetID x y skillID unknown type wait dispose)]],

        '0446' => ['minimap_indicator', 'a4 v4', [qw(npcID x y effect qtype)]],

        '01B3' => ['npc_image', 'Z64 C', [qw(npc_image type)]],
        '0142' => ['npc_talk_number', 'a4', [qw(ID)]],
        '01D4' => ['npc_talk_text', 'a4', [qw(ID)]],
		'00B4' => ['npc_talk', 'v a4 Z*', [qw(len ID msg)]],
		'00B5' => ['npc_talk_continue', 'a4', [qw(ID)]],
		'00B6' => ['npc_talk_close', 'a4', [qw(ID)]],
		'00B7' => ['npc_talk_responses'],

		'023A' => ['storage_password_request', 'v', [qw(flag)]],
		'023C' => ['storage_password_result', 'v2', [qw(type val)]],
		'023E' => ['storage_password_request', 'v', [qw(flag)]],

        '00D7' => ['chat_info', 'v a4 a4 v2 C a*', [qw(len ownerID ID limit num_users public title)]],
        '0229' => ['character_status', 'a4 v2 V C', [qw(ID opt1 opt2 option stance)]],

		'0B08' => ['item_list_start', 'v C Z*', [qw(len type name)]],
		'0B09' => ['item_list_stackable', 'v C a*', [qw(len type itemInfo)]],
		'0B0A' => ['item_list_nonstackable', 'v C a*', [qw(len type itemInfo)]],
		'0B0B' => ['item_list_end', 'C2', [qw(type flag)]],

        '00B0' => ['stat_info', 'v V', [qw(type val)]],
		'00B1' => ['stat_info', 'v V', [qw(type val)]],

        '01AA' => ['pet_emotion', 'a4 V', [qw(ID type)]],

		'00C4' => ['npc_store_begin', 'a4', [qw(ID)]],
		'00C6' => ['npc_store_info', 'v a*', [qw(len itemList)]],#-1
		'00C7' => ['npc_sell_list', 'v a*', [qw(len itemsdata)]],

		'00CA' => ['buy_result', 'C', [qw(fail)]],
		'00CB' => ['sell_result', 'C', [qw(fail)]],

        '07FD' => ['special_item_obtain', 'v C V c/Z a*', [qw(len type nameID holder etc)]],
        
		'0B31' => ['skill_add', 'v V v3 C v', [qw(skillID target lv sp range upgradable lv2)]], #17
		'0B32' => ['skills_list'],
		'0B33' => ['skill_update', 'v V v3 C v', [qw(skillID type lv sp range up lv2)]], #17

        '0283' => ['account_id', 'a4', [qw(accountID)]],
        '0ADE' => ['overweight_percent', 'V', [qw(percent)]],# 6 TODO

        '02EB' => ['map_loaded', 'V a3 a a v', [qw(syncMapSync coords xSize ySize font)]], # 13
		'0091' => ['map_change', 'Z16 v2', [qw(map x y)]],
        '0AC7' => ['map_changed', 'Z16 v2 a4 v a128', [qw(map x y IP port url)]], # 156

        '0ACC' => ['exp', 'a4 V2 v2', [qw(ID val val2 type flag)]],

        '0B1B' => ['load_confirm'],
    );
	
	$self->{packet_list}{$_} = $packets{$_} for keys %packets;

    my %handlers = qw(
    
        map_change 0091
        load_confirm 0B1B
        exp 0ACC
        map_changed 0AC7
        map_loaded 02EB
        overweight_percent 0ADE
        account_id 0283
        skill_add 0B31
        skills_list 0B32
        skill_update 0B33
        special_item_obtain 07FD
        actor_display 0086
        npc_store_begin 00C4
        npc_store_info 00C6
        npc_sell_list 00C7
        buy_result 00CA
        sell_result 00CB
        pet_emotion 01AA
        stat_info 00B0
        stat_info 00B1
        actor_status_active 043F
        actor_status_active 0196
        actor_status_active 0983
        actor_status_active 0984
        item_list_start 0B08
        item_list_stackable 0B09
        item_list_nonstackable 0B0A
        item_list_end 0B0B

        npc_talk 00B4
        npc_talk_continue 00B5
        npc_talk_close 00B6
        npc_talk_responses 00B7

        character_status 0229
        chat_info 00D7

        storage_password_request 023A
        storage_password_result 023C
        storage_password_request 023E

        npc_talk_number 0142
        npc_talk_text 01D4
        npc_image 01B3
        minimap_indicator 0446
        skill_cast 07FB
        actor_action 008A
        actor_action 02E1
        actor_action 08C8
        actor_movement_interrupted 0088
        actor_died_or_disappeared 0080
        actor_info 0195
        actor_look_at 009C
        actor_info 0ADF
        actor_info 0A30
        actor_moved 09FD
        actor_connected 09FE
        actor_exists 09FF
        actor_info 0095
        character_moves 0087
        character_name 0194
        received_sync 007F
        item_used 01C8
        item_disappeared 00A1
        item_exists 009D
        item_appeared 0ADD
        inventory_item_added 0A37
        storage_item_added 0A0A
        cart_item_added 0A0B
        monster_typechange 01B0
        monster_hp_info 0977

        account_server_info 0C32
        received_characters 099D
        received_characters_info 0C05
        sync_received_characters 09A0
    );

	$self->{packet_lut}{$_} = $handlers{$_} for keys %handlers;
	
    $self->{makable_item_list_pack} = 'V4';
    $self->{npc_store_info_pack} = 'V V C V';
    $self->{buying_store_items_list_pack} = 'V v C V';
    $self->{npc_market_info_pack} = "V C V2 v";
    $self->{vender_items_list_item_pack} = 'V v2 C V C3 a16 a25';
    $self->{rodex_read_mail_item_pack} = 'v V C3 a16 a4 C a4 a25';

	return $self;
}

sub guild_name {
	my ($self, $args) = @_;
	my $guildID = $args->{guildID};
	my $emblemID = $args->{emblemID};
	my $mode = $args->{mode};
	my $guildName = bytesToString($args->{guildName});

	$char->{guild}{name} = $guildName;
	$char->{guildID} = $guildID;
	$char->{guild}{emblem} = $emblemID;

	debug "guild name: $guildName\n";

	# Skip in XKore mode 1 / 3
	return if $self->{net}->version == 1;

	# emulate client behavior
	$messageSender->sendGuildRequestInfo(3);
	$messageSender->sendGuildRequestInfo(1); # Requests for Members list, list job title
}

sub adventure_agency_auth {
    my ($self, $args) = @_;
    $char->{adventureAgency} = {} unless exists $char->{adventureAgency};
    $char->{adventureAgency}{AuthToken} = unpack("A16", substr($args->{RAW_MSG}, 47, 16));
    $char->{adventureAgency}{AID} = unpack('V', substr($args->{RAW_MSG}, 8, 4));
    
    message T("[Adventure Agency] Authentication received\n"), "adventureagency";
}

sub adventure_agency_denied {
    my ($self, $args) = @_;
    my $partyOwner = unpack("Z24", substr($args->{RAW_MSG}, 2, 24));
    my $partyName  = unpack("Z24", substr($args->{RAW_MSG}, 26, 24));
    error T("[Adventure Agency] %s DENIED your entrance on party %s\n", $partyOwner, $partyName);
}

sub adventure_agency_accepted {
    my ($self, $args) = @_;
    my $partyName = unpack("Z24", substr($args->{RAW_MSG}, 23, 24));
    message T("[Adventure Agency] You were accepted into %s party\n", $partyName);
}

1;