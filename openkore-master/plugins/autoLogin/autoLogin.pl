# plugins/autoLogin/autoLogin.pl
package autoLogin;
use strict;
use warnings;
use Plugins;
use Globals qw(%config $net $char);
use Log qw(message warning);
use Time::HiRes qw(time);
use File::Basename qw(dirname);
use File::Spec;
use Commands;

my $PLUGIN_DIR = dirname(__FILE__);

# ---------- Estado ----------
my $last_ahk_call            = 0;
my $relog_pending            = 0;
my $relog_start_time         = 0;
my $relog_port;

my $first_wait_seen          = 0;     # pula a 1ª ocorrência da sessão
my $waiting_fired            = 0;     # trava até entrar IN_GAME

# contadores/flags dirigidos por LOG
our $wait_seen_count         = 0;     # total de "Aguardando conexão..." vistos
our $last_seen_port          = undef; # última porta capturada do texto
our $last_fired_wait_count   = 0;     # contagem na qual disparamos por último

# disparo agendado a partir do wrap do Log::message
our $need_fire               = 0;     # 1 = disparar AHK no próximo tick
our $need_fire_seen_count    = 0;     # contagem à qual esse disparo se refere
our $skip_notice_pending     = 0;     # log amigável para a 1ª ocorrência

Plugins::register(
    'autoLogin',
    'Focar ragexe + ESC a partir da 2ª ocorrência de "Aguardando conexão..."',
    \&on_unload, \&on_reload
);

# --------- Hook seguro de inicialização (sem INIT) ----------
Plugins::addHook('start3', \&on_start);

# --------- Captura textual do console (wrap do Log::message) ----------
BEGIN {
    no warnings 'redefine';
    my $orig = \&Log::message;
    *Log::message = sub {
        my ($msg, @rest) = @_;
        eval {
            if (defined $msg && $msg =~ /Aguardando conex(?:[ãa]o|ao) do cliente Ragnarok em\s*\(0\.0\.0\.0:(\d+)\)/i) {
                $autoLogin::wait_seen_count++;
                $autoLogin::last_seen_port = $1;

                if (!$autoLogin::first_wait_seen) {
                    $autoLogin::first_wait_seen     = 1;
                    $autoLogin::skip_notice_pending = 1;
                } elsif ($autoLogin::last_fired_wait_count < $autoLogin::wait_seen_count) {
                    $autoLogin::need_fire            = 1;
                    $autoLogin::need_fire_seen_count = $autoLogin::wait_seen_count;
                }
            }
        };
        $orig->($msg, @rest);
    };
}

# --------- Desconexões / relog ----------
Plugins::addHook('disconnected_from_loginserver', \&on_dc);
Plugins::addHook('disconnected_from_charserver',  \&on_dc);
Plugins::addHook('disconnected_from_mapserver',   \&on_dc);

# --------- Loop ----------
Plugins::addHook('AI_pre',       \&tick);
Plugins::addHook('mainLoop_pre', \&tick);

sub on_unload {}
sub on_reload {}

sub on_start {
    my $port       = _resolve_port();
    my $ahk_script = _ahk_script();
    my $ahk_bin    = $config{autoLogin_ahk_bin} // '(associação do .ahk)';
    message "[autoLogin] Plugin carregado. Porta=$port | AHK='$ahk_script' | BIN='$ahk_bin'\n", 'system';
}

sub on_dc {
    return unless _enabled();
    my $delay = _num('autoLogin_relog_delay', 5);
    $relog_port = _resolve_port();

    return if $relog_pending;
    message "[autoLogin] DC detectado. Executando 'relog' e aguardando ${delay}s [porta $relog_port]\n", 'system';

    eval { Commands::run('relog'); };
    if ($@) { warning "[autoLogin] Falha ao executar 'relog': $@\n"; }

    $relog_pending    = 1;
    $relog_start_time = time;

    # liberar para um novo disparo pós-relog (mantém 'pular a primeira' da sessão)
    $waiting_fired = 0;
}

