#####################################################################
# portalUIClear — após autosell, se move até o portal mais próximo	#
# billabong93														#
#####################################################################

package portalUIClear;
use strict;
use warnings;
use utf8;

use Plugins;
use Globals qw($char $field);
use Log qw(message warning);
use Commands;
use File::Spec;

my $PLUGIN_NAME = 'portalUIClear';
sub _on_ai_sell_auto_done;

my %PORTALS_BY_MAP;
my $PORTALS_LOADED = 0;
my $HOOK_SELL_AUTO_DONE;

$HOOK_SELL_AUTO_DONE = Plugins::addHook('AI_sell_auto_done', \&_on_ai_sell_auto_done);

### utils ###
sub _norm_map {
    my ($m) = @_;
    return '' unless defined $m;
    $m = lc $m;
    $m =~ s/\.(gat|rsw|gnd|fld)$//i;
    return $m;
}

sub _portal_file_path {
    my @candidates = (
        File::Spec->catfile('tables','ROla','portals.txt'),
        File::Spec->catfile('tables','portals.txt'),
    );
    for my $p (@candidates) {
        return $p if -e $p;
    }
    return undef;
}

sub _load_portals_once {
    return if $PORTALS_LOADED;
    my $path = _portal_file_path();
    if (!$path) {
        warning "[$PLUGIN_NAME] Não encontrei tables/ROla/portals.txt nem tables/portals.txt.\n";
        return;
    }
    open my $fh, '<', $path or do {
        warning "[$PLUGIN_NAME] Falha ao abrir $path: $!\n";
        return;
    };
    my $count = 0;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n$//;
        $line =~ s/#.*$//;
        next if $line =~ /^\s*$/;

        my @t = split /\s+/, $line;
        next unless @t == 6;

        my ($sm,$sx,$sy,$dm,$dx,$dy) = @t;
        next unless defined $sm && $sx =~ /^\d+$/ && $sy =~ /^\d+$/;
        next unless defined $dm && $dx =~ /^\d+$/ && $dy =~ /^\d+$/;

        my $smn = _norm_map($sm);
        my $dmn = _norm_map($dm);
        next unless $smn && $dmn;

        push @{ $PORTALS_BY_MAP{$smn} }, { sx => int($sx), sy => int($sy), dmap => $dmn };
        $count++;
    }
    close $fh;
    $PORTALS_LOADED = 1;
}

sub _char_xy {
    return (undef,undef) unless $char;
    my $p = ($char->{pos_to} && defined $char->{pos_to}{x}) ? $char->{pos_to} : $char->{pos};
    return (undef,undef) unless $p && defined $p->{x} && defined $p->{y};
    return (int($p->{x}), int($p->{y}));
}

sub _nearest_portal_xy_for_current_map {
    return (undef,undef,undef) unless $field;
    my $cur_map = _norm_map($field->baseName);
    return (undef,undef,undef) unless $cur_map;

    _load_portals_once();
    my $list = $PORTALS_BY_MAP{$cur_map};
    return (undef,undef,undef) unless $list && @$list;

    my ($cx,$cy) = _char_xy();
    return (undef,undef,undef) unless defined $cx;

    my ($best_x,$best_y,$best_to,$best_d);
    for my $e (@$list) {
        my ($x,$y) = ($e->{sx}, $e->{sy});
        my $d = abs($x - $cx) + abs($y - $cy);
        if (!defined $best_d || $d < $best_d) {
            ($best_x,$best_y,$best_to,$best_d) = ($x,$y,$e->{dmap},$d);
        }
    }
    return ($best_x,$best_y,$best_to);
}

### ação pós-autosell ###
sub after_sell {
    return unless $field;

    my ($x,$y,$to_map) = _nearest_portal_xy_for_current_map();
    unless (defined $x) {
        warning "[$PLUGIN_NAME] Nenhum portal candidato neste mapa ou posição indisponível.\n";
        return;
    }

    message "[$PLUGIN_NAME] Autosell finalizado. Indo ao portal mais próximo em ($x,$y) -> $to_map.\n";
    Commands::run("move $x $y");
}

### hooks AI ###
sub _on_ai_sell_auto_done {
    eval { portalUIClear::after_sell(); 1 } or do {
        warning "[$PLUGIN_NAME] Erro em after_sell: $@\n";
    };
}

### registro ###
Plugins::register(
    $PLUGIN_NAME,
    'Após autosell, move até o portal (warp) mais próximo (ignora NPCs)',
    \&on_unload
);

### unload ###

sub on_unload {
    Plugins::delHook($HOOK_SELL_AUTO_DONE) if $HOOK_SELL_AUTO_DONE;
    message "[$PLUGIN_NAME] Descarregado.\n";
}

1;
