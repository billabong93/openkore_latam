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
sub _on_log_message;

my %PORTALS_BY_MAP;
my $PORTALS_LOADED = 0;
my $HOOK_MESSAGE;
my $HOOK_AI_POST;
my $HOOK_MAP_CHANGED;
my $PENDING_AFTER_SELL = 0;
my $PENDING_RETURN_ROUTE = 0;
my $RETURN_TARGET;
my $RETURN_DISTANCE;
my $RETURN_BUY_ARGS;
my $PENDING_AFTER_SELL_TIME;

$HOOK_MESSAGE      = Log::addHook(\&_on_log_message);
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

sub _buy_target_from_args {
    my ($args) = @_;
    return unless $args && $args->{npc};

    my $npc = $args->{npc};
    return unless $npc->{map} && $npc->{pos};

    my $pos = $npc->{pos};
    return unless defined $pos->{x} && defined $pos->{y};

    return {
        map  => $npc->{map},
        x    => int($pos->{x}),
        y    => int($pos->{y}),
        dist => $args->{distance},
    };
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

### hooks ###
sub _on_log_message {
    my ($type, $domain, undef, undef, $text) = @_;
    return unless defined $type && $type eq 'message';
    return unless defined $domain && $domain eq 'success';
    return if $PENDING_AFTER_SELL || $PENDING_RETURN_ROUTE;

    my $clean = defined $text ? $text : '';
    $clean =~ s/\r?\n$//;
    return unless $clean eq 'Auto-sell sequence completed.'
        || $clean eq "Seqüência de vendas automáticas concluída.";

    $PENDING_AFTER_SELL      = 1;
    $PENDING_AFTER_SELL_TIME = time;
}

sub _on_ai_post {
    return unless $PENDING_AFTER_SELL;
    return if AI::is('sellAuto') || AI::inQueue('sellAuto');

    if (!AI::inQueue('buyAuto')) {
        my $buy_index = AI::findAction('buyAuto');
        unless (defined $buy_index || AI::is('buyAuto')) {
            if (defined $PENDING_AFTER_SELL_TIME && time - $PENDING_AFTER_SELL_TIME > 5) {
                $PENDING_AFTER_SELL      = 0;
                $PENDING_AFTER_SELL_TIME = undef;
            }
        }
        return;
    }

    $PENDING_AFTER_SELL_TIME = undef;

    my $buy_index = AI::findAction('buyAuto');
    return unless defined $buy_index;

    my $buy_args = AI::args($buy_index);
    $RETURN_BUY_ARGS = $buy_args;

    $PENDING_AFTER_SELL = 0;

    my $target = _buy_target_from_args($buy_args);
    if ($target) {
        $RETURN_TARGET   = { map => $target->{map}, x => $target->{x}, y => $target->{y} };
        $RETURN_DISTANCE = $target->{dist};
    } else {
        my ($cx,$cy) = _char_xy();
        my $cur_map = ($field ? _norm_map($field->baseName) : undef);
        if (defined $cur_map && defined $cx && defined $cy) {
            $RETURN_TARGET   = { map => $cur_map, x => $cx, y => $cy };
            $RETURN_DISTANCE = undef;
        } else {
            $RETURN_TARGET   = undef;
            $RETURN_DISTANCE = undef;
        }
    }

    my $moved = eval { portalUIClear::after_sell(); };
    if (!defined $moved && $@) {
        warning "[$PLUGIN_NAME] Erro em after_sell: $@\n";
        $RETURN_TARGET = undef;
        $RETURN_DISTANCE = undef;
        $RETURN_BUY_ARGS = undef;
        $PENDING_RETURN_ROUTE = 0;
        return;
    }
    if ($moved) {
        $PENDING_RETURN_ROUTE = 1;
    } else {
        $RETURN_TARGET = undef;
        $RETURN_DISTANCE = undef;
        $RETURN_BUY_ARGS = undef;
        $PENDING_RETURN_ROUTE = 0;
    }
}

sub _on_map_changed {
    return unless $PENDING_RETURN_ROUTE;
    $PENDING_RETURN_ROUTE = 0;

    my $buy_index = AI::findAction('buyAuto');
    unless (defined $buy_index) {
        $RETURN_TARGET = undef;
        $RETURN_DISTANCE = undef;
        $RETURN_BUY_ARGS = undef;
        return;
    }

    my $args = AI::args($buy_index);
    my $target = _buy_target_from_args($args);
    unless ($target) {
        $target = _buy_target_from_args($RETURN_BUY_ARGS) if $RETURN_BUY_ARGS;
    }
    unless ($target) {
        if ($RETURN_TARGET) {
            $target = { %{$RETURN_TARGET}, dist => $RETURN_DISTANCE };
        } else {
            warning "[$PLUGIN_NAME] Não consegui determinar o NPC de compra para retorno.\n";
            $RETURN_TARGET = undef;
            $RETURN_DISTANCE = undef;
            $RETURN_BUY_ARGS = undef;
            return;
        }
    }

    delete $args->{sentNpcTalk};
    delete $args->{sentNpcTalk_time};
    delete $args->{recv_buyList_time};
    AI::mapChanged($buy_index);

    my $map = $target->{map};
    my $x   = $target->{x};
    my $y   = $target->{y};
    my $dist = $target->{dist};
    $RETURN_TARGET = undef;
    $RETURN_DISTANCE = undef;
    $RETURN_BUY_ARGS = undef;

    return unless defined $map && defined $x && defined $y;

    message "[$PLUGIN_NAME] Retornando ao NPC de compra em $map ($x,$y).\n";
    if (defined $dist && $dist ne '') {
        AI::ai_route($map, $x, $y, attackOnRoute => 1, distFromGoal => $dist);
    } else {
        AI::ai_route($map, $x, $y, attackOnRoute => 1);
    }
}

### registro ###
Plugins::register(
    $PLUGIN_NAME,
    'Após autosell, move até o portal (warp) mais próximo (ignora NPCs)',
    \&on_unload
);

### unload ###

sub on_unload {
    Log::delHook($HOOK_MESSAGE)            if defined $HOOK_MESSAGE;
    Plugins::delHook($HOOK_AI_POST)       if $HOOK_AI_POST;
    Plugins::delHook($HOOK_MAP_CHANGED)   if $HOOK_MAP_CHANGED;
    message "[$PLUGIN_NAME] Descarregado.\n";
}

1;