sub in_game_state {
    my $state = ($net ? ($net->getState() // '') : '');
    return 1 if $state eq 'IN_GAME';
    return 1 if defined $char && $char->{name};
    return 0;
}

sub tick {
    return unless _enabled();

    if ($skip_notice_pending) {
        message "[autoLogin] Primeira detecção de 'aguardando cliente' — pulando esta vez.\n", 'system';
        $skip_notice_pending = 0;
    }

    # 0) Se já está no jogo: limpa travas e quaisquer agendamentos
    if (in_game_state()) {
        $waiting_fired  = 0;
        $need_fire      = 0;
        return;
    }

    # 1) Processa DISPARO AGENDADO PRIMEIRO (antes de respeitar relog_pending)
    if ($need_fire) {
        # Disparo válido (2ª ocorrência ou mais, e ainda não disparado para essa contagem)
        if ($wait_seen_count >= 2 && $last_fired_wait_count < $need_fire_seen_count) {
            my $port = _resolve_port();
            $port = $last_seen_port if defined $last_seen_port;

            message "[autoLogin] 'Aguardando cliente' detectado novamente. Chamando AHK (ESC) [porta $port]\n", 'system';
            _call_ahk_once($port, "aguardando-ESC");

            $waiting_fired             = 1;              # evita repetição até IN_GAME
            $last_fired_wait_count     = $need_fire_seen_count;
        }
        $need_fire = 0;
        return;
    }

    # 2) Delay pós-relog (sem impedir o disparo agendado acima)
    if ($relog_pending) {
        my $delay = _num('autoLogin_relog_delay', 5);
        if ((time - $relog_start_time) >= $delay) {
            $relog_pending = 0;
        }
        return;
    }

}

# ------------------ helpers ------------------

sub _call_ahk_once {
    my ($port, $why) = @_;
    my $ahk_script = _ahk_script();
    my $ahk_bin    = $config{autoLogin_ahk_bin}; # ex.: C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe

    my $now      = time;
    my $debounce = _num('autoLogin_debounce', 1); # baixo, só para evitar duplo-disparo na mesma iteração
    return if ($now - $last_ahk_call) < $debounce;
    $last_ahk_call = $now;

    if ($^O =~ /MSWin/i) {
        if (defined $ahk_bin && $ahk_bin ne '') {
            message "[autoLogin] AHK ($why): $ahk_bin \"$ahk_script\" --port $port\n", 'system';
            eval { system(1, $ahk_bin, $ahk_script, '--port', $port); 1 } or do {
                system($ahk_bin, $ahk_script, '--port', $port);
            };
        } else {
            message "[autoLogin] AHK ($why): start \"$ahk_script\" --port $port (associação)\n", 'system';
            eval { system(1, 'cmd', '/C', 'start', '""', $ahk_script, '--port', $port); 1 } or do {
                system('cmd', '/C', 'start', '""', $ahk_script, '--port', $port);
            };
        }
    } else {
        warning "[autoLogin] AHK é específico do Windows.\n";
    }
}

sub _ahk_script {
    return $config{autoLogin_ahk_path}
        ? $config{autoLogin_ahk_path}
        : File::Spec->catfile($PLUGIN_DIR, 'autoLogin.ahk');
}

sub _resolve_port {
    return $config{autoLogin_port} if defined $config{autoLogin_port};
    for my $k (qw(
        XKore_listen_port xkore_listen_port
        XKore_port        xkore_port
        XKore_listenPort  xkore_listenPort
        bindPort          proxy_port
    )) {
        return $config{$k} if defined $config{$k};
    }
    return 6901;
}

sub _enabled { return defined $config{autoLogin} ? !!$config{autoLogin} : 1; }
sub _num     { my ($k,$d)=@_; return defined $config{$k} ? ($config{$k}+0) : $d; }

1;
