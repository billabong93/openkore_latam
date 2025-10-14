#!/usr/bin/env perl
###########################################################
# Hydra Server - MULTIPORTA
# (Formerly known as Poseidon Server)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# Copyright (c) 2021-2025 OpenKore Development Team
#
# Credits:
# Celtos - OpenKore LATAM Community & openkore.com.br
# isieo - schematic of XKore 2 and other interesting ideas
# anonymous person - beta-testing
# kaliwanagan - original author
# illusionist - bRO support
# Fr3DBr - bRO Update (El Dicastes++)
###########################################################

use strict;
use warnings;
use utf8;

use FindBin qw($RealBin);
use lib "$RealBin/..";
use lib "$RealBin/../..";
use lib "$RealBin/../deps";
use Time::HiRes qw(time sleep);
use Getopt::Long;

use Poseidon::Config;
use Poseidon::RagnarokServer;
use Poseidon::QueryServer;

use constant SUPPORT_URL => 'https://openkore.com.br/';
use constant FORUM_URL => 'https://openkore.com.br/';
use constant SLEEP_TIME => 0.01;
use constant VERSION => '1.0-hydra';

our @roServers;
our @queryServers;

# Detecta se o terminal suporta cores
my $HAS_COLOR = (-t STDOUT) ? 1 : 0;
my $IS_WIN = ($^O =~ /MSWin32/i) ? 1 : 0;

# Habilita UTF-8 no output (com fallback)
eval { binmode(STDOUT, ":encoding(UTF-8)"); 1; };

# Detecta suporte a Unicode
sub _has_unicode {
    return 1 if $ENV{WT_SESSION} || $ENV{ConEmuANSI} || $ENV{ANSICON};
    my $lang = $ENV{LC_ALL} // $ENV{LANG} // '';
    return 1 if $lang =~ /UTF-?8/i;
    return 0 if $IS_WIN;
    return $HAS_COLOR ? 1 : 0;
}

my $HAS_UNICODE = _has_unicode();

# Códigos de cor ANSI
sub color {
    return $_[1] unless $HAS_COLOR;
    my ($code, $text) = @_;
    return "\e[${code}m${text}\e[0m";
}

# Paleta de cores
sub c_reset   { "\e[0m" }
sub c_bold    { color('1', $_[0]) }
sub c_red     { color('31', $_[0]) }
sub c_green   { color('32', $_[0]) }
sub c_yellow  { color('33', $_[0]) }
sub c_blue    { color('34', $_[0]) }
sub c_magenta { color('35', $_[0]) }
sub c_cyan    { color('36', $_[0]) }
sub c_white   { color('37', $_[0]) }
sub c_gray    { color('90', $_[0]) }
sub c_bred    { color('91', $_[0]) }
sub c_bgreen  { color('92', $_[0]) }
sub c_byellow { color('93', $_[0]) }
sub c_bblue   { color('94', $_[0]) }
sub c_bmagenta{ color('95', $_[0]) }
sub c_bcyan   { color('96', $_[0]) }
sub c_bwhite  { color('97', $_[0]) }

# Caracteres de desenho
sub get_box_chars {
    if ($HAS_UNICODE) {
        return {
            tl => '╔', tr => '╗', bl => '╚', br => '╝',
            h  => '═', v  => '║', 
            ml => '╠', mr => '╣', tm => '╦', bm => '╩',
            dot => '•', arrow => '→', check => '✓', 
            cross => '✗', star => '★', wave => '~',
            hydra => '🐉'
        };
    } else {
        return {
            tl => '+', tr => '+', bl => '+', br => '+',
            h  => '-', v  => '|',
            ml => '+', mr => '+', tm => '+', bm => '+',
            dot => '*', arrow => '>', check => 'v',
            cross => 'x', star => '*', wave => '~',
            hydra => 'H'
        };
    }
}

my $box = get_box_chars();

# Funções de desenho
sub draw_line {
    my ($char, $len) = @_;
    $len ||= 70;
    return $char x $len;
}

sub draw_box_top {
    my $len = shift || 70;
    return $box->{tl} . draw_line($box->{h}, $len-2) . $box->{tr};
}

sub draw_box_bottom {
    my $len = shift || 70;
    return $box->{bl} . draw_line($box->{h}, $len-2) . $box->{br};
}

sub draw_box_middle {
    my $len = shift || 70;
    return $box->{ml} . draw_line($box->{h}, $len-2) . $box->{mr};
}

