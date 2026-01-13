package AIChat::MessageHandler;

use strict;
use warnings;

use Log qw(warning message debug error);
use JSON::Tiny qw(decode_json);
# No direct Globals qw($char %jobs_lut $field) here.
# Instead, we will rely on data populated by aiChat.pl

use File::Spec;
use Plugins;

use AIChat::APIClient;
use AIChat::Config;
use AIChat::ConversationHistory;

# Global hash to store the bot's character data
our %bot_character_data;

my $api_client;
my $mondb_cache;
my $item_translation_cache;

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

sub _ensureWorldContext {
    my ($sender) = @_;
    return unless defined $sender;

    my $world_context = _buildWorldContext();
    return unless $world_context;

    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    my $last_context;
    for (my $i = @$history - 1; $i >= 0; $i--) {
        my $entry = $history->[$i];
        next unless $entry->{role} && $entry->{role} eq 'system';
        next unless ($entry->{type} // '') eq 'world_context';
        $last_context = $entry->{content};
        last;
    }
    return if defined $last_context && $last_context eq $world_context;

    AIChat::ConversationHistory::addMessage($sender, "system", $world_context, "world_context");
}

sub _buildWorldContext {
    my $map_name = $bot_character_data{map_name} // 'desconhecido';
    my $monsters = _normalizeList($bot_character_data{map_monsters});
    my $items = _normalizeList($bot_character_data{map_items});

    my $monster_text = @$monsters ? join(', ', @$monsters) : 'nenhum confirmado';
    my $item_text = @$items ? join(', ', @$items) : 'nenhum confirmado';
    my $drop_context = _buildBasicDropContext($monsters);

    my $drop_map_text = $drop_context->{map} || 'nenhum basico confirmado';
    my $drop_general = $drop_context->{general} || 'desconhecido';

    return join "\n",
        "Contexto do mapa atual:",
        "Mapa: $map_name",
        "Monstros vistos aqui: $monster_text",
        "Itens vistos no chao: $item_text",
        "Drops basicos possiveis no mapa: $drop_map_text",
        "Drops basicos (geral): $drop_general",
        "Se perguntarem sobre drops, responda apenas com base nesses dados. Use os nomes oficiais de monstros e itens desta lista (tabelas do servidor) e responda em linguagem popular. Se nao tiver certeza, diga que nao sabe ou nao tem certeza.";
}

sub _normalizeList {
    my ($value) = @_;
    return [] unless defined $value;
    return $value if ref $value eq 'ARRAY';
    return [];
}

sub _buildBasicDropContext {
    my ($monsters) = @_;
    my $mondb = _loadMonsterDropDb();
    return { general => '', map => '' } unless $mondb && %$mondb;

    my %present = map { lc $_ => 1 } @$monsters;
    my @general;
    my @map_specific;

    for my $monster (sort keys %$mondb) {
        my $drops = $mondb->{$monster} || [];
        next unless @$drops;
        push @general, "$monster: " . join(', ', @$drops);
        if ($present{lc $monster}) {
            push @map_specific, "$monster: " . join(', ', @$drops);
        }
    }

    return {
        general => join('; ', @general),
        map => join('; ', @map_specific),
    };
}

sub _loadMonsterDropDb {
    return $mondb_cache if $mondb_cache;

    my $path = File::Spec->catfile($Plugins::current_plugin_folder, 'mondb.txt');
    unless (-e $path) {
        $mondb_cache = {};
        return $mondb_cache;
    }

    my %db;
    if (open my $fh, '<:encoding(UTF-8)', $path) {
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s/\r//g;
            $line =~ s/^\s+//;
            $line =~ s/\s+$//;
            next if $line eq '' || $line =~ /^\s*#/;
            my ($monster, $drop_text) = split /\s*:\s*/, $line, 2;
            next unless defined $monster && defined $drop_text;
            my @drops = map {
                my $item = $_;
                $item =~ s/^\s+//;
                $item =~ s/\s+$//;
                _translateItemName($item);
            } split /\s*,\s*/, $drop_text;
            @drops = grep { defined $_ && $_ ne '' } @drops;
            $db{$monster} = \@drops if @drops;
        }
        close $fh;
    }

    $mondb_cache = \%db;
    return $mondb_cache;
}

