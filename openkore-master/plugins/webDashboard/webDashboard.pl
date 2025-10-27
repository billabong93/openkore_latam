package webDashboard;

use utf8;
use strict;
use warnings;
use open ':std', ':encoding(UTF-8)';
use POSIX qw(:errno_h);
use Encode qw(encode_utf8 decode_utf8);
use Plugins;
use Globals;
use Log qw(message warning error);
use Utils;
use Network;
use Field;
use Time::HiRes qw(time);
use IO::Socket::INET;
use JSON;
use Commands;
use AI;

# ========================== Registro/Hooks ==========================
Plugins::register('webDashboard', 'Dashboard Web para OpenKore', \&onUnload);

my $hooks = Plugins::addHooks(
    ['start3',        \&onStart,       undef],
    ['mainLoop_pre',  \&onLoop,        undef],
    ['packet_pubMsg', \&onChatPublic,  undef],
    ['packet_privMsg',\&onChatPrivate, undef],
    ['packet_selfChat',\&onChatSelf,   undef],
    ['packet_partyMsg',\&onChatParty,  undef],
    ['packet_guildMsg',\&onChatGuild,  undef],
);

# ============================ Estado ================================
my $server_socket;
my $port = 8888;
my $host = '127.0.0.1';
my $max_port_tries = 10;

my @console_logs;    # [{time,level,domain,message}]
my @chat_messages;   # [{time,type,name,message}]
my $max_logs = 500;
my $max_chat = 100;

my %session_stats = (
    start_time => time(),
    exp_start  => 0,
    zeny_start => 0,
    kills      => 0,
    deaths     => 0,
);

my $log_hook;

# =========================== Ciclo vida =============================
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
        $session_stats{exp_start}  = $char->{exp}  || 0;
        $session_stats{zeny_start} = $char->{zeny} || 0;
    }
}

# ============================ Servidor ==============================
sub onLoop {
    return unless $server_socket;

    my $client = $server_socket->accept();
    return unless $client;

    eval { $client->blocking(0) };

    my $request    = '';
    my $start_time = time();
    my $timeout    = 0.5;

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

    if ($request =~ /^(GET)\s+(\S+)\s+HTTP/i) {
        my $path = $2;
        handle_request($client, $path);
    } elsif ($request =~ /^(POST)\s+(\S+)\s+HTTP/i) {
        my $path = $2;

        my $content_length = 0;
        if ($request =~ /Content-Length:\s*(\d+)/i) {
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

sub start_server {
    my $current_port = $port;
    my $success      = 0;

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
                $port    = $current_port;
                $success = 1;
                message "[webDashboard] Servidor iniciado!\n";
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
        undef $server_socket;
        message "[webDashboard] Servidor parado.\n";
    }
}

# ============================ HTTP ================================
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
    } elsif ($path eq '/api/console') {
        send_json($client, { logs => \@console_logs });
    } elsif ($path eq '/api/chat') {
        send_json($client, { messages => \@chat_messages });
    } elsif ($path eq '/api/stats') {
        send_json($client, get_session_stats());
    } elsif ($path eq '/api/monsters') {
        send_json($client, get_monsters_list());
    } elsif ($path eq '/api/target') {
        send_json($client, get_target_info());
    } else {
        send_404($client);
    }
}

sub handle_post_request {
    my ($client, $path, $body) = @_;

    my $data = eval { JSON->new->utf8->decode($body) };
    $data = {} unless $data && ref $data eq 'HASH';

    if ($path eq '/api/command') {
        if (defined $data->{command} && $data->{command} ne '') {
            Commands::run($data->{command});
            send_json($client, { success => 1 });
            return;
        }
    } elsif ($path eq '/api/chat/send') {
        if (defined $data->{message} && $data->{message} ne '') {
            Commands::run("c " . $data->{message});
            send_json($client, { success => 1 });
            return;
        }
    } elsif ($path eq '/api/skill/use') {
        if (defined $data->{skill} && $data->{skill} ne '') {
            Commands::run("ss " . $data->{skill});
            send_json($client, { success => 1 });
            return;
        }
    } elsif ($path eq '/api/skill/upgrade') {
        if (defined $data->{skill} && $data->{skill} ne '') {
            Commands::run("skills add " . $data->{skill});
            send_json($client, { success => 1 });
            return;
        }
    } elsif ($path eq '/api/stat/upgrade') {
        if (defined $data->{stat} && $data->{stat} ne '') {
            Commands::run("stat_add " . $data->{stat});
            send_json($client, { success => 1 });
            return;
        }
    } elsif ($path eq '/api/item/use') {
        if (defined $data->{index}) {
            Commands::run("is " . $data->{index});
            send_json($client, { success => 1 });
            return;
        }
    } elsif ($path eq '/api/item/equip') {
        if (defined $data->{index}) {
            Commands::run("eq " . $data->{index});
            send_json($client, { success => 1 });
            return;
        }
    } elsif ($path eq '/api/item/unequip') {
        if (defined $data->{index}) {
            Commands::run("uneq " . $data->{index});
            send_json($client, { success => 1 });
            return;
        }
} elsif ($path eq '/api/item/drop') {
    if ($data && defined $data->{listIndex}) {
        my $list_idx = int($data->{listIndex});
        my ($inv_items, $it, $inv_idx, $max_amt) = (undef, undef, undef, 0);

        # Snapshot inventário
        if ($char) {
            if ($char->can('inventory') && $char->inventory && $char->inventory->can('getItems')) {
                $inv_items = $char->inventory->getItems();
            } elsif ($char->{inventory} && ref $char->{inventory} && $char->{inventory}->can('getItems')) {
                $inv_items = $char->{inventory}->getItems();
            } elsif ($char->{inventory} && ref $char->{inventory} eq 'ARRAY') {
                $inv_items = $char->{inventory};
            }
        }

        # Valida listIndex e extrai item
        if ($inv_items && ref($inv_items) eq 'ARRAY' && $list_idx >= 0 && $list_idx <= $#$inv_items) {
            $it = $inv_items->[$list_idx];
            $max_amt = ($it && $it->{amount}) ? int($it->{amount}) : 0;

            # Descobre o INVENTORY INDEX real aceito pelo Kore
            if ($it) {
                $inv_idx = defined $it->{index}     ? $it->{index}
                         : defined $it->{binID}     ? $it->{binID}
                         : defined $it->{invIndex}  ? $it->{invIndex}
                         : (ref($it) && $it->can('index')) ? eval { $it->index() } : undef;
            }
        } else {
            send_json($client, { success => 0, error => 'invalid_list_index' });
            return;
        }

        unless (defined $inv_idx) {
            send_json($client, { success => 0, error => 'no_inventory_index' });
            return;
        }

        # Quantidade solicitada, clamp 1..max
        my $amount = defined $data->{amount} ? int($data->{amount}) : 1;
        $amount = 1 if $amount < 1;
        $amount = $max_amt if $max_amt && $amount > $max_amt;

        # Sempre passe a quantidade (mesmo quando 1) e use o inv_idx real
        my $cmd = "drop $inv_idx $amount";
        Commands::run($cmd);

        send_json($client, { success => 1, used => $cmd, max => $max_amt, invIndex => $inv_idx, listIndex => $list_idx });
        return;
    }

    send_json($client, { success => 0, error => 'missing_list_index' });
    return;
}

}