sub draw_box_line {
    my ($text, $len) = @_;
    $len ||= 70;
    my $text_len = length($text);
    my $padding = $len - $text_len - 2;
    my $left = int($padding / 2);
    my $right = $padding - $left;
    return $box->{v} . (' ' x $left) . $text . (' ' x $right) . $box->{v};
}

# Banner ASCII Art
sub print_logo {
    print c_bcyan(draw_box_top(70)) . "\n";
    print c_bcyan($box->{v}) . c_bwhite("                      HYDRA SERVER                           ") . c_bcyan($box->{v}) . "\n";
    print c_bcyan($box->{v}) . c_byellow("                  ") . $box->{wave} . " MULTIPORT EDITION " . $box->{wave} . "                       " . c_bcyan($box->{v}) . "\n";
    print c_bcyan(draw_box_middle(70)) . "\n";
    
    if ($HAS_UNICODE) {
        print c_bcyan($box->{v}) . c_bblue("        🐉    ") . c_bwhite("GameGuard Query Server") . c_bblue("    🐉              ") . c_bcyan($box->{v}) . "\n";
    } else {
        print c_bcyan($box->{v}) . c_bblue("            ") . c_bwhite("GameGuard Query Server") . c_bblue("                ") . c_bcyan($box->{v}) . "\n";
    }
    
    print c_bcyan($box->{v}) . c_gray("                    Version " . VERSION . "                    ") . c_bcyan($box->{v}) . "\n";
    print c_bcyan(draw_box_middle(70)) . "\n";
    print c_bcyan($box->{v}) . c_bmagenta("              Developed by Celtos & Community                ") . c_bcyan($box->{v}) . "\n";
    print c_bcyan($box->{v}) . c_bblue("                 OpenKore LATAM Project                      ") . c_bcyan($box->{v}) . "\n";
    print c_bcyan(draw_box_bottom(70)) . "\n";
}

sub print_status {
    my ($icon, $color_func, $label, $value) = @_;
    print $color_func->($box->{dot} . " " . $label . ": ") . c_bwhite($value) . "\n";
}

sub print_server_pair {
    my ($idx, $ro_host, $ro_port, $qry_host, $qry_port) = @_;
    
    print c_bcyan($box->{ml} . draw_line($box->{h}, 68) . $box->{mr}) . "\n";
    print c_bcyan($box->{v}) . c_byellow(" " . $box->{star} . " PAR #$idx ") . (" " x 56) . c_bcyan($box->{v}) . "\n";
    print c_bcyan($box->{v}) . "  " . c_bgreen($box->{arrow} . " RO Server   : ") . 
          c_bwhite("$ro_host:$ro_port") . (" " x (70 - 20 - length("$ro_host:$ro_port"))) . c_bcyan($box->{v}) . "\n";
    print c_bcyan($box->{v}) . "  " . c_bblue($box->{arrow} . " Query Server: ") . 
          c_bwhite("$qry_host:$qry_port") . (" " x (70 - 20 - length("$qry_host:$qry_port"))) . c_bcyan($box->{v}) . "\n";
}

sub print_warning {
    my ($msg) = @_;
    print c_byellow($box->{v} . " " . $box->{cross} . " AVISO: ") . c_yellow($msg) . 
          (" " x (70 - length($msg) - 10)) . c_byellow($box->{v}) . "\n";
}

sub print_error {
    my ($msg) = @_;
    print c_bred($box->{v} . " " . $box->{cross} . " ERRO: ") . c_red($msg) . 
          (" " x (70 - length($msg) - 9)) . c_bred($box->{v}) . "\n";
}

sub print_success {
    my ($msg) = @_;
    print c_bgreen($box->{v} . " " . $box->{check} . " ") . c_green($msg) . 
          (" " x (70 - length($msg) - 4)) . c_bgreen($box->{v}) . "\n";
}

