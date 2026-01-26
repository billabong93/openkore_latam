package aiChat;

use strict;
use warnings;
use utf8;

use Commands;
use Globals qw(%timeout $messageSender $net %config $char $field $playersList %jobs_lut %emotions_lut %monsters %items %monsters_lut %monsters_name_lut %items_lut);
use Settings qw(%sys);
use I18N qw(bytesToString UTF8ToString isUTF8);
use Log qw(warning message debug);
use JSON::Tiny qw(decode_json);
use Plugins;
use AI;
use Misc qw(getEmotionByCommand);
use Utils qw(getHex timeOut distance);
use Cwd 'abs_path';
use Time::HiRes qw(time);
use Actor ();

use lib $Plugins::current_plugin_folder;
use AIChat::Config;
use AIChat::APIClient;
use AIChat::MessageHandler;
use AIChat::ConversationHistory;
use AIChat::HookManager;
use AIChat::Log;
use AIChat::References;

use constant {
    PLUGIN_PREFIX => "[aiChat]",
    PLUGIN_NAME => "aiChat",
    PLUGIN_PODIR => "$Plugins::current_plugin_folder/po",
    
    COMMAND_HANDLE => "aichat",
};

my $translator = new Translation(PLUGIN_PODIR, $sys{locale});
my $main_command;

my %hooks = (
    init => new AIChat::HookManager("start3", \&onInitialized),
    in_game => new AIChat::HookManager("in_game", \&updateBotCharacterData),
    map_changed => new AIChat::HookManager("Network::Receive::map_changed", \&updateBotCharacterData),
    main_loop_pre => new AIChat::HookManager("mainLoop_pre", \&onTick),
);

Plugins::register(PLUGIN_NAME, $translator->translate("AI Chat Integration for OpenKore"), \&onUnload, \&onReload);
$hooks{init}->hook();
$hooks{in_game}->hook();
$hooks{map_changed}->hook();
$hooks{main_loop_pre}->hook();

# Registrar o hook de mensagens privadas diretamente para debug
my $privMsgHookID = Plugins::addHook('packet_privMsg', \&onPrivateMessage, undef);
# Armazenar o ID para desregistrar depois
$hooks{packet_privMsg_direct} = $privMsgHookID;
my $pubMsgHookID = Plugins::addHook('packet_pubMsg', \&onPublicMessage, undef);
$hooks{packet_pubMsg_direct} = $pubMsgHookID;
my $emotionHookID = Plugins::addHook('packet_emotion', \&onEmotion, undef);
$hooks{packet_emotion_direct} = $emotionHookID;

my %message_buffers;
my $ack_client = AIChat::APIClient->new();
my $last_emotion_command;
my $last_emotion_time;
my %last_emotion_command_by_sender;
my %last_emotion_time_by_sender;
my %last_emotion_display_by_sender;
my %last_emotion_hint_by_sender;
my %pending_emotion_request_by_sender;
my %pending_emotion_followup_by_sender;
my %suppress_reply_until_by_sender;
my %emote_request_times_by_sender;
my %drop_db_question_count;
my %drop_db_force_refusal;
my %drop_db_refusal_limit;
my %question_streak_by_sender;
my %silenced_by_sender;
my %silence_message_count_by_sender;
my %blocked_by_sender;
my %silence_after_response_by_sender;
my %last_visibility_state_by_sender;
my %conversation_message_count_by_sender;
my %conversation_close_stage_by_sender;
my $last_packet_sent_at = 0;

my %invisibility_statuses = map { $_ => 1 } qw(
    EFST_HIDING
    EFST_CLOAKING
    EFST_INVISIBLE
    EFST_INVISIBILITY
    EFST_CLOAKINGEXCEED
    EFST_HALLUCINATIONWALK
    EFST_STEALTHFIELD
    EFST_CAMOUFLAGE
    EFST_CHASEWALK
    EFFECTSTATE_BURROW
    EFFECTSTATE_HIDING
    EFFECTSTATE_SPECIALHIDING
);

my @fallback_emotion_commands = qw(
    flg6
    !
    ?
    ho
    lv
    swt
    ic
    an
    ag
    $
    ...
);

use constant {
    MAX_CHAT_LENGTH => 200,
    DROP_DB_REFUSAL_MIN => 2,
    DROP_DB_REFUSAL_MAX => 4,
    SPAM_QUESTION_LIMIT => 3,
    SILENCE_BLOCK_THRESHOLD => 2,
    MAX_PUBLIC_CHAT_DISTANCE => 8,
};

sub _getBufferState {
    my ($sender) = @_;
    return $message_buffers{$sender} ||= {
        messages => [],
        response_queue => [],
        buffer_deadline => 0,
        typing_until => 0,
        response_started => 0,
        context => undef,
    };
}

sub _sanitizeOutgoingMessage {
    my ($message) = @_;
    return '' unless defined $message;
    my $sanitized = $message;
    if (!utf8::is_utf8($sanitized) && isUTF8($sanitized)) {
        $sanitized = UTF8ToString($sanitized);
    }
    $sanitized =~ s/\s*\r?\n\s*/ /g;
    $sanitized =~ s/[\x00-\x1F\x7F]+/ /g;
    $sanitized =~ s/\s+/ /g;
    $sanitized =~ s/^\s+//;
    $sanitized =~ s/\s+$//;
    if (length($sanitized) > MAX_CHAT_LENGTH) {
        $sanitized = substr($sanitized, 0, MAX_CHAT_LENGTH);
        $sanitized =~ s/\s+$//;
    }
    return $sanitized;
}

sub _splitOutgoingResponse {
    my ($response) = @_;
    return () unless defined $response;
    my $split_chance = AIChat::Config::get('split_chance');
    $split_chance = 0.2 unless defined $split_chance;
    if ($response =~ /\|\|/) {
        my @parts = split /\s*\|\|\s*/, $response;
        @parts = map {
            my $part = $_;
            $part =~ s/^\s+//;
            $part =~ s/\s+$//;
            $part;
        } grep { defined $_ && length $_ } @parts;
        return @parts if @parts;
    }

    if ($response =~ /\r?\n/) {
        my @parts = split /\s*\r?\n\s*/, $response;
        @parts = map {
            my $part = $_;
            $part =~ s/^\s+//;
            $part =~ s/\s+$//;
            $part;
        } grep { defined $_ && length $_ } @parts;
        if (@parts >= 2 && rand() < $split_chance) {
            my @pair = @parts[0, 1];
            my $first_words = scalar grep { length } split /\s+/, $pair[0];
            my $second_words = scalar grep { length } split /\s+/, $pair[1];
            return @pair if $first_words >= 2 && $second_words >= 2;
        }
    }
    return ($response);
}

sub _enqueueMessage {
    my ($sender, $message, $context) = @_;
    my $state = _getBufferState($sender);
    push @{$state->{messages}}, $message;
    $state->{context} = $context;
    my $buffer_delay = AIChat::Config::get('buffer_delay');
    $buffer_delay = 2 unless defined $buffer_delay;
    $state->{buffer_deadline} = time() + $buffer_delay;
    if (@{$state->{response_queue}}) {
        if (!$state->{response_started}) {
            $state->{response_queue} = [];
            $state->{typing_until} = 0;
        }
    }

    if ($state->{typing_until} && $state->{typing_until} < $state->{buffer_deadline}) {
        $state->{typing_until} = $state->{buffer_deadline};
    }
}

