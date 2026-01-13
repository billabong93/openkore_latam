package AIChat::MonsterDB;

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Spec;
use Log qw(warning debug);
use Plugins ();

use AIChat::Config;

my @db_entries;
my $db_loaded = 0;
my $db_mtime = 0;
my $db_path;
my $warned_missing = 0;

my %stopwords = map { $_ => 1 } qw(
    a ao aos as ate com como da das de do dos e eh em era isso me nao no nos
    onde o os ou para pra por que quem se sem sera so ta tava tem tenho ter
    to um uma umas uns voce vc voces vces vamo vamos eu tu ele ela eles elas
    isso isto esse essa esses essas aquele aquela aqueles aquelas minha meu
    meus minhas sua seu seus suas ai chat sabe saber pega pego pegar conseguir
    consigo encontro achar acharam encontrar drop dropa dropam dropar drops
    mapa mapas monstro monstros mob mobs bicho bichos item itens carta cartas
);

sub buildContext {
    my ($message) = @_;
    return unless defined $message && length $message;
    return unless _isMonsterQuery($message);

    my $matches = _findMatches($message);
    if (!$matches || !@$matches) {
        return {
            short_circuit => 1,
            response => 'nao sei',
        };
    }

    my $intro = "Use somente os dados abaixo do mondb.txt para responder sobre monstros, drops ou mapas. Se nao houver informacao exata nos dados, responda \"nao sei\".";
    my $content = join("\n", $intro, map { "- $_" } @$matches);

    return {
        system_message => $content,
    };
}

sub _isMonsterQuery {
    my ($message) = @_;
    my $normalized = _normalizeText($message);
    return 1 if $normalized =~ /\b(quem\s+dropa|onde\s+pego|onde\s+pega|onde\s+consigo|onde\s+conseguir|onde\s+encontro|onde\s+achar|onde\s+dropa)\b/;
    return 1 if $normalized =~ /\b(dropa|drop|drops|dropar|dropam|monstro|mob|bicho|carta|item|farmar)\b/;
    return 1 if $normalized =~ /\bmapa\b/ && $normalized =~ /\b(monstro|mob|drop|dropa|carta|item)\b/;
    return;
}

sub _findMatches {
    my ($message) = @_;
    _loadDB();
    return [] unless @db_entries;

    my $normalized = _normalizeText($message);
    my @terms = _extractTerms($normalized);
    return [] unless @terms;

    my @scored;
    for my $entry (@db_entries) {
        my $score = 0;
        for my $term (@terms) {
            next unless length $term;
            if (index($entry->{normalized}, $term) >= 0) {
                $score++;
            }
        }
        next unless $score;
        push @scored, {
            score => $score,
            raw => $entry->{raw},
            length => $entry->{length},
        };
    }

    @scored = sort {
        $b->{score} <=> $a->{score}
            || $a->{length} <=> $b->{length}
    } @scored;

    my @results = map { $_->{raw} } @scored[0 .. ($#scored > 7 ? 7 : $#scored)];
    return \@results;
}

sub _extractTerms {
    my ($normalized) = @_;
    return () unless defined $normalized && length $normalized;

    my %seen;
    my @terms;
    for my $word (split /\s+/, $normalized) {
        next if $stopwords{$word};
        next if length($word) < 3;
        next if $seen{$word}++;
        push @terms, $word;
    }

    return @terms;
}

sub _normalizeText {
    my ($text) = @_;
    return '' unless defined $text;
    my $normalized = lc $text;
    $normalized =~ tr/áàãâäéèêëíìîïóòõôöúùûüçñ/aaaaaeeeeiiiiooooouuuucn/;
    $normalized =~ s/[^a-z0-9\s]/ /g;
    $normalized =~ s/\s+/ /g;
    $normalized =~ s/^\s+//;
    $normalized =~ s/\s+$//;
    return $normalized;
}

sub _loadDB {
    my $path = _resolveDBPath();
    if (!$path || !-f $path) {
        if (!$warned_missing) {
            warning "[aiChat] mondb.txt nao encontrado. Configure aiChat_mondb_path com o caminho correto.\n", "plugin";
            $warned_missing = 1;
        }
        @db_entries = ();
        $db_loaded = 1;
        $db_path = $path;
        $db_mtime = 0;
        return;
    }

    my $mtime = (stat($path))[9] || 0;
    if ($db_loaded && $db_path && $db_path eq $path && $db_mtime == $mtime) {
        return;
    }

    open my $fh, '<:utf8', $path or do {
        warning "[aiChat] nao foi possivel abrir $path: $!\n", "plugin";
        return;
    };

    my @entries;
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\r$//;
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;
        my $normalized = _normalizeText($line);
        next unless length $normalized;
        push @entries, {
            raw => $line,
            normalized => $normalized,
            length => length($line),
        };
    }
    close $fh;

    @db_entries = @entries;
    $db_loaded = 1;
    $db_path = $path;
    $db_mtime = $mtime;
    $warned_missing = 0 if @db_entries;
    debug "[aiChat] mondb.txt carregado com " . scalar(@db_entries) . " linhas.\n", "plugin";
}

sub _resolveDBPath {
    my $configured = AIChat::Config::get('mondb_path');
    $configured = 'tables/mondb.txt' unless defined $configured && length $configured;

    if (File::Spec->file_name_is_absolute($configured)) {
        return abs_path($configured);
    }

    my @bases;
    if ($Plugins::current_plugin_folder) {
        push @bases, $Plugins::current_plugin_folder;
        push @bases, File::Spec->catdir($Plugins::current_plugin_folder, File::Spec->updir(), File::Spec->updir());
    }
    push @bases, File::Spec->curdir();

    for my $base (@bases) {
        my $candidate = File::Spec->catfile($base, $configured);
        return abs_path($candidate) if -f $candidate;
    }

    return File::Spec->catfile($bases[0] // File::Spec->curdir(), $configured);
}

1;
