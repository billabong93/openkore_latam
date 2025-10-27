###########################################################
# Poseidon server
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# Copyright (c) 2005-2006 OpenKore Development Team
#
# Credits:
# isieo - schematic of XKore 2 and other interesting ideas
# anonymous person - beta-testing
# kaliwanagan - original author
# illusionist - bRO support
###########################################################

package Poseidon::Config;

use strict;
use FindBin qw($RealBin);
require Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(%config);

our %config = ();

# Function to Parse the Environment Variables
sub parse_config_file {
    my $File = shift;
    my ($Key, $Value);

    # Caminhos de busca baseados na localizacao do script
    my @search_paths = (
        "$RealBin/../../control/$File",  # Caminho absoluto relativo ao script
        "../../control/$File",            # Compatibilidade: dois niveis acima
        "./control/$File",                # Compatibilidade: diretorio atual
        $File                             # Caminho direto
    );

    my $opened = 0;
    foreach my $path (@search_paths) {
        if (open (CONFIG, "<", $path)) {
            print "\t[debug] Config file found at: $path\n" if $config{debug};
            $opened = 1;
            last;
        }
    }

    unless ($opened) {
        die "ERROR: Config file not found: $File\n" .
            "Searched in:\n" . join("\n", map { "  - $_" } @search_paths) . "\n";
    }

    while (my $line = <CONFIG>) {
        chomp ($line);
        $line =~ s/^\s*//;
        $line =~ s/\s*$//;

        if ($line !~ /^#/ && $line ne "") {
            ($Key, $Value) = split (/=/, $line, 2);

            if ($config{$Key} ne "") {
                print "\t[debug] Skipping ".$Key." key in config file\n" if $config{debug};
                next;
            }

            $config{$Key} = $Value;
        }
    }

    close(CONFIG);
}

sub parseArguments {
    use Getopt::Long;
    GetOptions(
        'file=s',                   \$config{file},
        'ragnarokserver_ip=s',      \$config{ragnarokserver_ip},
        'ragnarokserver_ports=s',   \$config{ragnarokserver_ports},
        'queryserver_ip=s',         \$config{queryserver_ip},
        'queryserver_ports=s',      \$config{queryserver_ports},
        'server_type=s',            \$config{server_type},
        'fake_ip=s',                \$config{fake_ip},
        'debug=s',                  \$config{debug},
    );

    $config{file} = "hydra.txt" if ($config{file} eq "");
}

sub finalize {
    # Converte strings de portas CSV em arrays
    if (defined $config{ragnarokserver_ports} && !ref($config{ragnarokserver_ports})) {
        my @ports = split(/,/, $config{ragnarokserver_ports});
        s/^\s+|\s+$//g for @ports;  # Remove espacos
        $config{ragnarokserver_ports} = \@ports;
    }

    if (defined $config{queryserver_ports} && !ref($config{queryserver_ports})) {
        my @ports = split(/,/, $config{queryserver_ports});
        s/^\s+|\s+$//g for @ports;  # Remove espacos
        $config{queryserver_ports} = \@ports;
    }

    # Garante arrays vazios se nao definidos
    $config{ragnarokserver_ports} ||= [];
    $config{queryserver_ports}    ||= [];

    # Valores padrao
    $config{ragnarokserver_ip} ||= '127.0.0.1';
    $config{queryserver_ip}    ||= '127.0.0.1';
    $config{server_type}       ||= 'Default';
    $config{debug}             ||= 0;
    $config{fake_ip}           ||= '';
}

1;
