package AIChat::APIClient;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON::Tiny qw(decode_json encode_json);
use Log qw(warning message debug);
use Utils qw(dumpHash);
use Globals qw($field);

use AIChat::Config;
use AIChat::ConversationHistory;

my $ua = LWP::UserAgent->new;
$ua->timeout(20); # Aumentar timeout para proxy

sub _normalize_number {
    my ($value, $fallback) = @_;
    return $fallback unless defined $value;
    return $value + 0;
}

sub new {
    my $class = shift;
    my $self = {
        provider => AIChat::Config::get('provider'),
        # Não precisamos mais da API Key aqui, o proxy cuidará disso
        # api_key => AIChat::Config::get('api_key'),
        model => AIChat::Config::get('model'),
        max_tokens => _normalize_number(AIChat::Config::get('max_tokens'), 150),
        temperature => _normalize_number(AIChat::Config::get('temperature'), 0.6),
    };
    bless $self, $class;
    return $self;
}

sub callAPI {
    my ($self, $message, $sender) = @_;

    my $proxy_url = 'http://localhost:3000/proxy'; # URL do seu servidor Node.js

    # Obtém o histórico de conversas do jogador
    my $history = AIChat::ConversationHistory::getHistory($sender);
    
    # Prepara as mensagens incluindo o histórico
    my $prompt = AIChat::Config::get('prompt');
    if (defined $field && ($field->baseName // '') eq 'sec_pri') {
        my $gm_prompt = AIChat::Config::get('prompt_gm');
        $prompt = $gm_prompt if defined $gm_prompt && $gm_prompt ne '';
    }

    my @messages = (
        {
            role => "system",
            content => $prompt
        }
    );

    my $glossary = AIChat::Config::get('glossary');
    if (defined $glossary && $glossary ne '') {
        push @messages, {
            role => "system",
            content => "Glossario do jogo para referencia: $glossary",
        };
    }
    
    # Adiciona o histórico de conversas, garantindo que mensagens do sistema fiquem no início
    my @system_messages = grep { $_->{role} eq "system" } @$history;
    my @other_messages = grep { $_->{role} ne "system" } @$history;
    
    push @messages, @system_messages;
    push @messages, @other_messages;
    
    # Adiciona a mensagem atual
    push @messages, {
        role => "user",
        content => $message
    };

    my $data = {
        provider => $self->{provider}, # Enviar o provedor para o proxy
        model => $self->{model},
        messages => \@messages,
        max_tokens => $self->{max_tokens},
        temperature => $self->{temperature}
    };

    my $json_data = encode_json($data);

    my $request = HTTP::Request->new('POST', $proxy_url);
    $request->header('Content-Type' => 'application/json');
    # $request->header('Authorization' => 'Bearer ' . $self->{api_key}); # Removido, proxy adiciona
    $request->content($json_data);
    
    my $response = $ua->request($request);
    

    if ($response->is_success) {
        my $result = decode_json($response->content);
        # A resposta do proxy já deve ser o conteúdo direto da API de IA
        return $result->{choices}[0]{message}{content};
    } else {
        warning "[aiChat] Proxy request failed: " . $response->status_line . ". Content: " . $response->decoded_content . "\n", "plugin";
        return undef;
    }
}

sub callAPIWithMessages {
    my ($self, $messages, $options) = @_;
    return undef unless $messages && ref $messages eq 'ARRAY';

    my $proxy_url = 'http://localhost:3000/proxy';
    my $data = {
        provider => $self->{provider},
        model => $self->{model},
        messages => $messages,
        max_tokens => $self->{max_tokens},
        temperature => $self->{temperature},
    };

    if ($options && ref $options eq 'HASH') {
        $data->{max_tokens} = _normalize_number($options->{max_tokens}, $data->{max_tokens})
            if defined $options->{max_tokens};
        $data->{temperature} = _normalize_number($options->{temperature}, $data->{temperature})
            if defined $options->{temperature};
    }

    my $json_data = encode_json($data);
    my $request = HTTP::Request->new('POST', $proxy_url);
    $request->header('Content-Type' => 'application/json');
    $request->content($json_data);

    my $response = $ua->request($request);

    if ($response->is_success) {
        my $result = decode_json($response->content);
        return $result->{choices}[0]{message}{content};
    } else {
        warning "[aiChat] Proxy request failed: " . $response->status_line . ". Content: " . $response->decoded_content . "\n", "plugin";
        return undef;
    }
}

# Deixamos as subs originais comentadas para referência
sub _sendOpenAIRequest { die "Not implemented, use proxy."; }
sub _sendDeepSeekRequest { die "Not implemented, use proxy."; }

1; 