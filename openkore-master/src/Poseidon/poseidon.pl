#!/usr/bin/env perl
# =====================================================================
# Poseidon server — multiport (console only, sem deps extras)
# - Multi pares (RagnarokServer <-> QueryServer)
# - Mata processos nas portas alvo (sem matar a si mesmo)
# - Pré-flight de bind e "skip" de pares indisponíveis
# - Logs com timestamp + cores (quando TTY)
# - Banners em quadro (Unicode OU ASCII, auto-fallback)
# - Tratamento de sinais + saída limpa
# =====================================================================

use strict;
use warnings;
use utf8;  # ok mesmo com fallback ASCII; ignora se console não suportar
use FindBin qw($RealBin);
use lib "$RealBin/..";
use lib "$RealBin/../..";
use lib "$RealBin/../deps";

use Getopt::Long;
use IO::Socket::INET;
use Time::HiRes qw(sleep);
use Scalar::Util qw(looks_like_number);

use Poseidon::Config;
use Poseidon::RagnarokServer;
use Poseidon::QueryServer;

# ------------------------------- Consts --------------------------------
use constant VERSION        => '3.4e';
use constant BRAND_NAME     => 'Celtos / OpenKore LATAM';
use constant BRAND_SUPPORT  => 'https://openkore.com.br/';
use constant SLEEP_TIME     => 0.01;   # 10ms
use constant NETSTAT_WAIT_S => 0.20;

# ------------------------------- Globals -------------------------------
our @RO_SERVERS;       # Poseidon::RagnarokServer
our @QRY_SERVERS;      # Poseidon::QueryServer
our %PAIR_IDX_BY_QRY;  # "host:port" -> idx
our $HAS_TTY = -t STDOUT ? 1 : 0;
our $IS_WIN  = ($^O =~ /MSWin32/i) ? 1 : 0;

# Habilita UTF-8 no STDOUT (se o console aguentar; se não, só ignora)
eval { binmode(STDOUT, ":encoding(UTF-8)"); 1; };

# -------------------------------- Log ----------------------------------
sub _ts { my @t = gmtime(); sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900,$t[4]+1,@t[3,2,1,0]) }
sub _c  { return $_[1] unless $HAS_TTY; my($code,$s)=@_; "\e[${code}m${s}\e[0m" }

sub log_info { print  _c('36', "["._ts()."] [INFO] "), @_, "\n" }   # cyan
sub log_ok   { print  _c('32', "["._ts()."] [ OK ] "), @_, "\n" }   # green
sub log_warn { print  _c('33', "["._ts()."] [WARN] "), @_, "\n" }   # yellow
sub log_err  { print  _c('31', "["._ts()."] [ERR ] "), @_, "\n" }   # red
sub log_dbg  { return unless $Poseidon::Config::config{debug}; print _c('90',"["._ts()."] [DBG ] "), @_, "\n" } # gray

# --------- Quadro: Unicode seguro? Se não, usa ASCII (+- |) -----------
sub _unicode_box_ok {
    # Windows Terminal / ConEmu / ansicon ou LANG UTF-8 → OK
    return 1 if $ENV{WT_SESSION} || $ENV{ConEmuANSI} || $ENV{ANSICON};
    my $lang = $ENV{LC_ALL} // $ENV{LANG} // '';
    return 1 if $lang =~ /UTF-?8/i;
    # Em Windows padrão, assume NÃO
    return 0 if $IS_WIN;
    # Em outros TTYs (Linux/macOS) geralmente OK
    return $HAS_TTY ? 1 : 0;
}
my $BOX_UTF8 = _unicode_box_ok();

