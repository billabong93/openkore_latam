#!/usr/bin/env perl
###########################################################
# Poseidon server - multiport + bandeja no Windows
# - Múltiplos pares (RagnarokServer <-> QueryServer) no mesmo processo
# - Mata processos nas portas-alvo (sem matar a si mesmo)
# - Pré-flight de bind e "skip" de pares ocupados/sem permissão
# - Fallback p/ loop console se Win32::GUI indisponível
###########################################################

use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";
use lib "$RealBin/../..";
use lib "$RealBin/../deps";
use Time::HiRes qw(sleep);
use Getopt::Long;
use IO::Socket::INET;

use Poseidon::Config;
use Poseidon::RagnarokServer;
use Poseidon::QueryServer;

use constant SLEEP_TIME_MS => 10;    # 10ms
use constant SLEEP_TIME    => 0.01;

use constant BRAND_NAME        => 'Celtos / OpenKore LATAM';
use constant BRAND_SUPPORT_URL => 'https://openkore.com.br/';

our @RO_SERVERS;       # Poseidon::RagnarokServer
our @QRY_SERVERS;      # Poseidon::QueryServer
our %PAIR_IDX_BY_QRY;  # "host:port" -> idx
our ($W, $menu);       # Win32::GUI

# ---------------- util: testa se porta está livre p/ bind ----------------
sub _can_bind {
    my ($ip, $port) = @_;
    my $sock = IO::Socket::INET->new(
        LocalAddr => $ip,
        LocalPort => $port,
        Listen    => 1,
        Proto     => 'tcp',
        ReuseAddr => 1,
    );
    if ($sock) {
        close $sock;
        return 1;
    }
    return 0;
}

# === mata qualquer processo escutando nas portas pedidas (sem matar a si) ===
sub free_requested_ports {
    my %want;
    $want{$_} = 1 for (@{$config{ragnarokserver_ports}}, @{$config{queryserver_ports}});

    my %pid_to_ports;
    my $self_pid = $$;

    if ($^O =~ /MSWin32/i) {
        for my $port (sort { $a <=> $b } keys %want) {
            my @lines = `netstat -ano -p tcp | findstr :$port 2>NUL`;
            for my $ln (@lines) {
                next unless $ln =~ /\bLISTENING\b/i;
                if ($ln =~ /LISTENING\s+(\d+)\s*$/i) {
                    my $pid = $1 + 0;
                    next if $pid == 0 || $pid == $self_pid;
                    $pid_to_ports{$pid}{$port} = 1;
                }
            }
        }
        for my $pid (keys %pid_to_ports) {
            my $ports = join(',', sort { $a <=> $b } keys %{$pid_to_ports{$pid}});
            print "[port-free] Matando PID $pid (ports: $ports)...\n";
            my $rc = system("taskkill", "/F", "/PID", $pid);
            if ($rc != 0) {
                print "ERRO: não foi possível matar PID $pid (sem permissão?). Pulando.\n";
            }
            select(undef, undef, undef, 0.20);
        }
    } else {
        # Linux/Unix
        for my $port (sort { $a <=> $b } keys %want) {
            my @pids = `lsof -nP -iTCP:$port -sTCP:LISTEN -t 2>/dev/null`;
            chomp @pids;
            if (!@pids) {
                my @ss = `ss -ltnp 'sport = :$port' 2>/dev/null`;
                for my $ln (@ss) { while ($ln =~ /pid=(\d+)/g) { push @pids, $1 + 0; } }
            }
            for my $pid (@pids) {
                next if $pid == $self_pid;
                $pid_to_ports{$pid}{$port} = 1;
            }
        }
        for my $pid (keys %pid_to_ports) {
            my $ports = join(',', sort { $a <=> $b } keys %{$pid_to_ports{$pid}});
            print "[port-free] Matando PID $pid (ports: $ports)...\n";
            kill 9, $pid or print "ERRO: não foi possível matar PID $pid. Pulando.\n";
            select(undef, undef, undef, 0.20);
        }
    }
}

# --- filtra pares que realmente dá pra abrir (evita falhar o processo todo) ---
sub compute_available_pairs {
    my @pairs;
    for (my $i = 0; $i < @{$config{ragnarokserver_ports}}; $i++) {
        my $ro_p  = $config{ragnarokserver_ports}[$i];
        my $qry_p = $config{queryserver_ports}[$i];

        my $ro_ok  = _can_bind($config{ragnarokserver_ip}, $ro_p);
        my $qry_ok = _can_bind($config{queryserver_ip},    $qry_p);

        if ($ro_ok && $qry_ok) {
            push @pairs, [$ro_p, $qry_p];
        } else {
            my @why;
            push @why, "RO:$config{ragnarokserver_ip}:$ro_p"  unless $ro_ok;
            push @why, "QRY:$config{queryserver_ip}:$qry_p"   unless $qry_ok;
            print "[skip] Par ".($i+1)." indisponível -> ".join(' ', @why)."\n";
        }
    }
    return @pairs;
}

