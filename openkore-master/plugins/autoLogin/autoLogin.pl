# plugins/autoLogin.pl
package autoLogin;
use strict;
use warnings;
use Plugins;
use Globals qw(%config $net);
use Log qw(message warning);
use Time::HiRes qw(time);
use File::Basename qw(dirname);
use File::Spec;
use Commands;
use IO::Socket::INET;  # p/ checar porta/listen

my $PLUGIN_DIR = dirname(__FILE__);

# Estados
my $boot_time         = time;
my $last_ahk_call     = 0;
my $relog_pending     = 0;
my $relog_start_time  = 0;
my $relog_port;
my $stop_flag_time    = 0;
my $listen_seen_time  = 0; # p/ estabilidade da porta
my $login_seen_once   = 0; # só habilita lógica após primeiro login bem-sucedido

Plugins::register(
    'autoLogin',
    'Relogar e acionar AHK v2 (xkore3; DC + aguardando cliente)',
    \&on_unload, \&on_reload
);

INIT {
    my $port = _resolve_port();
    my $ahk_script = _ahk_script();
    my $ahk_bin    = $config{autoLogin_ahk_bin} // '(associação do .ahk)';
    message "[autoLogin] Carregado | Porta=$port | AHK='$ahk_script' | BIN='$ahk_bin'\n", 'system';
    message "[autoLogin] Habilitado="._enabled()." | Debounce="._num('autoLogin_debounce',45)."s | WaitDelay="._num('autoLogin_wait_delay',2)."s\n", 'system';
}

Plugins::addHook('disconnected_from_loginserver', \&on_dc);
Plugins::addHook('disconnected_from_charserver',  \&on_dc);
Plugins::addHook('disconnected_from_mapserver',   \&on_dc);

Plugins::addHook('AI_pre',       \&tick);
Plugins::addHook('mainLoop_pre', \&tick);

sub on_unload { _clear_stop_flag(_resolve_port()); }
sub on_reload { 1; }

sub on_dc {
    return unless _enabled();
    return unless $login_seen_once;

    my $delay = _num('autoLogin_relog_delay', 5);
    $relog_port = _resolve_port();
    return if $relog_pending;

    message "[autoLogin] DC detectado. Executando 'relog' e aguardando ${delay}s [porta $relog_port]\n", 'system';
    eval { Commands::run('relog'); };
    if ($@) { warning "[autoLogin] Falha ao executar 'relog': $@\n"; }

    $relog_pending     = 1;
    $relog_start_time  = time;
    $last_ahk_call     = 0;
    $listen_seen_time  = 0;
}