sub initialize {
    print "\n";
    print_logo();
    print "\n";
    
    print c_cyan(draw_box_top(70)) . "\n";
    print c_cyan($box->{v}) . c_bwhite("  CARREGANDO CONFIGURACAO...") . (" " x 40) . c_cyan($box->{v}) . "\n";
    print c_cyan(draw_box_bottom(70)) . "\n\n";

    # Carrega configuracao
    Getopt::Long::Configure('default');
    Poseidon::Config::parseArguments();
    Poseidon::Config::parse_config_file($config{file});
    Poseidon::Config::finalize();

    # Verifica configuracao
    my $ro_ports = $config{ragnarokserver_ports};
    my $qry_ports = $config{queryserver_ports};

    unless ($ro_ports && ref($ro_ports) eq 'ARRAY' && @$ro_ports > 0) {
        print c_bred(draw_box_top(70)) . "\n";
        print_error("ragnarokserver_ports nao definido!");
        print c_bred($box->{v}) . c_red("  Configure no poseidon.txt:") . (" " x 40) . c_bred($box->{v}) . "\n";
        print c_bred($box->{v}) . c_yellow("    ragnarokserver_ports=6901,6902,6903") . (" " x 28) . c_bred($box->{v}) . "\n";
        print c_bred(draw_box_bottom(70)) . "\n\n";
        exit(1);
    }

    unless ($qry_ports && ref($qry_ports) eq 'ARRAY' && @$qry_ports > 0) {
        print c_bred(draw_box_top(70)) . "\n";
        print_error("queryserver_ports nao definido!");
        print c_bred($box->{v}) . c_red("  Configure no poseidon.txt:") . (" " x 40) . c_bred($box->{v}) . "\n";
        print c_bred($box->{v}) . c_yellow("    queryserver_ports=24390,24391,24392") . (" " x 29) . c_bred($box->{v}) . "\n";
        print c_bred(draw_box_bottom(70)) . "\n\n";
        exit(1);
    }

    if (@$ro_ports != @$qry_ports) {
        print c_bred(draw_box_top(70)) . "\n";
        print_error("Numero de portas diferente!");
        print c_bred($box->{v}) . c_red("  RO Ports  : " . scalar(@$ro_ports)) . (" " x 51) . c_bred($box->{v}) . "\n";
        print c_bred($box->{v}) . c_red("  QRY Ports : " . scalar(@$qry_ports)) . (" " x 51) . c_bred($box->{v}) . "\n";
        print c_bred(draw_box_bottom(70)) . "\n\n";
        exit(1);
    }

    print c_bgreen(draw_box_top(70)) . "\n";
    print c_bgreen($box->{v}) . c_bwhite("  INICIANDO SERVIDORES...") . (" " x 43) . c_bgreen($box->{v}) . "\n";
    print c_bgreen(draw_box_bottom(70)) . "\n\n";

    # Cria os pares de servidores
    my $success_count = 0;
    for (my $i = 0; $i < @$ro_ports; $i++) {
        my $ro_port = $ro_ports->[$i];
        my $qry_port = $qry_ports->[$i];

        eval {
            my $roServer = new Poseidon::RagnarokServer(
                $ro_port, 
                $config{ragnarokserver_ip}
            );
            
            my $queryServer = new Poseidon::QueryServer(
                $qry_port, 
                $config{queryserver_ip}, 
                $roServer
            );

            push @roServers, $roServer;
            push @queryServers, $queryServer;

            print_server_pair($i+1, 
                $roServer->getHost(), $roServer->getPort(),
                $queryServer->getHost(), $queryServer->getPort());
            
            $success_count++;
        };
        
        if ($@) {
            print c_byellow(draw_box_top(70)) . "\n";
            print_warning("Par " . ($i+1) . " nao pode ser iniciado");
            print c_byellow($box->{v}) . c_yellow("  RO Port  : $ro_port") . (" " x (70 - 15 - length($ro_port))) . c_byellow($box->{v}) . "\n";
            print c_byellow($box->{v}) . c_yellow("  QRY Port : $qry_port") . (" " x (70 - 15 - length($qry_port))) . c_byellow($box->{v}) . "\n";
            print c_byellow($box->{v}) . c_gray("  Porta em uso ou sem permissao") . (" " x 37) . c_byellow($box->{v}) . "\n";
            print c_byellow(draw_box_bottom(70)) . "\n";
        }
    }

    unless ($success_count > 0) {
        print "\n";
        print c_bred(draw_box_top(70)) . "\n";
        print_error("NENHUM SERVIDOR INICIADO!");
        print c_bred($box->{v}) . c_red("  Verifique:") . (" " x 56) . c_bred($box->{v}) . "\n";
        print c_bred($box->{v}) . c_yellow("   1. Portas em uso por outro programa") . (" " x 30) . c_bred($box->{v}) . "\n";
        print c_bred($box->{v}) . c_yellow("   2. Permissoes (use sudo ou Admin)") . (" " x 32) . c_bred($box->{v}) . "\n";
        print c_bred($box->{v}) . c_yellow("   3. Firewall bloqueando as portas") . (" " x 33) . c_bred($box->{v}) . "\n";
        print c_bred(draw_box_bottom(70)) . "\n\n";
        exit(1);
    }

    # Banner final - STATUS
    print "\n";
    print c_bgreen(draw_box_top(70)) . "\n";
    if ($HAS_UNICODE) {
        print c_bgreen($box->{v}) . c_bwhite("                    ✨ SERVIDOR PRONTO ✨                    ") . c_bgreen($box->{v}) . "\n";
    } else {
        print c_bgreen($box->{v}) . c_bwhite("                    SERVIDOR PRONTO                          ") . c_bgreen($box->{v}) . "\n";
    }
    print c_bgreen(draw_box_middle(70)) . "\n";
    
    my $status_line = sprintf("Pares Ativos: %d de %d", $success_count, scalar(@$ro_ports));
    print c_bgreen($box->{v}) . "  " . c_bwhite($status_line) . (" " x (70 - length($status_line) - 4)) . c_bgreen($box->{v}) . "\n";
    
    print c_bgreen($box->{v}) . "  " . c_cyan("Server Type : ") . c_white($config{server_type}) . 
          (" " x (70 - 16 - length($config{server_type}) - 4)) . c_bgreen($box->{v}) . "\n";
    
    my $debug_status = $config{debug} ? c_byellow("ON") : c_gray("OFF");
    print c_bgreen($box->{v}) . "  " . c_cyan("Debug       : ") . $debug_status . 
          (" " x (70 - 16 - 2 - 4)) . c_bgreen($box->{v}) . "\n";
    
    if ($config{fake_ip}) {
        print c_bgreen($box->{v}) . "  " . c_cyan("Fake IP     : ") . c_white($config{fake_ip}) . 
              (" " x (70 - 16 - length($config{fake_ip}) - 4)) . c_bgreen($box->{v}) . "\n";
    }
    
    print c_bgreen(draw_box_middle(70)) . "\n";
    print c_bgreen($box->{v}) . c_gray("  Pressione CTRL+C para encerrar") . (" " x 36) . c_bgreen($box->{v}) . "\n";
    print c_bgreen(draw_box_bottom(70)) . "\n\n";
    
    print c_bmagenta("  " . $box->{hydra} . " Comunidade OpenKore LATAM\n");
    print c_bcyan("  " . $box->{arrow} . " Forum & Suporte: " . FORUM_URL . "\n");
    print c_gray("  " . $box->{arrow} . " Desenvolvido por Celtos\n\n");
}

