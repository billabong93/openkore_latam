package AIChat::ConversationHistory;

use strict;
use warnings;

use Log qw(warning message debug);

sub _profileKey {
    my $profile = 'default';
    if (defined $profiles::profile && length $profiles::profile) {
        $profile = $profiles::profile;
    }
    return $profile;
}

sub _historyKey {
    my ($player) = @_;
    return _profileKey() . ":" . $player;
}

# Hash para armazenar o histórico de conversas por jogador
my %conversation_history;

# Número máximo de mensagens a manter no histórico por jogador
use constant MAX_HISTORY => 10;

sub addMessage {
    my ($player, $role, $content) = @_;
    
    # Inicializa o histórico do jogador se não existir
    my $key = _historyKey($player);
    if (!exists $conversation_history{$key}) {
        $conversation_history{$key} = [];
    }
    
    # Adiciona a nova mensagem
    push @{$conversation_history{$key}}, {
        role => $role,
        content => $content
    };
    
    # Mantém apenas as últimas MAX_HISTORY mensagens
    if (scalar @{$conversation_history{$key}} > MAX_HISTORY) {
        shift @{$conversation_history{$key}};
    }
}

sub getHistory {
    my ($player) = @_;
    
    # Retorna o histórico do jogador ou array vazio se não existir
    my $key = _historyKey($player);
    return exists $conversation_history{$key} ? $conversation_history{$key} : [];
}

sub clearHistory {
    my ($player) = @_;
    
    my $key = _historyKey($player);
    if (exists $conversation_history{$key}) {
        delete $conversation_history{$key};
    }
}

1; 