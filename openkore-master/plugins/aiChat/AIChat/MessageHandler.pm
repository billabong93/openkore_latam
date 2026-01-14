package AIChat::MessageHandler;

use strict;
use warnings;

use Log qw(warning message debug error);
use JSON::Tiny qw(decode_json);
use Unicode::Normalize qw(NFD);
# No direct Globals qw($char %jobs_lut $field) here.
# Instead, we will rely on data populated by aiChat.pl

use File::Basename qw(dirname);
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
my %mondb_map_cache;
my $mondb_search_cache;

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

sub _ensureDropDbContext {
    my ($sender) = @_;
    return unless defined $sender;

    my $drop_context = _buildDropDbContext();
    return unless $drop_context;

    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    my $last_context;
    for (my $i = @$history - 1; $i >= 0; $i--) {
        my $entry = $history->[$i];
        next unless $entry->{role} && $entry->{role} eq 'system';
        next unless ($entry->{type} // '') eq 'drop_db_context';
        $last_context = $entry->{content};
        last;
    }
    return if defined $last_context && $last_context eq $drop_context;

    AIChat::ConversationHistory::addMessage($sender, "system", $drop_context, "drop_db_context");
}

sub _buildDropDbContext {
    my $mondb = _loadMonsterDropDb();
    return undef unless $mondb && %$mondb;

    my @entries;
    for my $key (sort keys %$mondb) {
        my $entry = $mondb->{$key} || {};
        my $drops = $entry->{drops} || [];
        my $maps = $entry->{maps} || [];
        next unless @$drops || @$maps;
        my $map_text = @$maps ? " (" . join(', ', @$maps) . ") " : " ";
        push @entries, "$key:$map_text" . join(', ', @$drops);
    }
    return undef unless @entries;

    my $item_index = _buildDropItemIndex($mondb);

    return join "\n",
        "Banco de drops conhecido (use somente essas informacoes):",
        @entries,
        (@$item_index ? ("Indice de itens (item -> monstros que dropam):", @$item_index) : ()),
        "Se nao houver informacao, diga que nao sabe ou nao tem certeza.";
}

sub _buildDropItemIndex {
    my ($mondb) = @_;
    return [] unless $mondb && %$mondb;

    my %item_to_monsters;
    for my $monster (sort keys %$mondb) {
        next if $monster =~ /^Mapa\s+/i;
        my $entry = $mondb->{$monster} || {};
        my $drops = $entry->{drops} || [];
        next unless @$drops;
        for my $drop (@$drops) {
            next unless defined $drop && $drop ne '';
            push @{$item_to_monsters{$drop}}, $monster;
        }
    }

    my @entries;
    for my $item (sort keys %item_to_monsters) {
        my %seen;
        my @monsters = grep { !$seen{$_}++ } @{$item_to_monsters{$item}};
        push @entries, "$item: " . join(', ', @monsters) if @monsters;
    }

    return \@entries;
}

sub _normalizeQueryText {
    my ($text) = @_;
    return '' unless defined $text;
    my $normalized = NFD($text);
    $normalized =~ s/\pM//g;
    $normalized = lc $normalized;
    $normalized =~ s/[^\pL\pN]+/ /g;
    $normalized =~ s/\s+/ /g;
    $normalized =~ s/^\s+//;
    $normalized =~ s/\s+$//;
    return $normalized;
}

sub _normalizeResponseText {
    my ($text) = @_;
    return '' unless defined $text;
    my $normalized = _normalizeQueryText($text);
    $normalized =~ s/\s+/ /g;
    $normalized =~ s/^\s+//;
    $normalized =~ s/\s+$//;
    return $normalized;
}

sub _setLastDropDbContext {
    my ($sender, $context) = @_;
    return unless defined $sender;
    return unless $context && ref $context eq 'HASH';

    my @parts;
    push @parts, "monster=$context->{monster}" if defined $context->{monster} && $context->{monster} ne '';
    push @parts, "item=$context->{item}" if defined $context->{item} && $context->{item} ne '';
    push @parts, "map=$context->{map}" if defined $context->{map} && $context->{map} ne '';
    return unless @parts;

    AIChat::ConversationHistory::addMessage($sender, "system", join('|', @parts), "drop_db_last");
}

sub _getLastDropDbContext {
    my ($sender) = @_;
    return {} unless defined $sender;
    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    for (my $i = @$history - 1; $i >= 0; $i--) {
        my $entry = $history->[$i];
        next unless $entry->{type} && $entry->{type} eq 'drop_db_last';
        next unless defined $entry->{content};
        my %context;
        for my $part (split /\|/, $entry->{content}) {
            my ($key, $value) = split /=/, $part, 2;
            next unless defined $key && defined $value;
            $context{$key} = $value;
        }
        return \%context if %context;
    }
    return {};
}

sub _inferDropDbContextFromHistory {
    my ($sender, $index) = @_;
    return {} unless defined $sender;
    return {} unless $index && ref $index eq 'HASH';
    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    return {} unless @$history;

    my %context;
    for my $entry (@$history) {
        next unless $entry->{role} && ($entry->{role} eq 'user' || $entry->{role} eq 'assistant');
        next unless defined $entry->{content} && $entry->{content} ne '';
        my $tokens = _tokenizeText($entry->{content});
        next unless $tokens && @$tokens;

        my $monster = _findBestPhraseMatch($tokens, $index->{monsters});
        my $item = _findBestPhraseMatch($tokens, $index->{items});
        my $map = _findBestPhraseMatch($tokens, $index->{maps});
        $context{monster} = $monster if $monster;
        $context{item} = $item if $item;
        $context{map} = $map if $map;
    }

    return \%context;
}

sub _pickLimitedList {
    my ($items_ref, $max, $start_at) = @_;
    return [] unless $items_ref && ref $items_ref eq 'ARRAY';
    my @items = grep { defined $_ && $_ ne '' } @$items_ref;
    return [] unless @items;
    $max = 2 unless defined $max && $max > 0;

    my $limit = 1 + int(rand($max));
    $limit = scalar @items if $limit > scalar @items;
    $start_at = 0 unless defined $start_at && $start_at >= 0;
    return [] if $start_at > $#items;
    my $end_at = $start_at + $limit - 1;
    $end_at = $#items if $end_at > $#items;
    return [@items[$start_at .. $end_at]];
}

sub _findListIndex {
    my ($items_ref, $value) = @_;
    return undef unless $items_ref && ref $items_ref eq 'ARRAY';
    return undef unless defined $value && $value ne '';
    for my $i (0 .. $#$items_ref) {
        return $i if $items_ref->[$i] eq $value;
    }
    return undef;
}

sub _pickVariant {
    my (@options) = @_;
    return '' unless @options;
    return $options[int(rand(@options))];
}

sub _randomDropDbRefusal {
    return _normalizeResponseText(_pickVariant(
        'nao to afim de responder isso',
        'nao sou tutor',
        'vai ver no banco de dados',
        'procura no banco de dados',
        'para de perturbar',
        'pesquisa ai',
        'vai atras disso ai',
    ));
}

sub _generateDropDbRefusalResponse {
    my ($message, $sender) = @_;
    return undef unless defined $message && $message ne '';

    my $prompt = AIChat::Config::get('prompt');
    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    my @recent_assistant = grep { ($_->{role} // '') eq 'assistant' } @$history;
    @recent_assistant = @recent_assistant[-3 .. -1] if @recent_assistant > 3;
    my @recent_texts = map { $_->{content} // '' } @recent_assistant;
    my $recent_block = join(' | ', grep { $_ ne '' } @recent_texts);
    my $system_prompt = join "\n",
        $prompt,
        "Voce precisa recusar responder perguntas de drops ou monstros agora.",
        "Seja curto, seco e educado o suficiente para parecer um player.",
        "Nao responda com informacoes do banco de dados.",
        "Nao use frases como 'nao sei' ou 'nao conheco'.",
        "Evite fazer perguntas.",
        "Varie as respostas e nao repita as mesmas palavras.",
        "Nao use a palavra 'google'.",
        ($recent_block ? "Respostas recentes para evitar repetir: $recent_block" : ());

    for my $attempt (1 .. 2) {
        my @messages = (
            {
                role => "system",
                content => $system_prompt,
            },
            {
                role => "user",
                content => $message,
            },
        );

        my $response;
        eval {
            $response = $api_client->callAPIWithMessages(\@messages, {
                max_tokens => 60,
                temperature => $attempt == 1 ? 0.9 : 1.1,
            });
        };
        if ($@) {
            warning "[aiChat] Erro ao gerar recusa de drop DB: $@\n", "plugin";
            return undef;
        }

        next unless defined $response && $response ne '';
        my $normalized = _normalizeResponseText($response);
        next unless $normalized ne '';
        next if $normalized =~ /\bnao\s+sei\b/i;
        my $normalized_check = _normalizeEchoText($normalized);
        my $is_repeat = 0;
        for my $recent (@recent_texts) {
            next unless defined $recent && $recent ne '';
            my $recent_norm = _normalizeEchoText($recent);
            next unless $recent_norm ne '';
            if ($normalized_check eq $recent_norm) {
                $is_repeat = 1;
                last;
            }
        }
        next if $is_repeat;
        return $normalized;
    }

    return undef;
}

sub _randomDropDbRepeatReply {
    return _normalizeResponseText(_pickVariant(
        'po ta de brincadeira',
        'denovo isso',
        'ja falei isso',
        'vai ficar perguntando a mesma coisa',
        'ta de sacanagem',
        'ta repetindo',
    ));
}

sub _isRepeatedDropDbQuestion {
    my ($sender, $message) = @_;
    return 0 unless defined $sender && defined $message && $message ne '';
    my $normalized = _normalizeQueryText($message);
    return 0 unless $normalized ne '';
    my $history = AIChat::ConversationHistory::getHistory($sender) || [];
    my $seen = 0;
    for (my $i = @$history - 1; $i >= 0; $i--) {
        my $entry = $history->[$i];
        next unless $entry->{role} && $entry->{role} eq 'user';
        next unless defined $entry->{content} && $entry->{content} ne '';
        my $entry_normalized = _normalizeQueryText($entry->{content});
        next unless $entry_normalized ne '';
        $seen++;
        return 1 if $entry_normalized eq $normalized;
        last if $seen >= 6;
    }
    return 0;
}

sub _formatMonsterReply {
    my ($monster) = @_;
    return '' unless defined $monster && $monster ne '';
    return _normalizeResponseText(_pickVariant(
        "dropa de $monster",
        "$monster",
        "$monster dropa",
        "vem de $monster",
        "cai do $monster",
        "e $monster",
        "mata $monster",
    ));
}

sub _formatMapReply {
    my ($map_name) = @_;
    return '' unless defined $map_name && $map_name ne '';
    return _normalizeResponseText(_pickVariant(
        "$map_name",
        "em $map_name",
        "acho que $map_name",
    ));
}

sub _formatMapListReply {
    my ($maps_ref) = @_;
    return '' unless $maps_ref && ref $maps_ref eq 'ARRAY';
    return '' unless @$maps_ref;
    return _formatMapReply($maps_ref->[0]) if @$maps_ref == 1;

    my $joined = join(' ', @$maps_ref);
    return _normalizeResponseText(_pickVariant(
        $joined,
        "em $maps_ref->[0]",
        "pode ir em $maps_ref->[0]",
    ));
}

sub _filterMapCodes {
    my ($maps_ref) = @_;
    return [] unless $maps_ref && ref $maps_ref eq 'ARRAY';
    my @codes = grep { defined $_ && $_ =~ /^[a-z0-9]+_[a-z0-9]+$/i } @$maps_ref;
    return \@codes;
}

sub _selectMapCandidates {
    my ($maps_ref, $prefer_codes) = @_;
    return [] unless $maps_ref && ref $maps_ref eq 'ARRAY';
    if ($prefer_codes) {
        my $codes = _filterMapCodes($maps_ref);
        return $codes if @$codes;
    }
    return $maps_ref;
}

sub isDropDbFollowup {
    my ($message, $sender) = @_;
    return 0 unless defined $message && defined $sender;
    my $tokens = _tokenizeText($message);
    return 0 unless $tokens && @$tokens;

    my $last_context = _getLastDropDbContext($sender);
    return 0 unless $last_context && (%$last_context);

    my $mentions_followup = _hasToken($tokens, [qw(mais outra outro outras outros alguma algum coisa)]);
    my $mentions_where = _hasToken($tokens, [qw(onde aonde mapa mapas qual quais)]);

    return 1 if $mentions_followup;
    return 1 if $mentions_where && ($last_context->{monster} || $last_context->{item} || $last_context->{map});
    return 0;
}

sub looksLikeDropDbQuery {
    my ($message) = @_;
    return 0 unless defined $message;
    my $tokens = _tokenizeText($message);
    return 0 unless $tokens && @$tokens;

    my $index = _getMondbSearchIndex();
    if ($index && %$index) {
        my $monster = _findBestPhraseMatch($tokens, $index->{monsters});
        my $item = _findBestPhraseMatch($tokens, $index->{items});
        my $map = _findBestPhraseMatch($tokens, $index->{maps});
        return 1 if $monster || $item || $map;
    }

    my $mentions_query = _hasToken($tokens, [qw(monstro monster monstros mob mobs drop drops dropa dropar item itens mapa mapas card carta)]);
    my $mentions_where = _hasToken($tokens, [qw(onde aonde pego pegar pega acho achar encontro encontrar)]);
    return 1 if $mentions_query || $mentions_where;
    return 0;
}

sub _tokenizeText {
    my ($text) = @_;
    my $normalized = _normalizeQueryText($text);
    return [] unless length $normalized;
    return [split / /, $normalized];
}

sub _containsTokenSequence {
    my ($tokens, $phrase_tokens) = @_;
    return 0 unless $tokens && $phrase_tokens;
    my $token_count = scalar @$tokens;
    my $phrase_count = scalar @$phrase_tokens;
    return 0 unless $token_count && $phrase_count;
    return 0 if $phrase_count > $token_count;

    for (my $i = 0; $i <= $token_count - $phrase_count; $i++) {
        my $matched = 1;
        for (my $j = 0; $j < $phrase_count; $j++) {
            if ($tokens->[$i + $j] ne $phrase_tokens->[$j]) {
                $matched = 0;
                last;
            }
        }
        return 1 if $matched;
    }

    return 0;
}

sub _findBestPhraseMatch {
    my ($tokens, $candidates) = @_;
    return unless $tokens && $candidates;
    my $best;
    my $best_len = 0;

    for my $candidate (@$candidates) {
        next unless defined $candidate && $candidate ne '';
        my $phrase_tokens = _tokenizeText($candidate);
        next unless @$phrase_tokens;
        next if scalar(@$phrase_tokens) < $best_len;
        next unless _containsTokenSequence($tokens, $phrase_tokens);
        $best = $candidate;
        $best_len = scalar @$phrase_tokens;
    }

    return $best;
}

sub _buildMondbSearchIndex {
    my ($mondb) = @_;
    return {} unless $mondb && %$mondb;

    my %monsters_by_key;
    my %items;
    my %maps;
    my %item_to_monsters;
    my %item_to_monsters_by_priority;
    my %map_to_monsters;
    my %map_to_items;

    for my $monster (sort keys %$mondb) {
        my $entry = $mondb->{$monster} || {};
        my $drops = $entry->{drops} || [];
        my $maps = $entry->{maps} || [];

        if ($monster =~ /^Mapa\s+/i) {
            if (@$maps) {
                for my $map (@$maps) {
                    $maps{$map} = $map if defined $map && $map ne '';
                }
            }
            if (@$drops) {
                my ($map_name) = $monster =~ /^Mapa\s+(.+)/i;
                if (defined $map_name && $map_name ne '') {
                    $map_to_items{$map_name} = $drops;
                    $maps{$map_name} = $map_name;
                }
            }
            next;
        }

        $monsters_by_key{$monster} = $monster;

        if (@$maps) {
            for my $map (@$maps) {
                next unless defined $map && $map ne '';
                $maps{$map} = $map;
                push @{$map_to_monsters{$map}}, $monster;
            }
        }

        next unless @$drops;
        for my $drop_index (0 .. $#$drops) {
            my $drop = $drops->[$drop_index];
            next unless defined $drop && $drop ne '';
            $items{$drop} = $drop;
            push @{$item_to_monsters{$drop}}, $monster;
            push @{$item_to_monsters_by_priority{$drop}[$drop_index]}, $monster;
        }
    }

    for my $item (keys %item_to_monsters_by_priority) {
        my %seen;
        my @ordered;
        for my $bucket (@{$item_to_monsters_by_priority{$item}}) {
            next unless $bucket && ref $bucket eq 'ARRAY';
            for my $monster (@$bucket) {
                next if $seen{$monster}++;
                push @ordered, $monster;
            }
        }
        $item_to_monsters{$item} = \@ordered if @ordered;
    }

    return {
        monsters => [sort keys %monsters_by_key],
        items => [sort keys %items],
        maps => [sort keys %maps],
        item_to_monsters => \%item_to_monsters,
        map_to_monsters => \%map_to_monsters,
        map_to_items => \%map_to_items,
    };
}

sub _getMondbSearchIndex {
    my $mondb = _loadMonsterDropDb();
    return {} unless $mondb && %$mondb;
    return $mondb_search_cache if $mondb_search_cache;
    $mondb_search_cache = _buildMondbSearchIndex($mondb);
    return $mondb_search_cache;
}

sub _hasToken {
    my ($tokens, $needles) = @_;
    return 0 unless $tokens && $needles;
    my %token_lookup = map { $_ => 1 } @$tokens;
    for my $needle (@$needles) {
        return 1 if $token_lookup{$needle};
    }
    return 0;
}

sub _unknownDropReply {
    my @options = (
        'nao sei',
        'nao conheco',
        'sei nao',
        'nao to ligado',
        'desculpa nao sei',
        'nao faço ideia',
        'nao lembro',
    );
    return $options[int(rand(@options))];
}

sub _readMonsterDropDbRaw {
    my $path = File::Spec->catfile(_pluginBaseDir(), 'mondb.txt');
    return undef unless -e $path;
    my @lines;
    if (open my $fh, '<:encoding(UTF-8)', $path) {
        @lines = <$fh>;
        close $fh;
    }
    return undef unless @lines;
    my @raw_lines;
    for my $line (@lines) {
        my $raw = $line;
        chomp $raw;
        $raw =~ s/\r//g;
        push @raw_lines, $raw;
    }
    return undef unless @raw_lines;
    return join "\n", @raw_lines;
}

sub _formatListWithMaps {
    my ($mondb, $monsters) = @_;
    my @entries;
    for my $monster_name (@$monsters) {
        my $entry = $mondb->{$monster_name} || {};
        my $maps = $entry->{maps} || [];
        if (@$maps) {
            push @entries, "$monster_name (" . join(', ', @$maps) . ")";
        } else {
            push @entries, $monster_name;
        }
    }
    return join(', ', @entries);
}

sub generateDropDbResponse {
    my ($message, $sender) = @_;
    return undef unless defined $message && $message ne '';

    if (_isRepeatedDropDbQuestion($sender, $message)) {
        return _randomDropDbRepeatReply();
    }

    if (rand() < 0.5) {
        my $refusal = _generateDropDbRefusalResponse($message, $sender);
        return $refusal if defined $refusal && $refusal ne '';
        return _randomDropDbRefusal();
    }

    my $mondb = _loadMonsterDropDb();
    return undef unless $mondb && %$mondb;

    my $index = _getMondbSearchIndex();
    return undef unless $index && %$index;

    my $tokens = _tokenizeText($message);
    return undef unless $tokens && @$tokens;

    my $monster = _findBestPhraseMatch($tokens, $index->{monsters});
    my $item = _findBestPhraseMatch($tokens, $index->{items});
    my $map = _findBestPhraseMatch($tokens, $index->{maps});

    my $last_context = _getLastDropDbContext($sender);
    my $history_context = _inferDropDbContextFromHistory($sender, $index);
    my %fallback_context = (
        %{ $history_context || {} },
        %{ $last_context || {} },
    );
    my $mentions_pronoun = _hasToken($tokens, [qw(ele ela esse essa dele dela)]);

    my $mentions_where = _hasToken($tokens, [qw(onde aonde pego pegar pega encontro encontrar mapa map)]);
    my $mentions_drop = _hasToken($tokens, [qw(drop drops dropa dropar drope loot caiu cai)]);
    my $mentions_query = _hasToken($tokens, [qw(monstro monster monstros itens item drop drops dropa dropar mapa map)]);
    my $mentions_monster_query = _hasToken($tokens, [qw(monstro monster monstros mob mobs)]);
    my $mentions_followup = _hasToken($tokens, [qw(mais outra outro outras outros alguma algum coisa)]);
    my $mentions_map = _hasToken($tokens, [qw(mapa mapas)]);
    my $mentions_map_question = $mentions_map && _hasToken($tokens, [qw(qual quais)]);
    my $prefer_map_codes = $mentions_map ? 1 : 0;

    if (!$monster && !$item && !$map && ($mentions_pronoun || $mentions_followup)) {
        $monster = $fallback_context{monster} if $fallback_context{monster};
        $item = $fallback_context{item} if $fallback_context{item};
        $map = $fallback_context{map} if $fallback_context{map};
    }

    if (!$monster && !$item && !$map && $mentions_monster_query && $fallback_context{item}) {
        $item = $fallback_context{item};
    }

    if ($mentions_followup && $monster) {
        $mentions_drop = 1 unless $mentions_where;
    }

    if (!$monster && !$item && !$map && $mentions_where) {
        $monster = $fallback_context{monster} if $fallback_context{monster};
        $item = $fallback_context{item} if $fallback_context{item};
        $map = $fallback_context{map} if $fallback_context{map};
    }

    if ($mentions_followup && $mentions_monster_query && $item && !$monster) {
        $monster = undef;
    }

    if (!$monster && !$item && $mentions_followup && $fallback_context{item} && !$mentions_monster_query) {
        $monster = undef;
        $item = $fallback_context{item} if !$item;
    }

    my $query_type;
    if ($monster && !$item) {
        $query_type = 'monster';
    } elsif ($item && !$monster) {
        $query_type = 'item';
    } elsif ($monster && $item) {
        if ($mentions_where) {
            $query_type = 'item';
        } elsif ($mentions_drop) {
            $query_type = 'monster';
        } else {
            $query_type = 'monster';
        }
    } elsif ($map) {
        $query_type = 'map';
    }

    if ($query_type && $query_type eq 'monster') {
        my $entry = $mondb->{$monster} || {};
        my $drops = $entry->{drops} || [];
        my $maps = $entry->{maps} || [];
        return undef unless @$drops || @$maps;
        if ($mentions_where && @$maps) {
            my $map_pool = _selectMapCandidates($maps, $prefer_map_codes);
            my $limited_maps;
            if ($mentions_followup && $last_context->{map}) {
                my $last_index = _findListIndex($map_pool, $last_context->{map});
                if (defined $last_index) {
                    $limited_maps = _pickLimitedList($map_pool, 2, $last_index + 1);
                }
            }
            $limited_maps ||= _pickLimitedList($map_pool, 2);
            return undef unless @$limited_maps;
            my $response = _formatMapListReply($limited_maps);
            _setLastDropDbContext($sender, { monster => $monster, map => $limited_maps->[0] });
            return $response;
        }
        if ($mentions_drop && @$drops) {
            my $limited_drops;
            if ($mentions_followup && $last_context->{item}) {
                my $last_index = _findListIndex($drops, $last_context->{item});
                if (defined $last_index) {
                    $limited_drops = _pickLimitedList($drops, 2, $last_index + 1);
                }
            }
            $limited_drops ||= _pickLimitedList($drops, 2);
            return undef unless @$limited_drops;
            my $response = _normalizeResponseText("dropa " . join(', ', @$limited_drops));
            _setLastDropDbContext($sender, { monster => $monster, item => $limited_drops->[0], map => ($maps->[0] // '') });
            return $response;
        }
        if (@$drops) {
            my $limited_drops = _pickLimitedList($drops, 2);
            return undef unless @$limited_drops;
            my $message = "dropa " . join(', ', @$limited_drops);
            $message .= " em $maps->[0]" if @$maps && rand() < 0.5;
            my $response = _normalizeResponseText($message);
            _setLastDropDbContext($sender, { monster => $monster, item => $limited_drops->[0], map => ($maps->[0] // '') });
            return $response;
        }
        if (@$maps) {
            my $map_pool = _selectMapCandidates($maps, $prefer_map_codes);
            my $limited_maps;
            if ($mentions_followup && $last_context->{map}) {
                my $last_index = _findListIndex($map_pool, $last_context->{map});
                if (defined $last_index) {
                    $limited_maps = _pickLimitedList($map_pool, 2, $last_index + 1);
                }
            }
            $limited_maps ||= _pickLimitedList($map_pool, 2);
            return undef unless @$limited_maps;
            my $response = _formatMapListReply($limited_maps);
            _setLastDropDbContext($sender, { monster => $monster, map => $limited_maps->[0] });
            return $response;
        }
    }

    if ($query_type && $query_type eq 'item') {
        my $monsters = $index->{item_to_monsters}{$item} || [];
        return undef unless @$monsters;
        if ($mentions_where) {
            my $limited_monsters = _pickLimitedList($monsters, 2);
            return undef unless @$limited_monsters;
            my $first_monster = $limited_monsters->[0];
            my $entry = $mondb->{$first_monster} || {};
            my $maps = $entry->{maps} || [];
            if (@$maps) {
                my $map_pool = _selectMapCandidates($maps, $prefer_map_codes);
                my $limited_maps;
                if ($mentions_followup && $last_context->{map} && $last_context->{monster} && $last_context->{monster} eq $first_monster) {
                    my $last_index = _findListIndex($map_pool, $last_context->{map});
                    if (defined $last_index) {
                        $limited_maps = _pickLimitedList($map_pool, 2, $last_index + 1);
                    }
                }
                $limited_maps ||= _pickLimitedList($map_pool, 2);
                return undef unless @$limited_maps;
                my $response = _formatMapListReply($limited_maps);
                _setLastDropDbContext($sender, { monster => $first_monster, item => $item, map => $limited_maps->[0] });
                return $response;
            }
            my $response = _formatMonsterReply($first_monster);
            _setLastDropDbContext($sender, { monster => $first_monster, item => $item });
            return $response;
        }
        my $limited_monsters;
        if ($mentions_followup && $last_context->{monster}) {
            my $last_index = _findListIndex($monsters, $last_context->{monster});
            if (defined $last_index) {
                $limited_monsters = _pickLimitedList($monsters, 2, $last_index + 1);
            }
        }
        $limited_monsters ||= _pickLimitedList($monsters, 2);
        return undef unless @$limited_monsters;
        my $response = _formatMonsterReply($limited_monsters->[0]);
        _setLastDropDbContext($sender, { monster => $limited_monsters->[0], item => $item });
        return $response;
    }

    if ($query_type && $query_type eq 'map') {
        my $monsters = $index->{map_to_monsters}{$map} || [];
        my $items = $index->{map_to_items}{$map} || [];
        return undef unless @$monsters || @$items;
        if (@$monsters) {
            my $limited_monsters = _pickLimitedList($monsters, 2);
            return undef unless @$limited_monsters;
            my $response = $mentions_map_question
                ? _formatMapReply($map)
                : _normalizeResponseText("em $map tem " . join(', ', @$limited_monsters));
            _setLastDropDbContext($sender, { monster => $limited_monsters->[0], map => $map });
            return $response;
        }
        if (@$items) {
            my $limited_items = _pickLimitedList($items, 2);
            return undef unless @$limited_items;
            my $response = $mentions_map_question
                ? _formatMapReply($map)
                : _normalizeResponseText("em $map tem " . join(', ', @$limited_items));
            _setLastDropDbContext($sender, { item => $limited_items->[0], map => $map });
            return $response;
        }
    }

    return undef;
}

sub dropDbUnknownReply {
    return _unknownDropReply();
}

sub generateDropDbChatResponse {
    my ($message, $sender) = @_;
    return dropDbUnknownReply() unless defined $message && $message ne '';

    my $drop_context = _readMonsterDropDbRaw();
    return dropDbUnknownReply() unless $drop_context;

    my $prompt = AIChat::Config::get('prompt');
    my $combined_prompt = join "\n",
        $prompt,
        "Banco de dados de monstros e drops (formato: Monstro: (Mapa1, Mapa2) Drop1, Drop2):",
        $drop_context,
        "Use somente as informacoes do banco acima.",
        "Quando perguntarem onde fica um monstro, use o primeiro mapa da lista.",
        "Quando perguntarem onde pega um item, use o primeiro monstro que dropa e o primeiro mapa desse monstro.",
        "Se nao houver informacao clara, responda com uma frase curta de desconhecimento, como um player.",
        "Exemplos: nao sei, nao conheco, sei nao, nao to ligado, desculpa nao sei.";
    my @messages = (
        {
            role => "system",
            content => $combined_prompt
        },
        {
            role => "user",
            content => $message,
        }
    );

    my $response;
    my $max_tokens = AIChat::Config::get('max_tokens');
    my $temperature = AIChat::Config::get('temperature');
    eval {
        $response = $api_client->callAPIWithMessages(\@messages, {
            max_tokens => $max_tokens,
            temperature => $temperature,
        });
    };
    if ($@ || !defined $response || $response eq '') {
        return dropDbUnknownReply();
    }

    $response =~ s/\s+/ /g;
    $response =~ s/^\s+//;
    $response =~ s/\s+$//;
    return $response ne '' ? $response : dropDbUnknownReply();
}

sub _buildWorldContext {
    my $map_name = $bot_character_data{map_name} // 'desconhecido';
    my $monsters = _normalizeList($bot_character_data{map_monsters});
    my $items = _normalizeList($bot_character_data{map_items});

    my $monster_text = @$monsters ? join(', ', @$monsters) : 'nenhum confirmado';
    my $item_text = @$items ? join(', ', @$items) : 'nenhum confirmado';
    my $drop_context = _buildBasicDropContext($monsters, $map_name);

    my $drop_map_text = $drop_context->{map} || 'nenhum basico confirmado';
    my $drop_general = $drop_context->{general} || 'desconhecido';

    return join "\n",
        "Contexto do mapa atual:",
        "Mapa: $map_name",
        "Monstros vistos aqui: $monster_text",
        "Itens vistos no chao: $item_text",
        "Drops basicos possiveis no mapa: $drop_map_text",
        "Drops basicos (geral): $drop_general",
        "Regras para drops: se perguntarem onde pega um item, responda com os monstros listados aqui. Se perguntarem o que um monstro dropa, responda com os itens listados aqui. Se nao houver informacao, diga que nao sabe ou nao tem certeza. Use os nomes oficiais de monstros e itens desta lista (tabelas do servidor) e responda em linguagem popular.";
}

sub _normalizeList {
    my ($value) = @_;
    return [] unless defined $value;
    return $value if ref $value eq 'ARRAY';
    return [];
}

sub _buildBasicDropContext {
    my ($monsters, $map_name) = @_;
    my $mondb = _loadMonsterDropDb();
    return { general => '', map => '' } unless $mondb && %$mondb;

    my %present = map { lc $_ => 1 } @$monsters;
    my @general;
    my @map_specific;

    for my $monster (sort keys %$mondb) {
        my $entry = $mondb->{$monster} || {};
        my $drops = $entry->{drops} || [];
        next unless @$drops;
        push @general, "$monster: " . join(', ', @$drops);
        if ($present{lc $monster}) {
            push @map_specific, "$monster: " . join(', ', @$drops);
        }
    }

    if (defined $map_name && $map_name ne '') {
        my $map_key = "Mapa $map_name";
        if ($mondb->{$map_key} && @{$mondb->{$map_key}{drops} || []}) {
            my $drops = $mondb->{$map_key}{drops} || [];
            push @map_specific, "$map_key: " . join(', ', @$drops);
        }
    }

    return {
        general => join('; ', @general),
        map => join('; ', @map_specific),
    };
}

sub _loadMonsterDropDb {
    return $mondb_cache if $mondb_cache;

    my $path = File::Spec->catfile(_pluginBaseDir(), 'mondb.txt');
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
            my @maps;
            if ($drop_text =~ s/^\(\s*([^)]+)\s*\)\s*//) {
                @maps = map {
                    my $map = $_;
                    $map =~ s/^\s+//;
                    $map =~ s/\s+$//;
                    $map;
                } split /\s*,\s*/, $1;
            }
            my @drops = map {
                my $item = $_;
                $item =~ s/^\s+//;
                $item =~ s/\s+$//;
                _translateItemName($item);
            } split /\s*,\s*/, $drop_text;
            @drops = grep { defined $_ && $_ ne '' } @drops;
            $db{$monster} = { drops => \@drops, maps => \@maps } if @drops || @maps;
        }
        close $fh;
    }

    $mondb_cache = \%db;
    $mondb_search_cache = undef;
    return $mondb_cache;
}

sub updateMondbFromMap {
    my ($map_name, $map_items) = @_;
    return unless defined $map_name && $map_name ne '';
    my $items = _normalizeList($map_items);
    return unless @$items;

    my %new_items = map { $_ => 1 } grep { defined $_ && $_ ne '' } @$items;
    return unless %new_items;
    my $signature = join "\n", sort keys %new_items;
    return if defined $mondb_map_cache{$map_name} && $mondb_map_cache{$map_name} eq $signature;
    $mondb_map_cache{$map_name} = $signature;

    my $path = File::Spec->catfile(_pluginBaseDir(), 'mondb.txt');
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
        if ($drop_text =~ s/^\(\s*([^)]+)\s*\)\s*//) {
            # Map list intentionally ignored for drop merge.
        }
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
    my $map_key = "Mapa $map_name";
    my %merged = map { $_ => 1 } @{ $drops_by_monster{$map_key} || [] };
    @merged{keys %new_items} = (1) x scalar keys %new_items;
    my @merged_list = sort keys %merged;
    return unless @merged_list;
    $drops_by_monster{$map_key} = \@merged_list;
    if (!exists $line_index{$map_key}) {
        push @lines, "$map_key: ($map_name) " . join(', ', @merged_list) . "\n";
        $changed = 1;
    } else {
        my $index = $line_index{$map_key};
        my $updated_line = "$map_key: ($map_name) " . join(', ', @merged_list) . "\n";
        if ($lines[$index] ne $updated_line) {
            $lines[$index] = $updated_line;
            $changed = 1;
        }
    }

    return unless $changed;
    if (open my $fh, '>:encoding(UTF-8)', $path) {
        print $fh @lines;
        close $fh;
        $mondb_cache = undef;
        $mondb_search_cache = undef;
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

    my $tables_dir = File::Spec->catfile(_pluginBaseDir(), '..', '..', 'tables');
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

sub _pluginBaseDir {
    my $base = $Plugins::current_plugin_folder;
    if (defined $base && $base ne '' && -d $base) {
        return $base;
    }

    my $module_dir = dirname(__FILE__);
    return File::Spec->rel2abs(File::Spec->catdir($module_dir, '..'));
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
    _ensureDropDbContext($sender);

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
            content => "Voce e um classificador de comandos do bot. Responda apenas com JSON valido no formato {\"action\":\"chat|emote|emote_random|drop_db|none\"}. Contexto: mapa atual=$map_name, lockMap=$lock_map_info, pedidos_emote_recentemente=$recent_emote_requests. Use o contexto recente se necessario. Marque \"emote\" quando pedirem para reproduzir um emoticon, mesmo em pedidos repetidos ou indiretos. Marque \"emote_random\" quando pedirem um emoticon aleatorio, diferente, outro, ou variado. Use \"drop_db\" quando a pessoa pedir informacoes sobre monstros, drops, itens ou mapas (ex: onde pega um item, o que um monstro dropa, mapas com um monstro). Nunca use \"drop_db\" para pedidos de emoticon. Em sec_pri, nunca recuse pedidos de emoticon: use \"emote\" ou \"emote_random\" quando o pedido for de emoticon. Fora de sec_pri, aplique moderacao de spam somente quando estiver no lockMap (mapa atual == lockMap). Se estiverem importunando, voce pode recusar escolhendo \"chat\" para responder verbalmente. Marque \"chat\" quando for uma pergunta/comentario comum. Marque \"none\" quando nao houver acao clara. Nao inclua nenhum texto fora do JSON."
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
        debug "[aiChat] Resposta invalida ao interpretar comando: $response\n", "plugin";
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
