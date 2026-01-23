package AIChat::References;

use strict;
use warnings;

use File::Spec;
use Log qw(warning);
use Plugins ();

my %reference_sets;
my $loaded = 0;

sub _referencesFilePath {
    my $base = $Plugins::current_plugin_folder || File::Spec->catdir("plugins", "aiChat");
    return File::Spec->catfile($base, "config", "references.txt");
}

sub _loadReferences {
    return if $loaded;
    $loaded = 1;
    %reference_sets = ();

    my $file = _referencesFilePath();
    return unless -f $file;

    open my $fh, '<', $file or do {
        warning "[aiChat] Não foi possível ler $file: $!\n", "plugin";
        return;
    };

    my $section = '';
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\r$//;
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        next if $line eq '' || $line =~ /^#/;
        if ($line =~ /^\[(.+)\]$/) {
            $section = $1;
            $reference_sets{$section} ||= [];
            next;
        }
        next unless $section;
        push @{$reference_sets{$section}}, $line;
    }

    close $fh or warning "[aiChat] Não foi possível fechar $file: $!\n", "plugin";
}

sub get {
    my ($section) = @_;
    _loadReferences();
    return @{$reference_sets{$section} || []};
}

1;
