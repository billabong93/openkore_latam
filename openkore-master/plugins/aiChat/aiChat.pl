package aiChat;

use strict;
use warnings;

use Commands;
use Globals qw(%timeout $messageSender $net %config $char $field %jobs_lut %emotions_lut);
use Settings qw(%sys);
use I18N qw(bytesToString);
use Log qw(warning message debug);
use Plugins;
use AI;
use Misc qw(getEmotionByCommand);
use Utils qw(getHex timeOut);
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
my $last_emotion_command;
my $last_emotion_time;
my %last_emotion_command_by_sender;
my %last_emotion_time_by_sender;
my %last_emotion_display_by_sender;
my %last_emotion_hint_by_sender;
my %pending_emotion_request_by_sender;
my %pending_emotion_followup_by_sender;
my %suppress_reply_until_by_sender;

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

sub _flushBufferedMessages {
    my ($sender, $state) = @_;
    my @messages = @{$state->{messages}};
    $state->{messages} = [];
    $state->{buffer_deadline} = 0;

    my $responses = AIChat::MessageHandler::processMessages(\@messages, $sender);
    if ($responses && ref $responses eq 'ARRAY' && @$responses) {
        push @{$state->{response_queue}}, @$responses;
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

    $response = shift @{$state->{response_queue}};
    $state->{response_started} = 1;
    my $context = $state->{context} || {};
    if ($emotion_command) {
        my $emotion_id = getEmotionByCommand($emotion_command);
        if (defined $emotion_id) {
            $messageSender->sendEmotion($emotion_id);
        } else {
            $messageSender->sendChat($response);
        }
    } elsif ($context->{type} && $context->{type} eq 'public') {
        $messageSender->sendChat($response);
        AIChat::Log::log_message(
            direction => 'out',
            visibility => 'public',
            sender => 'Public',
            message => $response,
        );
    } else {
        $messageSender->sendPrivateMsg($sender, $response);
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
    my $sender = bytesToString($args->{privMsgUser});
    my $message = bytesToString($args->{privMsg});

    if (_queueEmotionRequestIfNeeded($sender, $message, 'private')) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'private',
            sender => $sender,
            message => $message,
        );
        return;
    }

    _injectEmotionHint($sender);
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
    my $sender = bytesToString($args->{pubMsgUser} || $args->{MsgUser});
    my $message = bytesToString($args->{pubMsg} || $args->{Msg});

    return unless defined $sender && defined $message;
    return if $char && defined $char->{name} && $sender eq $char->{name};

    if (_queueEmotionRequestIfNeeded($sender, $message, 'public')) {
        AIChat::Log::log_message(
            direction => 'in',
            visibility => 'public',
            sender => $sender,
            message => $message,
        );
        return;
    }

    _injectEmotionHint($sender);

    my $map_name = $field->baseName // '';
    if ($map_name ne 'sec_pri') {
        my $lock_map = $config{lockMap} // '';
        return unless $lock_map && $map_name eq $lock_map;
        return unless AIChat::Config::get('public_on_lockmap');
    }
    AIChat::Log::log_message(
        direction => 'in',
        visibility => 'public',
        sender => $sender,
        message => $message,
    );
    _enqueueMessage($sender, $message, { type => 'public' });
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

    if ($response =~ /(?:^|\s)(?:\/?e)\s+([^\s]+)/i) {
        return $1;
    }

    return _getEmotionCommandFromText($response);
}

sub _normalizeSenderKey {
    my ($sender) = @_;
    return unless defined $sender;
    my $key = $sender;
    $key =~ s/^\s+//;
    $key =~ s/\s+$//;
    return lc $key;
}

sub _queueEmotionRequestIfNeeded {
    my ($sender, $message, $context) = @_;
    return unless defined $sender && defined $message;
    return unless _isEmotionRequest($message, $sender);

    my $sender_key = _normalizeSenderKey($sender);
    return unless $sender_key;

    my $delay = 3 + rand(3);
    my $state = _getBufferState($sender);
    $state->{messages} = [];
    $state->{response_queue} = [];
    $state->{typing_until} = 0;
    $state->{response_started} = 0;

    $pending_emotion_request_by_sender{$sender_key} = {
        requested_at => time(),
        respond_at => time() + $delay,
        context => $context,
        sender_name => $sender,
    };
    return 1;
}

