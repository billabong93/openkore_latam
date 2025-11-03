package webDashboard;

use utf8;
use strict;
use warnings;
use POSIX qw(:errno_h);
use Encode qw(encode_utf8 decode_utf8);
use Plugins;
use Globals qw(
    $char $field
    $playersList $monstersList $npcsList $portalsList
    %config %jobs_lut
);


use Log qw(message warning error);
use Utils;
use Network;
use Field;
use Time::HiRes qw(time);
use IO::Socket::INET;
use JSON;
use Commands;
use AI;

sub _i   { my $v = shift; return defined $v ? int($v) : 0 }
sub _num { my $v = shift; return (defined $v && $v =~ /^-?\d+(?:\.\d+)?$/) ? $v+0 : 0 }


Plugins::register('webDashboard', 'Dashboard Web para OpenKore', \&onUnload);

my $hooks = Plugins::addHooks(
    ['start3',           \&onStart,       undef],
    ['mainLoop_pre',     \&onLoop,        undef],
    ['packet_skill_use', \&onSkillUse,    undef],
    ['packet_attack',    \&onAttack,      undef],
    ['packet_mapChange', \&onMapChange,   undef],
    ['packet_dead',      \&onPlayerDead,  undef],

    # Hooks de chat (necessários para popular /api/chat)
    ['packet_pubMsg',    \&onChatPublic,  undef],
    ['packet_privMsg',   \&onChatPrivate, undef],
    ['packet_selfChat',  \&onChatSelf,    undef],
    ['packet_partyMsg',  \&onChatParty,   undef],
    ['packet_guildMsg',  \&onChatGuild,   undef],
);


my $server_socket;
my $port = 8888;
my $host = '127.0.0.1';
my $max_port_tries = 10;

my @chat_messages = ();
my $max_chat = 500;

my %session_stats = (
    start_time => time(),
    exp_start => 0,
    zeny_start => 0,
    kills => 0,
    deaths => 0,
    items_collected => 0,
    damage_dealt => 0,
    damage_received => 0,
    skills_used => 0,
    last_update => time(),
);

my $log_hook;

# Cache para melhor performance
my %cache = (
    last_update => 0,
    cache_duration => 0.5,
    last_character_data => {},
    last_map_data => {},
);

my %discovered_portals = ();  # Cache permanente de portais descobertos
my $current_map_name = '';    # Nome do mapa atual para limpar cache ao mudar

sub onUnload {
    Plugins::delHooks($hooks);
    if ($log_hook) {
        Log::delHook($log_hook);
    }
    stop_server();
    message "[webDashboard] Plugin descarregado.\n";
}

sub onStart {
    message "[webDashboard] Iniciando servidor web...\n";
    start_server();
    
    $log_hook = Log::addHook(\&onLogMessage);
    
    if ($char) {
        $session_stats{exp_start} = $char->{exp} || 0;
        $session_stats{zeny_start} = $char->{zeny} || 0;
        $session_stats{base_level_start} = $char->{lv} || 0;
        $session_stats{job_level_start} = $char->{lv_job} || 0;
    }
}

sub onLoop {
    return unless $server_socket;
    
    my $client = $server_socket->accept();
    return unless $client;
    
    eval {
        $client->blocking(0);
    };
    
    my $request = '';
    my $start_time = time();
    my $timeout = 0.5;
    
    while (time() - $start_time < $timeout) {
        my $buffer;
        my $bytes = sysread($client, $buffer, 4096);
        
        if (defined $bytes && $bytes > 0) {
            $request .= $buffer;
            last if $request =~ /\r?\n\r?\n/;
        } elsif (!defined $bytes && $! != POSIX::EWOULDBLOCK && $! != POSIX::EAGAIN) {
            close($client);
            return;
        }
        
        select(undef, undef, undef, 0.01);
    }
    
    return unless $request;
    
    if ($request =~ /GET (\S+) HTTP/) {
        my $path = $1;
        handle_request($client, $path);
    } elsif ($request =~ /POST (\S+) HTTP/) {
        my $path = $1;
        my $content_length = 0;
        if ($request =~ /Content-Length: (\d+)/i) {
            $content_length = $1;
        }
        
        my $body = '';
        if ($content_length > 0) {
            my $body_start = index($request, "\r\n\r\n");
            if ($body_start >= 0) {
                $body = substr($request, $body_start + 4);
            }
            
            while (length($body) < $content_length && time() - $start_time < $timeout) {
                my $buffer;
                my $bytes = sysread($client, $buffer, $content_length - length($body));
                $body .= $buffer if defined $bytes && $bytes > 0;
                select(undef, undef, undef, 0.01);
            }
        }
        
        handle_post_request($client, $path, $body);
    }
    
    close($client);
}

sub onSkillUse {
    my ($self, $args) = @_;
    $session_stats{skills_used}++;
}

sub onAttack {
    my ($self, $args) = @_;
    if ($args->{damage}) {
        $session_stats{damage_dealt} += $args->{damage};
    }
}

sub onMapChange {
    my ($self, $args) = @_;
    
    # Limpa cache quando muda de mapa
    %cache = (
        last_update => 0,
        cache_duration => 0.5,
        last_character_data => {},
        last_map_data => {},
    );
    
    # Limpa portais descobertos ao mudar de mapa
    if ($field && $field->baseName() && $field->baseName() ne $current_map_name) {
        %discovered_portals = ();
        $current_map_name = $field->baseName() || '';
    }
}

sub onPlayerDead {
    $session_stats{deaths}++;
}

sub start_server {
    my $current_port = $port;
    my $success = 0;
    
    for (my $i = 0; $i < $max_port_tries; $i++) {
        eval {
            $server_socket = IO::Socket::INET->new(
                LocalHost => $host,
                LocalPort => $current_port,
                Proto     => 'tcp',
                Listen    => 5,
                Reuse     => 1,
                Blocking  => 0
            );
            
            if ($server_socket) {
                $port = $current_port;
                $success = 1;
                message "[webDashboard] Servidor iniciado na porta $port!\n";
                message "[webDashboard] Acesse: http://localhost:$port\n";
            }
        };
        
        last if $success;
        $current_port++;
    }
    
    unless ($success) {
        error "[webDashboard] ERRO: Não foi possível iniciar servidor.\n";
    }
}

sub stop_server {
    if ($server_socket) {
        close($server_socket);
        message "[webDashboard] Servidor parado.\n";
    }
}

sub handle_request {
    my ($client, $path) = @_;
    
    if ($path eq '/' || $path eq '/index.html') {
        send_html($client);
    } elsif ($path eq '/api/all') {
        send_json($client, get_all_data());
    } elsif ($path eq '/api/character') {
        send_json($client, get_character_data());
    } elsif ($path eq '/api/map') {
        send_json($client, get_map_data());
    } elsif ($path eq '/api/inventory') {
        send_json($client, get_inventory_data());
    } elsif ($path eq '/api/skills') {
        send_json($client, get_skills_data());
    } elsif ($path eq '/api/chat') {
        send_json($client, { messages => \@chat_messages });
    } elsif ($path eq '/api/stats') {
        send_json($client, get_session_stats());
    } elsif ($path eq '/api/monsters') {
        send_json($client, get_monsters_list());
    } elsif ($path eq '/api/target') {
        send_json($client, get_target_info());
    } elsif ($path eq '/api/config') {
        send_json($client, get_config_info());
    } elsif ($path =~ /^\/api\/item\/(\d+)$/) {
        send_json($client, get_item_details($1));
    } else {
        send_404($client);
    }
}

