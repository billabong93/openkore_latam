package AIChat::MessageHandler;

use strict;
use warnings;

use Log qw(warning message debug error);
use JSON::Tiny qw(decode_json);
# No direct Globals qw($char %jobs_lut $field) here.
# Instead, we will rely on data populated by aiChat.pl

use AIChat::APIClient;
use AIChat::Config;
use AIChat::ConversationHistory;

# Global hash to store the bot's character data
our %bot_character_data;

my $api_client;

BEGIN {
    $api_client = AIChat::APIClient->new();
}

sub getCharacterInfo {
    my ($sender) = @_;
    
    # Checks if character data is available
    return undef unless %bot_character_data;

    # Checks if there's an existing conversation history for this player
    # If yes, we don't add the system message again for this specific type of info.
    my $history = AIChat::ConversationHistory::getHistory($sender);
    # Check if a 'system' message with 'character_info' type already exists
    my $system_info_exists = 0;
    for my $msg_ref (@$history) {
        if ($msg_ref->{role} eq "system" && $msg_ref->{type} && $msg_ref->{type} eq "character_info") {
            $system_info_exists = 1;
            last;
        }
    }
    return undef if $system_info_exists;

    # Format the message with the bot's character information
    my $info = sprintf(
        "Informações do personagem que voce está simulando:\n" .
        "Nome: %s\n" .
        "Classe: %s\n" .
        "Level Base: %d\n" .
        "Level Job: %d\n" .
        "Mapa Atual: %s",
        $bot_character_data{name},
        $bot_character_data{job},
        $bot_character_data{base_level},
        $bot_character_data{job_level},
        $bot_character_data{map_name}
    );
    
    return $info;
}