sub _isEmotionRequest {
    my ($message, $sender) = @_;
    return unless defined $message && defined $sender;
    return AIChat::MessageHandler::isEmotionRequest($message, $sender);
}

sub _processPendingEmotionRequests {
    my ($now) = @_;
    for my $sender_key (keys %pending_emotion_request_by_sender) {
        my $pending = $pending_emotion_request_by_sender{$sender_key};
        next unless $pending;

        my $respond_at = $pending->{respond_at} // 0;
        next unless $respond_at;
        next unless $now >= $respond_at;

        my $command = _getRecentEmotionForSender($sender_key, $now);
        if (!$command) {
            $command = _pickFallbackEmotionCommand();
        }

        _sendEmotionByCommand($command) if $command;
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
}

sub _queueEmotionFollowup {
    my ($sender_name, $context) = @_;
    return unless defined $sender_name;
    my $followup = _pickEmotionFollowup();
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

sub _pickEmotionFollowup {
    my @options = (
        "fiz certo?",
        "era esse emoticom?",
        "to liberado?",
    );
    return $options[int(rand(@options))];
}

sub _processPendingEmotionFollowups {
    my ($now) = @_;
    for my $sender_key (keys %pending_emotion_followup_by_sender) {
        my $pending = $pending_emotion_followup_by_sender{$sender_key};
        next unless $pending;

        my $send_at = $pending->{send_at} // 0;
        next unless $send_at;
        next unless $now >= $send_at;

        my $message = $pending->{message};
        my $context = $pending->{context};
        my $sender_name = $pending->{sender_name};
        if ($context && $context eq 'public') {
            $messageSender->sendChat($message);
            AIChat::Log::log_message(
                direction => 'out',
                visibility => 'public',
                sender => 'Public',
                message => $message,
            );
        } else {
            $messageSender->sendPrivateMsg($sender_name, $message);
            AIChat::Log::log_message(
                direction => 'out',
                visibility => 'private',
                sender => $sender_name,
                message => $message,
            );
        }

        delete $pending_emotion_followup_by_sender{$sender_key};
    }
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

sub _getEmotionCommandFromText {
    my ($text) = @_;
    return unless defined $text;

    my @candidates;
    while ($text =~ /\*([^*]+)\*/g) {
        push @candidates, $1;
    }
    push @candidates, $text;

    for my $candidate (@candidates) {
        my $trimmed = $candidate;
        $trimmed =~ s/^\s+//;
        $trimmed =~ s/\s+$//;
        next unless length $trimmed;

        my $command = _getEmotionCommandByDisplay($trimmed);
        return $command if $command;

        $command = _getEmotionCommandByNormalizedDisplay($trimmed);
        return $command if $command;
    }

    return;
}

sub _getEmotionCommandByNormalizedDisplay {
    my ($display) = @_;
    return unless defined $display;
    my $normalized = _normalizeEmotionDisplay($display);
    return unless length $normalized;

    for my $emotion_id (keys %emotions_lut) {
        my $stored_display = $emotions_lut{$emotion_id}{display};
        next unless defined $stored_display;
        my $normalized_display = _normalizeEmotionDisplay($stored_display);
        next unless length $normalized_display;
        next unless $normalized_display eq $normalized;
        my $commands = $emotions_lut{$emotion_id}{command};
        next unless $commands;
        my ($first_command) = split /\s*,\s*/, $commands;
        return $first_command if $first_command;
    }
    return;
}

sub _normalizeEmotionDisplay {
    my ($display) = @_;
    return '' unless defined $display;
    my $normalized = $display;
    $normalized =~ s/^\s+//;
    $normalized =~ s/\s+$//;
    $normalized =~ s/^\*+//;
    $normalized =~ s/\*+$//;
    $normalized =~ s/\s+/ /g;
    return lc $normalized;
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