sub handle_post_request {
    my ($client, $path, $body) = @_;
    
    my $data = eval { JSON->new->utf8->decode($body) };
    
    if ($path eq '/api/command') {
        if ($data && $data->{command}) {
            Commands::run($data->{command});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/chat/send') {
        if ($data && $data->{message}) {
            Commands::run("c " . $data->{message});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/skill/upgrade') {
        if ($data && $data->{skill_id}) {
            Commands::run("skills add " . $data->{skill_id});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/stat/upgrade') {
        if ($data && $data->{stat}) {
            Commands::run("stat_add " . $data->{stat});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/item/use') {
        if ($data && defined $data->{index}) {
            Commands::run("is " . $data->{index});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/item/equip') {
        if ($data && defined $data->{index}) {
            Commands::run("eq " . $data->{index});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/item/unequip') {
        if ($data && defined $data->{index}) {
            Commands::run("uneq " . $data->{index});
            send_json($client, { success => 1 });
        }
	} elsif ($path eq '/api/item/drop') {
		if ($data && defined $data->{index}) {
			my $idx = int($data->{index});
			my $amt = (defined $data->{amount}) ? int($data->{amount}) : 1;
			$amt = 1 if $amt < 1;
	
			# descobre o máximo disponível para clamp
			my $max_amt = 0;
			if ($char && $char->inventory()) {
				foreach my $it (@{$char->inventory()->getItems()}) {
					next unless $it;
					my $iinv = $it->{invIndex} // $it->{index} // $it->{binID};
					if (defined $iinv && $iinv == $idx) {
						$max_amt = int($it->{amount} || 0);
						last;
					}
				}
			}
			$amt = $max_amt if $max_amt && $amt > $max_amt;
	
			# COMANDO CERTO é drop <index> <amount>
			Commands::run("drop $idx $amt");
			send_json($client, { success => 1, index => $idx, amount => $amt, max => $max_amt });
		} else {
			send_json($client, { success => 0, error => 'missing_index' });
		}

    } elsif ($path eq '/api/move') {
        if ($data && defined $data->{x} && defined $data->{y}) {
            Commands::run("move " . $data->{x} . " " . $data->{y});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/ai') {
        if ($data && $data->{mode}) {
            Commands::run("ai " . $data->{mode});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/config/save') {
        if ($data && $data->{config}) {
            save_config_changes($data->{config});
            send_json($client, { success => 1 });
        }
    } else {
        send_404($client);
    }
}

sub send_html {
    my ($client) = @_;
    my $html = get_dashboard_html();
    
    my $html_bytes = encode_utf8($html);
    
    print $client "HTTP/1.1 200 OK\r\n";
    print $client "Content-Type: text/html; charset=utf-8\r\n";
    print $client "Content-Length: " . length($html_bytes) . "\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    print $client $html_bytes;
}

sub send_json {
    my ($client, $data) = @_;
    
    my $json;
    eval {
        $json = JSON->new->utf8->allow_nonref->encode($data);
    };
    
    if ($@) {
        $json = '{"error":"JSON encoding error"}';
    }
    
    print $client "HTTP/1.1 200 OK\r\n";
    print $client "Content-Type: application/json; charset=utf-8\r\n";
    print $client "Content-Length: " . length($json) . "\r\n";
    print $client "Access-Control-Allow-Origin: *\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    print $client $json;
}

sub send_404 {
    my ($client) = @_;
    my $html = '<html><body><h1>404 Not Found</h1></body></html>';
    
    print $client "HTTP/1.1 404 Not Found\r\n";
    print $client "Content-Type: text/html\r\n";
    print $client "Content-Length: " . length($html) . "\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    print $client $html;
}
sub _push_chat {
    my ($type, $name, $text) = @_;
    $text //= '';
    $text =~ s/\r?\n/ /g;
    $text =~ s/[\x00-\x1F\x7F]//g;
    push @chat_messages, { time => time(), type => $type, name => ($name // ''), message => $text };
    shift @chat_messages if @chat_messages > $max_chat;
}
sub onChatPublic  { my (undef,$a)=@_; _push_chat('public',  $a->{MsgUser}     || 'PUB',  $a->{Msg}      ) if $a }
sub onChatPrivate { my (undef,$a)=@_; _push_chat('private', $a->{privMsgUser}  || 'PM',   $a->{privMsg}  ) if $a }
sub onChatSelf    { my (undef,$a)=@_; _push_chat('self',    'Você',                    $a->{Msg}      ) if $a }
sub onChatParty   { my (undef,$a)=@_; _push_chat('party',   $a->{MsgUser}     || 'PT',   $a->{Msg}      ) if $a }
sub onChatGuild   { my (undef,$a)=@_; _push_chat('guild',   $a->{MsgUser}     || 'GD',   $a->{Msg}      ) if $a }


sub onLogMessage {
    # Assinatura correta para o hook de Log nas builds atuais:
    my ($type, $domain, $level, $verbosity, $message, @rest) = @_;
    return unless defined $message;

    # Filtros básicos pra não poluir:
    return if $message eq '' || $message =~ /^\s+$/;       # vazio/espaco
    return if $message =~ /^[01]\s*$/;                     # evita verbosidade 0/1
    return if length($message) <= 1 && $message !~ /[A-Za-zÀ-ÿ0-9]/;

    my $clean = $message;
    $clean =~ s/\r?\n/ /g;          # 1 linha
    $clean =~ s/[\x00-\x1F\x7F]//g; # remove control chars
    return if $clean eq '';

    push @chat_messages, {
        time    => time(),
        type    => 'console',
        name    => (defined $domain ? $domain : ''),
        message => $clean
    };
    shift @chat_messages if @chat_messages > $max_chat;
}



sub get_all_data {
    my $current_time = time();
    
    # Usa cache para melhor performance
    if ($current_time - $cache{last_update} < $cache{cache_duration}) {
        return {
            character => $cache{last_character_data},
            map => $cache{last_map_data},
            inventory => get_inventory_data(),
            skills => get_skills_data(),
            timestamp => $current_time
        };
    }
    
    $cache{last_update} = $current_time;
    $cache{last_character_data} = get_character_data();
    $cache{last_map_data} = get_map_data();
    
    return {
        character => $cache{last_character_data},
        map => $cache{last_map_data},
        inventory => get_inventory_data(),
        skills => get_skills_data(),
        timestamp => $current_time
    };
}

sub get_character_data {
	return {} unless $char;
	
	my $job_name = '';
	if (defined $char->{jobId}) {
		my $jid = $char->{jobId};
		$job_name = defined $jid ? ($jobs_lut{$jid} // $jid) : '';
	}
	
	# Calcula estatísticas de combate
	my $total_stats = 0;
	my @stat_values = ();
	if (defined $char->{str}) {
		$total_stats += _i($char->{str}) + _i($char->{agi}) + _i($char->{vit})
					+ _i($char->{int}) + _i($char->{dex}) + _i($char->{luk});
		@stat_values = (_i($char->{str}), _i($char->{agi}), _i($char->{vit}),
						_i($char->{int}), _i($char->{dex}), _i($char->{luk}));
	}

    
    my %data = (
        name => $char->{name} || 'N/A',
        level => $char->{lv} || 0,
        job => $job_name,
        job_level => $char->{lv_job} || 0,
        hp => $char->{hp} || 0,
        hp_max => $char->{hp_max} || 0,
        sp => $char->{sp} || 0,
        sp_max => $char->{sp_max} || 0,
        exp => $char->{exp} || 0,
        exp_max => $char->{exp_max} || 0,
        exp_job => $char->{exp_job} || 0,
        exp_job_max => $char->{exp_job_max} || 0,
        zeny => $char->{zeny} || 0,
        weight => $char->{weight} || 0,
        weight_max => $char->{weight_max} || 0,
        points_free => $char->{points_free} || 0,
        points_skill => $char->{points_skill} || 0,
        total_stats => $total_stats,
        stat_values => \@stat_values,
    );
    
    $data{stats} = {
        str => $char->{str} || 0,
        agi => $char->{agi} || 0,
        vit => $char->{vit} || 0,
        int => $char->{int} || 0,
        dex => $char->{dex} || 0,
        luk => $char->{luk} || 0,
    };
    
    # Status effects
    $data{status} = {
        poisoned => $char->{statuses}{POISON} ? 1 : 0,
        cursed => $char->{statuses}{CURSE} ? 1 : 0,
        silenced => $char->{statuses}{SILENCE} ? 1 : 0,
        blinded => $char->{statuses}{BLIND} ? 1 : 0,
    };
    
	$data{hp_percent}     = _i($data{hp_max})     ? int((_i($data{hp})     / _i($data{hp_max}))     * 100) : 0;
	$data{sp_percent}     = _i($data{sp_max})     ? int((_i($data{sp})     / _i($data{sp_max}))     * 100) : 0;
	$data{exp_percent}    = _i($data{exp_max})    ? sprintf('%.2f', (_i($data{exp})    / _i($data{exp_max}))    * 100) : 0;
	$data{exp_job_percent}= _i($data{exp_job_max})? sprintf('%.2f', (_i($data{exp_job})/ _i($data{exp_job_max})) * 100) : 0;
	$data{weight_percent} = _i($data{weight_max}) ? int((_i($data{weight}) / _i($data{weight_max})) * 100) : 0;

    
    return \%data;
}

sub get_map_data {
    return {} unless $field;

    my %data = (
        name   => $field->baseName() || 'N/A',
        width  => _i($field->width()),
        height => _i($field->height()),
    );

    if ($char) {
        $data{char_x} = _i($char->{pos_to}{x} // $char->{pos}{x});
        $data{char_y} = _i($char->{pos_to}{y} // $char->{pos}{y});
    } else {
        $data{char_x} = 0;
        $data{char_y} = 0;
    }

    # ... código dos players e monsters continua igual ...

    # MODIFICAÇÃO PARA PORTAIS COM MEMÓRIA
    my @portals;
    
    # Primeiro, adiciona portais visíveis atualmente e salva no cache
    if ($portalsList && $portalsList->can('getItems')) {
        foreach my $portal (@{ $portalsList->getItems() || [] }) {
            next unless $portal;
            my $x = _i($portal->{pos}{x});
            my $y = _i($portal->{pos}{y});
            my $name = $portal->name() || 'Portal';
            
            # Salva no cache permanente com chave única baseada na posição
            my $portal_key = "${x}_${y}";
            $discovered_portals{$portal_key} = {
                name => $name,
                x => $x,
                y => $y,
                discovered_time => time(),
            };
        }
    }
    
    # Depois, adiciona todos os portais descobertos (incluindo os não visíveis)
    foreach my $key (keys %discovered_portals) {
        push @portals, {
            name => $discovered_portals{$key}{name},
            x    => $discovered_portals{$key}{x},
            y    => $discovered_portals{$key}{y},
        };
    }
    
    $data{portals} = \@portals;

    # ... resto do código continua igual ...
    
    $data{ai_state}    = eval { AI::state() }   // 'unknown';
    $data{ai_sequence} = eval { AI::action() }  // '';

    return \%data;
}


sub get_inventory_data {
    my @items;
    my $total_value = 0;

    if ($char && $char->inventory()) {
        my $pos = 0;
        foreach my $item (@{$char->inventory()->getItems()}) {
            next unless $item;
            my $name    = $item->name() || '';
            my $type    = $item->{type} || 0; # nem sempre vem confiável
            my $equipped= $item->{equipped} ? 1 : 0;
            my $amount  = $item->{amount} || 1;
            my $idx     = $item->{invIndex} // $item->{index} // $item->{binID} // $pos;

            # heurística simples de categoria
            my $category = 'other';
            if ($equipped) { $category = 'equipped' }
            elsif ($type == 4 || $type == 5 || $name =~ /(Sword|Bow|Dagger|Shield|Armor|Hat|Boot|Robe|Manteau|Accessory|Elmo|Arco|Adaga|Escudo|Armadura|Chapéu|Bota|Capa|Acessório)/i) {
                $category = 'equipable';
            } elsif ($type == 3 || $name =~ /(Potion|Poção|Scroll|Comida|Food|Flecha|Arrow|Garrafa|Bottle)/i) {
                $category = 'consumable';
            }

            my $estimated_price = estimate_item_price($item);
            $total_value += $estimated_price * $amount;

            push @items, {
                name        => $name,
                nameID      => $item->{nameID} || 0,
                amount      => $amount,
                type        => $type,
                identified  => $item->{identified} ? JSON::true : JSON::false,
                equipped    => $equipped ? JSON::true : JSON::false,
                index       => int($idx),
                category    => $category,
                price       => $estimated_price,
                total_price => $estimated_price * $amount,
            };
            $pos++;
        }
    }

    return {
        items       => \@items,
        count       => scalar(@items),
        total_value => $total_value,
    };
}


sub estimate_item_price {
    my ($item) = @_;
    return 0 unless $item;
    
    # Estimativa básica de preço baseado no tipo e nome do item
    my $price = 0;
    my $name = $item->name() || '';
    
    if ($name =~ /Potion|Potão/i) {
        $price = 50;
    } elsif ($name =~ /Arrow|Flecha/i) {
        $price = 10;
    } elsif ($name =~ /Ore|Minério/i) {
        $price = 100;
    } elsif ($name =~ /Gem|Gema/i) {
        $price = 1000;
    } else {
        $price = 10; # preço padrão
    }
    
    return $price;
}

sub get_skills_data {
    my @skills = ();
    my $total_sp_cost = 0;
    
    if ($char && $char->{skills}) {
        foreach my $handle (keys %{$char->{skills}}) {
            my $skill = $char->{skills}{$handle};
            next unless ref($skill) eq 'HASH';
            
            my $skill_id = $skill->{ID} || $skill->{id} || 0;
            my $sp_cost = $skill->{sp} || 0;
            $total_sp_cost += $sp_cost;
            
            push @skills, {
                name => $skill->{name} || $handle,
                level => $skill->{lv} || 0,
                sp => $sp_cost,
                handle => $handle,
                id => $skill_id,  # Certifica-se que o ID está sendo enviado
                max_level => $skill->{max_lv} || 10,
            };
        }
    }
    
    # Ordena skills por nome
    @skills = sort { $a->{name} cmp $b->{name} } @skills;
    
    return {
        skills => \@skills,
        count => scalar(@skills),
        total_sp_cost => $total_sp_cost,
    };
}

sub get_session_stats {
    my $current_time = time();
    my $uptime = $current_time - $session_stats{start_time};
    my $exp_gained = 0;
    my $zeny_gained = 0;
    my $levels_gained = 0;
    my $job_levels_gained = 0;
    
    if ($char) {
        $exp_gained = ($char->{exp} || 0) - $session_stats{exp_start};
        $zeny_gained = ($char->{zeny} || 0) - $session_stats{zeny_start};
        $levels_gained = ($char->{lv} || 0) - ($session_stats{base_level_start} || 0);
        $job_levels_gained = ($char->{lv_job} || 0) - ($session_stats{job_level_start} || 0);
    }
    
    my $exp_per_hour = $uptime > 0 ? int(($exp_gained / $uptime) * 3600) : 0;
    my $zeny_per_hour = $uptime > 0 ? int(($zeny_gained / $uptime) * 3600) : 0;
    
    # Calcula estatísticas por minuto
    my $time_since_last = $current_time - $session_stats{last_update};
    my $kills_per_minute = $time_since_last > 0 ? ($session_stats{kills} / $time_since_last) * 60 : 0;
    my $skills_per_minute = $time_since_last > 0 ? ($session_stats{skills_used} / $time_since_last) * 60 : 0;
    
    $session_stats{last_update} = $current_time;
    
    # CORREÇÃO: Usar as variáveis do hash session_stats em vez de variáveis globais
    my $efficiency = $session_stats{deaths} > 0 ? 
        sprintf("%.2f", $session_stats{kills} / $session_stats{deaths}) : 
        $session_stats{kills};
    
    return {
        uptime => int($uptime),
        exp_gained => $exp_gained,
        zeny_gained => $zeny_gained,
        exp_per_hour => $exp_per_hour,
        zeny_per_hour => $zeny_per_hour,
        kills => $session_stats{kills},
        deaths => $session_stats{deaths},
        items_collected => $session_stats{items_collected},
        damage_dealt => $session_stats{damage_dealt},
        damage_received => $session_stats{damage_received},
        skills_used => $session_stats{skills_used},
        levels_gained => $levels_gained,
        job_levels_gained => $job_levels_gained,
        kills_per_minute => sprintf("%.2f", $kills_per_minute),
        skills_per_minute => sprintf("%.2f", $skills_per_minute),
        efficiency => $efficiency,  # Usando a variável calculada
    };
}

sub get_monsters_list {
    my @monsters = ();
    
    if ($monstersList) {
		foreach my $monster (@{$monstersList->getItems()}) {
			my $dist = 0;
			if ($char && $char->{pos_to} && $monster->{pos_to}) {
				$dist = int(Utils::distance($char->{pos_to}, $monster->{pos_to}) || 0);
			}
			my $mhp  = _i($monster->{hp});
			my $mmax = _i($monster->{hp_max});
			my $hp_percent = $mmax ? int(($mhp / $mmax) * 100) : 0;
		
			push @monsters, {
				name       => $monster->name() || '',
				nameID     => _i($monster->{nameID}),
				level      => _i($monster->{lv}),
				hp         => $mhp,
				hp_max     => $mmax,
				hp_percent => $hp_percent,
				distance   => $dist,
			};
		}

    }
    
    # Ordena por distância
    @monsters = sort { $a->{distance} <=> $b->{distance} } @monsters;
    
    return { monsters => \@monsters };
}

sub get_target_info {
    # Resolve alvo atual por múltiplas heurísticas:
    # 1) ID que o char está atacando (comum em builds recentes)
    # 2) Fallbacks conhecidos em estruturas internas
    # 3) Último recurso: variável de pacote (se existir) sem importar
    my $t;

    if ($char) {
        # 1) ID de alvo que o char está atacando (normalmente um GUID de ator)
        if ($char->{attackTarget} && $monstersList && $monstersList->can('getByID')) {
            my $cand = eval { $monstersList->getByID($char->{attackTarget}) };
            $t = $cand if $cand;
        }

        # 2) Alguns forks guardam referência direta
        if (!$t && $char->{target} && ref $char->{target}) {
            $t = $char->{target};
        }
    }

    # 3) Se existir uma variável global (não exportada), use-a sem importar
    if (!$t && defined $Globals::target && ref $Globals::target) {
        $t = $Globals::target;
    }

    # Sem alvo
    return { exists => JSON::false } unless $t && ref $t;

    # Distância
    my $dist = 0;
    if ($char && $char->{pos_to} && $t->{pos_to}) {
        $dist = int(Utils::distance($char->{pos_to}, $t->{pos_to}) || 0);
    }

    # HP e bounds (conserta typo hp_max)
    my $thp  = _i($t->{hp});
    my $tmax = _i($t->{hp_max});

    return {
        name       => ($t->can('name') ? ($t->name() // '') : ($t->{name} // '')),
        nameID     => _i($t->{nameID}),
        level      => _i($t->{lv}),
        hp         => $thp,
        hp_max     => $tmax,
        hp_percent => $tmax ? int(($thp / $tmax) * 100) : 0,
        distance   => $dist,
        exists     => JSON::true,
    };
}




sub get_config_info {
    my %cfg = (
        username => $config{username} // 'N/A',
        server   => $config{master}   // 'N/A',
        char     => $config{char}     // 'N/A',
    );
    return \%cfg;
}


sub get_item_details {
	my ($index) = @_;
	if ($char && $char->inventory()) {
		my $items = $char->inventory()->getItems();
		my $it = $items->[$index];
		if ($it) {
			my $idx = $it->{invIndex} // $it->{index} // $it->{binID} // $index;
			return {
				name        => $it->name() || '',
				nameID      => _i($it->{nameID}),
				amount      => _i($it->{amount} // 1),
				type        => _i($it->{type}),
				identified  => $it->{identified} ? JSON::true : JSON::false,
				equipped    => $it->{equipped}   ? JSON::true : JSON::false,
				index       => _i($idx),
				description => get_item_description($it),
			};
		}
	}
	return { error => 'Item não encontrado' };

}

sub get_item_description {
    my ($item) = @_;
    # Descrição básica do item (pode ser expandida)
    my $desc = "Item ID: " . ($item->{nameID} || 'N/A');
    $desc .= " | Tipo: " . ($item->{type} || 'N/A');
    $desc .= " | Identificado: " . ($item->{identified} ? 'Sim' : 'Não');
    $desc .= " | Equipado: " . ($item->{equipped} ? 'Sim' : 'Não');
    
    return $desc;
}

sub save_config_changes {
    my ($config_changes) = @_;
    return unless ref $config_changes eq 'HASH';
    for my $key (keys %$config_changes) {
        $config{$key} = $config_changes->{$key} if defined $config_changes->{$key};
    }
}



sub get_dashboard_html {
    return q{<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenKore Dashboard Pro</title>
    <style>
	
	.chat-entry.console { border-left-color: #888; color: #ddd; }
.chat-entry.public  { border-left-color: #44ccff; }
.chat-entry.private { border-left-color: #ff66ff; }
.chat-entry.party   { border-left-color: #66ffcc; }
.chat-entry.guild   { border-left-color: #ffaa00; }
.chat-entry.self    { border-left-color: #aaff66; }

	.item-badge {
    position: absolute;
    top: 4px;
    left: 6px;
    background: rgba(255,215,0,0.9);
    color: #000;
    font-size: 9px; /* pequeno */
    font-weight: 700;
    padding: 1px 4px;
    border-radius: 3px;
    letter-spacing: .3px;
}

.item { position: relative; } /* para posicionar a badge */

/* Cores por categoria */
.item.consumable { border-color: #44ff44; box-shadow: 0 0 8px rgba(68,255,68,0.15); }
.item.equipable  { border-color: #44ccff; box-shadow: 0 0 8px rgba(68,204,255,0.15); }
.item.other      { border-color: rgba(255,255,255,0.1); }
.item.equipped   { border-color: #ffd700; background: rgba(255,215,0,0.08); }

        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #0a0e27;
            color: #fff;
            overflow: hidden;
        }
        
        .dashboard {
            display: grid;
            grid-template-columns: 300px 1fr 400px;
            grid-template-rows: 60px 1fr;
            height: 100vh;
            gap: 10px;
            padding: 10px;
        }
        
        .header {
            grid-column: 1 / -1;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 10px 20px;
            border-radius: 10px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            box-shadow: 0 4px 15px rgba(0,0,0,0.3);
        }
        
        .header h1 {
            font-size: 1.5em;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .status-dot {
            width: 12px;
            height: 12px;
            border-radius: 50%;
            background: #44ff44;
            animation: pulse 2s infinite;
        }
        
        @keyframes pulse {
            0%, 100% { opacity: 1; box-shadow: 0 0 10px #44ff44; }
            50% { opacity: 0.5; box-shadow: 0 0 20px #44ff44; }
        }
        
        .ai-controls {
            display: flex;
            gap: 10px;
        }
        
        .ai-btn {
            padding: 8px 15px;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-weight: bold;
            transition: all 0.2s;
            font-size: 0.9em;
        }
        
        .ai-btn.off { background: #ff4444; color: #fff; }
        .ai-btn.on { background: #44ff44; color: #000; }
        .ai-btn.auto { background: #ffaa00; color: #000; }
        .ai-btn:hover { transform: translateY(-2px); box-shadow: 0 4px 10px rgba(0,0,0,0.3); }
        
        .sidebar-left, .sidebar-right, .main-content {
            display: flex;
            flex-direction: column;
            gap: 10px;
            overflow-y: auto;
        }
        
        .card {
            background: rgba(255,255,255,0.05);
            backdrop-filter: blur(10px);
            border-radius: 10px;
            padding: 15px;
            border: 1px solid rgba(255,255,255,0.1);
            box-shadow: 0 4px 15px rgba(0,0,0,0.2);
        }
        
        .card.minimized .card-content {
            display: none;
        }
        
        .card-title {
            font-size: 1.1em;
            font-weight: bold;
            margin-bottom: 10px;
            padding-bottom: 10px;
            border-bottom: 2px solid rgba(255,255,255,0.2);
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            user-select: none;
        }
        
        .minimize-btn {
            background: rgba(255,255,255,0.1);
            border: none;
            color: #fff;
            width: 24px;
            height: 24px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 1.2em;
        }
        
        .stat-row {
            display: flex;
            justify-content: space-between;
            padding: 8px;
            margin: 5px 0;
            background: rgba(0,0,0,0.2);
            border-radius: 5px;
            font-size: 0.9em;
        }
        
        .stat-label { color: #a8daff; font-weight: 500; }
        .stat-value { color: #ffd700; font-weight: bold; }
        
        .progress-bar {
            width: 100%;
            height: 20px;
            background: rgba(0,0,0,0.3);
            border-radius: 10px;
            overflow: hidden;
            margin: 8px 0;
        }
        
        .progress-fill {
            height: 100%;
            transition: width 0.3s;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 0.85em;
            font-weight: bold;
        }
        
        .progress-fill.hp { background: linear-gradient(90deg, #ff4444, #ff6b6b); }
        .progress-fill.sp { background: linear-gradient(90deg, #4444ff, #6b6bff); }
        .progress-fill.exp { background: linear-gradient(90deg, #44ff44, #6bff6b); }
        .progress-fill.weight { background: linear-gradient(90deg, #ffaa00, #ffcc00); }
        
        #mapContainer {
            position: relative;
            width: 100%;
            height: 450px;
            background: #000;
            border-radius: 10px;
            overflow: hidden;
            border: 2px solid rgba(255,255,255,0.2);
            display: flex;
            align-items: center;
            justify-content: center;
        }
        
        #mapCanvas {
            position: absolute;
            cursor: crosshair;
        }
        
        .map-info {
            position: absolute;
            top: 10px;
            left: 10px;
            background: rgba(0,0,0,0.8);
            padding: 8px 12px;
            border-radius: 5px;
            font-size: 0.85em;
            z-index: 10;
        }
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 10px;
        }
        
        .stat-box {
            background: rgba(0,0,0,0.3);
            padding: 12px;
            border-radius: 8px;
            text-align: center;
        }
        
        .stat-box-value {
            font-size: 1.6em;
            font-weight: bold;
            color: #ffd700;
        }
        
        .stat-box-label {
            font-size: 0.85em;
            color: #ccc;
            margin-top: 5px;
        }
        
        .stat-upgrade-btn {
            background: rgba(68,255,68,0.2);
            border: 1px solid #44ff44;
            color: #44ff44;
            padding: 3px 8px;
            border-radius: 3px;
            cursor: pointer;
            font-size: 0.75em;
            margin-top: 5px;
            display: none;
        }
        
        .stat-upgrade-btn.show {
            display: inline-block;
        }
        
        .stat-upgrade-btn:hover {
            background: rgba(68,255,68,0.3);
        }
        
        .inventory-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(70px, 1fr));
            gap: 8px;
            max-height: 400px;
            overflow-y: auto;
        }
        
        .item {
            background: rgba(0,0,0,0.3);
            padding: 8px;
            border-radius: 8px;
            border: 1px solid rgba(255,255,255,0.1);
            text-align: center;
            cursor: pointer;
            transition: all 0.2s;
        }
        
        .item:hover {
            transform: translateY(-2px);
            border-color: #ffd700;
            box-shadow: 0 4px 10px rgba(255,215,0,0.3);
        }
        
        .item.equipped {
            border-color: #ffd700;
            background: rgba(255,215,0,0.1);
        }
        
        .item-icon {
            width: 40px;
            height: 40px;
            margin: 0 auto 5px;
            background: rgba(0,0,0,0.5);
            border-radius: 5px;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        
        .item-icon img {
            max-width: 100%;
            max-height: 100%;
        }
        
        .item-name {
            font-size: 0.75em;
            color: #ffd700;
            margin-bottom: 3px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        
        .item-amount {
            font-size: 0.7em;
            color: #ccc;
        }
        
        .context-menu {
            position: fixed;
            background: rgba(20, 20, 40, 0.95);
            border: 1px solid rgba(255,255,255,0.2);
            border-radius: 8px;
            padding: 5px;
            z-index: 10000;
            box-shadow: 0 4px 20px rgba(0,0,0,0.5);
        }
        
        .context-menu-item {
            padding: 8px 15px;
            cursor: pointer;
            border-radius: 4px;
            font-size: 0.9em;
        }
        
        .context-menu-item:hover {
            background: rgba(255,255,255,0.1);
        }
        
        .context-menu-item.danger {
            color: #ff6b6b;
        }
        
        .skills-list {
            display: flex;
            flex-direction: column;
            gap: 8px;
            max-height: 400px;
            overflow-y: auto;
        }
        
        .skill-item {
            background: rgba(0,0,0,0.3);
            padding: 10px;
            border-radius: 8px;
            border: 1px solid rgba(255,255,255,0.1);
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .skill-info {
            flex: 1;
        }
        
        .skill-name {
            font-weight: bold;
            color: #ffd700;
            font-size: 0.9em;
            margin-bottom: 3px;
        }
        
        .skill-details {
            font-size: 0.75em;
            color: #ccc;
        }
        
        .skill-btn {
            padding: 5px 10px;
            border: 1px solid rgba(68,255,68,0.5);
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.75em;
            background: rgba(68,255,68,0.2);
            color: #44ff44;
            transition: all 0.2s;
        }
        
        .skill-btn:hover {
            background: rgba(68,255,68,0.3);
        }
        
        .monsters-list {
            display: flex;
            flex-direction: column;
            gap: 8px;
            max-height: 450px;
            overflow-y: auto;
        }
        
        .monster-item {
            background: rgba(0,0,0,0.3);
            padding: 10px;
            border-radius: 8px;
            border: 1px solid rgba(255,255,255,0.1);
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .monster-item:hover {
            background: rgba(255,68,68,0.2);
            border-color: #ff4444;
        }
        
        .monster-info {
            flex: 1;
        }
        
        .monster-name {
            font-weight: bold;
            color: #ff6b6b;
            font-size: 0.85em;
            margin-bottom: 2px;
        }
        
        .monster-hp {
            font-size: 0.75em;
            color: #ccc;
        }
        
        .monster-distance {
            font-size: 0.75em;
            color: #ffaa00;
        }
        
        .chat-container {
            background: rgba(0,0,0,0.4);
            padding: 10px;
            border-radius: 8px;
            height: 400px;
            overflow-y: auto;
            font-family: 'Courier New', monospace;
            font-size: 0.8em;
        }
        
        .chat-entry {
            margin: 3px 0;
            padding: 4px;
            border-left: 3px solid #4444ff;
            padding-left: 8px;
            word-wrap: break-word;
        }
        
        .chat-entry.system { border-left-color: #ffaa00; color: #ffcc66; }
        
        .chat-input-group {
            display: flex;
            gap: 8px;
            margin-top: 10px;
        }
        
        .chat-input {
            flex: 1;
            background: rgba(0,0,0,0.3);
            border: 1px solid rgba(255,255,255,0.2);
            color: #fff;
            padding: 8px;
            border-radius: 5px;
            font-size: 0.85em;
        }
        
        .send-btn {
            background: rgba(68,255,68,0.2);
            border: 1px solid #44ff44;
            color: #fff;
            padding: 8px 15px;
            border-radius: 5px;
            cursor: pointer;
            font-size: 0.85em;
        }
        
        .send-btn:hover {
            background: rgba(68,255,68,0.3);
        }
        
        .session-stats {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 10px;
        }
        
        .session-stat {
            background: rgba(0,0,0,0.3);
            padding: 12px;
            border-radius: 8px;
            text-align: center;
        }
        
        .session-stat-value {
            font-size: 1.3em;
            font-weight: bold;
            color: #44ff44;
        }
        
        .session-stat-label {
            font-size: 0.75em;
            color: #ccc;
            margin-top: 3px;
        }
        
        .target-display {
            background: rgba(255,68,68,0.2);
            border: 2px solid #ff4444;
            padding: 12px;
            border-radius: 8px;
            display: flex;
            align-items: center;
            gap: 12px;
        }
        
        .target-info {
            flex: 1;
        }
        
        .target-name {
            font-size: 1.1em;
            font-weight: bold;
            color: #ff6b6b;
            margin-bottom: 5px;
        }
        
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: rgba(0,0,0,0.2); border-radius: 3px; }
        ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.3); border-radius: 3px; }
        ::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.5); }
        
        .command-panel {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 8px;
        }
        
        .cmd-btn {
            background: rgba(255,255,255,0.1);
            border: 1px solid rgba(255,255,255,0.2);
            color: #fff;
            padding: 8px;
            border-radius: 5px;
            cursor: pointer;
            font-size: 0.8em;
            transition: all 0.2s;
        }
        
        .cmd-btn:hover {
            background: rgba(255,255,255,0.2);
            transform: translateY(-2px);
        }
    </style>
</head>
<body>
    <div class="dashboard">
        <div class="header">
            <h1>
                <span class="status-dot" id="statusDot"></span>
                OpenKore Dashboard Pro
            </h1>
            <div class="ai-controls">
                <button class="ai-btn off" onclick="setAI('off')">AI OFF</button>
                <button class="ai-btn on" onclick="setAI('manual')">AI MANUAL</button>
                <button class="ai-btn auto" onclick="setAI('auto')">AI AUTO</button>
            </div>
        </div>
<div class="sidebar-left">
            <div class="card" id="cardChar">
                <div class="card-title" onclick="toggleCard('cardChar')">
                    📊 Personagem
                    <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardChar')">−</button>
                </div>
                <div class="card-content">
                    <div class="stat-row">
                        <span class="stat-label">Nome:</span>
                        <span class="stat-value" id="charName">-</span>
                    </div>
                    <div class="stat-row">
                        <span class="stat-label">Level / Job:</span>
                        <span class="stat-value" id="charLevel">-</span>
                    </div>
                    <div class="stat-row">
                        <span class="stat-label">Zeny:</span>
                        <span class="stat-value" id="charZeny">-</span>
                    </div>
                    
                    <div style="margin-top: 10px;">
                        <div class="stat-label">HP</div>
                        <div class="progress-bar">
                            <div class="progress-fill hp" id="hpBar">0%</div>
                        </div>
                        <div class="stat-label">SP</div>
                        <div class="progress-bar">
                            <div class="progress-fill sp" id="spBar">0%</div>
                        </div>
                        <div class="stat-label">EXP Base</div>
                        <div class="progress-bar">
                            <div class="progress-fill exp" id="expBar">0%</div>
                        </div>
                        <div class="stat-label">EXP Job</div>
                        <div class="progress-bar">
                            <div class="progress-fill exp" id="expJobBar">0%</div>
                        </div>
                        <div class="stat-label">Peso</div>
                        <div class="progress-bar">
                            <div class="progress-fill weight" id="weightBar">0%</div>
                        </div>
                    </div>
                </div>
            </div>
            
            <div class="card" id="cardStats">
                <div class="card-title" onclick="toggleCard('cardStats')">
                    💪 Atributos
                    <span style="font-size: 0.85em; color: #44ff44;">Pts: <span id="statPoints">0</span></span>
                    <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardStats')">−</button>
                </div>
                <div class="card-content">
                    <div class="stats-grid">
                        <div class="stat-box">
                            <div class="stat-box-value" id="statStr">0</div>
                            <div class="stat-box-label">STR</div>
                            <button class="stat-upgrade-btn" id="btnStr" onclick="upgradeStat('str')">+</button>
                        </div>
                        <div class="stat-box">
                            <div class="stat-box-value" id="statAgi">0</div>
                            <div class="stat-box-label">AGI</div>
                            <button class="stat-upgrade-btn" id="btnAgi" onclick="upgradeStat('agi')">+</button>
                        </div>
                        <div class="stat-box">
                            <div class="stat-box-value" id="statVit">0</div>
                            <div class="stat-box-label">VIT</div>
                            <button class="stat-upgrade-btn" id="btnVit" onclick="upgradeStat('vit')">+</button>
                        </div>
                        <div class="stat-box">
                            <div class="stat-box-value" id="statInt">0</div>
                            <div class="stat-box-label">INT</div>
                            <button class="stat-upgrade-btn" id="btnInt" onclick="upgradeStat('int')">+</button>
                        </div>
                        <div class="stat-box">
                            <div class="stat-box-value" id="statDex">0</div>
                            <div class="stat-box-label">DEX</div>
                            <button class="stat-upgrade-btn" id="btnDex" onclick="upgradeStat('dex')">+</button>
                        </div>
                        <div class="stat-box">
                            <div class="stat-box-value" id="statLuk">0</div>
                            <div class="stat-box-label">LUK</div>
                            <button class="stat-upgrade-btn" id="btnLuk" onclick="upgradeStat('luk')">+</button>
                        </div>
                    </div>
                </div>
            </div>
            
            <div class="card" id="cardSession">
                <div class="card-title" onclick="toggleCard('cardSession')">
                    📈 Estatísticas
                    <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardSession')">−</button>
                </div>
                <div class="card-content">
                    <div class="session-stats">
                        <div class="session-stat">
                            <div class="session-stat-value" id="sessionUptime">0:00:00</div>
                            <div class="session-stat-label">Tempo Online</div>
                        </div>
                        <div class="session-stat">
                            <div class="session-stat-value" id="sessionExpHour">0</div>
                            <div class="session-stat-label">EXP/hora</div>
                        </div>
                        <div class="session-stat">
                            <div class="session-stat-value" id="sessionZenyHour">0</div>
                            <div class="session-stat-label">Zeny/hora</div>
                        </div>
                        <div class="session-stat">
                            <div class="session-stat-value" id="sessionKills">0</div>
                            <div class="session-stat-label">Kills</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="main-content">
            <div class="card" id="targetCard" style="display: none;">
                <div class="target-display">
                    <div class="target-info">
                        <div class="target-name" id="targetName">-</div>
                        <div class="stat-label">HP</div>
                        <div class="progress-bar" style="margin: 5px 0;">
                            <div class="progress-fill hp" id="targetHpBar">0%</div>
                        </div>
                        <div style="display: flex; justify-content: space-between; font-size: 0.85em; color: #ccc;">
                            <span>Lv: <span id="targetLevel">-</span></span>
                            <span>Dist: <span id="targetDistance">-</span>m</span>
                        </div>
                    </div>
                </div>
            </div>
            
            <div class="card" id="cardCommands">
                <div class="card-title" onclick="toggleCard('cardCommands')">
                    ⚡ Comandos
                    <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardCommands')">−</button>
                </div>
                <div class="card-content">
                    <div class="command-panel">
                        <button class="cmd-btn" onclick="sendCommand('pause')">⏸️ Pause</button>
                        <button class="cmd-btn" onclick="sendCommand('reload all')">🔄 Reload</button>
                        <button class="cmd-btn" onclick="sendCommand('s')">📊 Status</button>
                        <button class="cmd-btn" onclick="sendCommand('i')">🎒 Inv</button>
                        <button class="cmd-btn" onclick="sendCommand('skills')">✨ Skills</button>
                        <button class="cmd-btn" onclick="sendCommand('exp')">📈 EXP</button>
                        <button class="cmd-btn" onclick="sendCommand('relog')">🔌 Relog</button>
                        <button class="cmd-btn" onclick="sendCommand('respawn')">💀 Respawn</button>
                    </div>
                    <div class="chat-input-group">
                        <input type="text" class="chat-input" id="customCommand" placeholder="Comando..." onkeypress="if(event.key==='Enter')sendCustomCommand()">
                        <button class="send-btn" onclick="sendCustomCommand()">Enviar</button>
                    </div>
                </div>
            </div>
            
            <div class="card" id="cardInv">
                <div class="card-title" onclick="toggleCard('cardInv')">
                    🎒 Inventário (<span id="invCount">0</span>)
                    <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardInv')">−</button>
                </div>
                <div class="card-content">
                    <div class="inventory-grid" id="inventoryGrid"></div>
                </div>
            </div>
            
            <div class="card" id="cardChat">
                <div class="card-title" onclick="toggleCard('cardChat')">
                    💬 Chat / Console
                    <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardChat')">−</button>
                </div>
                <div class="card-content">
                    <div class="chat-container" id="chatContainer"></div>
                    <div class="chat-input-group">
                        <input type="text" class="chat-input" id="chatInput" placeholder="Mensagem..." onkeypress="if(event.key==='Enter')sendChat()">
                        <button class="send-btn" onclick="sendChat()">Enviar</button>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="sidebar-right">
            <div class="card" id="cardMap">
                <div class="card-title" onclick="toggleCard('cardMap')">
                    🗺️ Mapa - <span id="mapName">-</span>
                    <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardMap')">−</button>
                </div>
                <div class="card-content">
                    <div id="mapContainer">
                        <div class="map-info">
                            <div>Pos: <span id="mapPos">0, 0</span></div>
                            <div>AI: <span id="aiState">-</span></div>
                        </div>
                        <canvas id="mapCanvas"></canvas>
                    </div>
                    <div class="stat-row">
                        <span class="stat-label">Players:</span>
                        <span class="stat-value" id="playersCount">0</span>
                    </div>
                    <div class="stat-row">
                        <span class="stat-label">Monstros:</span>
                        <span class="stat-value" id="monstersCount">0</span>
                    </div>
                    <div class="stat-row">
                        <span class="stat-label">Portais:</span>
                        <span class="stat-value" id="portalsCount">0</span>
                    </div>
                </div>
            </div>
            
            <div class="card" id="cardMonsters">
                <div class="card-title" onclick="toggleCard('cardMonsters')">
                    👹 Monstros Próximos
                    <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardMonsters')">−</button>
                </div>
                <div class="card-content">
                    <div class="monsters-list" id="monstersList"></div>
                </div>
            </div>
            
            <div class="card" id="cardSkills">
                <div class="card-title" onclick="toggleCard('cardSkills')">
                    ✨ Skills
                    <span style="font-size: 0.85em; color: #44ff44;">Pts: <span id="skillPoints">0</span></span>
                    <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardSkills')">−</button>
                </div>
                <div class="card-content">
                    <div class="skills-list" id="skillsList"></div>
                </div>
            </div>
        </div>
    </div>

    <script>
        let mapData = null;
        const canvas = document.getElementById('mapCanvas');
        const ctx = canvas.getContext('2d');
        const mapImg = new Image();
        let mapImageLoaded = false;
        let contextMenu = null;
        
        setInterval(updateDashboard, 1000);
        updateDashboard();
        
        function toggleCard(cardId) {
            const card = document.getElementById(cardId);
            card.classList.toggle('minimized');
            const btn = card.querySelector('.minimize-btn');
            btn.textContent = card.classList.contains('minimized') ? '+' : '−';
        }
        
        document.addEventListener('click', () => {
            if (contextMenu) {
                contextMenu.remove();
                contextMenu = null;
            }
        });
        
function showContextMenu(e, item) {
    e.preventDefault();
    if (contextMenu) contextMenu.remove();

    contextMenu = document.createElement('div');
    contextMenu.className = 'context-menu';
    contextMenu.style.left = e.pageX + 'px';
    contextMenu.style.top = e.pageY + 'px';

    const actions = [
        { label: '🎮 Usar', action: () => apiPost('/api/item/use', { index: item.index }) },
        { label: item.equipped ? '⚔️ Desequipar' : '⚔️ Equipar',
          action: () => apiPost(item.equipped ? '/api/item/unequip' : '/api/item/equip', { index: item.index }) },
        { label: '🗑️ Dropar…', danger: true, action: async () => {
            let q = prompt(`Quantidade para dropar (máx ${item.amount}):`, '1');
            if (q === null) return;
            q = parseInt(q, 10);
            if (isNaN(q) || q < 1) q = 1;
            if (q > item.amount) q = item.amount;
            await apiPost('/api/item/drop', { index: item.index, amount: q });
        }},
    ];

    actions.forEach(a => {
        const div = document.createElement('div');
        div.className = 'context-menu-item' + (a.danger ? ' danger' : '');
        div.textContent = a.label;
        div.onclick = ev => { ev.stopPropagation(); a.action(); contextMenu.remove(); contextMenu = null; };
        contextMenu.appendChild(div);
    });

    document.body.appendChild(contextMenu);
}

        
        async function updateDashboard() {
            try {
                const [data, stats, monsters, target] = await Promise.all([
                    fetch('/api/all').then(r => r.json()),
                    fetch('/api/stats').then(r => r.json()),
                    fetch('/api/monsters').then(r => r.json()),
                    fetch('/api/target').then(r => r.json())
                ]);
                
                updateCharacter(data.character);
                updateMap(data.map);
                updateInventory(data.inventory);
                updateSkills(data.skills);
                updateSessionStats(stats);
                updateMonstersList(monsters.monsters);
                updateTarget(target);
                updateChat();
                
                document.getElementById('statusDot').style.background = '#44ff44';
            } catch (error) {
                console.error('Erro:', error);
                document.getElementById('statusDot').style.background = '#ff4444';
            }
        }
function updateCharacter(char) {
            if (!char) return;
            
            document.getElementById('charName').textContent = char.name || '-';
            document.getElementById('charLevel').textContent = `${char.level} / ${char.job} (${char.job_level})`;
            document.getElementById('charZeny').textContent = (char.zeny || 0).toLocaleString('pt-BR');
            
            const statPoints = char.points_free || 0;
            const skillPoints = char.points_skill || 0;
            
            document.getElementById('statPoints').textContent = statPoints;
            document.getElementById('skillPoints').textContent = skillPoints;
            
            const statBtns = ['btnStr', 'btnAgi', 'btnVit', 'btnInt', 'btnDex', 'btnLuk'];
            statBtns.forEach(btnId => {
                const btn = document.getElementById(btnId);
                if (statPoints > 0) {
                    btn.classList.add('show');
                } else {
                    btn.classList.remove('show');
                }
            });
            
            updateProgressBar('hpBar', char.hp_percent, `${char.hp}/${char.hp_max}`);
            updateProgressBar('spBar', char.sp_percent, `${char.sp}/${char.sp_max}`);
            updateProgressBar('expBar', char.exp_percent, `${char.exp_percent}%`);
            updateProgressBar('expJobBar', char.exp_job_percent, `${char.exp_job_percent}%`);
            updateProgressBar('weightBar', char.weight_percent, `${char.weight}/${char.weight_max}`);
            
            if (char.stats) {
                document.getElementById('statStr').textContent = char.stats.str || 0;
                document.getElementById('statAgi').textContent = char.stats.agi || 0;
                document.getElementById('statVit').textContent = char.stats.vit || 0;
                document.getElementById('statInt').textContent = char.stats.int || 0;
                document.getElementById('statDex').textContent = char.stats.dex || 0;
                document.getElementById('statLuk').textContent = char.stats.luk || 0;
            }
        }
        
        function updateProgressBar(id, percent, text) {
            const bar = document.getElementById(id);
            bar.style.width = Math.min(percent, 100) + '%';
            bar.textContent = text;
        }
        
        function updateMap(map) {
            if (!map) return;
            
            mapData = map;
            document.getElementById('mapName').textContent = map.name || '-';
            document.getElementById('mapPos').textContent = `${map.char_x}, ${map.char_y}`;
            document.getElementById('aiState').textContent = map.ai_state || '-';
            document.getElementById('playersCount').textContent = (map.players || []).length;
            document.getElementById('monstersCount').textContent = (map.monsters || []).length;
            document.getElementById('portalsCount').textContent = (map.portals || []).length;
            
            if (map.name && (!mapImg.src || !mapImg.src.includes(map.name))) {
                mapImageLoaded = false;
                mapImg.src = `https://www.divine-pride.net/img/map/original/${map.name}`;
                mapImg.onload = () => {
                    mapImageLoaded = true;
                    drawMap();
                };
                mapImg.onerror = () => {
                    mapImageLoaded = false;
                    drawMap();
                };
            } else {
                drawMap();
            }
        }
        
        function drawMap() {
            if (!mapData) return;
            
            const container = document.getElementById('mapContainer');
            const cw = container.offsetWidth - 4;
            const ch = container.offsetHeight - 4;
            
            if (mapImageLoaded && mapImg.complete && mapImg.naturalWidth > 0) {
                canvas.width = mapImg.naturalWidth;
                canvas.height = mapImg.naturalHeight;
                const scale = Math.min(cw / canvas.width, ch / canvas.height);
                canvas.style.width = (canvas.width * scale) + 'px';
                canvas.style.height = (canvas.height * scale) + 'px';
                ctx.drawImage(mapImg, 0, 0);
            } else {
                const w = mapData.width || 100;
                const h = mapData.height || 100;
                canvas.width = w;
                canvas.height = h;
                const scale = Math.min(cw / w, ch / h);
                canvas.style.width = (w * scale) + 'px';
                canvas.style.height = (h * scale) + 'px';
                ctx.fillStyle = '#1a1a2e';
                ctx.fillRect(0, 0, canvas.width, canvas.height);
                ctx.strokeStyle = 'rgba(255,255,255,0.1)';
                ctx.lineWidth = 1;
                for (let i = 0; i <= 10; i++) {
                    const x = (canvas.width / 10) * i;
                    const y = (canvas.height / 10) * i;
                    ctx.beginPath();
                    ctx.moveTo(x, 0);
                    ctx.lineTo(x, canvas.height);
                    ctx.stroke();
                    ctx.beginPath();
                    ctx.moveTo(0, y);
                    ctx.lineTo(canvas.width, y);
                    ctx.stroke();
                }
            }
            
            const scaleX = canvas.width / (mapData.width || 1);
            const scaleY = canvas.height / (mapData.height || 1);
            const sx = (x) => x * scaleX;
            const sy = (y) => (mapData.height - y) * scaleY;
            
            if (mapData.portals) {
                ctx.fillStyle = '#aa00ff';
                ctx.strokeStyle = '#ff00ff';
                ctx.lineWidth = 2;
                mapData.portals.forEach(p => {
                    const x = sx(p.x || 0);
                    const y = sy(p.y || 0);
                    ctx.beginPath();
                    ctx.arc(x, y, 8, 0, Math.PI * 2);
                    ctx.fill();
                    ctx.stroke();
                });
            }
            
            if (mapData.monsters) {
                mapData.monsters.forEach(m => {
                    const x = sx(m.x || 0);
                    const y = sy(m.y || 0);
                    ctx.fillStyle = '#ff4444';
                    ctx.beginPath();
                    ctx.arc(x, y, 6, 0, Math.PI * 2);
                    ctx.fill();
                    if (m.hp_max > 0) {
                        const hp = m.hp / m.hp_max;
                        const bw = 20;
                        const bh = 3;
                        ctx.fillStyle = 'rgba(0,0,0,0.5)';
                        ctx.fillRect(x - bw / 2, y - 12, bw, bh);
                        ctx.fillStyle = '#44ff44';
                        ctx.fillRect(x - bw / 2, y - 12, bw * hp, bh);
                    }
                });
            }
            
            if (mapData.players) {
                ctx.fillStyle = '#4444ff';
                mapData.players.forEach(p => {
                    const x = sx(p.x || 0);
                    const y = sy(p.y || 0);
                    ctx.beginPath();
                    ctx.arc(x, y, 5, 0, Math.PI * 2);
                    ctx.fill();
                });
            }
            
            const cx = sx(mapData.char_x || 0);
            const cy = sy(mapData.char_y || 0);
            
            ctx.fillStyle = 'rgba(68,255,68,0.3)';
            ctx.beginPath();
            ctx.arc(cx, cy, 14, 0, Math.PI * 2);
            ctx.fill();
            ctx.fillStyle = '#44ff44';
            ctx.beginPath();
            ctx.arc(cx, cy, 9, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = '#fff';
            ctx.lineWidth = 2;
            ctx.stroke();
        }
        
        canvas.addEventListener('click', (e) => {
            if (!mapData) return;
            const rect = canvas.getBoundingClientRect();
            const scaleX = mapData.width / canvas.width;
            const scaleY = mapData.height / canvas.height;
            const x = Math.floor(((e.clientX - rect.left) / rect.width) * canvas.width * scaleX);
            const y = mapData.height - Math.floor(((e.clientY - rect.top) / rect.height) * canvas.height * scaleY);
            apiPost('/api/move', { x, y });
        });
        
function updateInventory(inv) {
    if (!inv) return;
    const grid = document.getElementById('inventoryGrid');
    document.getElementById('invCount').textContent = inv.count || 0;
    grid.innerHTML = '';

    if (inv.items && inv.items.length > 0) {
        inv.items.forEach(item => {
            const div = document.createElement('div');
            const classes = ['item'];
            if (item.category) classes.push(item.category);
            if (item.equipped) classes.push('equipped');
            div.className = classes.join(' ');
            div.onclick = () => apiPost('/api/item/use', { index: item.index });
            div.oncontextmenu = (e) => showContextMenu(e, item);

            const badge = item.equipped ? `<span class="item-badge">EQUIPADO</span>` : '';

            div.innerHTML = `
                ${badge}
                <div class="item-icon"><img src="https://static.divine-pride.net/images/items/item/${item.nameID}.png" onerror="this.style.display='none'"></div>
                <div class="item-name" title="${item.name}">${item.name}</div>
                <div class="item-amount">x${item.amount}</div>
            `;
            grid.appendChild(div);
        });
    }
}

        
        function updateSkills(skills) {
            if (!skills) return;
            
            const list = document.getElementById('skillsList');
            const skillPoints = parseInt(document.getElementById('skillPoints').textContent) || 0;
            list.innerHTML = '';
            
            if (skills.skills && skills.skills.length > 0) {
                skills.skills.forEach(skill => {
                    const div = document.createElement('div');
                    div.className = 'skill-item';
                    
                    const upgradeBtn = skillPoints > 0 ? 
                        `<button class="skill-btn" onclick="upgradeSkill('${skill.handle}')">+ Upar</button>` :
                        '';
                    
                    div.innerHTML = `
                        <div class="skill-info">
                            <div class="skill-name">${skill.name}</div>
                            <div class="skill-details">Lv. ${skill.level} | SP: ${skill.sp}</div>
                        </div>
                        ${upgradeBtn}
                    `;
                    
                    list.appendChild(div);
                });
            }
        }
        
        function updateMonstersList(monsters) {
            const list = document.getElementById('monstersList');
            list.innerHTML = '';
            
            if (monsters && monsters.length > 0) {
                monsters.slice(0, 15).forEach(monster => {
                    const div = document.createElement('div');
                    div.className = 'monster-item';
                    
                    const hpPercent = monster.hp_max > 0 ? (monster.hp / monster.hp_max * 100).toFixed(0) : 0;
                    
                    div.innerHTML = `
                        <div class="monster-info">
                            <div class="monster-name">${monster.name}</div>
                            <div class="monster-hp">HP: ${hpPercent}%</div>
                            <div class="monster-distance">${monster.distance}m</div>
                        </div>
                    `;
                    
                    list.appendChild(div);
                });
            }
        }
        
        function updateTarget(target) {
            const card = document.getElementById('targetCard');
            
            if (target && target.name) {
                card.style.display = 'block';
                document.getElementById('targetName').textContent = target.name;
                document.getElementById('targetLevel').textContent = target.level || '-';
                document.getElementById('targetDistance').textContent = target.distance || '-';
                
                const hpPercent = target.hp_max > 0 ? (target.hp / target.hp_max * 100) : 0;
                updateProgressBar('targetHpBar', hpPercent, `${target.hp}/${target.hp_max}`);
            } else {
                card.style.display = 'none';
            }
        }
        
        function updateSessionStats(stats) {
            if (!stats) return;
            
            const hours = Math.floor(stats.uptime / 3600);
            const minutes = Math.floor((stats.uptime % 3600) / 60);
            const seconds = stats.uptime % 60;
            
            document.getElementById('sessionUptime').textContent = 
                `${hours}:${String(minutes).padStart(2,'0')}:${String(seconds).padStart(2,'0')}`;
            document.getElementById('sessionExpHour').textContent = stats.exp_per_hour.toLocaleString('pt-BR');
            document.getElementById('sessionZenyHour').textContent = stats.zeny_per_hour.toLocaleString('pt-BR');
            document.getElementById('sessionKills').textContent = stats.kills;
        }
        
        async function updateChat() {
            try {
                const data = await fetch('/api/chat').then(r => r.json());
                const container = document.getElementById('chatContainer');
                
                if (data.messages && data.messages.length > 0) {
                    const shouldScroll = container.scrollHeight - container.scrollTop <= container.clientHeight + 50;
                    
                    container.innerHTML = data.messages.slice(-100).map(msg => {
                        const time = new Date(msg.time * 1000).toLocaleTimeString('pt-BR');
                        return `<div class="chat-entry ${msg.type}">[${time}] ${msg.message}</div>`;
                    }).join('');
                    
                    if (shouldScroll) {
                        container.scrollTop = container.scrollHeight;
                    }
                }
            } catch (e) {}
        }
        
        async function sendCommand(cmd) {
            await apiPost('/api/command', { command: cmd });
        }
        
        function sendCustomCommand() {
            const input = document.getElementById('customCommand');
            if (input.value.trim()) {
                sendCommand(input.value.trim());
                input.value = '';
            }
        }
        
        async function sendChat() {
            const input = document.getElementById('chatInput');
            if (input.value.trim()) {
                await apiPost('/api/chat/send', { message: input.value.trim() });
                input.value = '';
            }
        }
        
        async function setAI(mode) {
            await apiPost('/api/ai', { mode });
        }
        
        async function upgradeStat(stat) {
            await apiPost('/api/stat/upgrade', { stat });
        }
        
        async function upgradeSkill(handle) {
            await apiPost('/api/skill/upgrade', { skill: handle });
        }
        
        async function apiPost(url, data) {
            try {
                const response = await fetch(url, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(data)
                });
                return await response.json();
            } catch (error) {
                console.error('API Error:', error);
            }
        }
    </script>
</body>
</html>};
}

1;		