sub send_html {
    my ($client) = @_;
    my $html = get_dashboard_html();
    my $html_bytes = encode_utf8($html);

    print $client "HTTP/1.1 200 OK\r\n";
    print $client "Content-Type: text/html; charset=utf-8\r\n";
    print $client "Content-Length: " . length($html_bytes) . "\r\n";
    print $client "Connection: close\r\n\r\n";
    print $client $html_bytes;
}

sub send_json {
    my ($client, $data) = @_;
    my $json;
    eval { $json = JSON->new->utf8->allow_nonref->encode($data) };
    $json = '{"error":"JSON encoding error"}' if $@ || !defined $json;

    print $client "HTTP/1.1 200 OK\r\n";
    print $client "Content-Type: application/json; charset=utf-8\r\n";
    print $client "Access-Control-Allow-Origin: *\r\n";
    print $client "Content-Length: " . length($json) . "\r\n";
    print $client "Connection: close\r\n\r\n";
    print $client $json;
}

sub send_404 {
    my ($client) = @_;
    my $html = '<html><body><h1>404 Not Found</h1></body></html>';

    print $client "HTTP/1.1 404 Not Found\r\n";
    print $client "Content-Type: text/html\r\n";
    print $client "Content-Length: " . length($html) . "\r\n";
    print $client "Connection: close\r\n\r\n";
    print $client $html;
}

# ============================ Logs/Chat =============================
sub onLogMessage {
    my (undef, $domain, $level, $msg) = @_;
    return unless defined $msg;

    # Filtra ruído e normaliza
    my $clean = $msg;
    $clean =~ s/[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F]//g;
    return if $clean =~ /^[\s0-9]+$/;
    return if length($clean) < 3;

    push @console_logs, {
        time   => time(),
        level  => $level || 'info',
        domain => $domain || '',
        message => $clean
    };
    shift @console_logs if @console_logs > $max_logs;

    # Heurística simples de kills/mortes
    if ($clean =~ /\b(Alvo|Target).*(morreu|died)/i) {
        $session_stats{kills}++;
    }
    if ($clean =~ /\b(você morreu|you died|killed by)\b/i) {
        $session_stats{deaths}++;
    }
}

sub onChatPublic {
    my (undef, $args) = @_;
    return unless $args && $args->{Msg};
    push @chat_messages, {
        time => time(), type => 'public',
        name => $args->{MsgUser} || 'Unknown',
        message => $args->{Msg}
    };
    shift @chat_messages if @chat_messages > $max_chat;
}

sub onChatPrivate {
    my (undef, $args) = @_;
    return unless $args && $args->{privMsg};
    push @chat_messages, {
        time => time(), type => 'private',
        name => $args->{privMsgUser} || 'Unknown',
        message => $args->{privMsg}
    };
    shift @chat_messages if @chat_messages > $max_chat;
}

sub onChatSelf {
    my (undef, $args) = @_;
    return unless $args && $args->{Msg};
    push @chat_messages, {
        time => time(), type => 'self',
        name => 'Você',
        message => $args->{Msg}
    };
    shift @chat_messages if @chat_messages > $max_chat;
}

sub onChatParty {
    my (undef, $args) = @_;
    return unless $args && $args->{Msg};
    push @chat_messages, {
        time => time(), type => 'party',
        name => $args->{MsgUser} || 'Party',
        message => $args->{Msg}
    };
    shift @chat_messages if @chat_messages > $max_chat;
}

sub onChatGuild {
    my (undef, $args) = @_;
    return unless $args && $args->{Msg};
    push @chat_messages, {
        time => time(), type => 'guild',
        name => $args->{MsgUser} || 'Guild',
        message => $args->{Msg}
    };
    shift @chat_messages if @chat_messages > $max_chat;
}

# ============================ API Data ==============================
sub get_all_data {
    return {
        character => get_character_data(),
        map       => get_map_data(),
        inventory => get_inventory_data(),
        skills    => get_skills_data(),
    };
}

sub _pct {
    my ($cur, $max) = @_;
    $cur ||= 0; $max ||= 0;
    return 0 if $max <= 0;
    my $p = int(($cur * 100) / $max);
    $p = 0   if $p < 0;
    $p = 100 if $p > 100;
    return $p;
}

sub get_character_data {
    return undef unless $char;

    my $hp   = $char->{hp}     || 0;
    my $hpM  = $char->{hp_max} || 1;
    my $sp   = $char->{sp}     || 0;
    my $spM  = $char->{sp_max} || 1;
    my $w    = $char->{weight} || 0;
    my $wM   = $char->{weight_max} || 1;

    my %stats = (
        str => $char->{str} || 0,
        agi => $char->{agi} || 0,
        vit => $char->{vit} || 0,
        int => $char->{int} || 0,
        dex => $char->{dex} || 0,
        luk => $char->{luk} || 0,
    );

    return {
        name           => $char->{name} || '',
        level          => $char->{lv}   || 0,
        job            => $char->{job}  || '',
        job_level      => $char->{lv_job} || 0,
        zeny           => $char->{zeny} || 0,

        hp             => $hp,
        hp_max         => $hpM,
        sp             => $sp,
        sp_max         => $spM,
        exp_percent    => $char->{exp_bar} || 0,
        exp_job_percent=> $char->{exp_job_bar} || 0,
        weight         => $w,
        weight_max     => $wM,
        hp_percent     => _pct($hp,$hpM),
        sp_percent     => _pct($sp,$spM),
        weight_percent => _pct($w,$wM),

        points_free    => $char->{points_free}  || 0,
        points_skill   => $char->{points_skill} || 0,
        stats          => \%stats,
    };
}

