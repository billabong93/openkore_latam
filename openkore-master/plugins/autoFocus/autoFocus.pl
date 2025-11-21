# plugins/autoFocus.pl
package autoFocus;
use strict;
use warnings;
use Plugins;
use Globals qw(%config $net);
use Log qw(message warning debug);
use Time::HiRes qw(time);
use File::Basename qw(dirname);
use File::Spec;
use Commands;
use utf8;

my $PLUGIN_DIR = dirname(__FILE__);

# Estados
my $boot_time        = time;
my $last_ahk_call    = 0;
my $relog_pending    = 0;
my $relog_start_time = 0;
my $relog_port;
my $stop_flag_time   = 0;

# Gatilho "Aguardando conexão..."
my $listen_ping_ts   = 0;
my $listen_regex     = qr/Aguardando conex(?:[ãa]o) do cliente Ragnarok em/i;
my $last_console_msg = '';   # última linha do console
my $listen_repeat_active = 0;    # repetição após o primeiro disparo
my $listen_repeat_next   = 0;    # próximo timestamp para repetir

# Gatilho "Proxeando conexão..." (para detectar spam)
my $prox_regex      = qr/Proxeando conex(?:[ãa]o)? para \[Latam - ROla: Freya\/Nidhogg\/Yggdrasil\]/i;
my $prox_count      = 0;     # contador de mensagens Proxeando...
my $prox_last_time  = 0;     # último timestamp dessa mensagem

# Sequência especial: disconnect -> (2s) -> relog
my $spam_phase      = 0;     # 0 = inativo; 1 = esperando 2s p/ relog
my $spam_t0         = 0;     # timestamp do início da fase atual

Plugins::register(
    'autoFocus',
    'Aciona AHK (xkore3) só quando estiver aguardando conexão ou pós-relog',
    \&on_unload, \&on_reload
);

# Mensagem de boot
Plugins::addHook('start3', sub {
    my $port       = _resolve_port();
    my $ahk_script = _ahk_script();
    my $ahk_bin    = $config{autoLogin_ahk_bin} // '(associação do .ahk)';
    message "[autoFocus] Plugin carregado. Porta=$port | AHK='$ahk_script' | BIN='$ahk_bin'\n", 'system';
});

# Hooks de DC -> relog -> pós-delay chama AHK (fluxo normal)
Plugins::addHook('disconnected_from_loginserver', \&on_dc);
Plugins::addHook('disconnected_from_charserver',  \&on_dc);
Plugins::addHook('disconnected_from_mapserver',   \&on_dc);

# Ticks
Plugins::addHook('AI_pre',       \&tick);
Plugins::addHook('mainLoop_pre', \&tick);
Plugins::addHook('in_game',      \&on_in_game);
Plugins::addHook('map_loaded',   \&on_in_game);   # modo XKore

sub on_unload {}
sub on_reload {}

# Escutar Log (sem quebrar logger original)
{
    no warnings 'redefine';
    my $orig_message = \&Log::message;
    *Log::message = sub {
        my ($msg, @rest) = @_;

        $last_console_msg = $msg if defined $msg;  # guarda última linha

        eval {
            # Gatilho "Aguardando conexão..."
            if (defined $msg && $msg =~ $listen_regex) {
                $listen_ping_ts = time;
            }

            # Gatilho "Proxeando conexão..." para detectar spam
            if (defined $msg && $msg =~ $prox_regex) {
                my $now = time;

                # Se passou muito tempo desde o último, zera o contador
                if ($prox_last_time && ($now - $prox_last_time) > 30) {
                    $prox_count = 0;
                }

                $prox_last_time = $now;
                $prox_count++;

                debug "[autoFocus] Proxeando conexão detectado ($prox_count vezes).\n", 'autoFocus';

                # Depois de 7 vezes: disconnect -> inicia sequência especial
                if ($prox_count >= 7 && !$spam_phase) {
                    debug "[autoFocus] Spam de 'Proxeando conexão...' (>=7). Executando 'disconnect' e iniciando sequência.\n", 'autoFocus';

                    eval { Commands::run('disconnect'); };
                    if ($@) {
                        warning "[autoFocus] Falha ao executar 'disconnect' (spam Proxeando): $@\n";
                    }

                    # Fase 1: esperar 2s para mandar 'relog'
                    $spam_phase = 1;
                    $spam_t0    = $now;

                    # Reseta contador de Proxeando
                    $prox_count     = 0;
                    $prox_last_time = 0;
                }
            }
        };

        $orig_message->($msg, @rest);
    };
}