sub _queueDirectResponse {
    my ($sender, $response, $context) = @_;
    return unless defined $sender && defined $response;
    my $state = _getBufferState($sender);
    $state->{messages} = [];
    $state->{response_queue} = [];
    my $buffer_delay = AIChat::Config::get('buffer_delay');
    $buffer_delay = 2 unless defined $buffer_delay;
    $state->{buffer_deadline} = time() + $buffer_delay;
    $state->{typing_until} = 0;
    $state->{response_started} = 0;
    $state->{context} = $context;
    my @parts = _splitOutgoingResponse($response);
    return unless @parts;
    my $typing_delay = _calculateTypingDelay($parts[0]);
    if ($typing_delay > 0) {
        $state->{typing_until} = time() + $buffer_delay + $typing_delay;
    }
    push @{$state->{response_queue}}, @parts;
}

sub _flushBufferedMessages {
    my ($sender, $state) = @_;
    my @messages = @{$state->{messages}};
    $state->{messages} = [];
    $state->{buffer_deadline} = 0;

    my $responses = AIChat::MessageHandler::processMessages(\@messages, $sender);
    if ($responses && ref $responses eq 'ARRAY' && @$responses) {
        my @filtered = grep { defined $_ && $_ ne '' } @$responses;
        if (@filtered) {
            push @{$state->{response_queue}}, @filtered;
        }
        $state->{response_started} = 0;
    } else {
        debug "[aiChat] Nenhuma resposta da AI gerada para mensagens de '$sender'\n", "plugin";
    }
}

sub _hasAggressiveMonsters {
    my $aggressive_count = AI::ai_getAggressives(1, 1);
    return $aggressive_count && $aggressive_count > 0;
}

sub _sendQueuedResponse {
    my ($sender, $state) = @_;
    return unless @{$state->{response_queue}};
    return if $state->{buffer_deadline} && time() < $state->{buffer_deadline};
    return if _hasPendingEmotionRequest($sender);
    return if _hasPendingEmotionFollowup($sender);
    return if _isReplySuppressed($sender);
    return if _isSilenced($sender) && !_shouldAllowSilenceResponse($sender);
    return if _isBlockedSender($sender);

    my $response = $state->{response_queue}[0];
    my $emotion_command = _extractEmotionCommand($response);
    if (!$state->{typing_until}) {
        my $delay = 0;
        if ($emotion_command) {
            $delay = 2 + rand(3);
        } else {
            my $typing_speed = AIChat::Config::get('typing_speed');
            if ($typing_speed && $typing_speed > 0) {
                $delay = length($response) / $typing_speed;
            }
        }
        $state->{typing_until} = time() + $delay;
    }

    return if $state->{typing_until} && time() < $state->{typing_until};
    if (_shouldThrottleOutgoingPackets($state)) {
        return;
    }

    $response = shift @{$state->{response_queue}};
    $state->{response_started} = 1;
    my $context = $state->{context} || {};
    if ($emotion_command) {
        my $emotion_id = getEmotionByCommand($emotion_command);
        if (defined $emotion_id) {
            $messageSender->sendEmotion($emotion_id);
            _recordOutgoingPacketSent();
        } else {
            $response = _sanitizeOutgoingMessage($response);
            if (!$response) {
                debug "[aiChat] Resposta vazia apos sanitizacao para '$sender'\n", "plugin";
                $state->{typing_until} = 0;
                $state->{response_started} = 0 unless @{$state->{response_queue}};
                return;
            }
            $messageSender->sendChat($response);
            _recordOutgoingPacketSent();
        }
    } else {
        if ($context->{sabotage} || $context->{normalize}) {
            $response = AIChat::MessageHandler::_normalizeResponseText($response);
        }
        $response = _sanitizeOutgoingMessage($response);
        if (!$response) {
            debug "[aiChat] Resposta vazia apos sanitizacao para '$sender'\n", "plugin";
            $state->{typing_until} = 0;
            $state->{response_started} = 0 unless @{$state->{response_queue}};
            return;
        }
    }

    if (!$emotion_command && $context->{type} && $context->{type} eq 'public') {
        $messageSender->sendChat($response);
        _recordOutgoingPacketSent();
        AIChat::Log::log_message(
            direction => 'out',
            visibility => 'public',
            sender => 'Public',
            message => $response,
        );
    } elsif (!$emotion_command) {
        $messageSender->sendPrivateMsg($sender, $response);
        _recordOutgoingPacketSent();
        AIChat::Log::log_message(
            direction => 'out',
            visibility => 'private',
            sender => $sender,
            message => $response,
        );
    }

    AIChat::ConversationHistory::addMessage($sender, "assistant", $response);
    $state->{typing_until} = 0;
    $state->{response_started} = 0 unless @{$state->{response_queue}};
    _finalizeSilenceIfNeeded($sender);
}

sub onTick {
    my $now = time();

    _processPendingEmotionRequests($now);
    _processPendingEmotionFollowups($now);

    for my $sender (keys %message_buffers) {
        my $state = $message_buffers{$sender};
        next unless $state;
        next if _hasPendingEmotionRequest($sender);
        next if _hasPendingEmotionFollowup($sender);
        next if _isReplySuppressed($sender);
        next if _isSilenced($sender);
        next if _isBlockedSender($sender);

        if (_hasAggressiveMonsters()) {
            if (@{$state->{messages}} && $state->{buffer_deadline} && $now >= $state->{buffer_deadline}) {
                $state->{buffer_deadline} = $now + 1;
            }
            if (@{$state->{response_queue}}) {
                $state->{typing_until} = 0;
            }
            next;
        }

        if (@{$state->{messages}} && $state->{buffer_deadline} && $now >= $state->{buffer_deadline}) {
            _flushBufferedMessages($sender, $state);
        }

        next if $state->{buffer_deadline} && $now < $state->{buffer_deadline};
        next if $state->{typing_until} && $now < $state->{typing_until};

        _sendQueuedResponse($sender, $state);
    }
}


sub updateBotCharacterData {
    # Popula AIChat::MessageHandler::%bot_character_data com as informações mais recentes do personagem
    debug "[aiChat] Executando updateBotCharacterData...\n", "plugin";
    if (defined $char && defined $char->{name}) {
        $AIChat::MessageHandler::bot_character_data{name} = $char->{name} || "Desconhecido";
        $AIChat::MessageHandler::bot_character_data{base_level} = $char->{lv} || 0;
        $AIChat::MessageHandler::bot_character_data{job_level} = $char->{lv_job} || 0;
        $AIChat::MessageHandler::bot_character_data{job} = ($char->{jobID} && $jobs_lut{$char->{jobID}}) || "Desconhecido";
        
        my $current_map_name = "Desconhecido";
        if (defined $field) {
            $current_map_name = $field->baseName || "Desconhecido";
            debug "[aiChat] \$field está definido. baseName: '$current_map_name'\n", "plugin";
        } else {
            debug "[aiChat] \$field não está definido.\n", "plugin";
        }
        $AIChat::MessageHandler::bot_character_data{map_name} = $current_map_name;

        my %map_monsters;
        for my $id (keys %monsters) {
            my $monster = $monsters{$id};
            next unless $monster;
            my $name = $monster->{name};
            if ((!defined $name || $name eq '') && $monster->{nameID}) {
                $name = $monsters_lut{$monster->{nameID}} || $monsters_name_lut{$monster->{nameID}};
            }
            $map_monsters{$name} = 1 if defined $name && $name ne '';
        }
        my @map_monsters = sort keys %map_monsters;
        $AIChat::MessageHandler::bot_character_data{map_monsters} = \@map_monsters;

        my %map_items;
        for my $id (keys %items) {
            my $item = $items{$id};
            next unless $item;
            my $name = $item->{name};
            if ((!defined $name || $name eq '') && $item->{nameID}) {
                $name = $items_lut{$item->{nameID}};
            }
            $map_items{$name} = 1 if defined $name && $name ne '';
        }
        my @map_items = sort keys %map_items;
        $AIChat::MessageHandler::bot_character_data{map_items} = \@map_items;
        AIChat::MessageHandler::updateMondbFromMap($current_map_name, \@map_items);
        
        debug "[aiChat] Dados do personagem atualizados: " . join(", ", map { "$_: " . $AIChat::MessageHandler::bot_character_data{$_} } keys %AIChat::MessageHandler::bot_character_data) . "\n", "plugin";
    } else {
        debug "[aiChat] Não foi possível atualizar os dados do personagem: \$char ou \$char->{name} não definidos.\n", "plugin";
    }
}