sub get_map_data {
    my $map_name = '';
    my ($mw, $mh) = (100, 100);

    if ($field) {
        eval {
            $map_name = $field->name() || $field->{name} || '';
            $mw = $field->width()  || $field->{width}  || $mw;
            $mh = $field->height() || $field->{height} || $mh;
        };
    }

    my ($cx, $cy) = (0, 0);
    if ($char && $char->{pos_to}) {
        $cx = $char->{pos_to}{x} || 0;
        $cy = $char->{pos_to}{y} || 0;
    }

    my @players;
    if ($playersList) {
        foreach my $p (@{$playersList->getItems()}) {
            next unless $p && $p->{pos_to};
            push @players, { x => $p->{pos_to}{x}||0, y => $p->{pos_to}{y}||0 };
        }
    }

    my @portals;
    if ($portalsList) {
        foreach my $po (@{$portalsList->getItems()}) {
            next unless $po && $po->{pos};
            push @portals, { x => $po->{pos}{x}||0, y => $po->{pos}{y}||0 };
        }
    }

    my @monsters;
    if ($monstersList) {
        foreach my $m (@{$monstersList->getItems()}) {
            next unless $m && $m->{pos_to};
            push @monsters, {
                x => $m->{pos_to}{x}||0,
                y => $m->{pos_to}{y}||0,
                nameID => $m->{nameID}||0,
                hp     => $m->{hp}||0,
                hp_max => $m->{hp_max}||0,
            };
        }
    }

    my $ai_state = AI::state() || 'off';

    return {
        name    => $map_name,
        width   => $mw, height => $mh,
        char_x  => $cx, char_y => $cy,
        players => \@players,
        portals => \@portals,
        monsters=> \@monsters,
        ai_state=> $ai_state,
    };
}

sub get_inventory_data {
    my %out = ( count => 0, items => [] );

    my $inv_list;
    if ($char) {
        if ($char->can('inventory') && $char->inventory && $char->inventory->can('getItems')) {
            $inv_list = $char->inventory->getItems();
        } elsif ($char->{inventory} && ref $char->{inventory} && $char->{inventory}->can('getItems')) {
            $inv_list = $char->{inventory}->getItems();
        } elsif ($char->{inventory} && ref $char->{inventory} eq 'ARRAY') {
            $inv_list = $char->{inventory};
        }
    }

    return \%out unless $inv_list && ref $inv_list eq 'ARRAY';

    my @items;
    my $pos = 0;
    foreach my $it (@{$inv_list}) {
        next unless $it;
        my $idx = (defined $it->{index}) ? $it->{index}
                 : (defined $it->{binID}) ? $it->{binID}
                 : (defined $it->{invIndex}) ? $it->{invIndex}
                 : undef;
        if (!defined $idx && ref($it) && $it->can('index')) {
            $idx = eval { $it->index() };
        }

        push @items, {
            index     => $idx,
            listIndex => $pos,
            nameID    => $it->{nameID} // 0,
            name      => $it->{name}   // '',
            amount    => $it->{amount} // 0,
            equipped  => $it->{equipped} ? JSON::true : JSON::false,
        };
        $pos++;
    }

    $out{count} = scalar @items;
    $out{items} = \@items;
    return \%out;
}


