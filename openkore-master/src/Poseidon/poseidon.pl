#!/usr/bin/env perl
###########################################################
# Poseidon server - start minimized to system tray on Windows
# Falls back to console loop on non-Windows or without Win32::GUI
###########################################################



use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";
use lib "$RealBin/../..";
use lib "$RealBin/../deps";
use Time::HiRes qw(time sleep);
use Getopt::Long;

use Poseidon::Config;
use Poseidon::RagnarokServer;
use Poseidon::QueryServer;

use constant POSEIDON_SUPPORT_URL => 'https://openkore.com/wiki/Poseidon';
use constant SLEEP_TIME_MS        => 10;   # 10ms (aprox 0.01s)
use constant SLEEP_TIME           => 0.01;

our ($roServer, $queryServer);
our ($W, $menu); # usados por handlers Win32::GUI

use constant BRAND_NAME        => 'Celtos / OpenKore LATAM';
use constant BRAND_SUPPORT_URL => 'https://openkore.com.br/';

sub initialize {
    my $version = "3.0";

    print ">>> Poseidon $version - " . BRAND_NAME . " <<<\n";
    print "Carregando configuracao...\n";

    Getopt::Long::Configure('default');
    Poseidon::Config::parseArguments();
    Poseidon::Config::parse_config_file($config{file});

    print "Inicializando servidores...\n";

    $roServer = Poseidon::RagnarokServer->new(
        $config{ragnarokserver_port},
        $config{ragnarokserver_ip}
    );
    print "[OK] Ragnarok Online Server: " 
        . $roServer->getHost() . ":" . $roServer->getPort() . "\n";

    $queryServer = Poseidon::QueryServer->new(
        $config{queryserver_port},
        $config{queryserver_ip},
        $roServer
    );
    print "[OK] Query Server: " 
        . $queryServer->getHost() . ":" . $queryServer->getPort() . "\n";

    print "Fake Server IP: " . $config{fake_ip} . "\n" if ($config{fake_ip});

    print ">>> Poseidon $version pronto (Debug: "
        . (($config{debug}) ? "On" : "Off") . ") <<<\n\n";
    print "Suporte / Comunidade: " . BRAND_SUPPORT_URL . "\n";
}


# ---------- Loop “console” (fallback) ----------
sub run_console_loop {
    initialize();
    while (1) {
        $roServer->iterate();
        $queryServer->iterate();
        sleep SLEEP_TIME;
    }
}

# ---------- Tray no Windows com Win32::GUI ----------
sub run_tray_windows {
    my $ok_gui = 0;

    # Tenta carregar Win32 & Win32::GUI dinamicamente
    eval {
        require Win32;
        Win32->import();
        require Win32::GUI;
        Win32::GUI->import();
        $ok_gui = 1;
        1;
    } or do {
        $ok_gui = 0;
    };

    # Se não tiver GUI, volta pro console
    return run_console_loop() unless $ok_gui;

    initialize();

    # Janela oculta + ícone na bandeja
    my $ICO_PATH = "$RealBin/poseidon.ico";
    my $icon = -e $ICO_PATH
        ? Win32::GUI::Icon->new($ICO_PATH)
        : Win32::GUI::LoadIcon(0, 32512); # IDI_APPLICATION

    $W = Win32::GUI::Window->new(
        -name    => 'PoseidonWnd',
        -text    => 'Poseidon',
        -visible => 0,   # invisível
        -width   => 0,
        -height  => 0,
    );

    $W->AddNotifyIcon(
        -name => 'Tray',
        -id   => 1,
        -icon => $icon,
        -tip  => 'Poseidon Server (rodando)',
    );

    # Menu de contexto do tray
    $menu = Win32::GUI::Menu->new(
        "&TrayMenu"            => "TrayMenu",
        ">&Abrir Log"          => "Tray_OpenLog",
        ">&Copiar Enderecos"   => "Tray_CopyAddrs",
        ">&Sair"               => "Tray_Exit",
    );

    # Timer para iterar servidores
    $W->AddTimer('Tick', SLEEP_TIME_MS);

    # === Handlers do tray ===
    sub PoseidonWnd_Tray_RightClick {
        my ($self) = @_;
        my ($x, $y) = Win32::GUI::GetCursorPos();
        $self->TrackPopupMenu($menu->{TrayMenu}, $x, $y);
        return 1;
    }

    sub PoseidonWnd_Tray_Click {
        # Futuro: abrir janela de status
        return 1;
    }

    # Timer — loop principal sem bloquear a GUI
    sub PoseidonWnd_Tick_Timer {
        eval {
            $roServer->iterate();
            $queryServer->iterate();
            1;
        } or do {
            # log opcional
        };
        return 1;
    }

    # Ações do menu
    sub PoseidonWnd_Tray_OpenLog_Click {
        # Se tiver log, abra aqui:
        # Win32::GUI::ShellExecute(0, "open", "poseidon.log", "", ".", 1);
        return 1;
    }

    sub PoseidonWnd_Tray_CopyAddrs_Click {
        my $txt = "";
        eval {
            $txt .= "Ragnarok: " . $roServer->getHost() . ":" . $roServer->getPort() . "\n";
            $txt .= "Query   : " . $queryServer->getHost() . ":" . $queryServer->getPort() . "\n";
            1;
        };
        Win32::GUI::Clipboard()->Open();
        Win32::GUI::Clipboard()->Empty();
        Win32::GUI::Clipboard()->SetAs($txt);
        Win32::GUI::Clipboard()->Close();
        return 1;
    }

    sub PoseidonWnd_Tray_Exit_Click {
        PoseidonWnd_Terminate();
        return -1;
    }

    sub PoseidonWnd_Terminate {
        eval { $W->RemoveNotifyIcon('Tray'); 1 };
        eval { $W->PostQuitMessage(0); 1 };
        return 1;
    }

    sub PoseidonWnd_Terminate_Click { PoseidonWnd_Terminate() }

    # === Detach do console, se rodando com perl.exe ===
    eval {
        require Win32::API::More;
        Win32::API::More->import();
        my $FreeConsole = Win32::API::More->new('kernel32', 'BOOL FreeConsole()');
        $FreeConsole && $FreeConsole->Call();
        1;
    };

    # Loop de mensagens GUI
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