sub onInitialized {
    Commands::register([
        COMMAND_HANDLE,
        $translator->translate("AI Chat commands"),
        \&onCommand
    ]);
    AIChat::Config::load();

    # Chamar updateBotCharacterData uma vez na inicialização, caso o bot já esteja em jogo
    updateBotCharacterData();
}

sub onUnload {
    Commands::unregister([COMMAND_HANDLE]);
    # Desativar o hook de inicialização e o hook de mensagens privadas direto
    $hooks{init}->unhook();
    $hooks{in_game}->unhook();
    $hooks{map_changed}->unhook();
    $hooks{main_loop_pre}->unhook();
    Plugins::delHook($hooks{packet_privMsg_direct}) if defined $hooks{packet_privMsg_direct};
    Plugins::delHook($hooks{packet_pubMsg_direct}) if defined $hooks{packet_pubMsg_direct};
    Plugins::delHook($hooks{packet_emotion_direct}) if defined $hooks{packet_emotion_direct};
    
    # Tentar encerrar o servidor Node.js
    my $pid_file = "plugins/aiChat/proxy_pid.txt";
    if (-e $pid_file) { # Se o arquivo PID existe
        open my $fh, '<', $pid_file or warning "[aiChat] Não foi possível abrir $pid_file: $!\n", "plugin";
        my $pid = <$fh>;
        chomp $pid;
        close $fh;

        if ($pid =~ /^\d+$/) {
            system("taskkill /F /PID $pid"); # /F para forçar o encerramento
        } else {
            warning "[aiChat] PID inválido encontrado em $pid_file: '$pid'\n", "plugin";
        }
        unlink $pid_file or warning "[aiChat] Não foi possível remover $pid_file: $!\n", "plugin";
    } else {
        debug "[aiChat] Arquivo PID ($pid_file) não encontrado. O proxy pode já ter sido fechado ou não foi iniciado.\n", "plugin";
    }
}

sub onReload {
    AIChat::Config::load();
    updateBotCharacterData(); # Atualizar dados ao recarregar
}

sub onCommand {
    my (undef, $args) = @_;
    my $arg = $args;
    
    if ($arg eq "help") {
        message $translator->translate("Comandos do AI Chat:\n" .
            "aichat help - Mostra esta ajuda\n" .
            "aichat status - Mostra o status atual\n" .
            "aichat config - Mostra a configuração atual\n" .
            "aichat set <chave> <valor> - Define um valor de configuração\n" .
            "aichat provider <openai|deepseek> - Altera o provedor de IA\n"), "list";
    } elsif ($arg eq "status") {
        message $translator->translatef("%s Status: Ativo\n", PLUGIN_PREFIX), "list";
        message "Provedor: " . AIChat::Config::get('provider'), "list";
        message "Modelo: " . AIChat::Config::get('model'), "list";
        message "Nome: " . $AIChat::MessageHandler::bot_character_data{name}, "list";
        message "Level Base: " . $AIChat::MessageHandler::bot_character_data{base_level}, "list";
        message "Level Job: " . $AIChat::MessageHandler::bot_character_data{job_level}, "list";
        message "Classe: " . $AIChat::MessageHandler::bot_character_data{job}, "list";
        message "Mapa: " . $AIChat::MessageHandler::bot_character_data{map_name}, "list";
    } elsif ($arg eq "config") {
        message $translator->translatef("%s Configuração:\n", PLUGIN_PREFIX), "list";
        message "Provedor: " . AIChat::Config::get('provider'), "list";
        message "Chave API: " . (AIChat::Config::get('api_key') ? "Configurada" : "Não configurada"), "list";
        message "Modelo: " . AIChat::Config::get('model'), "list";
        message "Prompt: " . AIChat::Config::get('prompt'), "list";
        message "Prompt GM (sec_pri): " . AIChat::Config::get('prompt_gm'), "list";
        message "Max Tokens: " . AIChat::Config::get('max_tokens'), "list";
        message "Temperatura: " . AIChat::Config::get('temperature'), "list";
        message "Chance de dividir resposta: " . AIChat::Config::get('split_chance'), "list";
        message "Delay do buffer: " . AIChat::Config::get('buffer_delay'), "list";
        message "Responder no chat publico no lockMap: " . AIChat::Config::get('public_on_lockmap'), "list";
        message "Intervalo minimo entre pacotes: " . AIChat::Config::get('min_packet_interval'), "list";
        message "Limite de mensagens antes de encerrar papo: " . AIChat::Config::get('conversation_limit'), "list";
        message "Limite de perguntas seguidas antes de recusar spam: " . AIChat::Config::get('spam_question_limit'), "list";
        message "Limite de perguntas do dropdb antes de recusar: " . AIChat::Config::get('dropdb_question_limit'), "list";
    } elsif ($arg =~ /^provider\s+(openai|deepseek)$/) {
        if (AIChat::Config::set('provider', $1)) {
            message $translator->translatef("%s Provedor alterado para %s\n", PLUGIN_PREFIX, $1), "list";
        } else {
            message $translator->translate("Provedor inválido. Use 'openai' ou 'deepseek'."), "list";
        }
    } elsif ($arg =~ /^set\s+(\w+)\s+(.+)$/) {
        my ($key, $value) = ($1, $2);
        if (AIChat::Config::set($key, $value)) {
            message $translator->translatef("%s Configuração atualizada.\n", PLUGIN_PREFIX), "list";
        } else {
            message $translator->translate("Chave de configuração inválida."), "list";
        }
    } else {
        message $translator->translate("Comando desconhecido. Use 'aichat help' para ver os comandos disponíveis."), "list";
    }
}