# ------------------------- Pretty Box Helpers --------------------------
sub _box_chars {
    if ($BOX_UTF8) {
        return ("╔","╗","╚","╝","═","║","╠","╣");
    } else {
        return ("+","+","+","+","-","|","+","+"); # ASCII fallback
    }
}
sub _box_line   { my ($ch,$len)=@_; ($ch//'=') x ($len//72) }

# Largura segura: usa 72 colunas (não quebra em consoles estreitos)
sub _box_center {
    my ($text,$width) = @_;
    $width ||= 72;
    $text  = "" unless defined $text;
    my $len = length($text);
    my $pad = $width - $len; $pad = 0 if $pad < 0;
    my $left  = int($pad/2);
    my $right = $pad - $left;
    return (" " x $left).$text.(" " x $right);
}
sub pretty_banner {
    my ($title, @lines) = @_;
    my $width  = 72;
    my ($TL,$TR,$BL,$BR,$H,$V,$HL,$HR) = _box_chars();
    my $border = _box_line($H,$width);

    print _c('36', $TL.$border.$TR."\n");
    print _c('36', $V)._c('37', _box_center($title,$width))._c('36', $V."\n");
    print _c('36', $HL.$border.$HR."\n");
    for my $ln (@lines) {
        print _c('36', $V)._c('37', _box_center($ln,$width))._c('36', $V."\n");
    }
    print _c('36', $BL.$border.$BR."\n");
}

# ------------------------------ Utils ----------------------------------
sub _valid_port {
    my ($p) = @_;
    return 0 unless defined $p && looks_like_number($p);
    return $p > 0 && $p < 65536;
}

sub _can_bind {
    my ($ip, $port) = @_;
    return 0 unless _valid_port($port);
    my $sock = IO::Socket::INET->new(
        LocalAddr => $ip,
        LocalPort => $port,
        Listen    => 1,
        Proto     => 'tcp',
        ReuseAddr => 1,
    );
    if ($sock) { close $sock; return 1 }
    return 0;
}

# Mata processos escutando nas portas pedidas (sem matar a si)
sub free_requested_ports {
    my %want;
    my %cfg = %Poseidon::Config::config;
    for my $p (@{$cfg{ragnarokserver_ports}}, @{$cfg{queryserver_ports}}) {
        next unless _valid_port($p);
        $want{$p} = 1;
    }
    return unless %want;

    my %pid_to_ports;
    my $self_pid = $$;

    if ($IS_WIN) {
        for my $port (sort {$a<=>$b} keys %want) {
            my $needle = int($port);
            my @lines = `netstat -ano -p tcp | findstr :$needle 2>NUL`;
            for my $ln (@lines) {
                next unless $ln =~ /\bLISTENING\b/i;
                if ($ln =~ /LISTENING\s+(\d+)\s*$/i) {
                    my $pid = 0 + $1;
                    next if $pid == 0 || $pid == $self_pid;
                    $pid_to_ports{$pid}{$needle} = 1;
                }
            }
        }
        for my $pid (sort {$a<=>$b} keys %pid_to_ports) {
            my $ports = join(',', sort {$a<=>$b} keys %{$pid_to_ports{$pid}});
            log_warn("[port-free] Matando PID $pid (ports: $ports)...");
            my $rc = system('taskkill','/F','/PID', $pid); # sem shell
            if ($rc != 0) { log_err("Falha ao matar PID $pid (permissão?). Pulando.") }
            select(undef,undef,undef, NETSTAT_WAIT_S);
        }
    } else {
        for my $port (sort {$a<=>$b} keys %want) {
            my @pids = `lsof -nP -iTCP:$port -sTCP:LISTEN -t 2>/dev/null`;
            chomp @pids;
            if (!@pids) {
                my @ss = `ss -ltnp 'sport = :$port' 2>/dev/null`;
                for my $ln (@ss) { while ($ln =~ /pid=(\d+)/g) { push @pids, 0+$1 } }
            }
            for my $pid (@pids) {
                next if $pid == $self_pid;
                $pid_to_ports{$pid}{$port} = 1;
            }
        }
        for my $pid (sort {$a<=>$b} keys %pid_to_ports) {
            my $ports = join(',', sort {$a<=>$b} keys %{$pid_to_ports{$pid}});
            log_warn("[port-free] Matando PID $pid (ports: $ports)...");
            kill 9, $pid or log_err("Não foi possível matar PID $pid. Pulando.");
            select(undef,undef,undef, NETSTAT_WAIT_S);
        }
    }
}

sub compute_available_pairs {
    my %cfg = %Poseidon::Config::config;
    my @pairs;

    my $n = scalar @{$cfg{ragnarokserver_ports}};
    my $m = scalar @{$cfg{queryserver_ports}};
    if ($n != $m) {
        die "Config inválida: ragnarokserver_ports ($n) difere de queryserver_ports ($m).\n";
    }

    for (my $i = 0; $i < $n; $i++) {
        my ($ro_p, $qry_p) = ($cfg{ragnarokserver_ports}[$i], $cfg{queryserver_ports}[$i]);

        unless (_valid_port($ro_p) && _valid_port($qry_p)) {
            log_warn("[skip] Par ".($i+1)." possui porta inválida (RO:$ro_p, QRY:$qry_p)");
            next;
        }

        my $ro_ok  = _can_bind($cfg{ragnarokserver_ip}, $ro_p);
        my $qry_ok = _can_bind($cfg{queryserver_ip},    $qry_p);

        if ($ro_ok && $qry_ok) {
            push @pairs, [$ro_p, $qry_p];
        } else {
            my @why;
            push @why, "RO:$cfg{ragnarokserver_ip}:$ro_p" unless $ro_ok;
            push @why, "QRY:$cfg{queryserver_ip}:$qry_p"  unless $qry_ok;
            log_warn("[skip] Par ".($i+1)." indisponível -> ".join(' ', @why));
        }
    }
    return @pairs;
}

sub _pairs_summary_lines {
    my @out;
    for (my $i = 0; $i < @RO_SERVERS; $i++) {
        my $ro = $RO_SERVERS[$i];
        my $qs = $QRY_SERVERS[$i];
        push @out, sprintf("Par %d  RO:%s:%d  <->  QRY:%s:%d",
            $i+1, $ro->getHost(), $ro->getPort(), $qs->getHost(), $qs->getPort());
    }
    return @out;
}

# ------------------------------ Boot -----------------------------------
sub initialize {
    print "\n";
    pretty_banner(
        "Poseidon ".VERSION." - ".BRAND_NAME,
        "Carregando configuração...",
        "Suporte: ".BRAND_SUPPORT,
    );

    Getopt::Long::Configure('default');
    Poseidon::Config::parseArguments();
    Poseidon::Config::parse_config_file($Poseidon::Config::config{file});
    Poseidon::Config::finalize();

    # Sinais para saída limpa
    $SIG{INT}  = sub { log_warn("SIGINT recebido. Finalizando..."); _cleanup_and_exit(0) };
    $SIG{TERM} = sub { log_warn("SIGTERM recebido. Finalizando..."); _cleanup_and_exit(0) };

    free_requested_ports();

    my @pairs = compute_available_pairs();
    if (!@pairs) { die "Nenhum par de portas livre para bind. Ajuste as portas ou rode como Administrador.\n"; }

    log_info("Inicializando servidores (pares: ".scalar(@pairs).")...");
    @RO_SERVERS = ();
    @QRY_SERVERS = ();
    %PAIR_IDX_BY_QRY = ();

    my %cfg = %Poseidon::Config::config;

    for (my $i = 0; $i < @pairs; $i++) {
        my ($ro_p, $qry_p) = @{$pairs[$i]};
        my $ro = Poseidon::RagnarokServer->new($ro_p,  $cfg{ragnarokserver_ip});
        my $qs = Poseidon::QueryServer->new   ($qry_p, $cfg{queryserver_ip}, $ro);

        push @RO_SERVERS,  $ro;
        push @QRY_SERVERS, $qs;

        $PAIR_IDX_BY_QRY{$qs->getHost().":".$qs->getPort()} = $i;

        log_ok(sprintf("Par %d  RO:%s:%d  <->  QRY:%s:%d",
            $i+1, $ro->getHost(), $ro->getPort(), $qs->getHost(), $qs->getPort()));
    }

    if ($cfg{fake_ip}) { log_info("Fake Server IP: $cfg{fake_ip}") }

    my @sum = _pairs_summary_lines();
    pretty_banner(
        "Poseidon ".VERSION." pronto",
        "Debug: ".(($cfg{debug}) ? "On" : "Off"),
        "Pares ativos: ".scalar(@pairs),
        @sum,
        "CTRL+C para sair"
    );
}

# --------------------------- Console loop ------------------------------
sub run_console_loop {
    initialize();
    while (1) {
        for my $ro (@RO_SERVERS)  { $ro->iterate() }
        for my $qs (@QRY_SERVERS) { $qs->iterate() }
        sleep SLEEP_TIME;
    }
}

# ------------------------------ Cleanup --------------------------------
sub _cleanup_and_exit {
    my ($code) = @_;
    log_info("Encerrado (code=$code).");
    exit($code);
}

END { 1 }

# -------------------------------- Main ---------------------------------
run_console_loop();