sub __start {
    initialize();
    
    # Loop principal
    while (1) {
        for my $roServer (@roServers) {
            eval { $roServer->iterate(); };
            warn c_red("Erro RO: $@\n") if $@;
        }
        
        for my $queryServer (@queryServers) {
            eval { $queryServer->iterate(); };
            warn c_red("Erro Query: $@\n") if $@;
        }
        
        sleep SLEEP_TIME;
    }
}

# Tratamento de sinais
$SIG{INT} = sub {
    print "\n\n";
    print c_byellow(draw_box_top(70)) . "\n";
    if ($HAS_UNICODE) {
        print c_byellow($box->{v}) . c_bwhite("                   👋 ENCERRANDO HYDRA 👋                    ") . c_byellow($box->{v}) . "\n";
    } else {
        print c_byellow($box->{v}) . c_bwhite("                   ENCERRANDO HYDRA                          ") . c_byellow($box->{v}) . "\n";
    }
    print c_byellow(draw_box_middle(70)) . "\n";
    print c_byellow($box->{v}) . c_yellow("  Fechando servidores...") . (" " x 44) . c_byellow($box->{v}) . "\n";
    print c_byellow($box->{v}) . c_bmagenta("  Obrigado por usar Hydra Server!") . (" " x 34) . c_byellow($box->{v}) . "\n";
    print c_byellow($box->{v}) . c_gray("  OpenKore LATAM - openkore.com.br") . (" " x 33) . c_byellow($box->{v}) . "\n";
    print c_byellow(draw_box_bottom(70)) . "\n\n";
    exit(0);
};

$SIG{TERM} = $SIG{INT};

# Inicia o servidor
__start() unless defined $ENV{INTERPRETER};