sub onPrivateMessage {
    my (undef, $args) = @_;
    my $sender = _resolvePacketField($args, qw(privMsgUser MsgUser));
    my $message = _resolvePacketField($args, qw(privMsg Msg));
    $sender = bytesToString($args->{privMsgUser}) if (!defined $sender || $sender eq '') && defined $args->{privMsgUser};
    $message = bytesToString($args->{privMsg}) if (!defined $message || $message eq '') && defined $args->{privMsg};
    return unless defined $sender && $sender ne '';
    return unless defined $message && $message ne '';

    my $actor = _getSenderActor($sender);
    my $visibility_state = _resolveVisibilityState($actor);
    _ensureVisibilityInfo($sender, $visibility_state);
    _ensurePlayerInfo($sender, $actor) if $visibility_state eq 'visible';

    my $intent_context = { map_name => $field ? $field->baseName : undef, lock_map => $config{lockMap} };
    my $intent;
    $intent = _interpretCommand($message, $sender, $intent_context);
    if (_shouldForceDropDbIntent($sender, $intent, $message)) {
        $intent = { action => 'drop_db', is_question => 1 };
    }
    if (_handleSpamCheck($sender, $message, 'private', $intent)) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'private',
            sender => $sender,
            message => $message,
        );
        return;
    }
    if (_handleConversationLimit($sender, $message, 'private')) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'private',
            sender => $sender,
            message => $message,
        );
        return;
    }
    my $force_drop_refusal = 0;
    if (_isDropDbIntent($intent)) {
        _recordDropDbQuestion($sender);
        $force_drop_refusal = _shouldForceDropDbRefusal($sender);
    }
    _injectEmotionHint($sender);
    if (_shouldRefuseEmoteRequest($sender, $intent, $intent_context)) {
        _injectEmoteSpamRefusalHint($sender);
    } elsif (_queueEmotionRequestIfNeeded($sender, $message, 'private', $intent, $intent_context)) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'private',
            sender => $sender,
            message => $message,
        );
        return;
    } elsif (_queueDropDbResponseIfNeeded($sender, $message, 'private', $intent, $force_drop_refusal)) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'private',
            sender => $sender,
            message => $message,
        );
        return;
    }

    AIChat::Log::log_message(
        direction => 'in',
        visibility => 'private',
        sender => $sender,
        message => $message,
    );
    _enqueueMessage($sender, $message, { type => 'private' });
}

sub onPublicMessage {
    my (undef, $args) = @_;
    return unless defined $field;
    my $sender = _resolvePacketField($args, qw(pubMsgUser MsgUser));
    my $message = _resolvePacketField($args, qw(pubMsg Msg));
    $sender = bytesToString($args->{pubMsgUser}) if (!defined $sender || $sender eq '') && defined $args->{pubMsgUser};
    $message = bytesToString($args->{pubMsg}) if (!defined $message || $message eq '') && defined $args->{pubMsg};
    return unless defined $sender && $sender ne '';
    return unless defined $message && $message ne '';

    return unless defined $sender && defined $message;
    return if $char && defined $char->{name} && $sender eq $char->{name};

    my $map_name = $field->baseName // '';
    if ($map_name ne 'sec_pri') {
        my $lock_map = $config{lockMap} // '';
        my $allow_public = AIChat::Config::get('public_on_lockmap');
        return unless $lock_map && $map_name eq $lock_map && $allow_public;
    }

    my $sender_id = $args->{pubID};
    my $actor = _getSenderActor($sender, $sender_id);
    my $visibility_state = _resolveVisibilityState($actor);
    return if $actor && !_isSenderWithinPublicRange($actor);
    _ensureVisibilityInfo($sender, $visibility_state);
    _ensurePlayerInfo($sender, $actor) if $visibility_state eq 'visible';

    my $intent_context = { map_name => $field ? $field->baseName : undef, lock_map => $config{lockMap} };
    my $intent;
    $intent = _interpretCommand($message, $sender, $intent_context);
    if (_shouldForceDropDbIntent($sender, $intent, $message)) {
        $intent = { action => 'drop_db', is_question => 1 };
    }
    if (_handleSpamCheck($sender, $message, 'public', $intent)) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'public',
            sender => $sender,
            message => $message,
        );
        return;
    }
    if (_handleConversationLimit($sender, $message, 'public')) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'public',
            sender => $sender,
            message => $message,
        );
        return;
    }
    my $force_drop_refusal = 0;
    if (_isDropDbIntent($intent)) {
        _recordDropDbQuestion($sender);
        $force_drop_refusal = _shouldForceDropDbRefusal($sender);
    }
    _injectEmotionHint($sender);
    if (_shouldRefuseEmoteRequest($sender, $intent, $intent_context)) {
        _injectEmoteSpamRefusalHint($sender);
    } elsif (_queueEmotionRequestIfNeeded($sender, $message, 'public', $intent, $intent_context)) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'public',
            sender => $sender,
            message => $message,
        );
        return;
    } elsif (_queueDropDbResponseIfNeeded($sender, $message, 'public', $intent, $force_drop_refusal)) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'public',
            sender => $sender,
            message => $message,
        );
        return;
    }

    AIChat::Log::log_message(
        direction => 'in',
        visibility => 'public',
        sender => $sender,
        message => $message,
    );
    _enqueueMessage($sender, $message, { type => 'public' });
}

sub _getSenderActor {
    my ($sender, $sender_id) = @_;
    my $actor;
    if (defined $sender_id) {
        $actor = Actor::get($sender_id);
    }
    if (!$actor && $playersList && defined $sender) {
        ($actor) = grep { $_->{name} && $_->{name} eq $sender } @{$playersList->getItems};
    }
    return $actor;
}

sub _resolveActorClass {
    my ($actor) = @_;
    return unless $actor;
    my $job_id = $actor->{jobID};
    return $jobs_lut{$job_id} if defined $job_id && $jobs_lut{$job_id};
    return $actor->{job} if defined $actor->{job} && $actor->{job} ne '';
    return;
}

sub _isActorInvisible {
    my ($actor) = @_;
    return unless $actor;
    my $statuses = $actor->{statuses};
    return unless $statuses && ref $statuses eq 'HASH';
    for my $status (keys %invisibility_statuses) {
        return 1 if $statuses->{$status};
    }
    return;
}

sub _resolveVisibilityState {
    my ($actor) = @_;
    return 'not_visible' unless $actor;
    return 'not_visible' if _isActorInvisible($actor);
    return 'visible';
}

