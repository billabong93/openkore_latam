package AIChat::Config;

use strict;
use warnings;

use Log qw(warning message debug);
use File::Path qw(make_path);
use File::Spec;
use FileParsers;
use Plugins ();

use constant {
    DEFAULT_API_KEY => "",
    DEFAULT_PROVIDER => "deepseek", # openai ou deepseek
    DEFAULT_MODEL => "deepseek-chat", # gpt-3.5-turbo ou deepseek-chat
    DEFAULT_PROMPT => "voce é um assistente se passando por um jogador dentro do ragnarok online no servidor ROLA (ragnarok latam) sempre responde como se fosse um player mesmo simples direto curto sem enrolar nao escreve certo demais nem usa acento nem pontuacao escreve igual a galera da net evita texto longo responde sempre curto e na lata pode ser seco se a pessoa ficar insistindo ou enchendo o saco saudacoes tipo oi e ae vc responde so com oi e ae tb sem enrolar nao faz piada boba nem tenta ser engraçado usa o historico da conversa pra parecer que vc ta ali jogando mesmo parece jogador de verdade falando no chat do jogo, verifique as Informações do personagem para responder de acordo, então analise o level e classe para por exemplo falar onde upar etc",
    DEFAULT_MAX_TOKENS => 150,
    DEFAULT_TEMPERATURE => 0.6,
    DEFAULT_TYPING_SPEED => 20, # Caracteres por segundo (para simular digitação)
    DEFAULT_SPLIT_CHANCE => 0.2, # Chance de dividir resposta em duas mensagens
    DEFAULT_BUFFER_DELAY => 2, # Segundos para aguardar novas mensagens antes de responder
};

# Use a lexically scoped variable for the package's internal config
my %_aiChatConfig;
my $config_loaded = 0;
my %_file_key_map = (
    aiChat_provider => 'provider',
    aiChat_api_key => 'api_key',
    aiChat_model => 'model',
    aiChat_prompt => 'prompt',
    aiChat_max_tokens => 'max_tokens',
    aiChat_temperature => 'temperature',
    aiChat_typing_speed => 'typing_speed',
    aiChat_split_chance => 'split_chance',
    aiChat_buffer_delay => 'buffer_delay',
);

sub _configFilePath {
    my $base = $Plugins::current_plugin_folder || File::Spec->catdir("plugins", "aiChat");
    return File::Spec->catfile($base, "config.txt");
}

sub _loadFromConfigHash {
    my ($file_config) = @_;
    my @load_order = (
        'aiChat_provider',
        'aiChat_model',
        'aiChat_api_key',
        'aiChat_prompt',
        'aiChat_max_tokens',
        'aiChat_temperature',
        'aiChat_typing_speed',
        'aiChat_split_chance',
        'aiChat_buffer_delay',
    );

    for my $file_key (@load_order) {
        next unless exists $file_config->{$file_key};
        my $internal_key = $_file_key_map{$file_key};
        next unless $internal_key;
        _applyValue($internal_key, $file_config->{$file_key});
    }
}

sub _applyValue {
    my ($key, $value) = @_;
    return unless exists $_aiChatConfig{$key};

    if ($key eq 'provider') {
        return unless $value =~ /^(openai|deepseek)$/;
        if ($value eq 'openai') {
            $_aiChatConfig{model} = 'gpt-3.5-turbo';
        } else {
            $_aiChatConfig{model} = 'deepseek-chat';
        }
    } elsif ($key eq 'typing_speed') {
        return unless $value =~ /^\d+$/;
    } elsif ($key eq 'max_tokens') {
        return unless $value =~ /^\d+$/;
    } elsif ($key eq 'temperature') {
        return unless $value =~ /^-?\d+(?:\.\d+)?$/;
    } elsif ($key eq 'split_chance') {
        return unless $value =~ /^-?\d+(?:\.\d+)?$/;
        return if $value < 0 || $value > 1;
    } elsif ($key eq 'buffer_delay') {
        return unless $value =~ /^\d+(?:\.\d+)?$/;
    }

    $_aiChatConfig{$key} = $value;
    return 1;
}

# Initialize internal config with defaults
BEGIN {
    %_aiChatConfig = (
        provider => DEFAULT_PROVIDER,
        api_key => DEFAULT_API_KEY,
        model => DEFAULT_MODEL,
        prompt => DEFAULT_PROMPT,
        max_tokens => DEFAULT_MAX_TOKENS,
        temperature => DEFAULT_TEMPERATURE,
        typing_speed => DEFAULT_TYPING_SPEED,
        split_chance => DEFAULT_SPLIT_CHANCE,
        buffer_delay => DEFAULT_BUFFER_DELAY,
    );
}

sub load {
    my $config_file = _configFilePath();
    if (-f $config_file) {
        my %file_config;
        return unless FileParsers::parseConfigFile($config_file, \%file_config, 1);
        _loadFromConfigHash(\%file_config);
        $config_loaded = 1;
        return;
    }

    $config_loaded = 1;
}

sub save {
    my $config_file = _configFilePath();
    my (undef, $dir, undef) = File::Spec->splitpath($config_file);
    if ($dir && !-d $dir) {
        make_path($dir);
    }
    open my $fh, '>', $config_file or do {
        warning "[aiChat] Não foi possível salvar $config_file: $!\n", "plugin";
        return;
    };

    print $fh "aiChat_provider $_aiChatConfig{provider}\n";
    print $fh "aiChat_api_key $_aiChatConfig{api_key}\n";
    print $fh "aiChat_model $_aiChatConfig{model}\n";
    print $fh "aiChat_prompt $_aiChatConfig{prompt}\n";
    print $fh "aiChat_max_tokens $_aiChatConfig{max_tokens}\n";
    print $fh "aiChat_temperature $_aiChatConfig{temperature}\n";
    print $fh "aiChat_typing_speed $_aiChatConfig{typing_speed}\n";
    print $fh "aiChat_split_chance $_aiChatConfig{split_chance}\n";
    print $fh "aiChat_buffer_delay $_aiChatConfig{buffer_delay}\n";
    close $fh or warning "[aiChat] Não foi possível fechar $config_file: $!\n", "plugin";
}

sub get {
    my ($key) = @_;
    return $_aiChatConfig{$key};
}

sub set {
    my ($key, $value) = @_;
    load() unless $config_loaded;
    return unless _applyValue($key, $value);
    save();
    return 1; # Indicate success
}

1; 
