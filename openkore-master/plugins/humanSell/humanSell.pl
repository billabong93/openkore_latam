############################################
# humanSell — força autosell a simular comandos manuais
# billabong93
############################################
package humanSell;
use strict;
use warnings;
use utf8;

use Plugins;
use Globals qw(%config $char);
use Log qw(message debug warning error);
use Time::HiRes qw(time);
use Commands;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# --------- Local config (na mesma pasta do plugin) ---------
my $PLUGIN_DIR = eval { dirname(abs_path(__FILE__)) } || '.';
my @CONF_CANDIDATES = (
    "$PLUGIN_DIR/humanSell.config.txt",
    "$PLUGIN_DIR/config.txt",
);
my %hs_conf;

sub _load_local_conf {
    my %h;
    for my $file (@CONF_CANDIDATES) {
        next unless -e $file;
        if (open my $fh, '<:encoding(UTF-8)', $file) {
            while (my $line = <$fh>) {
                $line =~ s/\r?\n$//;
                $line =~ s/^\s+|\s+$//g;
                next if $line eq '' || $line =~ /^(#|;)/;
                $line =~ s/[#;].*$//;
                next if $line eq '';
                if ($line =~ /^([A-Za-z0-9_.:-]+)\s+(.*)$/) {
                    my ($k,$v) = ($1,$2);
                    $v =~ s/^\s+|\s+$//g;
                    $h{$k} = $v;
                }
            }
            close $fh;
            debug "[humanSell] Usando config local: $file\n", "ai";
            last;
        }
    }
    %hs_conf = %h;
}
_load_local_conf();

# Helpers de leitura
sub _conf_raw {
    my ($k) = @_;
    return $hs_conf{$k} if exists $hs_conf{$k};
    return $config{$k}  if exists $config{$k}; # fallback global
    return undef;
}

sub _conf_num {
    my ($k, $def) = @_;
    my $v = _conf_raw($k);
    return $def unless defined $v;
    $v =~ s/[#;].*$//;
    $v =~ s/^\s+|\s+$//g;
    my ($n) = $v =~ /(-?\d+(?:\.\d+)?)/;
    return defined $n ? 0 + $n : $def;
}

sub _conf_bool {
    my ($k, $def) = @_;
    my $v = _conf_raw($k);
    return $def unless defined $v;
    $v =~ s/[#;].*$//;
    $v =~ s/^\s+|\s+$//g;
    return 1 if $v =~ /^(1|true|on|yes)$/i;
    return 0 if $v =~ /^(0|false|off|no)$/i;
    return $def;
}

# Recarregar config local sem reiniciar
Commands::register(
    ['hsreload', 'Recarrega config local do humanSell', sub {
        _load_local_conf();
        my $hz = _conf_num('sellAuto_humanDelay', 1.0);
        my $on = _conf_bool('sellAuto_humanize', 1);
        message sprintf("[humanSell] Config recarregada: sellAuto_humanize=%d, sellAuto_humanDelay=%.2fs\n", $on, $hz), "info";
    }]
);

# --------- Estado do envio manual ---------
my $hs_running = 0;
my $hs_last    = 0;
my $hs_delay   = 1.0;
my @hs_queue   = ();

# Hook para disparar os envios com delay
my $hk_ai_pre = Plugins::addHook('AI_pre', \&on_ai_pre);

# Patch
BEGIN {
    no strict 'refs';
    no warnings 'redefine';

    eval "require AI::CoreLogic;";
    if ($@) {
        die "[humanSell] Falha ao carregar AI::CoreLogic: $@";
    }

    # Original
    *AI::CoreLogic::completeNpcSell_ORIG = \&AI::CoreLogic::completeNpcSell;

    # Substituto
    *AI::CoreLogic::completeNpcSell = sub {
        my ($list_ref) = @_;

        # Se desativado na config local, use o original
        unless (_conf_bool('sellAuto_humanize', 1)) {
            return AI::CoreLogic::completeNpcSell_ORIG(@_);
        }

        # Monta fila manual com base no inventário atual
        my %want;
        for my $e (@{$list_ref||[]}) {
            next unless ref $e eq 'HASH';
            my $id  = $e->{ID};
            my $amt = $e->{amount} // 0;
            next unless defined $id && $amt > 0;
            $want{$id} = $amt;
        }

        @hs_queue = ();
        for my $it (@{$char->inventory}) {
            next unless exists $want{$it->{ID}};
            my $amt = $want{$it->{ID}};
            push @hs_queue, [ $it->{binID}, $amt, $it->nameString ];
        }

        if (!@hs_queue) {
            debug "[humanSell] Fila vazia; executando completeNpcSell original.\n", "ai";
            return AI::CoreLogic::completeNpcSell_ORIG(@_);
        }

        $hs_delay   = _conf_num('sellAuto_humanDelay', 1.0);
        $hs_last    = time - $hs_delay;
        $hs_running = 1;

        message sprintf("[humanSell] Venda humanizada: %d item(ns), delay %.2fs.\n", scalar(@hs_queue), $hs_delay), "info";

        # Não chama o original # AI continuará o fluxo após 'sell done'
        return;
    };
}

sub on_ai_pre {
    return unless $hs_running;

    my $now = time();
    return if ($now - $hs_last) < $hs_delay;

    if (@hs_queue) {
        my ($binID, $amount, $name) = @{ shift @hs_queue };
        $name //= '';
        Commands::run(sprintf("sell %d %d", $binID, $amount));
        debug sprintf("[humanSell] Added to sell list: %s (%d) x %d\n", $name, $binID, $amount), "ai";
        $hs_last = $now;
        return;
    }

    # Terminou a fila -> finaliza
    Commands::run("sell done");
    debug "[humanSell] 'sell done' enviado.\n", "ai";

    # limpa estado
    $hs_running = 0;
    $hs_last    = 0;
    @hs_queue   = ();
}

Plugins::register('humanSell', 'Autosell manual com delay por item', sub {
    Plugins::delHook($hk_ai_pre) if $hk_ai_pre;
});

1;