sub updateMondbFromMap {
    my ($map_monsters, $map_items) = @_;
    my $monsters = _normalizeList($map_monsters);
    my $items = _normalizeList($map_items);
    return unless @$monsters && @$items;

    my %new_items = map { $_ => 1 } grep { defined $_ && $_ ne '' } @$items;
    return unless %new_items;

    my $path = File::Spec->catfile($Plugins::current_plugin_folder, 'mondb.txt');
    return unless -e $path;

    my @lines = ();
    my %drops_by_monster = ();
    if (open my $fh, '<:encoding(UTF-8)', $path) {
        @lines = <$fh>;
        close $fh;
    }

    for my $line (@lines) {
        my $raw = $line;
        chomp $raw;
        $raw =~ s/\r//g;
        next if $raw =~ /^\s*#/ || $raw !~ /:/;
        my ($monster, $drop_text) = split /\s*:\s*/, $raw, 2;
        next unless defined $monster && defined $drop_text;
        my @drops = map {
            my $item = $_;
            $item =~ s/^\s+//;
            $item =~ s/\s+$//;
            $item;
        } split /\s*,\s*/, $drop_text;
        $drops_by_monster{$monster} = \@drops;
    }

    my %line_index = ();
    for my $i (0 .. $#lines) {
        my $raw = $lines[$i];
        chomp $raw;
        $raw =~ s/\r//g;
        next if $raw =~ /^\s*#/ || $raw !~ /:/;
        my ($monster) = split /\s*:\s*/, $raw, 2;
        $line_index{$monster} = $i if defined $monster;
    }

    my $changed = 0;
    for my $monster (@$monsters) {
        next unless defined $monster && $monster ne '';
        my %merged = map { $_ => 1 } @{ $drops_by_monster{$monster} || [] };
        @merged{keys %new_items} = (1) x scalar keys %new_items;
        my @merged_list = sort keys %merged;
        next unless @merged_list;
        $drops_by_monster{$monster} = \@merged_list;
        if (!exists $line_index{$monster}) {
            push @lines, "$monster: " . join(', ', @merged_list) . "\n";
            $changed = 1;
        } else {
            my $index = $line_index{$monster};
            my $updated_line = "$monster: " . join(', ', @merged_list) . "\n";
            if ($lines[$index] ne $updated_line) {
                $lines[$index] = $updated_line;
                $changed = 1;
            }
        }
    }

    return unless $changed;
    if (open my $fh, '>:encoding(UTF-8)', $path) {
        print $fh @lines;
        close $fh;
        $mondb_cache = undef;
    }
}

sub _translateItemName {
    my ($item_name) = @_;
    return '' unless defined $item_name && $item_name ne '';
    my $normalized = $item_name;
    $normalized =~ s/\s+$//;
    $normalized =~ s/^\s+//;

    my $map = _loadItemTranslationMap();
    return $map->{lc $normalized} if exists $map->{lc $normalized};
    return $normalized;
}

sub _loadItemTranslationMap {
    return $item_translation_cache if $item_translation_cache;

    my $tables_dir = File::Spec->catfile($Plugins::current_plugin_folder, '..', '..', 'tables');
    my $english_path = File::Spec->catfile($tables_dir, 'items.txt');
    $english_path = File::Spec->catfile($tables_dir, 'Old', 'items.txt') unless -e $english_path;
    my $translated_path = File::Spec->catfile($tables_dir, 'ROla', 'items.txt');

    my %english_by_id;
    if (-e $english_path && open my $fh, '<:encoding(UTF-8)', $english_path) {
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s/\r//g;
            next if $line =~ /^\s*#/ || $line =~ /^\s*\/\// || $line eq '';
            my ($id, $name) = split /#/, $line, 3;
            next unless defined $id && defined $name;
            $english_by_id{$id} = $name if $name ne '';
        }
        close $fh;
    }

    my %translated_by_id;
    if (-e $translated_path && open my $fh, '<:encoding(UTF-8)', $translated_path) {
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s/\r//g;
            next if $line =~ /^\s*#/ || $line =~ /^\s*\/\// || $line eq '';
            my ($id, $name) = split /#/, $line, 3;
            next unless defined $id && defined $name;
            $translated_by_id{$id} = $name if $name ne '';
        }
        close $fh;
    }

    my %map;
    for my $id (keys %english_by_id) {
        my $english = $english_by_id{$id};
        my $translated = $translated_by_id{$id};
        next unless defined $english && defined $translated;
        $map{lc $english} = $translated;
    }

    $item_translation_cache = \%map;
    return $item_translation_cache;
}

sub processMessage {
    my ($message, $sender) = @_;
    return processMessages([$message], $sender);
}

sub processMessages {
    my ($messages, $sender) = @_;
    return undef unless $messages && ref $messages eq 'ARRAY' && @$messages;

    _ensureCharacterInfo($sender);
    _ensureWorldContext($sender);

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
            content => "Você acabou de exibir um emoticon a pedido de uma pessoa. Responda com uma mensagem curta, confirmando se era o que a pessoa queria. Não simule emoticons ou ações em hipotese alguma, apenas uma resposta curta com o estilo de confirmacao curto tipo \"ok?\", \"mais alguma coisa?\", \"ta bom?\", \"foi isso?\". Responda seriamente, mas não seja negativo. Mantenha entre 1 e 4 palavras. Nao use emoticon. Nao diga que nao vai fazer ou que esta ocupado, até porque se esse prompt está sendo ativado, é porque já fez o emoticon. Varie a frase e seja natural."
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
    $response =~ s/\s+/ /g;
    $response =~ s/^\s+//;
    $response =~ s/\s+$//;
    return undef unless length $response;
    my @words = split /\s+/, $response;
    if (@words > 6) {
        $response = join ' ', @words[0..5];
    }
    return $response if length $response;
    return undef;
}

1;
