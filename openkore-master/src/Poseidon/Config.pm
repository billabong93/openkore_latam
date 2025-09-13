package Poseidon::Config;

use strict;
use warnings;
require Exporter;

our @ISA    = qw(Exporter);
our @EXPORT = qw(%config parseArguments parse_config_file finalize);

our %config = ();

sub parse_config_file {
    my $File = shift;
    my ($Key, $Value);

    # Se já veio tudo por linha de comando, pode pular o arquivo
    if (defined $config{ragnarokserver_ip}    && $config{ragnarokserver_ip} ne '' &&
        defined $config{ragnarokserver_port}  && $config{ragnarokserver_port} ne '' &&
        defined $config{queryserver_ip}       && $config{queryserver_ip} ne '' &&
        defined $config{queryserver_port}     && $config{queryserver_port} ne '' &&
        defined $config{server_type}          && $config{server_type} ne '' &&
        defined $config{debug}) {
        print "\t[debug] Skipping config file\n" if $config{debug};
        return;
    }

    my $CFG;
    if (open($CFG, "<", "../../control/$File")
        or open($CFG, "<", "./control/$File")
        or open($CFG, "<", $File)) {

        while (my $line = <$CFG>) {
            chomp $line;
            $line =~ s/^\s*//;
            $line =~ s/\s*$//;
            next if $line eq '' || $line =~ /^#/;
            ($Key, $Value) = split(/=/, $line, 2);
            next if !defined $Key;
            # Mantém prioridade do CLI
            if (defined $config{$Key} && $config{$Key} ne '') {
                print "\t[debug] Skipping $Key from config file\n" if $config{debug};
                next;
            }
            $config{$Key} = defined($Value) ? $Value : '';
        }
        close($CFG);
    } else {
        die "ERROR: Config file not found : $File";
    }
}

sub parseArguments {
    use Getopt::Long;
    GetOptions(
        'file=s',                 \$config{file},
        'ragnarokserver_ip=s',    \$config{ragnarokserver_ip},
        'ragnarokserver_port=s',  \$config{ragnarokserver_port},
        'queryserver_ip=s',       \$config{queryserver_ip},
        'queryserver_port=s',     \$config{queryserver_port},
        'server_type=s',          \$config{server_type},
        'debug=s',                \$config{debug},
        'fake_ip=s',              \$config{fake_ip},
        # aceita *_ports por CLI também
        'ragnarokserver_ports=s', \$config{ragnarokserver_ports},
        'queryserver_ports=s',    \$config{queryserver_ports},
    );
    $config{file} ||= 'poseidon.txt';
}

# ---------- helpers ----------
sub _parse_ports {
    my ($v) = @_;
    return [] unless defined $v && $v ne '';
    my @raw = ref($v) eq 'ARRAY' ? @$v : split(/\s*,\s*/, $v);
    my %seen;
    my @ports = grep {
        $_ =~ /^\d+$/ && $_ > 0 && $_ < 65536 && !$seen{$_}++
    } map { int($_) } @raw;
    return \@ports;
}

sub _is_local_bind_ip {
    my ($ip) = @_;
    return 1 if !defined $ip || $ip eq '' || $ip eq '0.0.0.0' || $ip eq '127.0.0.1';
    # Fallback simples para redes privadas
    return 1 if $ip =~ /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[0-1])\.)/;
    # Opcional: validar IPs locais no Windows, se Win32::IPHelper existir
    if ($^O =~ /MSWin32/i) {
        eval {
            require Win32::IPHelper;
            my $adapters = Win32::IPHelper::GetAdaptersAddresses();
            for my $ad (@$adapters) {
                next unless $ad->{Unicast};
                for my $u (@{$ad->{Unicast}}) {
                    return 1 if defined $u->{Address} && $u->{Address} eq $ip;
                }
            }
            1;
        };
    }
    return 0;
}

# ---------- FINALIZE: normaliza e valida após carregar tudo ----------
sub finalize {
    # aceita *_ports (lista) ou *_port (CSV), prioriza *_ports
    my $ro_list = exists $config{ragnarokserver_ports} ? $config{ragnarokserver_ports}
                : exists $config{ragnarokserver_port}  ? $config{ragnarokserver_port}
                : '';
    my $qs_list = exists $config{queryserver_ports}    ? $config{queryserver_ports}
                : exists $config{queryserver_port}     ? $config{queryserver_port}
                : '';

    $config{ragnarokserver_ports} = _parse_ports($ro_list);
    $config{queryserver_ports}    = _parse_ports($qs_list);

    # defaults de bind (só se estiverem vazios)
    $config{ragnarokserver_ip} = '0.0.0.0'
        unless defined $config{ragnarokserver_ip} && $config{ragnarokserver_ip} ne '';
    $config{queryserver_ip}    = '127.0.0.1'
        unless defined $config{queryserver_ip} && $config{queryserver_ip} ne '';

    # NÃO forçar override — apenas avisar se parecer não-local
    if (!_is_local_bind_ip($config{ragnarokserver_ip})) {
        warn "Config: ragnarokserver_ip '$config{ragnarokserver_ip}' pode não ser IP local. Tentando mesmo assim.\n";
    }
    if (!_is_local_bind_ip($config{queryserver_ip})) {
        warn "Config: queryserver_ip '$config{queryserver_ip}' pode não ser IP local. Tentando mesmo assim.\n";
    }

    die "Config: ragnarokserver_ports vazio\n" unless @{$config{ragnarokserver_ports}};
    die "Config: queryserver_ports vazio\n"    unless @{$config{queryserver_ports}};

    my $n_ro = @{$config{ragnarokserver_ports}};
    my $n_qs = @{$config{queryserver_ports}};
    die "Config: quantidade de ragnarokserver_ports ($n_ro) difere de queryserver_ports ($n_qs)\n"
        unless $n_ro == $n_qs;
}


1;