sub on_dc {
    return unless _enabled();

    # Durante a sequência especial de spam, NÃO deixar o fluxo normal de DC mexer com relog
    if ($spam_phase) {
        debug "[autoFocus] on_dc durante sequência de spam; ignorando relog automático.\n", 'autoFocus';
        return;
    }

    my $delay = _num('autoLogin_relog_delay', 5);
    $relog_port = _resolve_port();

    return if $relog_pending;
    message "[autoFocus] DC detectado. 'relog' e aguardando ${delay}s [porta $relog_port]\n", 'system';

    eval { Commands::run('relog'); };
    if ($@) { warning "[autoFocus] Falha ao executar 'relog': $@\n"; }

    $relog_pending    = 1;
    $relog_start_time = time;
}

sub tick {
    return unless _enabled();

    my $state = ($net ? ($net->getState() // '') : '');
    my $now   = time;

    # === Sequência especial: disconnect -> (2s) -> relog (SEM chamar AHK aqui) ===
    if ($spam_phase) {
        # Fase 1: já demos 'disconnect', agora esperamos 2s para mandar 'relog'
        if ($spam_phase == 1) {
            if ( ($now - $spam_t0) >= 2 ) {
                debug "[autoFocus] 2s após 'disconnect' (spam Proxeando); executando 'relog'.\n", 'autoFocus';
                eval { Commands::run('relog'); };
                if ($@) {
                    warning "[autoFocus] Falha ao executar 'relog' (spam Proxeando): $@\n";
                }
                # Sequência especial termina aqui
                $spam_phase = 0;
                $spam_t0    = 0;
            }
        }
        # não há fase 2 mais
    }

    # Fora de jogo: se sobrou stop flag, limpe para permitir próxima automação
    if ($state ne 'IN_GAME' && -e _stop_flag_path(_resolve_port()) && !$stop_flag_time) {
        _clear_stop_flag(_resolve_port());
        message "[autoFocus] stop flag detectado fora de jogo; limpando para permitir automação.\n", 'system';
    }

    # Dentro do jogo => cria stop flag (uma única vez) e reseta ciclo
    if ($state eq 'IN_GAME') {
        if (!$stop_flag_time) {
            _emit_stop_flag(_resolve_port());
            _reset_cycle();
        }
        return;
    }

    # Pós-RELOG normal: aguarda X s e chama AHK uma vez
    if ($relog_pending) {
        my $delay = _num('autoLogin_relog_delay', 5);
        if (($now - $relog_start_time) >= $delay) {
            _call_ahk_once(($relog_port // _resolve_port()), "pos-relog");
        }
        return;
    }

    # Gatilho "Aguardando conexão..." => depois de 5s chama AHK uma vez
    if ($listen_ping_ts) {
        # espera 5 segundos desde que a mensagem apareceu
        if ( ($now - $listen_ping_ts) >= 5 ) {

            # Só dispara se a ÚLTIMA linha ainda for "Aguardando conexão..."
            if (defined $last_console_msg && $last_console_msg =~ $listen_regex) {
                my $port = _resolve_port();
                _call_ahk_once($port, "listen", 1);   # force (ignora debounce)

                # Inicia repetição a cada 10s enquanto não conectar
                my $repeat = _num('autoLogin_listen_repeat', 10);
                $repeat = 10 if $repeat <= 0;
                $listen_repeat_active = 1;
                $listen_repeat_next   = $now + $repeat;
            } else {
                debug "[autoFocus] Timer expirou, mas 'Aguardando conexão...' não é mais a última linha; não chamando AHK.\n", 'autoFocus';
            }

            $listen_ping_ts = 0;
        }
        return;
    }

    # Se acionado pelo gatilho, repete a cada 10s até entrar no jogo
    if ($listen_repeat_active) {
        if ($state eq 'IN_GAME') {
            _stop_listen_repeat();
            return;
        }

        my $repeat = _num('autoLogin_listen_repeat', 10);
        $repeat = 10 if $repeat <= 0;

        if ($now >= $listen_repeat_next) {
            my $port = _resolve_port();
            _call_ahk_once($port, "listen-repeat", 1);   # force (ignora debounce)
            $listen_repeat_next = $now + $repeat;
        }
    }
}

# ------------------ helpers ------------------

sub on_in_game {
    return unless _enabled();
    _stop_listen_repeat();
}

# $why (texto p/ log) / $force: 1 ignora debounce
sub _call_ahk_once {
    my ($port, $why, $force) = @_;
    my $ahk_script = _ahk_script();
    my $ahk_bin    = $config{autoLogin_ahk_bin};

    my $now      = time;
    my $debounce = _num('autoLogin_debounce', 20);
    return if (!$force && ($now - $last_ahk_call) < $debounce);

    $last_ahk_call = $now;

    if ($^O =~ /MSWin/i) {
        if (defined $ahk_bin && $ahk_bin ne '') {
            message "[autoFocus] AHK ($why): $ahk_bin \"$ahk_script\" --port $port\n", 'system';
            eval { system(1, $ahk_bin, $ahk_script, '--port', $port); };
            if ($@) { system($ahk_bin, $ahk_script, '--port', $port); }
        } else {
            message "[autoFocus] AHK ($why): start \"$ahk_script\" --port $port (associação)\n", 'system';
            eval { system(1, 'cmd', '/C', 'start', '""', $ahk_script, '--port', $port); };
            if ($@) { system('cmd', '/C', 'start', '""', $ahk_script, '--port', $port); }
        }
    } else {
        warning "[autoFocus] AHK é específico do Windows.\n";
    }
}

sub _ahk_script {
    # Mantém compat com sua config atual (autoLogin_ahk_path),
    # mas o padrão vira autoFocus.ahk no diretório do plugin.
    return $config{autoLogin_ahk_path}
        ? $config{autoLogin_ahk_path}
        : File::Spec->catfile($PLUGIN_DIR, 'autoFocus.ahk');
}

sub _resolve_port {
    # se autoLogin_port estiver setado e não vazio, usa ele (retrocompat)
    if (defined $config{autoLogin_port} && $config{autoLogin_port} ne '') {
        return $config{autoLogin_port};
    }

    for my $k (qw(
        XKore_listen_port xkore_listen_port
        XKore_port        xkore_port
        XKore_listenPort  xkore_listenPort
        bindPort          proxy_port
    )) {
        next unless defined $config{$k} && $config{$k} ne '';
        return $config{$k};
    }

    # Sem porta fixa: se nada foi configurado, devolve 0 (AHK decide o default)
    return 0;
}

# Stop flag
sub _stop_flag_path {
    my ($port) = @_;
    $port //= _resolve_port();
    return File::Spec->catfile($PLUGIN_DIR, "autoFocus.stop_$port");
}
sub _emit_stop_flag {
    my ($port) = @_;
    my $path = _stop_flag_path($port);
    if (open my $fh, '>', $path) {
        print $fh time;
        close $fh;
        $stop_flag_time = time;
        message "[autoFocus] stop flag criado: $path\n", 'system';
    }
}
sub _clear_stop_flag {
    my ($port) = @_;
    my $path = _stop_flag_path($port);
    if (-e $path) {
        unlink $path;
        message "[autoFocus] stop flag removido: $path\n", 'system';
    }
    $stop_flag_time = 0;
}

sub _enabled {
    # ainda usa autoLogin no config pra não quebrar nada
    return defined $config{autoLogin} ? !!$config{autoLogin} : 1;
}

sub _num {
    my ($k,$d)=@_;
    return $d unless defined $config{$k};
    my $v = $config{$k};
    # Filtro inline
    $v =~ s/\s*#.*$//;
    $v =~ s/^\s+|\s+$//g;
    return ($v ne '') ? ($v+0) : $d;
}

sub _reset_cycle {
    $relog_pending    = 0;
    $relog_start_time = 0;
    $relog_port       = undef;

    # ciclo de repetição do listen
    _stop_listen_repeat();

    # também resetamos o contador de "Proxeando..." ao estabilizar
    $prox_count      = 0;
    $prox_last_time  = 0;

    # e garantimos que a sequência especial esteja limpa
    $spam_phase = 0;
    $spam_t0    = 0;
}

sub _stop_listen_repeat {
    $listen_repeat_active = 0;
    $listen_repeat_next   = 0;
    $listen_ping_ts       = 0;
}

1;