sub tick {
    return unless _enabled();

    my $state = ($net ? ($net->getState() // '') : '');
    my $now   = time;

    # (A) Já IN_GAME => garante stop-flag (1x), registra login inicial, limpa estados e não chama AHK
    if ($state eq 'IN_GAME') {
        if (!$login_seen_once) {
            $login_seen_once = 1;
            message "[autoLogin] Primeiro login detectado. Plugin habilitado após este ponto.\n", 'system';
        }
        if (!$stop_flag_time) { _emit_stop_flag(_resolve_port()); }
        _reset_cycle();
        return;
    }

    # Não realiza nenhuma ação até que o jogador tenha logado pelo menos uma vez
    return unless $login_seen_once;

    # (B) Fase de conexão (qualquer estado não-vazio e não IN_GAME costuma indicar login/char/map connect)
    if (defined $state && $state ne '' && $state ne 'IN_GAME') {
        # não atrapalha o handshake: cria stop-flag e não chama AHK
        if (!$stop_flag_time) { _emit_stop_flag(_resolve_port()); }
        return;
    }

    # (C) Pós-RELOG: espera Xs e chama AHK uma vez
    if ($relog_pending) {
        my $delay = _num('autoLogin_relog_delay', 5);
        if (($now - $relog_start_time) >= $delay) {
            _call_ahk_once(($relog_port // _resolve_port()), "pos-relog");
        }
        return;
    }

    # (D) "Aguardando cliente" -> só dispara se a porta estiver EM USO e estável
    if (_bool('autoLogin_on_wait', 1)) {
        my $wait_delay    = _num('autoLogin_wait_delay', 2);
        my $debounce_sec  = _num('autoLogin_debounce', 45);
        my $stable_needed = _num('autoLogin_listen_stable', 2); # segundos

        return if ($now - $boot_time) < $wait_delay;
        return if ($now - $last_ahk_call) < $debounce_sec;

        my $port = _resolve_port();
        if (_port_in_use($port)) {
            if (!$listen_seen_time) { $listen_seen_time = $now; return; }
            return if ($now - $listen_seen_time) < $stable_needed;

            # porta ocupada e estável: dispara AHK UMA vez, limpando stop-flag antes
            message "[autoLogin] Presumindo 'aguardando cliente'. Tentando AHK [porta $port]\n", 'system';
            _call_ahk_once($port, "aguardando");
            $listen_seen_time = 0;
        } else {
            $listen_seen_time = 0;
        }
    }

    # Limpeza do stop-flag ~8s depois (tempo suficiente p/ AHK encerrar)
    if ($stop_flag_time && (time - $stop_flag_time) > 8) {
        _clear_stop_flag(_resolve_port());
    }
}

# ------------------ helpers ------------------

sub _call_ahk_once {
    my ($port, $why) = @_;
    my $ahk_script = _ahk_script();
    my $ahk_bin    = $config{autoLogin_ahk_bin};

    my $now      = time;
    my $debounce = _num('autoLogin_debounce', 45);
    return if ($now - $last_ahk_call) < $debounce;

    $last_ahk_call = $now;

    # importantíssimo: libere stop-flag ANTES de chamar o AHK
    _clear_stop_flag($port);

    if ($^O =~ /MSWin/i) {
        if (defined $ahk_bin && $ahk_bin ne '') {
            message "[autoLogin] AHK ($why): $ahk_bin \"$ahk_script\" --port $port\n", 'system';
            eval { system(1, $ahk_bin, $ahk_script, '--port', $port); };
            if ($@) { system($ahk_bin, $ahk_script, '--port', $port); }
        } else {
            message "[autoLogin] AHK ($why): start \"$ahk_script\" --port $port (associação)\n", 'system';
            eval { system(1, 'cmd', '/C', 'start', '""', $ahk_script, '--port', $port); };
            if ($@) { system('cmd', '/C', 'start', '""', $ahk_script, '--port', $port); }
        }
    } else {
        warning "[autoLogin] AHK é específico do Windows.\n";
    }
}

# porta em uso = X-Kore escutando -> retorna 1; se livre -> 0
sub _port_in_use {
    my ($port) = @_;
    $port ||= _resolve_port();

    my $sock = IO::Socket::INET->new(
        LocalAddr => '0.0.0.0',
        LocalPort => $port,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 0
    );

    if ($sock) { close $sock; return 0; }
    return 1;
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
        return $config{$k} if defined $k && defined $config{$k};
    }
    return 6901;
}

# stop-flag
sub _stop_flag_path {
    my ($port) = @_;
    $port //= _resolve_port();
    return File::Spec->catfile($PLUGIN_DIR, "autoLogin.stop_$port");
}
sub _emit_stop_flag {
    my ($port) = @_;
    my $path = _stop_flag_path($port);
    return if -e $path;
    if (open my $fh, '>', $path) {
        print $fh time;
        close $fh;
        $stop_flag_time = time;
        message "[autoLogin] stop flag criado: $path\n", 'system';
    }
}
sub _clear_stop_flag {
    my ($port) = @_;
    my $path = _stop_flag_path($port);
    if (-e $path) {
        unlink $path;
        message "[autoLogin] stop flag removido: $path\n", 'system';
    }
    $stop_flag_time = 0;
}

sub _enabled { return defined $config{autoLogin} ? !!$config{autoLogin} : 1; }
sub _num     { my ($k,$d)=@_; return defined $config{$k} ? ($config{$k}+0) : $d; }

sub _reset_cycle {
    $relog_pending     = 0;
    $relog_start_time  = 0;
    $relog_port        = undef;
    # preserva $last_ahk_call p/ respeitar debounce
}

1;