sub _ensurePlayerInfo {
    my ($sender, $actor) = @_;
    return unless defined $sender;
    return unless $actor;
    my $class = _resolveActorClass($actor) // 'Desconhecida';
    my $player_info = join "\n",
        "Informacoes do jogador que esta falando com voce:",
        "Nome: $sender",
        "Classe: $class";

    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    my $last_info;
    for (my $i = @$history - 1; $i >= 0; $i--) {
        my $entry = $history->[$i];
        next unless $entry->{role} && $entry->{role} eq 'system';
        next unless ($entry->{type} // '') eq 'player_info';
        $last_info = $entry->{content};
        last;
    }
    return if defined $last_info && $last_info eq $player_info;

    AIChat::ConversationHistory::addMessage($sender, "system", $player_info, "player_info");
}

sub _ensureVisibilityInfo {
    my ($sender, $visibility_state) = @_;
    return unless defined $sender && defined $visibility_state;

    my $sender_key = _normalizeSenderKey($sender);
    my $last_state = $last_visibility_state_by_sender{$sender_key};
    return if defined $last_state && $last_state eq $visibility_state;

    $last_visibility_state_by_sender{$sender_key} = $visibility_state;

    my $visibility_info;
    if ($visibility_state eq 'visible') {
        $visibility_info = join "\n",
            "Informacoes de visibilidade do jogador:",
            "O jogador esta visivel para voce agora.";
    } else {
        $visibility_info = join "\n",
            "Informacoes de visibilidade do jogador:",
            "Voce nao esta vendo esse jogador agora (pode estar longe ou invisivel).",
            "Se a pergunta depender de ver o jogador, responda dizendo que nao esta vendo.";
    }

    AIChat::ConversationHistory::addMessage($sender, "system", $visibility_info, "visibility_info");
}

sub _isSenderWithinPublicRange {
    my ($actor) = @_;
    return unless $char && $char->{pos_to};
    return unless $actor && $actor->{pos_to};

    my $dist = distance($char->{pos_to}, $actor->{pos_to});
    return defined $dist && $dist <= MAX_PUBLIC_CHAT_DISTANCE;
}

sub onEmotion {
    my (undef, $args) = @_;

    my $command = _getEmotionCommandByDisplay($args->{emotion});
    return unless $command;

    $last_emotion_command = $command;
    $last_emotion_time = time;

    my $actor = Actor::get($args->{ID});
    return unless $actor;
    my $name = bytesToString($actor->name);
    return unless defined $name && $name ne '';
    my $sender_key = _normalizeSenderKey($name);

    $last_emotion_command_by_sender{$sender_key} = $command;
    $last_emotion_time_by_sender{$sender_key} = $last_emotion_time;
    $last_emotion_display_by_sender{$sender_key} = $args->{emotion};
}

sub _getEmotionCommandByDisplay {
    my ($display) = @_;
    return unless defined $display;
    for my $emotion_id (keys %emotions_lut) {
        next unless defined $emotions_lut{$emotion_id}{display};
        next unless $emotions_lut{$emotion_id}{display} eq $display;
        my $commands = $emotions_lut{$emotion_id}{command};
        next unless $commands;
        my ($first_command) = split /\s*,\s*/, $commands;
        return $first_command if $first_command;
    }
    return;
}

sub _extractEmotionCommand {
    my ($response) = @_;
    return unless defined $response;
    if ($response =~ /^\s*(?:\/?e)\s+([^\s]+)\s*$/i) {
        return $1;
    }
    return;
}

sub _queueDropDbResponseIfNeeded {
    my ($sender, $message, $context, $intent, $force_refusal) = @_;
    return unless defined $sender && defined $message;
    return unless $intent && ref $intent eq 'HASH';
    return unless ($intent->{action} // '') eq 'drop_db';

    my $mob_database_enabled = AIChat::Config::get('mob_database');
    if (!defined $mob_database_enabled || !$mob_database_enabled) {
        $force_refusal = 1;
    }

    my $response;
    if ($force_refusal) {
        $response = AIChat::MessageHandler::generateDropDbRefusal($message, $sender);
    } else {
        $response = AIChat::MessageHandler::generateDropDbChatResponse($message, $sender);
    }
    $response = AIChat::MessageHandler::dropDbUnknownReply() unless defined $response && $response ne '';
	$response = AIChat::MessageHandler::_normalizeDropDbOutput($response)
		if defined $response && $response ne '';
    AIChat::ConversationHistory::addMessage($sender, "user", $message, "intent");
    my @parts = _splitOutgoingResponse($response);
    if (@parts > 1) {
        my $state = _getBufferState($sender);
        $state->{messages} = [];
        $state->{response_queue} = [];
        my $buffer_delay = AIChat::Config::get('buffer_delay');
        $buffer_delay = 2 unless defined $buffer_delay;
        $state->{buffer_deadline} = time() + $buffer_delay;
        $state->{typing_until} = 0;
        $state->{response_started} = 0;
        $state->{context} = { type => $context };
        push @{$state->{response_queue}}, @parts;
    } else {
        _queueDirectResponse($sender, $response, { type => $context });
    }
    return 1;
}

sub _isDropDbIntent {
    my ($intent) = @_;
    return $intent && ref $intent eq 'HASH' && ($intent->{action} // '') eq 'drop_db';
}

sub _getLastDropDbStance {
    my ($sender) = @_;
    return unless defined $sender;
    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    for (my $i = @$history - 1; $i >= 0; $i--) {
        my $entry = $history->[$i];
        next unless ($entry->{type} // '') eq 'drop_db_stance';
        return $entry->{content};
    }
    return;
}

sub _hasLastDropDbSubject {
    my ($sender) = @_;
    return 0 unless defined $sender;
    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    for (my $i = @$history - 1; $i >= 0; $i--) {
        my $entry = $history->[$i];
        next unless ($entry->{type} // '') eq 'drop_db_answer';
        my $content = $entry->{content};
        next unless defined $content && $content ne '';
        my $data;
        eval { $data = decode_json($content); };
        next if $@ || !$data || ref $data ne 'HASH';
        return 1 if defined $data->{subject} && $data->{subject} ne '';
        return 1 if defined $data->{entity} && $data->{entity} ne '';
    }
    return 0;
}

sub _hasDropDbIntentHistory {
    my ($sender) = @_;
    return 0 unless defined $sender;
    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    for (my $i = @$history - 1; $i >= 0; $i--) {
        my $entry = $history->[$i];
        next unless ($entry->{type} // '') eq 'intent';
        my $content = $entry->{content};
        next unless defined $content && $content ne '';
        my $data;
        eval { $data = decode_json($content); };
        next if $@ || !$data || ref $data ne 'HASH';
        return 1 if ($data->{action} // '') eq 'drop_db';
    }
    return 0;
}

sub _countWords {
    my ($text) = @_;
    return 0 unless defined $text;
    my @words = grep { length } split /\s+/, $text;
    return scalar @words;
}

sub _shouldForceDropDbIntent {
    my ($sender, $intent, $message) = @_;
    return 0 unless defined $sender;
    $intent = {} unless $intent && ref $intent eq 'HASH';
    return 0 if ($intent->{action} // '') eq 'drop_db';
    if (defined $message && $message ne '' && AIChat::MessageHandler::_isDropDbQueryMessage($message)) {
        return 1;
    }
    return 0 unless (_hasLastDropDbSubject($sender) || _hasDropDbIntentHistory($sender));
    my $normalized = defined $message ? AIChat::MessageHandler::_normalizeQueryText($message) : '';
    my $has_followup_keyword = $normalized =~ /\b(onde|mapa|qual|local|localizacao|lugar)\b/;
    return 1 if $has_followup_keyword;
    return 1 if ($intent->{is_question} // 0) && _countWords($message) <= 4;
    return 1 if defined $message && $message =~ /[?]/ && _countWords($message) <= 4;
    return _countWords($message) <= 2;
}

sub _normalizeSenderKey {
    my ($sender) = @_;
    return unless defined $sender;
    my $key = $sender;
    $key =~ s/^\s+//;
    $key =~ s/\s+$//;
    return lc $key;
}

sub _resolvePacketField {
    my ($args, @keys) = @_;
    return undef unless $args && ref $args eq 'HASH';
    for my $key (@keys) {
        my $value = $args->{$key};
        return $value if defined $value && $value ne '';
    }
    return undef;
}

sub _recordDropDbQuestion {
    my ($sender) = @_;
    return unless defined $sender;
    my $key = _normalizeSenderKey($sender);
    return unless $key;
    $drop_db_question_count{$key} = ($drop_db_question_count{$key} // 0) + 1;
    $drop_db_refusal_limit{$key} = _getDropDbQuestionLimit()
        unless defined $drop_db_refusal_limit{$key};
    if ($drop_db_question_count{$key} >= $drop_db_refusal_limit{$key}) {
        $drop_db_force_refusal{$key} = 1;
    }
}

sub _getDropDbQuestionLimit {
    my $limit = AIChat::Config::get('dropdb_question_limit');
    my $resolved = _resolveRangeLimit($limit, 0);
    return $resolved if $resolved && $resolved > 0;
    return DROP_DB_REFUSAL_MIN + int(rand(DROP_DB_REFUSAL_MAX - DROP_DB_REFUSAL_MIN + 1));
}

sub _resolveRangeLimit {
    my ($value, $fallback) = @_;
    $fallback = 0 unless defined $fallback;
    return $fallback unless defined $value;
    my $trimmed = $value;
    $trimmed =~ s/^\s+//;
    $trimmed =~ s/\s+$//;
    if ($trimmed =~ /^(\d+)\s*\.\.\s*(\d+)$/) {
        my ($min, $max) = ($1, $2);
        return $min if $min == $max;
        ($min, $max) = ($max, $min) if $min > $max;
        return $min + int(rand($max - $min + 1));
    }
    return $trimmed if $trimmed =~ /^\d+$/;
    return $fallback;
}

sub _shouldForceDropDbRefusal {
    my ($sender) = @_;
    return unless defined $sender;
    my $key = _normalizeSenderKey($sender);
    return unless $key;
    return $drop_db_force_refusal{$key} ? 1 : 0;
}

sub _queueEmotionRequestIfNeeded {
    my ($sender, $message, $context, $intent, $intent_context) = @_;
    return unless defined $sender && defined $message;
    return unless _isEmotionRequest($message, $sender, $intent, $intent_context);

    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;

    my $delay = 3 + rand(3);
    my $state = _getBufferState($sender);
    $state->{messages} = [];
    $state->{response_queue} = [];
    $state->{typing_until} = 0;
    $state->{response_started} = 0;

    AIChat::ConversationHistory::addMessage($sender, "user", $message, "intent");
    _recordEmoteRequest($sender);

    my $action = $intent && ref $intent eq 'HASH' ? ($intent->{action} // '') : '';
    $pending_emotion_request_by_sender{$sender_key} = {
        requested_at => time(),
        respond_at => time() + $delay,
        context => $context,
        sender_name => $sender,
        mode => $action,
    };
    return 1;
}

sub _isEmotionRequest {
    my ($message, $sender, $intent, $context) = @_;
    return unless defined $message && defined $sender;
    my $result = $intent || _interpretCommand($message, $sender, $context);
    return unless $result && ref $result eq 'HASH';
    return $result->{action} && ($result->{action} eq 'emote' || $result->{action} eq 'emote_random');
}

sub _shouldRefuseEmoteRequest {
    my ($sender, $intent, $context) = @_;
    return unless defined $sender;
    return unless $intent && ref $intent eq 'HASH';
    return unless $intent->{action} && ($intent->{action} eq 'emote' || $intent->{action} eq 'emote_random');

    my $map_name = $context && defined $context->{map_name} ? $context->{map_name} : '';
    return if $map_name eq 'sec_pri';

    my $lock_map = $context && defined $context->{lock_map} ? $context->{lock_map} : '';
    return unless $lock_map && $map_name eq $lock_map;

    return _isEmoteSpam($sender);
}

sub _recordEmoteRequest {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    push @{$emote_request_times_by_sender{$sender_key}}, time();
}

sub _isEmoteSpam {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    my $now = time();
    my $window = 60;
    my $max_requests = 3;
    my $times = $emote_request_times_by_sender{$sender_key} || [];
    my @recent = grep { ($now - $_) <= $window } @$times;
    $emote_request_times_by_sender{$sender_key} = \@recent;
    return scalar(@recent) >= $max_requests;
}

sub _injectEmoteSpamRefusalHint {
    my ($sender) = @_;
    return unless defined $sender;
    AIChat::ConversationHistory::addMessage($sender, "system", "Usuario insistiu em varios emoticons seguidos. Responda curto e seco recusando ou pedindo para parar.", "intent");
}

sub _interpretCommand {
    my ($message, $sender, $context) = @_;
    return unless defined $message && defined $sender;
    return AIChat::MessageHandler::interpretCommand($message, $sender, $context);
}

sub _processPendingEmotionRequests {
    my ($now) = @_;
    for my $sender_key (keys %pending_emotion_request_by_sender) {
        my $pending = $pending_emotion_request_by_sender{$sender_key};
        next unless $pending;

        my $respond_at = $pending->{respond_at} // 0;
        next unless $respond_at;
        next unless $now >= $respond_at;
        if (_shouldThrottleOutgoingPackets()) {
            $pending->{respond_at} = _nextAllowedPacketTime();
            next;
        }

        my $command;
        if (($pending->{mode} // '') eq 'emote_random') {
            $command = _pickFallbackEmotionCommand();
        } else {
            $command = _getRecentEmotionForSender($sender_key, $now);
            if (!$command) {
                $command = _pickFallbackEmotionCommand();
            }
        }

        _sendEmotionByCommand($command) if $command;
        _resetQuestionStreak($pending->{sender_name});
        _queueEmotionFollowup($pending->{sender_name}, $pending->{context});
        delete $pending_emotion_request_by_sender{$sender_key};
    }
}

sub _getRecentEmotionForSender {
    my ($sender_key, $now) = @_;
    return unless defined $sender_key;
    my $command = $last_emotion_command_by_sender{$sender_key};
    my $seen_time = $last_emotion_time_by_sender{$sender_key} // 0;
    return unless $command && $seen_time;
    return if ($now - $seen_time) > 120;
    return $command;
}

sub _pickFallbackEmotionCommand {
    my $count = scalar @fallback_emotion_commands;
    return unless $count;
    return $fallback_emotion_commands[int(rand($count))];
}

sub _sendEmotionByCommand {
    my ($command) = @_;
    return unless defined $command;
    my $emotion_id = getEmotionByCommand($command);
    return unless defined $emotion_id;
    $messageSender->sendEmotion($emotion_id);
    _recordOutgoingPacketSent();
}

sub _queueEmotionFollowup {
    my ($sender_name, $context) = @_;
    return unless defined $sender_name;
    return unless rand() < 0.25;
    my $followup = AIChat::MessageHandler::generateEmoteFollowup($sender_name, { map_name => $field ? $field->baseName : undef });
    return unless $followup;

    my $sender_key = _normalizeSenderKey($sender_name);
    return unless $sender_key;

    my $typing_speed = AIChat::Config::get('typing_speed');
    my $typing_delay = 3;
    if ($typing_speed && $typing_speed > 0) {
        $typing_delay = length($followup) / $typing_speed;
        $typing_delay = 3 if $typing_delay < 3;
    }

    my $send_at = time() + $typing_delay;
    $pending_emotion_followup_by_sender{$sender_key} = {
        send_at => $send_at,
        message => $followup,
        context => $context,
        sender_name => $sender_name,
    };
    $suppress_reply_until_by_sender{$sender_key} = $send_at + 1;
}

sub _processPendingEmotionFollowups {
    my ($now) = @_;
    for my $sender_key (keys %pending_emotion_followup_by_sender) {
        my $pending = $pending_emotion_followup_by_sender{$sender_key};
        next unless $pending;

        my $send_at = $pending->{send_at} // 0;
        next unless $send_at;
        next unless $now >= $send_at;
        next if _shouldThrottleOutgoingPackets();

        my $message = _sanitizeOutgoingMessage($pending->{message});
        if (!$message) {
            delete $pending_emotion_followup_by_sender{$sender_key};
            next;
        }
        my $context = $pending->{context};
        my $sender_name = $pending->{sender_name};
        if ($context && $context eq 'public') {
            $messageSender->sendChat($message);
            _recordOutgoingPacketSent();
            AIChat::Log::log_message(
                direction => 'out',
                visibility => 'public',
                sender => 'Public',
                message => $message,
            );
        } else {
            $messageSender->sendPrivateMsg($sender_name, $message);
            _recordOutgoingPacketSent();
            AIChat::Log::log_message(
                direction => 'out',
                visibility => 'private',
                sender => $sender_name,
                message => $message,
            );
        }

        AIChat::ConversationHistory::addMessage($sender_name, "assistant", $message);
        delete $pending_emotion_followup_by_sender{$sender_key};
    }
}

sub _minPacketInterval {
    my $interval = AIChat::Config::get('min_packet_interval');
    $interval = 0.6 unless defined $interval;
    return $interval < 0 ? 0 : $interval;
}

sub _nextAllowedPacketTime {
    my $interval = _minPacketInterval();
    return $last_packet_sent_at + $interval;
}

sub _shouldThrottleOutgoingPackets {
    my ($state) = @_;
    my $now = time();
    my $next_allowed = _nextAllowedPacketTime();
    return if $now >= $next_allowed;
    if ($state) {
        $state->{typing_until} = $next_allowed
            if !$state->{typing_until} || $state->{typing_until} < $next_allowed;
    }
    return 1;
}

sub _recordOutgoingPacketSent {
    $last_packet_sent_at = time();
}

sub _hasPendingEmotionRequest {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    return exists $pending_emotion_request_by_sender{$sender_key};
}

sub _hasPendingEmotionFollowup {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    return exists $pending_emotion_followup_by_sender{$sender_key};
}

sub _isReplySuppressed {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    my $until = $suppress_reply_until_by_sender{$sender_key} // 0;
    return 1 if $until && time() < $until;
    delete $suppress_reply_until_by_sender{$sender_key} if $until;
    return;
}

sub _isSilenced {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    return $silenced_by_sender{$sender_key} ? 1 : 0;
}

sub _shouldAllowSilenceResponse {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    return $silence_after_response_by_sender{$sender_key} ? 1 : 0;
}

sub _isBlockedSender {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    return $blocked_by_sender{$sender_key} ? 1 : 0;
}

sub _shouldHandleConversationLimit {
    my $limit = AIChat::Config::get('conversation_limit');
    return _resolveRangeLimit($limit, 0);
}

sub _incrementConversationCount {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    $conversation_message_count_by_sender{$sender_key} = ($conversation_message_count_by_sender{$sender_key} // 0) + 1;
    return $conversation_message_count_by_sender{$sender_key};
}

sub _conversationCloseStage {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    return $conversation_close_stage_by_sender{$sender_key} // 0;
}

sub _setConversationCloseStage {
    my ($sender, $stage) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    $conversation_close_stage_by_sender{$sender_key} = $stage;
}

sub _pickConversationCloseWarning {
    my @messages = AIChat::References::get('conversation_close_warning');
    return '' unless @messages;
    return $messages[int(rand(@messages))];
}

sub _pickConversationCloseFinal {
    my @messages = AIChat::References::get('conversation_close_final');
    return '' unless @messages;
    return $messages[int(rand(@messages))];
}

sub _pickConversationCloseGoodbye {
    my @messages = AIChat::References::get('conversation_close_goodbye');
    return '' unless @messages;
    return $messages[int(rand(@messages))];
}

sub _interpretConversationCloseAcknowledgement {
    my ($sender, $message) = @_;
    return unless defined $sender && defined $message;

    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    my @recent = grep { $_->{role} ne "system" } @$history;
    @recent = @recent[-6 .. -1] if @recent > 6;

    my @messages = (
        {
            role => "system",
            content => "Voce e um classificador de conversa. Responda apenas com JSON valido no formato {\"acknowledge\":true|false}. Marque true se o jogador concordar em encerrar a conversa, aceitar o encerramento, se despedir, agradecer ou indicar que vai parar o papo. Marque false se ele insistir, pedir para continuar, insistir em assunto, ou ignorar o encerramento. Nao inclua nenhum texto fora do JSON.",
        }
    );

    push @messages, map {
        {
            role => $_->{role},
            content => $_->{content},
        }
    } @recent;

    push @messages, {
        role => "user",
        content => $message,
    };

    my $response;
    eval {
        $response = $ack_client->callAPIWithMessages(\@messages, {
            max_tokens => 40,
            temperature => 0,
        });
    };
    if ($@) {
        warning "[aiChat] Erro ao interpretar encerramento: $@\n", "plugin";
        return;
    }

    return unless defined $response && length $response;
    my $parsed;
    eval {
        $parsed = decode_json($response);
    };
    if ($@ || !ref $parsed) {
        debug "[aiChat] Resposta invalida ao interpretar encerramento: $response\n", "plugin";
        return;
    }

    return $parsed->{acknowledge} ? 1 : 0;
}

sub _handleConversationLimit {
    my ($sender, $message, $context) = @_;
    return unless defined $sender;
    my $limit = _shouldHandleConversationLimit();
    return unless $limit;
    my $count = _incrementConversationCount($sender);
    return unless defined $count;
    my $stage = _conversationCloseStage($sender);
    return if $count < $limit && !$stage;

    if (!$stage) {
        my $response = _pickConversationCloseWarning();
        _queueDirectResponse($sender, $response, { type => $context, normalize => 1 });
        _setConversationCloseStage($sender, 1);
        return 1;
    }

    if ($stage == 1) {
        my $response = _interpretConversationCloseAcknowledgement($sender, $message)
            ? _pickConversationCloseGoodbye()
            : _pickConversationCloseFinal();
        _queueDirectResponse($sender, $response, { type => $context, normalize => 1 });
        _setConversationCloseStage($sender, 2);
        _markSilenceAfterResponse($sender);
        return 1;
    }

    return 1 if $stage >= 2;
    return;
}

sub _resetQuestionStreak {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    $question_streak_by_sender{$sender_key} = 0;
}

sub _handleSpamCheck {
    my ($sender, $message, $context, $intent) = @_;
    return unless defined $sender && defined $message;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;

    if (_isBlockedSender($sender)) {
        return 1;
    }

    if (_isSilenced($sender)) {
        $silence_message_count_by_sender{$sender_key} = ($silence_message_count_by_sender{$sender_key} // 0) + 1;
        if ($silence_message_count_by_sender{$sender_key} >= SILENCE_BLOCK_THRESHOLD) {
            _blockSender($sender);
        }
        return 1;
    }

    if (_isSabotageIntent($intent)) {
        my $queued = _queueSabotageRefusal($sender, $context);
        $queued = _queueSabotageRefusalFallback($sender, $context) unless $queued;
        _markSilenceAfterResponse($sender) if $queued;
        return 1;
    }

    my $should_count = _shouldCountSpamQuestion($intent);
    if (!$should_count) {
        _resetQuestionStreak($sender);
        return;
    }

    my $spam_limit = _getSpamQuestionLimit();
    return if $spam_limit <= 0;

    $question_streak_by_sender{$sender_key} = ($question_streak_by_sender{$sender_key} // 0) + 1;
    if ($question_streak_by_sender{$sender_key} >= $spam_limit) {
        my $queued = _queueSpamRefusal($sender, $message, $context);
        $queued = _queueSpamRefusalFallback($sender, $context) unless $queued;
        _markSilenceAfterResponse($sender) if $queued;
        return 1;
    }

    return;
}

sub _getSpamQuestionLimit {
    my $limit = AIChat::Config::get('spam_question_limit');
    return _resolveRangeLimit($limit, SPAM_QUESTION_LIMIT);
}

sub _buildSpamRefusalMessage {
    my $message = _pickSpamRefusalReference();
    return AIChat::MessageHandler::_normalizeResponseText($message);
}

sub _queueSpamRefusal {
    my ($sender, $message, $context) = @_;
    return unless defined $sender && defined $message;
    my $response = _buildSpamRefusalMessage($sender, $message);
    return unless defined $response && $response ne '';
    my $state = _getBufferState($sender);
    $state->{messages} = [];
    $state->{response_queue} = [];
    my $buffer_delay = AIChat::Config::get('buffer_delay');
    $buffer_delay = 2 unless defined $buffer_delay;
    $state->{typing_until} = 0;
    $state->{response_started} = 0;
    $state->{context} = { type => $context, sabotage => 1 };
    $state->{buffer_deadline} = time() + $buffer_delay;
    my @parts = _splitOutgoingResponse($response);
    return unless @parts;
    my $typing_delay = _calculateTypingDelay($parts[0]);
    if ($typing_delay > 0) {
        $state->{typing_until} = time() + $buffer_delay + $typing_delay;
    }
    push @{$state->{response_queue}}, @parts;
    return 1;
}

sub _queueSpamRefusalFallback {
    my ($sender, $context) = @_;
    return unless defined $sender;
    my $message = _pickSpamRefusalReference();
    return unless defined $message && $message ne '';
    my $state = _getBufferState($sender);
    $state->{messages} = [];
    $state->{response_queue} = [];
    my $buffer_delay = AIChat::Config::get('buffer_delay');
    $buffer_delay = 2 unless defined $buffer_delay;
    $state->{typing_until} = 0;
    $state->{response_started} = 0;
    $state->{context} = { type => $context, sabotage => 1 };
    $state->{buffer_deadline} = time() + $buffer_delay;
    my @parts = _splitOutgoingResponse($message);
    return unless @parts;
    my $typing_delay = _calculateTypingDelay($parts[0]);
    if ($typing_delay > 0) {
        $state->{typing_until} = time() + $buffer_delay + $typing_delay;
    }
    push @{$state->{response_queue}}, @parts;
    return 1;
}

sub _pickSpamRefusalReference {
    my @messages = AIChat::References::get('spam_refusal');
    return '' unless @messages;
    return $messages[int(rand(@messages))];
}

sub _pickSabotageRefusalReference {
    my @messages = AIChat::References::get('sabotage_refusal');
    return '' unless @messages;
    return $messages[int(rand(@messages))];
}

sub _buildSabotageRefusalMessage {
    my $message = _pickSabotageRefusalReference();
    return AIChat::MessageHandler::_normalizeResponseText($message);
}

sub _queueSabotageRefusal {
    my ($sender, $context) = @_;
    return unless defined $sender;
    my $message = _buildSabotageRefusalMessage();
    return unless defined $message && $message ne '';
    my $state = _getBufferState($sender);
    $state->{messages} = [];
    $state->{response_queue} = [];
    my $buffer_delay = AIChat::Config::get('buffer_delay');
    $buffer_delay = 2 unless defined $buffer_delay;
    $state->{typing_until} = 0;
    $state->{response_started} = 0;
    $state->{context} = { type => $context, sabotage => 1 };
    $state->{buffer_deadline} = time() + $buffer_delay;
    my @parts = _splitOutgoingResponse($message);
    return unless @parts;
    my $typing_delay = _calculateTypingDelay($parts[0]);
    if ($typing_delay > 0) {
        $state->{typing_until} = time() + $buffer_delay + $typing_delay;
    }
    push @{$state->{response_queue}}, @parts;
    return 1;
}

sub _queueSabotageRefusalFallback {
    my ($sender, $context) = @_;
    return _queueSabotageRefusal($sender, $context);
}

sub _markSilenceAfterResponse {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    $silence_after_response_by_sender{$sender_key} = 1;
    $silence_message_count_by_sender{$sender_key} = 0;
    $question_streak_by_sender{$sender_key} = 0;
}

sub _calculateTypingDelay {
    my ($message) = @_;
    return 0 unless defined $message;
    my $typing_speed = AIChat::Config::get('typing_speed');
    return 0 unless $typing_speed && $typing_speed > 0;
    my $delay = length($message) / $typing_speed;
    return $delay > 0 ? $delay : 0;
}

sub _finalizeSilenceIfNeeded {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    return unless delete $silence_after_response_by_sender{$sender_key};
    _silenceSender($sender);
}

sub _silenceSender {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    $silenced_by_sender{$sender_key} = 1;
    $silence_message_count_by_sender{$sender_key} = 0;
    $question_streak_by_sender{$sender_key} = 0;
    delete $conversation_message_count_by_sender{$sender_key};
    delete $conversation_close_stage_by_sender{$sender_key};
    delete $message_buffers{$sender};
    delete $pending_emotion_request_by_sender{$sender_key};
    delete $pending_emotion_followup_by_sender{$sender_key};
    delete $suppress_reply_until_by_sender{$sender_key};
}

sub _blockSender {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;
    return if $blocked_by_sender{$sender_key};
    Commands::run("ignore 1 $sender");
    $blocked_by_sender{$sender_key} = 1;
    delete $conversation_message_count_by_sender{$sender_key};
    delete $conversation_close_stage_by_sender{$sender_key};
}

sub _shouldCountSpamQuestion {
    my ($intent) = @_;
    return unless $intent && ref $intent eq 'HASH';
    my $action = $intent->{action} // '';
    return 1 if $action eq 'chat' && $intent->{is_question};
    return 1 if $action eq 'drop_db';
    return;
}

sub _isSabotageIntent {
    my ($intent) = @_;
    return unless $intent && ref $intent eq 'HASH';
    return ($intent->{action} // '') eq 'sabotage';
}

sub _injectEmotionHint {
    my ($sender) = @_;
    return unless defined $sender;
    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;

    my $command = $last_emotion_command_by_sender{$sender_key};
    my $display = $last_emotion_display_by_sender{$sender_key};
    my $seen_time = $last_emotion_time_by_sender{$sender_key};
    if (!$command || !$seen_time || (time - $seen_time) > 120) {
        $command = $last_emotion_command;
        $seen_time = $last_emotion_time;
        $display = undef;
    }
    return unless $command && $seen_time && (time - $seen_time) <= 120;

    my $hint = "Último emoticon visto: comando e $command";
    $hint .= " (display $display)" if defined $display && $display ne '';
    my $last_hint = $last_emotion_hint_by_sender{$sender_key};
    return if defined $last_hint && $last_hint eq $hint;

    AIChat::ConversationHistory::addMessage($sender, "system", $hint, "emotion_hint");
    $last_emotion_hint_by_sender{$sender_key} = $hint;
}

1;