sub _splitResponse {
    my ($response, $sender_messages) = @_;
    $response = _dedupeMirror($response, $sender_messages);
    my @parts;
    my $split_chance = AIChat::Config::get('split_chance');
    $split_chance = 0.2 unless defined $split_chance;

    if ($response =~ /\|\|/) {
        @parts = split /\s*\|\|\s*/, $response;
    } else {
        $response =~ s/\s*\r?\n\s*/ /g;
        if (rand() < $split_chance) {
            my ($first, $second);
            if ($response =~ /(.+?[.!?])\s+(.+)/s) {
                ($first, $second) = ($1, $2);
            } elsif ($response =~ /(.+?,)\s+(.+)/s) {
                ($first, $second) = ($1, $2);
            } else {
                my $best_split;
                my $middle = length($response) / 2;
                while ($response =~ /\s+(e|mas|pq|porque|entao|então|so|da[ií])\s+/gi) {
                    my $split_start = $-[0];
                    my $candidate = substr($response, 0, $split_start);
                    my $remainder = substr($response, $split_start + 1);
                    next unless _wordCount($candidate) >= 2 && _wordCount($remainder) >= 2;
                    my $distance = abs($split_start - $middle);
                    if (!$best_split || $distance < $best_split->{distance}) {
                        $best_split = {
                            first => $candidate,
                            second => $remainder,
                            distance => $distance,
                        };
                    }
                }

                if ($best_split) {
                    ($first, $second) = @{$best_split}{qw(first second)};
                }
            }

            if (defined $first && defined $second) {
                if (_wordCount($first) >= 2 && _wordCount($second) >= 2) {
                    @parts = ($first, $second);
                }
            }
        }
    }

    @parts = map {
        my $part = $_;
        $part =~ s/^\s+//;
        $part =~ s/\s+$//;
        $part;
    } grep { defined $_ && length $_ } @parts;

    if (@parts == 2) {
        @parts = () if length($parts[0]) < 3 || length($parts[1]) < 3;
    }

    if (@parts > 2) {
        $parts[1] = join " ", @parts[1 .. $#parts];
        @parts = @parts[0, 1];
    }

    return \@parts if @parts;
    return [$response];
}

sub _wordCount {
    my ($text) = @_;
    return 0 unless defined $text;
    my @words = grep { length } split /\s+/, $text;
    return scalar @words;
}

sub _ensureCharacterInfo {
    my ($sender) = @_;
    my $char_info = getCharacterInfo($sender);
    if ($char_info) {
        AIChat::ConversationHistory::addMessage($sender, "system", $char_info, "character_info");
    }
}

sub processMessage {
    my ($message, $sender) = @_;
    return processMessages([$message], $sender);
}

sub processMessages {
    my ($messages, $sender) = @_;
    return undef unless $messages && ref $messages eq 'ARRAY' && @$messages;

    _ensureCharacterInfo($sender);

    for my $message (@$messages) {
        AIChat::ConversationHistory::addMessage($sender, "user", $message);
    }

    my $combined_message = join "\n", @$messages;
    my $response;
    eval {
        $response = $api_client->callAPI($combined_message, $sender);
    };
    if ($@) {
        error "[aiChat] Erro ao chamar a API: $@\n", "plugin";
        return undef;
    }

    return undef unless defined $response && length $response > 0;

    my $parts = _splitResponse($response, $messages);
    return $parts;
}

sub _normalizeEchoText {
    my ($text) = @_;
    return '' unless defined $text;
    my $normalized = lc $text;
    $normalized =~ s/^\s+//;
    $normalized =~ s/\s+$//;
    $normalized =~ s/\s+/ /g;
    $normalized =~ s/[?!.,:;'"()]+//g;
    return $normalized;
}

sub _dedupeMirror {
    my ($response, $sender_messages) = @_;
    return $response unless defined $response && $sender_messages && ref $sender_messages eq 'ARRAY';
    my $normalized_response = _normalizeEchoText($response);
    return $response unless length $normalized_response;
    return $response if length($normalized_response) < 4;

    for my $message (@$sender_messages) {
        next unless defined $message;
        my $normalized_message = _normalizeEchoText($message);
        next unless length $normalized_message;
        if ($normalized_response eq $normalized_message) {
            return '';
        }
    }

    return $response;
}

sub interpretCommand {
    my ($message, $sender, $context) = @_;
    return undef unless defined $message && defined $sender;

    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    my @recent = grep { $_->{role} ne "system" } @$history;
    @recent = @recent[-6 .. -1] if @recent > 6;

    my @recent_intents = grep { ($_->{type} // '') eq 'intent' } @$history;
    @recent_intents = @recent_intents[-10 .. -1] if @recent_intents > 10;
    my $recent_emote_requests = scalar @recent_intents;

    my $map_name = $context && defined $context->{map_name} ? $context->{map_name} : ($bot_character_data{map_name} // 'desconhecido');
    my $lock_map = $context && defined $context->{lock_map} ? $context->{lock_map} : '';
    my $lock_map_info = $lock_map ne '' ? $lock_map : 'nenhum';
    my @messages = (
        {
            role => "system",
            content => "Voce e um classificador de comandos do bot. Responda apenas com JSON valido no formato {\"action\":\"chat|emote|emote_random|none\"}. Contexto: mapa atual=$map_name, lockMap=$lock_map_info, pedidos_emote_recentemente=$recent_emote_requests. Use o contexto recente se necessario. Marque \"emote\" quando pedirem para reproduzir um emoticon, mesmo em pedidos repetidos ou indiretos. Marque \"emote_random\" quando pedirem um emoticon aleatorio, diferente, outro, ou variado. Em sec_pri, nunca recuse pedidos de emoticon: use \"emote\" ou \"emote_random\" quando o pedido for de emoticon. Fora de sec_pri, aplique moderacao de spam somente quando estiver no lockMap (mapa atual == lockMap). Se estiverem importunando, voce pode recusar escolhendo \"chat\" para responder verbalmente. Marque \"chat\" quando for uma pergunta/comentario comum. Marque \"none\" quando nao houver acao clara. Nao inclua nenhum texto fora do JSON."
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
        $response = $api_client->callAPIWithMessages(\@messages, {
            max_tokens => 80,
            temperature => 0,
        });
    };
    if ($@) {
        warning "[aiChat] Erro ao interpretar comando: $@\n", "plugin";
        return undef;
    }

    return undef unless defined $response && length $response;
    my $parsed;
    eval {
        $parsed = decode_json($response);
    };
    if ($@ || !ref $parsed) {
        warning "[aiChat] Resposta invalida ao interpretar comando: $response\n", "plugin";
        return undef;
    }

    return $parsed;
}

sub generateEmoteFollowup {
    my ($sender, $context) = @_;
    return undef unless defined $sender;

    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    my @recent = grep { $_->{role} ne "system" } @$history;
    @recent = @recent[-6 .. -1] if @recent > 6;

    my $prompt = AIChat::Config::get('prompt');
    my $map_name = $context && defined $context->{map_name} ? $context->{map_name} : ($bot_character_data{map_name} // '');
    if (defined $map_name && $map_name eq 'sec_pri') {
        my $gm_prompt = AIChat::Config::get('prompt_gm');
        $prompt = $gm_prompt if defined $gm_prompt && $gm_prompt ne '';
    }

    my @messages = (
        {
            role => "system",
            content => $prompt
        },
        {
            role => "system",
            content => "Responda com uma mensagem curta apos um emoticon, confirmando se era o que a pessoa queria. Mantenha entre 2 e 6 palavras. Nao use emojis. Varie a frase e seja natural."
        }
    );

    push @messages, map {
        {
            role => $_->{role},
            content => $_->{content},
        }
    } @recent;

    my $response;
    eval {
        $response = $api_client->callAPIWithMessages(\@messages, {
            max_tokens => 40,
            temperature => 0.7,
        });
    };
    if ($@) {
        warning "[aiChat] Erro ao gerar followup de emoticon: $@\n", "plugin";
        return undef;
    }

    return undef unless defined $response && length $response;
    $response =~ s/^\s+//;
    $response =~ s/\s+$//;
    return $response if length $response;
    return undef;
}

1;