sub get_skills_data {
    my @skills;

    # Tenta estruturas comuns do OpenKore
    if ($char && $char->{skills}) {
        # Lista pode vir em hash por handle
        if (ref $char->{skills} eq 'HASH') {
            foreach my $k (keys %{$char->{skills}}) {
                my $s = $char->{skills}{$k};
                next unless ref $s eq 'HASH';
                push @skills, {
                    id     => $s->{ID}    || 0,
                    handle => $k,
                    name   => $s->{name}  || $k,
                    level  => $s->{lv}    || 0,
                    sp     => $s->{sp}    || 0,
                };
            }
        }
        # Ou array/lista
        if (ref $char->{skills} eq 'ARRAY') {
            foreach my $s (@{$char->{skills}}) {
                next unless ref $s eq 'HASH';
                my $handle = $s->{handle} || $s->{name} || ($s->{ID}//0);
                push @skills, {
                    id     => $s->{ID}    || 0,
                    handle => $handle,
                    name   => $s->{name}  || "$handle",
                    level  => $s->{lv}    || 0,
                    sp     => $s->{sp}    || 0,
                };
            }
        }
    }

    return { skills => \@skills };
}

sub get_session_stats {
    my $uptime = time() - ($session_stats{start_time} || time());

    my $exp_now  = ($char && defined $char->{exp})  ? $char->{exp}  : $session_stats{exp_start};
    my $zeny_now = ($char && defined $char->{zeny}) ? $char->{zeny} : $session_stats{zeny_start};

    my $exp_gain  = ($exp_now  || 0) - ($session_stats{exp_start}  || 0);
    my $zeny_gain = ($zeny_now || 0) - ($session_stats{zeny_start} || 0);

    my $hours = $uptime > 0 ? ($uptime / 3600.0) : 0;
    my $exp_h  = $hours > 0 ? int($exp_gain  / $hours) : 0;
    my $zeny_h = $hours > 0 ? int($zeny_gain / $hours) : 0;

    return {
        uptime        => int($uptime),
        exp_per_hour  => $exp_h,
        zeny_per_hour => $zeny_h,
        kills         => $session_stats{kills},
        deaths        => $session_stats{deaths},
    };
}

sub get_monsters_list {
    my @monsters;

    if ($monstersList) {
        foreach my $monster (@{$monstersList->getItems()}) {
            next unless $monster;
            my $dist = 0;
            if ($char && $char->{pos_to} && $monster->{pos_to}) {
                $dist = int(Utils::distance($char->{pos_to}, $monster->{pos_to}) || 0);
            }

            push @monsters, {
                name     => eval { $monster->name() } || '',
                nameID   => $monster->{nameID} || 0,
                level    => $monster->{lv}     || 0,
                hp       => $monster->{hp}     || 0,
                hp_max   => $monster->{hp_max} || 0,
                distance => $dist,
            };
        }
    }

    return { monsters => \@monsters };
}

sub get_target_info {
    my %target_data;

    if ($char && $char->{target} && $monstersList) {
        my $target = $monstersList->getByID($char->{target});
        if ($target) {
            my $dist = 0;
            if ($char->{pos_to} && $target->{pos_to}) {
                $dist = int(Utils::distance($char->{pos_to}, $target->{pos_to}) || 0);
            }

            %target_data = (
                name     => eval { $target->name() } || '',
                nameID   => $target->{nameID} || 0,
                level    => $target->{lv}     || 0,
                hp       => $target->{hp}     || 0,
                hp_max   => $target->{hp_max} || 0,
                distance => $dist,
            );
        }
    }

    return \%target_data;
}

# ============================ HTML UI ===============================
sub get_dashboard_html {
    return q{<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OpenKore Dashboard Pro (Beta 0.1) 27/10/25</title>
<style>
* { margin:0; padding:0; box-sizing:border-box; }
body { font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif; background:#0a0e27; color:#fff; overflow:hidden; }
.dashboard { display:grid; grid-template-columns:300px 1fr 400px; grid-template-rows:60px 1fr; height:100vh; gap:10px; padding:10px; }
.header { grid-column:1/-1; background:linear-gradient(135deg,#667eea 0%,#764ba2 100%); padding:10px 20px; border-radius:10px; display:flex; justify-content:space-between; align-items:center; box-shadow:0 4px 15px rgba(0,0,0,0.3); }
.header h1 { font-size:1.5em; display:flex; align-items:center; gap:10px; }
.status-dot { width:12px; height:12px; border-radius:50%; background:#44ff44; animation:pulse 2s infinite; }
@keyframes pulse { 0%,100%{opacity:1; box-shadow:0 0 10px #44ff44;} 50%{opacity:.5; box-shadow:0 0 20px #44ff44;} }
.ai-controls { display:flex; gap:10px; }
.ai-btn { padding:8px 15px; border:none; border-radius:5px; cursor:pointer; font-weight:bold; transition:all .2s; font-size:.9em; }
.ai-btn.off{background:#ff4444;color:#fff;} .ai-btn.on{background:#44ff44;color:#000;} .ai-btn.auto{background:#ffaa00;color:#000;}
.ai-btn:hover{transform:translateY(-2px); box-shadow:0 4px 10px rgba(0,0,0,0.3);}
.sidebar-left,.sidebar-right,.main-content{ display:flex; flex-direction:column; gap:10px; overflow-y:auto; }
.card { background:rgba(255,255,255,0.05); backdrop-filter:blur(10px); border-radius:10px; padding:15px; border:1px solid rgba(255,255,255,0.1); box-shadow:0 4px 15px rgba(0,0,0,0.2); position:relative; }
.card.minimized .card-content{ display:none; }
.card-title { font-size:1.1em; font-weight:bold; margin-bottom:10px; padding-bottom:10px; border-bottom:2px solid rgba(255,255,255,0.2); display:flex; justify-content:space-between; align-items:center; cursor:pointer; user-select:none; }
.card-title:hover{ background:rgba(255,255,255,0.05); margin:-5px -5px 10px -5px; padding:5px 5px 15px 5px; border-radius:5px; }
.minimize-btn{ background:rgba(255,255,255,0.1); border:none; color:#fff; width:24px; height:24px; border-radius:4px; cursor:pointer; display:flex; align-items:center; justify-content:center; font-size:1.2em; line-height:1; }
.minimize-btn:hover{ background:rgba(255,255,255,0.2); }
.stat-row{ display:flex; justify-content:space-between; padding:8px; margin:5px 0; background:rgba(0,0,0,0.2); border-radius:5px; font-size:.9em; }
.stat-label{color:#a8daff;font-weight:500;} .stat-value{color:#ffd700;font-weight:bold;}
.progress-bar{ width:100%; height:20px; background:rgba(0,0,0,0.3); border-radius:10px; overflow:hidden; margin:8px 0; }
.progress-fill{ height:100%; transition:width .3s; display:flex; align-items:center; justify-content:center; font-size:.85em; font-weight:bold; }
.progress-fill.hp{background:linear-gradient(90deg,#ff4444,#ff6b6b);} .progress-fill.sp{background:linear-gradient(90deg,#4444ff,#6b6bff);} .progress-fill.exp{background:linear-gradient(90deg,#44ff44,#6bff6b);} .progress-fill.weight{background:linear-gradient(90deg,#ffaa00,#ffcc00);}
#mapContainer{ position:relative; width:100%; height:450px; background:#000; border-radius:10px; overflow:hidden; border:2px solid rgba(255,255,255,0.2); display:flex; align-items:center; justify-content:center; }
#mapCanvas{ position:absolute; cursor:crosshair; }
.map-info{ position:absolute; top:10px; left:10px; background:rgba(0,0,0,0.8); padding:8px 12px; border-radius:5px; font-size:.85em; z-index:10; }
.stats-grid{ display:grid; grid-template-columns:repeat(3,1fr); gap:10px; }
.stat-box{ background:rgba(0,0,0,0.3); padding:12px; border-radius:8px; text-align:center; }
.stat-box-value{ font-size:1.6em; font-weight:bold; color:#ffd700; }
.stat-box-label{ font-size:.85em; color:#ccc; margin-top:5px; }
.stat-upgrade-btn{ background:rgba(68,255,68,0.2); border:1px solid #44ff44; color:#44ff44; padding:3px 8px; border-radius:3px; cursor:pointer; font-size:.75em; margin-top:5px; display:none; }
.stat-upgrade-btn.show{ display:inline-block; }
.stat-upgrade-btn:hover{ background:rgba(68,255,68,0.3); }
.inventory-grid{ display:grid; grid-template-columns:repeat(auto-fill,minmax(70px,1fr)); gap:8px; max-height:350px; overflow-y:auto; }
.item{ background:rgba(0,0,0,0.3); padding:6px; border-radius:8px; border:1px solid rgba(255,255,255,0.1); text-align:center; cursor:pointer; transition:all .2s; position:relative; }
.item:hover{ transform:translateY(-2px); border-color:#ffd700; box-shadow:0 4px 10px rgba(255,215,0,0.3);}
.item.equipped{ border-color:#ffd700; background:rgba(255,215,0,0.1); }
.item-icon{ width:40px; height:40px; margin:0 auto 5px; background:rgba(0,0,0,0.5); border-radius:5px; display:flex; align-items:center; justify-content:center; }
.item-name{ font-size:.7em; color:#ffd700; margin-bottom:2px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.item-amount{ font-size:.65em; color:#ccc; }
.context-menu{ position:fixed; background:rgba(20,20,40,0.95); border:1px solid rgba(255,255,255,0.2); border-radius:8px; padding:5px; z-index:10000; box-shadow:0 4px 20px rgba(0,0,0,0.5); backdrop-filter:blur(10px); }
.context-menu-item{ padding:8px 15px; cursor:pointer; border-radius:4px; font-size:.9em; white-space:nowrap; }
.context-menu-item:hover{ background:rgba(255,255,255,0.1); }
.context-menu-item.danger{ color:#ff6b6b; }
.skills-list{ display:flex; flex-direction:column; gap:8px; max-height:400px; overflow-y:auto; }
.skill-item{ background:rgba(0,0,0,0.3); padding:10px; border-radius:8px; border:1px solid rgba(255,255,255,0.1); display:flex; align-items:center; gap:10px; }
.skill-icon{ width:32px; height:32px; background:rgba(0,0,0,0.5); border-radius:5px; display:flex; align-items:center; justify-content:center; flex-shrink:0; }
.skill-info{ flex:1; } .skill-name{ font-weight:bold; color:#ffd700; font-size:.9em; margin-bottom:3px; }
.skill-details{ font-size:.75em; color:#ccc; }
.skill-btns{ display:flex; gap:5px; }
.skill-btn{ padding:4px 8px; border:1px solid rgba(255,255,255,0.3); border-radius:4px; cursor:pointer; font-size:.75em; background:rgba(0,0,0,0.3); color:#fff; transition:all .2s; }
.skill-btn:hover{ background:rgba(255,255,255,0.1); }
.monsters-list{ display:flex; flex-direction:column; gap:8px; max-height:450px; overflow-y:auto; }
.monster-item{ background:rgba(0,0,0,0.3); padding:8px; border-radius:8px; border:1px solid rgba(255,255,255,0.1); display:flex; align-items:center; gap:10px; cursor:pointer; transition:all .2s; }
.monster-item:hover{ background:rgba(255,68,68,0.2); border-color:#ff4444; }
.monster-icon{ width:40px; height:40px; background:rgba(0,0,0,0.5); border-radius:5px; display:flex; align-items:center; justify-content:center; flex-shrink:0; }
.monster-name{ font-weight:bold; color:#ff6b6b; font-size:.85em; margin-bottom:2px; }
.monster-hp{ font-size:.75em; color:#ccc; } .monster-distance{ font-size:.75em; color:#ffaa00; }
.console-container,.chat-container{ background:rgba(0,0,0,0.4); padding:10px; border-radius:8px; max-height:350px; overflow-y:auto; font-family:'Courier New',monospace; font-size:.8em; }
.log-entry,.chat-entry{ margin:3px 0; padding:4px; border-left:3px solid #4444ff; padding-left:8px; word-wrap:break-word; }
.log-entry.error{ border-left-color:#ff4444; color:#ff6b6b; } .log-entry.warning{ border-left-color:#ffaa00; color:#ffcc66; }
.chat-entry.public{ border-left-color:#44ff44; } .chat-entry.private{ border-left-color:#ff44ff; } .chat-entry.system{ border-left-color:#ffaa00; }
.chat-input-group{ display:flex; gap:8px; margin-top:10px; } .chat-input{ flex:1; background:rgba(0,0,0,0.3); border:1px solid rgba(255,255,255,0.2); color:#fff; padding:8px; border-radius:5px; font-size:.85em; }
.send-btn{ background:rgba(68,255,68,0.2); border:1px solid #44ff44; color:#fff; padding:8px 15px; border-radius:5px; cursor:pointer; font-size:.85em; }
.send-btn:hover{ background:rgba(68,255,68,0.3); }
.session-stats{ display:grid; grid-template-columns:repeat(2,1fr); gap:10px; }
.session-stat{ background:rgba(0,0,0,0.3); padding:12px; border-radius:8px; text-align:center; }
.session-stat-value{ font-size:1.3em; font-weight:bold; color:#44ff44; } .session-stat-label{ font-size:.75em; color:#ccc; margin-top:3px; }
.target-display{ background:rgba(255,68,68,0.2); border:2px solid #ff4444; padding:12px; border-radius:8px; display:flex; align-items:center; gap:12px; }
.target-icon{ width:48px; height:48px; background:rgba(0,0,0,0.5); border-radius:8px; display:flex; align-items:center; justify-content:center; flex-shrink:0; }
.target-name{ font-size:1.1em; font-weight:bold; color:#ff6b6b; margin-bottom:5px; }
::-webkit-scrollbar{ width:6px; } ::-webkit-scrollbar-track{ background:rgba(0,0,0,0.2); border-radius:3px; } ::-webkit-scrollbar-thumb{ background:rgba(255,255,255,0.3); border-radius:3px; } ::-webkit-scrollbar-thumb:hover{ background:rgba(255,255,255,0.5); }
.command-panel{ display:grid; grid-template-columns:repeat(4,1fr); gap:8px; }
.cmd-btn{ background:rgba(255,255,255,0.1); border:1px solid rgba(255,255,255,0.2); color:#fff; padding:8px; border-radius:5px; cursor:pointer; font-size:.8em; transition:all .2s; }
.cmd-btn:hover{ background:rgba(255,255,255,0.2); transform:translateY(-2px); }
</style>
</head>
<body>
<div class="dashboard">
  <div class="header">
    <h1><span class="status-dot" id="statusDot"></span>OpenKore Dashboard Pro (Beta 0.1) 27/10/25</h1>
    <div class="ai-controls">
      <button class="ai-btn off"  onclick="setAI('off')">AI OFF</button>
      <button class="ai-btn on"   onclick="setAI('on')">AI ON</button>
      <button class="ai-btn auto" onclick="setAI('auto')">AI AUTO</button>
    </div>
  </div>

  <div class="sidebar-left">
    <div class="card" id="cardChar">
      <div class="card-title" onclick="toggleCard('cardChar')">📊 Personagem
        <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardChar')">−</button>
      </div>
      <div class="card-content">
        <div class="stat-row"><span class="stat-label">Nome:</span><span class="stat-value" id="charName">-</span></div>
        <div class="stat-row"><span class="stat-label">Level / Job:</span><span class="stat-value" id="charLevel">-</span></div>
        <div class="stat-row"><span class="stat-label">Zeny:</span><span class="stat-value" id="charZeny">-</span></div>
        <div style="margin-top:10px;">
          <div class="stat-label">HP</div><div class="progress-bar"><div class="progress-fill hp" id="hpBar">0%</div></div>
          <div class="stat-label">SP</div><div class="progress-bar"><div class="progress-fill sp" id="spBar">0%</div></div>
          <div class="stat-label">EXP Base</div><div class="progress-bar"><div class="progress-fill exp" id="expBar">0%</div></div>
          <div class="stat-label">EXP Job</div><div class="progress-bar"><div class="progress-fill exp" id="expJobBar">0%</div></div>
          <div class="stat-label">Peso</div><div class="progress-bar"><div class="progress-fill weight" id="weightBar">0%</div></div>
        </div>
      </div>
    </div>

    <div class="card" id="cardStats">
      <div class="card-title" onclick="toggleCard('cardStats')">💪 Atributos
        <span style="font-size:.85em;color:#44ff44;">Pts: <span id="statPoints">0</span></span>
        <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardStats')">−</button>
      </div>
      <div class="card-content">
        <div class="stats-grid">
          <div class="stat-box"><div class="stat-box-value" id="statStr">0</div><div class="stat-box-label">STR</div><button class="stat-upgrade-btn" id="btnStr" onclick="upgradeStat('str')">+</button></div>
          <div class="stat-box"><div class="stat-box-value" id="statAgi">0</div><div class="stat-box-label">AGI</div><button class="stat-upgrade-btn" id="btnAgi" onclick="upgradeStat('agi')">+</button></div>
          <div class="stat-box"><div class="stat-box-value" id="statVit">0</div><div class="stat-box-label">VIT</div><button class="stat-upgrade-btn" id="btnVit" onclick="upgradeStat('vit')">+</button></div>
          <div class="stat-box"><div class="stat-box-value" id="statInt">0</div><div class="stat-box-label">INT</div><button class="stat-upgrade-btn" id="btnInt" onclick="upgradeStat('int')">+</button></div>
          <div class="stat-box"><div class="stat-box-value" id="statDex">0</div><div class="stat-box-label">DEX</div><button class="stat-upgrade-btn" id="btnDex" onclick="upgradeStat('dex')">+</button></div>
          <div class="stat-box"><div class="stat-box-value" id="statLuk">0</div><div class="stat-box-label">LUK</div><button class="stat-upgrade-btn" id="btnLuk" onclick="upgradeStat('luk')">+</button></div>
        </div>
      </div>
    </div>

    <div class="card" id="cardSession">
      <div class="card-title" onclick="toggleCard('cardSession')">📈 Estatísticas
        <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardSession')">−</button>
      </div>
      <div class="card-content">
        <div class="session-stats">
          <div class="session-stat"><div class="session-stat-value" id="sessionUptime">0:00:00</div><div class="session-stat-label">Tempo Online</div></div>
          <div class="session-stat"><div class="session-stat-value" id="sessionExpHour">0</div><div class="session-stat-label">EXP/hora</div></div>
          <div class="session-stat"><div class="session-stat-value" id="sessionZenyHour">0</div><div class="session-stat-label">Zeny/hora</div></div>
          <div class="session-stat"><div class="session-stat-value" id="sessionKills">0</div><div class="session-stat-label">Kills</div></div>
        </div>
      </div>
    </div>
  </div>

  <div class="main-content">
    <div class="card" id="targetCard" style="display:none;">
      <div class="target-display">
        <div class="target-icon"><img id="targetIcon" src="" alt="Target"></div>
        <div class="target-info">
          <div class="target-name" id="targetName">-</div>
          <div class="stat-label">HP</div>
          <div class="progress-bar" style="margin:5px 0;"><div class="progress-fill hp" id="targetHpBar">0%</div></div>
          <div style="display:flex;justify-content:space-between;font-size:.85em;color:#ccc;">
            <span>Lv: <span id="targetLevel">-</span></span>
            <span>Dist: <span id="targetDistance">-</span>m</span>
          </div>
        </div>
      </div>
    </div>

    <div class="card" id="cardCommands">
      <div class="card-title" onclick="toggleCard('cardCommands')">⚡ Comandos
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
      <div class="card-title" onclick="toggleCard('cardInv')">🎒 Inventário (<span id="invCount">0</span>)
        <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardInv')">−</button>
      </div>
      <div class="card-content"><div class="inventory-grid" id="inventoryGrid"></div></div>
    </div>

    <div class="card" id="cardChat">
      <div class="card-title" onclick="toggleCard('cardChat')">💬 Chat
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
      <div class="card-title" onclick="toggleCard('cardMap')">🗺️ Mapa - <span id="mapName">-</span>
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
        <div class="stat-row"><span class="stat-label">Players:</span><span class="stat-value" id="playersCount">0</span></div>
        <div class="stat-row"><span class="stat-label">Monstros:</span><span class="stat-value" id="monstersCount">0</span></div>
        <div class="stat-row"><span class="stat-label">Portais:</span><span class="stat-value" id="portalsCount">0</span></div>
      </div>
    </div>

    <div class="card" id="cardMonsters">
      <div class="card-title" onclick="toggleCard('cardMonsters')">👹 Monstros Próximos
        <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardMonsters')">−</button>
      </div>
      <div class="card-content"><div class="monsters-list" id="monstersList"></div></div>
    </div>

    <div class="card" id="cardSkills">
      <div class="card-title" onclick="toggleCard('cardSkills')">✨ Skills
        <span style="font-size:.85em;color:#44ff44;">Pts: <span id="skillPoints">0</span></span>
        <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardSkills')">−</button>
      </div>
      <div class="card-content"><div class="skills-list" id="skillsList"></div></div>
    </div>

    <div class="card" id="cardConsole">
      <div class="card-title" onclick="toggleCard('cardConsole')">💻 Console
        <button class="minimize-btn" onclick="event.stopPropagation(); toggleCard('cardConsole')">−</button>
      </div>
      <div class="card-content"><div class="console-container" id="consoleContainer"></div></div>
    </div>
  </div>
</div>

<script>
let mapData=null, contextMenu=null;
const canvas=document.getElementById('mapCanvas');
const ctx=canvas.getContext('2d');
const mapImg=new Image();
let mapImageLoaded=false;

setInterval(updateDashboard, 1000);
updateDashboard();

function toggleCard(id){const c=document.getElementById(id); c.classList.toggle('minimized'); const b=c.querySelector('.minimize-btn'); b.textContent=c.classList.contains('minimized')?'+':'−';}
document.addEventListener('click', ()=>{ if(contextMenu){contextMenu.remove(); contextMenu=null;} });

function showContextMenu(e,item){
  e.preventDefault();
  if(contextMenu) contextMenu.remove();
  contextMenu=document.createElement('div');
  contextMenu.className='context-menu';
  contextMenu.style.left=e.pageX+'px';
  contextMenu.style.top=e.pageY+'px';
  const actions=[
    {label:'🎮 Usar', action:()=>apiPost('/api/item/use',{index:item.index})},
    {label: item.equipped?'⚔️ Desequipar':'⚔️ Equipar', action:()=>apiPost(item.equipped?'/api/item/unequip':'/api/item/equip',{index:item.index})},
{
  label: '🗑️ Dropar',
  action: () => {
    const max = Number(item.amount) || 0;
    if (!max) return;
    const val = prompt(`Quantidade para dropar (1–${max}):`, 1);
    if (val === null) return;
    let qty = parseInt(val, 10);
    if (isNaN(qty) || qty < 1) qty = 1;
    if (qty > max) qty = max;
    apiPost('/api/item/drop', { listIndex: item.listIndex, amount: qty });
  },
  danger: true
},


  ];
  actions.forEach(a=>{const d=document.createElement('div'); d.className='context-menu-item'+(a.danger?' danger':''); d.textContent=a.label; d.onclick=(ev)=>{ev.stopPropagation(); a.action(); contextMenu.remove(); contextMenu=null;}; contextMenu.appendChild(d);});
  document.body.appendChild(contextMenu);
}

async function updateDashboard(){
  try{
    const [data,stats,monsters,target]=await Promise.all([
      fetch('/api/all').then(r=>r.json()),
      fetch('/api/stats').then(r=>r.json()),
      fetch('/api/monsters').then(r=>r.json()),
      fetch('/api/target').then(r=>r.json())
    ]);
    updateCharacter(data.character);
    updateMap(data.map);
    updateInventory(data.inventory);
    updateSkills(data.skills);
    updateSessionStats(stats);
    updateMonstersList(monsters.monsters);
    updateTarget(target);
    updateConsole();
    updateChat();
    document.getElementById('statusDot').style.background='#44ff44';
  }catch(e){
    console.error('Erro:', e);
    document.getElementById('statusDot').style.background='#ff4444';
  }
}

function updateCharacter(char){
  if(!char) return;
  document.getElementById('charName').textContent=char.name||'-';
  document.getElementById('charLevel').textContent=`${char.level} / ${char.job} (${char.job_level})`;
  document.getElementById('charZeny').textContent=(char.zeny||0).toLocaleString('pt-BR');
  const statPoints=char.points_free||0, skillPoints=char.points_skill||0;
  document.getElementById('statPoints').textContent=statPoints;
  document.getElementById('skillPoints').textContent=skillPoints;
  ['btnStr','btnAgi','btnVit','btnInt','btnDex','btnLuk'].forEach(id=>{
    const b=document.getElementById(id);
    if(!b) return;
    if(statPoints>0) b.classList.add('show'); else b.classList.remove('show');
  });
  updateProgressBar('hpBar', char.hp_percent, `${char.hp}/${char.hp_max}`);
  updateProgressBar('spBar', char.sp_percent, `${char.sp}/${char.sp_max}`);
  updateProgressBar('expBar', char.exp_percent, `${char.exp_percent}%`);
  updateProgressBar('expJobBar', char.exp_job_percent, `${char.exp_job_percent}%`);
  updateProgressBar('weightBar', char.weight_percent, `${char.weight}/${char.weight_max}`);
  if(char.stats){
    document.getElementById('statStr').textContent=char.stats.str||0;
    document.getElementById('statAgi').textContent=char.stats.agi||0;
    document.getElementById('statVit').textContent=char.stats.vit||0;
    document.getElementById('statInt').textContent=char.stats.int||0;
    document.getElementById('statDex').textContent=char.stats.dex||0;
    document.getElementById('statLuk').textContent=char.stats.luk||0;
  }
}

function updateProgressBar(id,pct,text){
  const b=document.getElementById(id); if(!b) return;
  const p=Math.max(0,Math.min(100, Math.floor(pct||0)));
  b.style.width=p+'%'; b.textContent=text;
}

function updateMap(map){
  if(!map) return;
  mapData=map;
  document.getElementById('mapName').textContent=map.name||'-';
  document.getElementById('mapPos').textContent=`${map.char_x}, ${map.char_y}`;
  document.getElementById('aiState').textContent=map.ai_state||'-';
  document.getElementById('playersCount').textContent=(map.players||[]).length;
  document.getElementById('monstersCount').textContent=(map.monsters||[]).length;
  document.getElementById('portalsCount').textContent=(map.portals||[]).length;

  if(map.name && (!mapImg.src || !mapImg.src.includes(map.name))){
    mapImageLoaded=false;
    mapImg.src=`https://www.divine-pride.net/img/map/original/${map.name}`;
    mapImg.onload=()=>{ mapImageLoaded=true; drawMap(); };
    mapImg.onerror=()=>{ mapImageLoaded=false; drawMap(); };
  }else if(mapImageLoaded){ drawMap(); }
}

function drawMap(){
  if(!mapData) return;
  const container=document.getElementById('mapContainer');
  const cw=container.offsetWidth-4, ch=container.offsetHeight-4;

  if(mapImageLoaded && mapImg.complete && mapImg.naturalWidth>0){
    canvas.width=mapImg.naturalWidth; canvas.height=mapImg.naturalHeight;
    const scale=Math.min(cw/canvas.width, ch/canvas.height);
    canvas.style.width=(canvas.width*scale)+'px';
    canvas.style.height=(canvas.height*scale)+'px';
    ctx.drawImage(mapImg,0,0);
  }else{
    const w=mapData.width||100, h=mapData.height||100;
    canvas.width=w; canvas.height=h;
    const scale=Math.min(cw/w, ch/h);
    canvas.style.width=(w*scale)+'px';
    canvas.style.height=(h*scale)+'px';
    ctx.fillStyle='#1a1a2e'; ctx.fillRect(0,0,canvas.width,canvas.height);
    ctx.strokeStyle='rgba(255,255,255,0.1)'; ctx.lineWidth=1;
    for(let i=0;i<=10;i++){
      const x=(canvas.width/10)*i, y=(canvas.height/10)*i;
      ctx.beginPath(); ctx.moveTo(x,0); ctx.lineTo(x,canvas.height); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(0,y); ctx.lineTo(canvas.width,y); ctx.stroke();
    }
  }

  const scaleX=canvas.width/(mapData.width||1);
  const scaleY=canvas.height/(mapData.height||1);

  if(mapData.portals){
    ctx.fillStyle='#aa00ff'; ctx.strokeStyle='#ff00ff'; ctx.lineWidth=2;
    mapData.portals.forEach(p=>{ const x=p.x*scaleX, y=(mapData.height-p.y)*scaleY; ctx.beginPath(); ctx.arc(x,y,8,0,Math.PI*2); ctx.fill(); ctx.stroke(); });
  }
  if(mapData.monsters){
    mapData.monsters.forEach(m=>{
      const x=m.x*scaleX, y=(mapData.height-m.y)*scaleY;
      ctx.fillStyle='#ff4444'; ctx.beginPath(); ctx.arc(x,y,6,0,Math.PI*2); ctx.fill();
      if(m.hp_max>0){
        const hp=m.hp/m.hp_max, bw=20, bh=3;
        ctx.fillStyle='rgba(0,0,0,0.5)'; ctx.fillRect(x-bw/2, y-12, bw, bh);
        ctx.fillStyle='#44ff44'; ctx.fillRect(x-bw/2, y-12, bw*hp, bh);
      }
    });
  }
  if(mapData.players){
    ctx.fillStyle='#4444ff';
    mapData.players.forEach(p=>{ const x=p.x*scaleX, y=(mapData.height-p.y)*scaleY; ctx.beginPath(); ctx.arc(x,y,5,0,Math.PI*2); ctx.fill(); });
  }
  const cx=mapData.char_x*scaleX, cy=(mapData.height-mapData.char_y)*scaleY;
  ctx.fillStyle='rgba(68,255,68,0.3)'; ctx.beginPath(); ctx.arc(cx,cy,14,0,Math.PI*2); ctx.fill();
  ctx.fillStyle='#44ff44'; ctx.beginPath(); ctx.arc(cx,cy,9,0,Math.PI*2); ctx.fill();
  ctx.strokeStyle='#fff'; ctx.lineWidth=2; ctx.stroke();
}

canvas.addEventListener('click', (e)=>{
  if(!mapData) return;
  const rect=canvas.getBoundingClientRect();
  const scaleX=mapData.width/canvas.width, scaleY=mapData.height/canvas.height;
  const x=Math.floor(((e.clientX-rect.left)/rect.width)*canvas.width*scaleX);
  const y=mapData.height - Math.floor(((e.clientY-rect.top)/rect.height)*canvas.height*scaleY);
  apiPost('/api/move',{x,y});
});

function updateInventory(inv){
  if(!inv) return;
  const grid=document.getElementById('inventoryGrid');
  document.getElementById('invCount').textContent=inv.count||0;
  grid.innerHTML='';
  if(inv.items && inv.items.length>0){
    inv.items.forEach(item=>{
      const div=document.createElement('div');
      div.className='item'+(item.equipped?' equipped':'');
      div.onclick=()=>apiPost('/api/item/use',{index:item.index});
      div.oncontextmenu=(e)=>showContextMenu(e,item);
      div.innerHTML=`
        <div class="item-icon"><img src="https://static.divine-pride.net/images/items/item/${item.nameID}.png" onerror="this.style.display='none'"></div>
        <div class="item-name" title="${item.name}">${item.name}</div>
        <div class="item-amount">x${item.amount}</div>
      `;
      grid.appendChild(div);
    });
  }
}

function updateSkills(sk){
  if(!sk) return;
  const list=document.getElementById('skillsList');
  const sp=parseInt(document.getElementById('skillPoints').textContent)||0;
  list.innerHTML='';
  if(sk.skills && sk.skills.length>0){
    sk.skills.forEach(s=>{
      const upBtn= sp>0 ? `<button class="skill-btn" onclick="upgradeSkill('${s.handle}')">+</button>` : '';
      const div=document.createElement('div');
      div.className='skill-item';
      div.innerHTML=`
        <div class="skill-icon"><img src="https://static.divine-pride.net/images/skill/${s.id}.png" onerror="this.src='https://static.divine-pride.net/images/skill/0.png'"></div>
        <div class="skill-info"><div class="skill-name">${s.name}</div><div class="skill-details">Lv. ${s.level} | SP: ${s.sp}</div></div>
        <div class="skill-btns"><button class="skill-btn" onclick="useSkill('${s.handle}')">Usar</button>${upBtn}</div>
      `;
      list.appendChild(div);
    });
  }
}

function updateMonstersList(monsters){
  const list=document.getElementById('monstersList'); list.innerHTML='';
  if(monsters && monsters.length>0){
    monsters.slice(0,15).forEach(m=>{
      const hp=m.hp_max>0?Math.round(m.hp/m.hp_max*100):0;
      const div=document.createElement('div');
      div.className='monster-item';
      div.innerHTML=`
        <div class="monster-icon"><img src="https://static.divine-pride.net/images/mobs/png/${m.nameID}.png" onerror="this.style.display='none'"></div>
        <div class="monster-info">
          <div class="monster-name">${m.name}</div>
          <div class="monster-hp">HP: ${hp}%</div>
          <div class="monster-distance">${m.distance||0}m</div>
        </div>
      `;
      list.appendChild(div);
    });
  }
}

function updateTarget(t){
  const card=document.getElementById('targetCard');
  if(t && t.name){
    card.style.display='block';
    document.getElementById('targetName').textContent=t.name;
    document.getElementById('targetLevel').textContent=t.level||'-';
    document.getElementById('targetDistance').textContent=t.distance||'-';
    if(t.nameID){ document.getElementById('targetIcon').src=`https://static.divine-pride.net/images/mobs/png/${t.nameID}.png`; }
    const hp=t.hp_max>0?Math.round(t.hp/t.hp_max*100):0;
    updateProgressBar('targetHpBar', hp, `${t.hp}/${t.hp_max}`);
  }else{
    card.style.display='none';
  }
}

function updateSessionStats(s){
  if(!s) return;
  const h=Math.floor(s.uptime/3600), m=Math.floor((s.uptime%3600)/60), sec=s.uptime%60;
  document.getElementById('sessionUptime').textContent=`${h}:${String(m).padStart(2,'0')}:${String(sec).padStart(2,'0')}`;
  document.getElementById('sessionExpHour').textContent=(s.exp_per_hour||0).toLocaleString('pt-BR');
  document.getElementById('sessionZenyHour').textContent=(s.zeny_per_hour||0).toLocaleString('pt-BR');
  document.getElementById('sessionKills').textContent=s.kills||0;
}

async function updateConsole(){
  try{
    const data=await fetch('/api/console').then(r=>r.json());
    const c=document.getElementById('consoleContainer');
    if(data.logs && data.logs.length>0){
      const stick=(c.scrollHeight-c.scrollTop)===c.clientHeight;
      c.innerHTML=data.logs.slice(-50).map(l=>{
        const t=new Date(l.time*1000).toLocaleTimeString('pt-BR');
        const cls=l.level==='error'?'error':(l.level==='warning'?'warning':'');
        return `<div class="log-entry ${cls}">[${t}] ${l.message}</div>`;
      }).join('');
      if(stick) c.scrollTop=c.scrollHeight;
    }
  }catch(e){}
}

async function updateChat(){
  try{
    const data=await fetch('/api/chat').then(r=>r.json());
    const c=document.getElementById('chatContainer');
    if(data.messages && data.messages.length>0){
      c.innerHTML=data.messages.slice(-20).map(m=>{
        const t=new Date(m.time*1000).toLocaleTimeString('pt-BR');
        return `<div class="chat-entry ${m.type}">[${t}] <strong>${m.name}:</strong> ${m.message}</div>`;
      }).join('');
      c.scrollTop=c.scrollHeight;
    }
  }catch(e){}
}

async function sendCommand(cmd){ await apiPost('/api/command',{command:cmd}); }
function sendCustomCommand(){ const i=document.getElementById('customCommand'); if(i.value.trim()){ sendCommand(i.value.trim()); i.value=''; } }
async function sendChat(){ const i=document.getElementById('chatInput'); if(i.value.trim()){ await apiPost('/api/chat/send',{message:i.value.trim()}); i.value=''; } }
async function setAI(mode){ await apiPost('/api/ai',{mode}); }
async function upgradeStat(s){ await apiPost('/api/stat/upgrade',{stat:s}); }
async function useSkill(h){ await apiPost('/api/skill/use',{skill:h}); }
async function upgradeSkill(h){ await apiPost('/api/skill/upgrade',{skill:h}); }

async function apiPost(url, data){
  try{
    const r=await fetch(url,{method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(data)});
    return await r.json();
  }catch(e){ console.error('API Error:',e); }
}
</script>
</body>
</html>};
}

# ============================ EOF ================================
1;
