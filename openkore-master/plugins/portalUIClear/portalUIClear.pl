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
use AI;
use Log qw(message warning);
use Commands;
use File::Spec;

my $PLUGIN_NAME = 'portalUIClear';
sub _on_ai_sell_auto_done;

my %PORTALS_BY_MAP;
my $PORTALS_LOADED = 0;
my $HOOK_SELL_AUTO_DONE;
my $HOOK_AI_POST;
my $HOOK_MAP_CHANGED;
my $PENDING_AFTER_SELL = 0;
my $PENDING_RETURN_ROUTE = 0;
my $RETURN_TARGET;

$HOOK_SELL_AUTO_DONE = Plugins::addHook('AI_sell_auto_done', \&_on_ai_sell_auto_done);
$HOOK_AI_POST       = Plugins::addHook('AI_post', \&_on_ai_post);
$HOOK_MAP_CHANGED   = Plugins::addHook('packet/map_changed', \&_on_map_changed);

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
    return 0 unless $field;

    my ($x,$y,$to_map) = _nearest_portal_xy_for_current_map();
    unless (defined $x) {
        warning "[$PLUGIN_NAME] Nenhum portal candidato neste mapa ou posição indisponível.\n";
        return 0;
    }

    message "[$PLUGIN_NAME] Autosell finalizado. Indo ao portal mais próximo em ($x,$y) -> $to_map.\n";
    Commands::run("move $x $y");
    return 1;
}

### hooks AI ###
sub _on_ai_sell_auto_done {
    return unless AI::inQueue('buyAuto');
    $PENDING_AFTER_SELL = 1;
}

sub _on_ai_post {
    return unless $PENDING_AFTER_SELL;
    return if AI::is('sellAuto') || AI::inQueue('sellAuto');
    return unless AI::inQueue('buyAuto');

    $PENDING_AFTER_SELL = 0;

    my ($cx,$cy) = _char_xy();
    my $cur_map = ($field ? _norm_map($field->baseName) : undef);
    if (defined $cur_map && defined $cx && defined $cy) {
        $RETURN_TARGET = { map => $cur_map, x => $cx, y => $cy };
    } else {
        $RETURN_TARGET = undef;
    }

    my $moved = eval { portalUIClear::after_sell(); };
    if (!defined $moved && $@) {
        warning "[$PLUGIN_NAME] Erro em after_sell: $@\n";
        $RETURN_TARGET = undef;
        $PENDING_RETURN_ROUTE = 0;
        return;
    }
    if ($moved) {
        $PENDING_RETURN_ROUTE = 1 if $RETURN_TARGET;
    } else {
        $RETURN_TARGET = undef;
        $PENDING_RETURN_ROUTE = 0;
    }
}

sub _on_map_changed {
    return unless $PENDING_RETURN_ROUTE;
    $PENDING_RETURN_ROUTE = 0;
    return unless $RETURN_TARGET;

    my $buy_index = AI::findAction('buyAuto');
    unless (defined $buy_index) {
        $RETURN_TARGET = undef;
        return;
    }

    my $args = AI::args($buy_index);
    delete $args->{sentNpcTalk};
    delete $args->{sentNpcTalk_time};
    delete $args->{recv_buyList_time};
    AI::mapChanged($buy_index);

    my $map = $RETURN_TARGET->{map};
    my $x   = $RETURN_TARGET->{x};
    my $y   = $RETURN_TARGET->{y};
    $RETURN_TARGET = undef;

    return unless defined $map && defined $x && defined $y;

    message "[$PLUGIN_NAME] Retornando ao NPC de compra em $map ($x,$y).\n";
    AI::ai_route($map, $x, $y, attackOnRoute => 1);
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
    Plugins::delHook($HOOK_AI_POST)       if $HOOK_AI_POST;
    Plugins::delHook($HOOK_MAP_CHANGED)   if $HOOK_MAP_CHANGED;
    message "[$PLUGIN_NAME] Descarregado.\n";
}

1;