sub initialize {
    my $version = "3.3";

    print ">>> Poseidon $version - " . BRAND_NAME . " <<<\n";
    print "Carregando configuracao...\n";

    Getopt::Long::Configure('default');
    Poseidon::Config::parseArguments();
    Poseidon::Config::parse_config_file($config{file});
    Poseidon::Config::finalize();

    # Mata quem estiver ocupando as portas solicitadas (sem matar a si mesmo)
    free_requested_ports();

    # Pré-flight: só sobe o que está realmente livre
    my @pairs = compute_available_pairs();
    if (!@pairs) {
        die "Nenhum par de portas livre para bind. Ajuste as portas ou rode como Administrador.\n";
    }

    print "Inicializando servidores (pares: " . scalar(@pairs) . ")...\n";

    @RO_SERVERS  = ();
    @QRY_SERVERS = ();
    %PAIR_IDX_BY_QRY = ();

    for (my $i = 0; $i < @pairs; $i++) {
        my ($ro_p, $qry_p) = @{$pairs[$i]};

        my $ro = Poseidon::RagnarokServer->new($ro_p,  $config{ragnarokserver_ip});
        my $qs = Poseidon::QueryServer->new   ($qry_p, $config{queryserver_ip}, $ro);

        push @RO_SERVERS,  $ro;
        push @QRY_SERVERS, $qs;

        $PAIR_IDX_BY_QRY{$qs->getHost() . ":" . $qs->getPort()} = $i;

        print sprintf("[OK] Par %d  RO:%s:%d  <->  QRY:%s:%d\n",
            $i+1, $ro->getHost(), $ro->getPort(), $qs->getHost(), $qs->getPort());
    }

    print "Fake Server IP: $config{fake_ip}\n" if ($config{fake_ip});
    print ">>> Poseidon $version pronto (Debug: " . (($config{debug}) ? "On" : "Off") . ") <<<\n\n";
    print "Suporte / Comunidade: " . BRAND_SUPPORT_URL . "\n";
}

# ---------- Loop console ----------
sub run_console_loop {
    initialize();
    while (1) {
        for my $ro (@RO_SERVERS)  { $ro->iterate(); }
        for my $qs (@QRY_SERVERS) { $qs->iterate(); }
        sleep SLEEP_TIME;
    }
}

# ---------- Tray no Windows ----------
sub run_tray_windows {
    my $ok_gui = 0;

    eval {
        require Win32;
        Win32->import();
        require Win32::GUI;
        Win32::GUI->import();
        $ok_gui = 1;
        1;
    } or do { $ok_gui = 0; };

    return run_console_loop() unless $ok_gui;

    initialize();

    my $ICO_PATH = "$RealBin/poseidon.ico";
    my $icon = -e $ICO_PATH
        ? Win32::GUI::Icon->new($ICO_PATH)
        : Win32::GUI::LoadIcon(0, 32512); # IDI_APPLICATION

    $W = Win32::GUI::Window->new(
        -name    => 'PoseidonWnd',
        -text    => 'Poseidon',
        -visible => 0,
        -width   => 0,
        -height  => 0,
    );

    $W->AddNotifyIcon(
        -name => 'Tray',
        -id   => 1,
        -icon => $icon,
        -tip  => 'Poseidon Server (rodando)',
    );

    $menu = Win32::GUI::Menu->new(
        "&TrayMenu"            => "TrayMenu",
        ">&Abrir Log"          => "Tray_OpenLog",
        ">&Copiar Enderecos"   => "Tray_CopyAddrs",
        ">&Sair"               => "Tray_Exit",
    );

    $W->AddTimer('Tick', SLEEP_TIME_MS);

    sub PoseidonWnd_Tray_RightClick {
        my ($self) = @_;
        my ($x, $y) = Win32::GUI::GetCursorPos();
        $self->TrackPopupMenu($menu->{TrayMenu}, $x, $y);
        return 1;
    }

    sub PoseidonWnd_Tray_Click { return 1; }

    sub PoseidonWnd_Tick_Timer {
        eval {
            for my $ro (@RO_SERVERS)  { $ro->iterate(); }
            for my $qs (@QRY_SERVERS) { $qs->iterate(); }
            1;
        };
        return 1;
    }

    sub PoseidonWnd_Tray_OpenLog_Click { return 1; }

    sub PoseidonWnd_Tray_CopyAddrs_Click {
        my $txt = "";
        eval {
            for (my $i = 0; $i < @RO_SERVERS; $i++) {
                my $ro = $RO_SERVERS[$i];
                my $qs = $QRY_SERVERS[$i];
                $txt .= sprintf("Par %d\n  Ragnarok: %s:%d\n  Query   : %s:%d\n",
                    $i+1, $ro->getHost(), $ro->getPort(), $qs->getHost(), $qs->getPort());
            }
            1;
        };
        Win32::GUI::Clipboard()->Open();
        Win32::GUI::Clipboard()->Empty();
        Win32::GUI::Clipboard()->SetAs($txt);
        Win32::GUI::Clipboard()->Close();
        return 1;
    }

    sub PoseidonWnd_Tray_Exit_Click { PoseidonWnd_Terminate(); return -1; }

    sub PoseidonWnd_Terminate {
        eval { $W->RemoveNotifyIcon('Tray'); 1 };
        eval { $W->PostQuitMessage(0); 1 };
        return 1;
    }

    eval {
        require Win32::API::More;
        Win32::API::More->import();
        my $FreeConsole = Win32::API::More->new('kernel32', 'BOOL FreeConsole()');
        $FreeConsole && $FreeConsole->Call();
        1;
    };

    Win32::GUI::Dialog();
    exit(0);
}

# -------- Entry --------
if ($^O =~ /MSWin32/i) {
    eval { run_tray_windows(); 1 } or do {
        warn "[Tray] Falhou Win32::GUI ($@). Caindo pro loop console...\n";
        run_console_loop();
    };
} else {
    run_console_loop();
}
