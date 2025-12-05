
# ============================================================================
# webDashboard.pl - Dashboard Web para OpenKore
# ============================================================================
# Plugin que fornece uma interface web para monitorar e controlar o OpenKore
# através de um servidor HTTP local com dashboard interativo.
# ============================================================================
#
# Créditos:
# - Criado por: Celtos - Openkore.com.br
# - Modificado por: JC - Ue?ComoAssim!?
#
# ============================================================================

package webDashboard;

# ============================================================================
# SEÇÃO 1: IMPORTS E DEPENDÊNCIAS
# ============================================================================

use utf8;
use strict;
use warnings;
use POSIX qw(:errno_h);
use Encode qw(encode_utf8 encode decode is_utf8);
use Plugins;
use Globals qw(
    $char $field $net
    $playersList $monstersList $npcsList $portalsList
    $messageSender %monsters_old
    $totalBaseExp $totalJobExp $startTime_EXP $startingzeny
    %config %jobs_lut
);

use Log qw(message warning error debug);
use Utils;
use Network;
use Field;
use Time::HiRes qw(time);
use IO::Socket::INET;
use JSON;
use Commands;
use AI;
use Settings;
use Scalar::Util qw(blessed);

# ============================================================================
# SEÇÃO 2: FUNÇÕES AUXILIARES DE CONVERSÃO
# ============================================================================

# Converte valor para inteiro de forma segura (retorna 0 se undefined)
sub _i   { my $v = shift; return defined $v ? int($v) : 0 }

# Normaliza strings (UTF-8, ISO-8859-1, etc) - Melhorado para ABNT-2
# Baseado na implementação de consolebridge.pl para maior compatibilidade
sub normalize_string {
    my ($text) = @_;
    return "" unless defined $text;
    $text = "$text" if ref($text);
    $text =~ s/\x00//g;
    return $text if is_utf8($text);

    my $decoded;
    eval { $decoded = decode('ISO-8859-1', $text) };
    if ($@ or not defined $decoded) {
        eval { $decoded = decode('UTF-8', $text) };
    }
    if ($@ or not defined $decoded) {
        eval {
            # Tentativa de correção para dupla codificação
            $decoded = decode('UTF-8', encode('ISO-8859-1', $text), Encode::FB_CROAK);
        };
    }
    
    # Retorna o resultado ou o texto original
    return $decoded || $text;
}

# Formata tempo em formato legível
sub format_time {
    my ($seconds) = @_;
    return "0s" if $seconds <= 0;
    
    my $days = int($seconds / 86400);
    $seconds %= 86400;
    my $hours = int($seconds / 3600);
    $seconds %= 3600;
    my $minutes = int($seconds / 60);
    $seconds %= 60;
    
    my $result = '';
    $result .= "${days}d " if $days > 0;
    $result .= "${hours}h " if $hours > 0;
    $result .= "${minutes}m " if $minutes > 0;
    $result .= "${seconds}s" if $seconds > 0 || (!$days && !$hours && !$minutes);
    
    return $result;
}

# Função auxiliar para obter nome de monstro de forma segura
sub get_monster_name {
    my ($monster) = @_;
    return '' unless $monster;
    
    my $name = '';
    eval {
        $name = $monster->name if blessed($monster) && $monster->can('name');
        $name ||= $monster->{name} if defined $monster->{name};
        $name ||= $monster->{name_given} if defined $monster->{name_given};
    };

    if (!$name) {
        my $nid = get_monster_nameID($monster);
        $name = $nid ? "Monster_$nid" : "Unknown Monster";
    }
    
    $name = normalize_string($name) if $name;
    return $name || '';
}

# Função auxiliar para obter nameID de monstro de forma segura
sub get_monster_nameID {
    my ($monster) = @_;
    return 0 unless $monster;
    
    if (defined $monster->{nameID} && $monster->{nameID} > 0) {
        return _i($monster->{nameID});
    } elsif (defined $monster->{binType} && $monster->{binType} > 0) {
        return _i($monster->{binType});
    } elsif (defined $monster->{type} && $monster->{type} > 0) {
        return _i($monster->{type});
    }
    
    return 0;
}

# Função auxiliar para obter nome de item de forma robusta
# EXATAMENTE como no consolebridge.pl
sub get_item_name {
    my ($item) = @_;
    return '' unless $item;
    
    my $name = '';
    
    # EXATAMENTE como consolebridge.pl: tenta método name() primeiro
    $name = eval { $item->name() } if blessed($item) && $item->can('name');
    
    # Se não tem, tenta do hash (OpenKore já processa e armazena em $item->{name})
    $name ||= eval { $item->{name} } || '';
    
    # Último recurso: usa nameID
    if (!$name) {
        my $nid = eval { $item->{nameID} } // 0;
        $name = $nid ? "Item_$nid" : "Unknown Item";
    }

    # Normaliza o nome do item (ABNT-2) - EXATAMENTE como consolebridge.pl
    $name = normalize_string($name) if $name;
    
    return $name || '';
}


# ============================================================================
# SEÇÃO 3: REGISTRO DO PLUGIN E HOOKS
# ============================================================================

Plugins::register('webDashboard', 'Dashboard Web para OpenKore', \&onUnload);

my $hooks = Plugins::addHooks(
    ['start3',           \&onStart,       undef],
    ['mainLoop_pre',     \&onLoop,        undef],
    ['packet_skill_use', \&onSkillUse,    undef],
    ['packet_attack',    \&onAttack,      undef],
    ['packet_mapChange', \&onMapChange,   undef],
    ['packet_dead',      \&onPlayerDead,  undef],
    ['packet_stat_info', \&on_stat_info,  undef],  # Para detectar ganhos de EXP
    ['monster_disappeared', \&on_monster_disappeared, undef],  # Para capturar dados do monstro antes de ser removido
    ['item_gathered',    \&on_item_gathered, undef],  # Para detectar itens coletados
    ['charinfo',         \&on_char_select, undef],  # Para solicitar informações da guilda ao selecionar personagem
    ['charUpdated',      \&on_char_select, undef],  # Para solicitar informações da guilda quando personagem é atualizado
    ['net_state_changed', \&on_net_state_change, undef],  # Para solicitar informações da guilda ao entrar no jogo

    # Hooks de chat (necessários para popular /api/chat)
    ['packet_pubMsg',    \&onChatPublic,  undef],
    ['packet_privMsg',   \&onChatPrivate, undef],
    ['packet_selfChat',  \&onChatSelf,    undef],
    ['packet_partyMsg',  \&onChatParty,   undef],
    ['packet_guildMsg',  \&onChatGuild,   undef],
);

# Hook para contar desconexões
Plugins::addHook('disconnected', \&on_disconnected);

# ============================================================================
# SEÇÃO 4: VARIÁVEIS GLOBAIS E CONFIGURAÇÃO
# ============================================================================

my $server_socket;
my $central_socket;  # Socket para porta 8888 (página central)
my $port = 8888;
my $host = '127.0.0.1';
my $max_port_tries = 10;

my @chat_messages = ();
my $max_chat = 500;

my %session_stats = (
    start_time => time(),
    exp_start => 0,
    zeny_start => 0,
    kills => 0,
    deaths => 0,
    items_collected => 0,
    damage_dealt => 0,
    damage_received => 0,
    skills_used => 0,
    last_update => time(),
    last_level => 0,  # Último nível conhecido para detectar level up
);

# Variáveis para tracking de monstros mortos (separado entre seus kills e party kills)
my @monsters_Killed = ();        # Array de { nameID, name, count, exp_gained, ... } - MONSTROS QUE VOCÊ MATOU
my @monsters_Killed_party = ();  # Array de { nameID, name, count, exp_gained, ... } - MONSTROS QUE A PARTY MATOU
my $last_exp = 0;                # Última EXP conhecida para detectar ganhos
my $last_target_id = undef;      # ID do último monstro atacado

# Cache de monstros atacados recentemente (para identificar quando morrem)
# ID => { name, nameID, level, last_attack_time, dmgFromYou, dmgFromParty }
my %monster_attack_cache = ();
my $CACHE_EXPIRE_TIME = 10;     # Segundos para expirar cache

# Histórico de drops de itens (separado entre seus kills e party)
my @items_dropped_your = ();    # Array de { nameID, name, amount, monster_name, ... } - ITENS DE SEUS KILLS
my @items_dropped_party = ();   # Array de { nameID, name, amount, monster_name, ... } - ITENS DA PARTY
# Cache de monstros mortos recentemente para associar drops aos monstros (últimos 5 segundos)
my %recent_killed_monsters = ();
my $RECENT_KILL_CACHE_TIME = 5; # Segundos para manter cache de monstros mortos recentes

# Variáveis para estatísticas de experiência
my $initialBaseExp = 0;
my $initialJobExp = 0;
my $initialBaseLevel = 0;
my $initialJobLevel = 0;
my $dc_count = 0;  # Contador de desconexões

my $log_hook;

# Variáveis para solicitação automática de informações da guilda
my $guild_info_requested = 0;    # Flag: já solicitamos informações da guilda?
my $last_guild_request_time = 0; # Última vez que solicitamos informações
my $GUILD_REQUEST_INTERVAL = 30; # Intervalo mínimo entre solicitações (segundos)

# Cache para melhor performance
my %cache = (
    last_update => 0,
    cache_duration => 0.5,
    last_character_data => {},
    last_map_data => {},
);

# ============================================================================
# SEÇÃO 5: CALLBACKS DE CICLO DE VIDA DO PLUGIN
# ============================================================================

sub onUnload {
    Plugins::delHooks($hooks);
    if ($log_hook) {
        Log::delHook($log_hook);
    }
    stop_server();
    message "[webDashboard] Plugin descarregado.\n";
}

sub onStart {
    message "[webDashboard] Iniciando servidor web...\n";
    start_server();
    start_central_server();  # Tenta iniciar servidor central na 8888
    
    $log_hook = Log::addHook(\&onLogMessage);
    
    # Inicializa histórico de monstros mortos e drops
    @monsters_Killed = ();
    @monsters_Killed_party = ();
    @items_dropped_your = ();
    @items_dropped_party = ();
    $last_exp = 0;
    $last_target_id = undef;
    %monster_attack_cache = ();
    %recent_killed_monsters = ();
    
    # Inicializa flags de solicitação de informações da guilda
    $guild_info_requested = 0;
    $last_guild_request_time = 0;
    
    if ($char) {
        $session_stats{exp_start} = $char->{exp} || 0;
        $session_stats{zeny_start} = $char->{zeny} || 0;
        $session_stats{base_level_start} = $char->{lv} || 0;
        $session_stats{job_level_start} = $char->{lv_job} || 0;
        $session_stats{last_level} = $char->{lv} || 0;
        
        $initialBaseExp = $char->{exp} || 0;
        $initialJobExp = $char->{exp_job} || 0;
        $initialBaseLevel = $char->{lv} || 0;
        $initialJobLevel = $char->{lv_job} || 0;
        $last_exp = $char->{exp} || 0;
        
        # Inicializa variáveis globais do OpenKore se necessário
        $startTime_EXP = time() unless defined $startTime_EXP && $startTime_EXP > 0;
        $totalBaseExp = 0 unless defined $totalBaseExp;
        $totalJobExp = 0 unless defined $totalJobExp;
        $startingzeny = $char->{zeny} || 0 unless defined $startingzeny && $startingzeny > 0;
    }
}

# ============================================================================
# SEÇÃO 6: CALLBACKS DE EVENTOS DO JOGO
# ============================================================================

sub onLoop {
    return unless ($net && $net->getState() == Network::IN_GAME && $char);
    
    # Detecta mudanças de EXP (fallback - importante para garantir que kills sejam contabilizados)
    if ($char && defined $char->{exp}) {
        my $current_exp = $char->{exp} || 0;
        my $current_level = $char->{lv} || 0;
        my $last_level = $session_stats{last_level} || $current_level;
        
        # Inicializa last_exp se ainda não foi inicializado
        if ($last_exp == 0 && $current_exp > 0) {
            $last_exp = $current_exp;
            $session_stats{last_level} = $current_level;
        }
        
        # Se o nível aumentou, apenas atualiza referências (o ganho de EXP já foi detectado antes)
        if ($current_level > $last_level) {
            $last_exp = $current_exp;
            $session_stats{last_level} = $current_level;
        } elsif ($last_exp > 0 && $current_exp > $last_exp) {
            # Ganho normal de EXP (sem level up)
            my $exp_gained = $current_exp - $last_exp;
            if ($exp_gained > 0) {
                register_monster_kill($exp_gained);
            }
            $last_exp = $current_exp;
        } elsif ($current_exp < $last_exp && $current_level == $last_level) {
            # EXP diminuiu sem level up (pode ser reset ou erro) - atualiza last_exp mas não registra kill
            $last_exp = $current_exp;
        }
    }
    
    # Atualiza cache de monstros atacados
    if ($char && $monstersList) {
        my $current_target_id = undef;
        if ($char->{attackTarget}) {
            $current_target_id = $char->{attackTarget};
        } elsif ($char->{target} && ref($char->{target})) {
            $current_target_id = eval { $char->{target}->{ID} } // undef;
        }
        
        if ($current_target_id && $monstersList->can('getByID')) {
            my $monster = eval { $monstersList->getByID($current_target_id) };
            if ($monster) {
                my $nameID = get_monster_nameID($monster);
                my $name = get_monster_name($monster);
                $monster_attack_cache{$current_target_id} = {
                    name => $name || "Unknown Monster",
                    nameID => $nameID,
                    level => _i($monster->{lv}),
                    last_attack_time => time(),
                    dead => 0,
                };
            }
        }
        
        $last_target_id = $current_target_id;
    }
    
    # Limpa cache expirado periodicamente
    cleanup_expired_cache();
    
    # Solicita informações da guilda automaticamente se necessário
    # Verifica se está em uma guilda mas ainda não tem informações completas
    if ($char && $char->{guildID}) {
        my $current_time = time();
        if (!$guild_info_requested || ($current_time - $last_guild_request_time) > $GUILD_REQUEST_INTERVAL) {
            # Verifica se realmente precisa solicitar (não tem membros ou informações incompletas)
            if (!%::guild || !$::guild{name} || !$::guild{member} || @{$::guild{member} || []} == 0) {
                request_guild_info(0);
            }
        }
    }
    
    # Processa requisições do servidor principal
    if ($server_socket) {
        my $client = $server_socket->accept();
        if ($client) {
            process_client_request($client);
        }
    }
    
    # Processa requisições do servidor central (8888)
    if ($central_socket) {
        my $client = $central_socket->accept();
        if ($client) {
            process_client_request($client);
        }
    }
}

# Processa requisição HTTP de um cliente conectado
# Lê a requisição completa (headers + body) e roteia para o handler apropriado
sub process_client_request {
    my ($client) = @_;
    
    # Configura socket como não-bloqueante para leitura
    eval {
        $client->blocking(0);
    };
    
    my $request = '';
    my $start_time = time();
    my $timeout = 0.5;  # Timeout de 500ms para ler a requisição completa
    
    while (time() - $start_time < $timeout) {
        my $buffer;
        my $bytes = sysread($client, $buffer, 4096);
        
        if (defined $bytes && $bytes > 0) {
            $request .= $buffer;
            last if $request =~ /\r?\n\r?\n/;
        } elsif (!defined $bytes && $! != POSIX::EWOULDBLOCK && $! != POSIX::EAGAIN) {
            close($client);
            return;
        }
        
        select(undef, undef, undef, 0.01);
    }
    
    return unless $request;
    
    if ($request =~ /GET (\S+) HTTP/) {
        my $path = $1;
        handle_request($client, $path);
    } elsif ($request =~ /POST (\S+) HTTP/) {
        my $path = $1;
        my $content_length = 0;
        if ($request =~ /Content-Length: (\d+)/i) {
            $content_length = $1;
        }
        
        my $body = '';
        if ($content_length > 0) {
            my $body_start = index($request, "\r\n\r\n");
            if ($body_start >= 0) {
                $body = substr($request, $body_start + 4);
            }
            
            while (length($body) < $content_length && time() - $start_time < $timeout) {
                my $buffer;
                my $bytes = sysread($client, $buffer, $content_length - length($body));
                $body .= $buffer if defined $bytes && $bytes > 0;
                select(undef, undef, undef, 0.01);
            }
        }
        
        handle_post_request($client, $path, $body);
    }
    
    close($client);
}

# ============================================================================
# SEÇÃO 7: HANDLERS DE EVENTOS DE COMBATE E AÇÕES
# ============================================================================
# Handlers para eventos de combate, skills, ataques e mudanças de mapa
# ============================================================================

sub onSkillUse {
    my ($self, $args) = @_;
    $session_stats{skills_used}++;
}

# Handler chamado quando o personagem ataca um monstro
# Atualiza estatísticas de dano e cache de monstros atacados para tracking de kills
sub onAttack {
    my ($self, $args) = @_;
    if ($args->{damage}) {
        $session_stats{damage_dealt} += $args->{damage};
    }
    
    # Atualiza cache de monstros atacados (para tracking de kills)
    # O cache é usado posteriormente para identificar qual monstro foi morto quando ganha EXP
    return unless $char && $monstersList;
    
    my $target_id = undef;
    if ($char->{attackTarget}) {
        $target_id = $char->{attackTarget};
    } elsif ($char->{target} && ref($char->{target})) {
        $target_id = eval { $char->{target}->{ID} } // undef;
    }
    
    if ($target_id && $monstersList->can('getByID')) {
        my $monster = eval { $monstersList->getByID($target_id) };
        if ($monster) {
            my $nameID = get_monster_nameID($monster);
            my $name = normalize_string(get_monster_name($monster));
            $monster_attack_cache{$target_id} = {
                name => $name || "Unknown Monster",
                nameID => $nameID,
                level => _i($monster->{lv}),
                last_attack_time => time(),
                dead => 0,
            };
        }
    }
    
    $last_target_id = $target_id;
}

sub onMapChange {
    my ($self, $args) = @_;
    # Limpa cache quando muda de mapa
    %cache = (
        last_update => 0,
        cache_duration => 0.5,
        last_character_data => {},
        last_map_data => {},
    );
}

sub onPlayerDead {
    $session_stats{deaths}++;
}

# ============================================================================
# SEÇÃO 8: CALLBACKS PARA SOLICITAÇÃO AUTOMÁTICA DE INFORMAÇÕES DA GUILDA
# ============================================================================

sub on_net_state_change {
    my ($self, $args) = @_;
    my $new_state = $args->{newState};
    my $old_state = $args->{oldState};

    if ($new_state != Network::IN_GAME) {
        # Reseta flag de solicitação quando desconecta
        $guild_info_requested = 0;
        $last_guild_request_time = 0;
        # Reseta tracking de kills quando desconecta
        $last_exp = 0;
        $session_stats{last_level} = 0;
    } elsif ($new_state == Network::IN_GAME && $old_state != Network::IN_GAME) {
        # Inicializa tracking de EXP ao entrar no jogo
        if ($char) {
            $last_exp = $char->{exp} || 0;
            $session_stats{last_level} = $char->{lv} || 0;
        }
        # Solicita informações da guilda automaticamente ao entrar no jogo
        request_guild_info(1);
    }
}

sub on_char_select {
    if ($char) {
        # Inicializa tracking de EXP quando personagem é selecionado
        $last_exp = $char->{exp} || 0;
        $session_stats{last_level} = $char->{lv} || 0;
        # Solicita informações da guilda automaticamente quando personagem é selecionado
        request_guild_info(0);
    }
}

# Solicita automaticamente informações da guilda do servidor quando necessário
# Baseado no comando "guild info" do OpenKore (src/Commands.pm linha 3444-3460)
# Parâmetros:
#   $force: 1 = tenta enviar imediatamente (se estiver IN_GAME)
#           0 = agenda se não estiver IN_GAME
sub request_guild_info {
    my ($force) = @_;

    # Se não estamos IN_GAME, não faz nada
    return unless ($net && $net->getState() == Network::IN_GAME);
    
    # Se já solicitamos recentemente e não é forçado, não solicita novamente
    my $now = time();
    if (!$force && $guild_info_requested && 
        ($now - $last_guild_request_time) < $GUILD_REQUEST_INTERVAL) {
        return;
    }

    # Verifica se o personagem está em uma guilda
    if (!$char || !$char->{guildID}) {
        return;
    }

    # Verifica se messageSender está disponível
    return unless $messageSender;

    # Solicita informações da guilda (igual ao comando "guild info" do OpenKore)
    # Baseado em src/Commands.pm linha 3444-3460
    eval {
        # Envia sendGuildMasterMemberCheck primeiro (alguns servidores precisam)
        if ($messageSender->can('sendGuildMasterMemberCheck')) {
            $messageSender->sendGuildMasterMemberCheck();
        }
        
        # Solicita informações básicas da guilda (0150/01B6) e lista de aliados/inimigos (014C)
        if ($messageSender->can('sendGuildRequestInfo')) {
            $messageSender->sendGuildRequestInfo(0);
            
            # Solicita lista de membros (0154) e títulos de membros (0166)
            $messageSender->sendGuildRequestInfo(1);
            
            # Solicita informações de títulos de membros (0166/0160)
            $messageSender->sendGuildRequestInfo(2);
            
            # Solicita informações de skills da guilda (0162)
            $messageSender->sendGuildRequestInfo(3);
            
            # Solicita lista de expulsões (015C)
            $messageSender->sendGuildRequestInfo(4);
        }
    };
    
    if ($@) {
        # Silenciosamente ignora erros para não poluir o console
        # message("[webDashboard] Erro ao solicitar informações da guilda: $@\n");
    } else {
        $guild_info_requested = 1;
        $last_guild_request_time = $now;
    }
}

# ============================================================================
# SEÇÃO 9: GERENCIAMENTO DE PORTAS E INSTÂNCIAS
# ============================================================================
# Sistema de mapeamento de portas para múltiplas contas:
# - Porta 8888: Página central (dashboard principal)
# - Ue-Kore0: Conta1->8889, Conta2->8890, Conta3->8891
# - Ue-Kore3: Conta1->8892, Conta2->8893, Conta3->8894
# ============================================================================

# Calcula a porta HTTP para uma conta específica baseado no kore_id e account_id
# Sistema de mapeamento de portas para múltiplas instâncias do OpenKore:
# - Porta 8888: Página central (dashboard principal, não usado para contas específicas)
# - Ue-Kore0: Conta1->8889, Conta2->8890, Conta3->8891
# - Ue-Kore3: Conta1->8892, Conta2->8893, Conta3->8894
# Parâmetros:
#   $kore_id: ID do kore (ex: "Ue-Kore0", "Ue-Kore3")
#   $account_id: ID da conta (ex: "Conta1", "Conta2", "Conta3")
# Retorna: Número da porta ou 0 se não conseguir determinar
sub get_port_for_account {
    my ($kore_id, $account_id) = @_;
    
    # Identifica o número do kore (0 ou 3)
    my $kore_num = 0;
    if ($kore_id =~ /Ue-Kore(\d+)/i) {
        $kore_num = $1;
    }
    
    # Identifica o número da conta (1, 2 ou 3)
    my $conta_num = 0;
    if ($account_id =~ /Conta(\d+)/i) {
        $conta_num = $1;
    }
    
    # Mapeia portas baseado no kore e conta
    if ($kore_num == 0) {
        # Ue-Kore0 usa portas 8889-8891
        if ($conta_num == 1) {
            return 8889;
        } elsif ($conta_num == 2) {
            return 8890;
        } elsif ($conta_num == 3) {
            return 8891;
        }
    } elsif ($kore_num == 3) {
        # Ue-Kore3 usa portas 8892-8894
        if ($conta_num == 1) {
            return 8892;
        } elsif ($conta_num == 2) {
            return 8893;
        } elsif ($conta_num == 3) {
            return 8894;
        }
    }
    
    # Se não conseguir identificar, usa porta padrão baseada na conta (mas nunca 8888)
    if ($conta_num == 1) {
        return 8889;
    } elsif ($conta_num == 2) {
        return 8890;
    } elsif ($conta_num == 3) {
        return 8891;
    }
    
    # Fallback: usa 8889 se não conseguir identificar
    return 8889;
}

# ============================================================================
# SEÇÃO 10: GERENCIAMENTO DO SERVIDOR HTTP
# ============================================================================

sub start_server {
    # Identifica qual conta está rodando para usar porta específica
    my ($kore_id, $account_id) = get_account_info();
    my $preferred_port = get_port_for_account($kore_id, $account_id);
    
    my $current_port = $preferred_port;
    my $success = 0;
    my $tried_ports = 0;
    
    # Tenta primeiro a porta preferida para a conta
    for (my $i = 0; $i < $max_port_tries; $i++) {
        eval {
            $server_socket = IO::Socket::INET->new(
                LocalHost => $host,
                LocalPort => $current_port,
                Proto     => 'tcp',
                Listen    => 5,
                Reuse     => 1,
                Blocking  => 0
            );
            
            if ($server_socket) {
                $port = $current_port;
                $success = 1;
                my $account_label = "$kore_id - $account_id";
                message "[webDashboard] Servidor iniciado na porta $port para $account_label!\n";
                message "[webDashboard] Acesse: http://localhost:$port\n";
            }
        };
        
        last if $success;
        
        # Se a porta preferida falhou, tenta próximas portas
        $tried_ports++;
        if ($tried_ports == 1) {
            # Tenta próxima porta sequencial
            $current_port = $preferred_port + 1;
        } else {
            # Tenta portas alternativas
            $current_port = $preferred_port + $tried_ports;
        }
        
        # Limita a faixa de portas (8888-8895)
        if ($current_port > 8895) {
            $current_port = 8888 + ($tried_ports % 8);
        }
    }
    
    unless ($success) {
        error "[webDashboard] ERRO: Não foi possível iniciar servidor em nenhuma porta disponível.\n";
    }
}

sub start_central_server {
    # Tenta iniciar servidor central na porta 8888
    # Apenas uma instância consegue iniciar na 8888 (a primeira que tentar)
    # Se já estiver rodando em outra instância, não faz nada
    return if $central_socket;  # Já está rodando
    
    # Só tenta iniciar na 8888 se a porta atual não for 8888
    # (para evitar conflito se esta instância já está rodando em 8888)
    return if $port == 8888;
    
    eval {
        $central_socket = IO::Socket::INET->new(
            LocalHost => $host,
            LocalPort => 8888,
            Proto     => 'tcp',
            Listen    => 5,
            Reuse     => 1,
            Blocking  => 0
        );
        
        if ($central_socket) {
            message "[webDashboard] Servidor central iniciado na porta 8888!\n";
            message "[webDashboard] Página central: http://localhost:8888\n";
        }
    };
    
    # Se falhar, apenas ignora (outra instância já está servindo)
}

# ============================================================================
# SEÇÃO 11: HANDLERS DE REQUISIÇÕES HTTP
# ============================================================================

sub stop_server {
    if ($server_socket) {
        close($server_socket);
        message "[webDashboard] Servidor parado.\n";
    }
    if ($central_socket) {
        close($central_socket);
        message "[webDashboard] Servidor central parado.\n";
    }
}

# Roteia requisições HTTP GET para handlers apropriados
# Processa diferentes endpoints da API e serve o HTML do dashboard
# Parâmetros:
#   $client: Socket do cliente
#   $path: Caminho da requisição (ex: '/api/character', '/api/stats')
sub handle_request {
    my ($client, $path) = @_;
    
    # Handler para favicon (evita erro 404 no console do navegador)
    if ($path eq '/favicon.ico') {
        send_204($client);
        return;
    }
    
    # Roteamento de endpoints
    if ($path eq '/' || $path eq '/index.html') {
        send_html($client);  # Serve o HTML do dashboard
    } elsif ($path eq '/api/all') {
        send_json($client, get_all_data());
    } elsif ($path eq '/api/character') {
        send_json($client, get_character_data());
    } elsif ($path eq '/api/map') {
        send_json($client, get_map_data());
    } elsif ($path eq '/api/inventory') {
        send_json($client, get_inventory_data());
    } elsif ($path eq '/api/cart') {
        send_json($client, get_cart_data());
    } elsif ($path eq '/api/skills') {
        send_json($client, get_skills_data());
    } elsif ($path eq '/api/chat') {
        send_json($client, { messages => \@chat_messages });
    } elsif ($path eq '/api/stats') {
        send_json($client, get_session_stats());
    } elsif ($path eq '/api/monsters') {
        send_json($client, get_monsters_list());
    } elsif ($path eq '/api/target') {
        send_json($client, get_target_info());
    } elsif ($path eq '/api/config') {
        send_json($client, get_config_info());
    } elsif ($path eq '/api/instances') {
        send_json($client, get_available_instances());
    } elsif ($path eq '/api/current-instance') {
        send_json($client, get_current_instance_info());
    } elsif ($path =~ /^\/api\/proxy\/(\d+)\/(.+)$/) {
        # Proxy para acessar outras instâncias: /api/proxy/PORTA/caminho
        handle_proxy_request($client, $1, $2);
    } elsif ($path =~ /^\/api\/item\/(\d+)$/) {
        send_json($client, get_item_details($1));
    } elsif ($path eq '/api/monster-kills') {
        send_json($client, get_monster_kills_history());
    } elsif ($path eq '/api/item-drops') {
        send_json($client, get_items_drops_history());
    } elsif ($path eq '/api/guild') {
        send_json($client, get_guild_data());
    } elsif ($path eq '/api/party') {
        send_json($client, get_party_data());
    } elsif ($path eq '/api/experience') {
        send_json($client, get_experience_stats());
    } else {
        send_404($client);
    }
}

# ============================================================================
# SEÇÃO 12: HANDLERS DE REQUISIÇÕES POST (AÇÕES)
# ============================================================================

# Processa requisições POST (ações do usuário)
# Roteia para handlers específicos baseado no path
# Parâmetros:
#   $client: Socket do cliente
#   $path: Caminho da requisição
#   $body: Corpo da requisição (JSON)
sub handle_post_request {
    my ($client, $path, $body) = @_;
    
    # Verifica se é uma requisição proxy (redireciona para outra instância)
    if ($path =~ /^\/api\/proxy\/(\d+)\/(.+)$/) {
        handle_proxy_post_request($client, $1, $2, $body);
        return;
    }
    
    # Decodifica JSON do corpo da requisição
    my $data = eval { JSON->new->utf8->decode($body) };
    
    # Handler para comandos do OpenKore
    if ($path eq '/api/command') {
        if ($data && $data->{command}) {
            my $command = $data->{command};
            # Remove espaços no início e fim, mas preserva espaços internos
            $command =~ s/^\s+|\s+$//g;
            
            # Valida que o comando não está vazio após limpeza
            if ($command && $command ne '') {
                eval {
                    # Executa o comando exatamente como no console do OpenKore
                    Commands::run($command);
                };
                if ($@) {
                    # Se houver erro, registra mas não quebra o fluxo
                    debug "Erro ao executar comando '$command': $@\n", "webDashboard";
                    send_json($client, { success => 0, error => "Erro ao executar comando" });
                } else {
                    send_json($client, { success => 1 });
                }
            } else {
                send_json($client, { success => 0, error => "Comando vazio" });
            }
        } else {
            send_json($client, { success => 0, error => "Comando não fornecido" });
        }
    # Handler para enviar mensagem de chat público
    } elsif ($path eq '/api/chat/send') {
        if ($data && $data->{message}) {
            # Usa comando "c" do OpenKore para chat público
            Commands::run("c " . $data->{message});
            send_json($client, { success => 1 });
        }
    # Handler para upar skill
    } elsif ($path eq '/api/skill/upgrade') {
        if ($data && $data->{skill}) {
            # Usa comando "skills add" do OpenKore
            Commands::run("skills add " . $data->{skill});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/stat/upgrade') {
        if ($data && $data->{stat}) {
            Commands::run("stat_add " . $data->{stat});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/item/use') {
        if ($data && defined $data->{index}) {
            Commands::run("is " . $data->{index});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/item/equip') {
        if ($data && defined $data->{index}) {
            Commands::run("eq " . $data->{index});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/item/unequip') {
        if ($data && defined $data->{index}) {
            Commands::run("uneq " . $data->{index});
            send_json($client, { success => 1 });
        }
	} elsif ($path eq '/api/item/drop') {
		if ($data && defined $data->{index}) {
			my $idx = int($data->{index});
			my $amt = (defined $data->{amount}) ? int($data->{amount}) : 1;
			$amt = 1 if $amt < 1;
	
			# descobre o máximo disponível para clamp
			my $max_amt = 0;
			if ($char && $char->inventory()) {
				foreach my $it (@{$char->inventory()->getItems()}) {
					next unless $it;
					my $iinv = $it->{invIndex} // $it->{index} // $it->{binID};
					if (defined $iinv && $iinv == $idx) {
						$max_amt = int($it->{amount} || 0);
						last;
					}
				}
			}
			$amt = $max_amt if $max_amt && $amt > $max_amt;
	
			# COMANDO CERTO é drop <index> <amount>
			Commands::run("drop $idx $amt");
			send_json($client, { success => 1, index => $idx, amount => $amt, max => $max_amt });
		} else {
			send_json($client, { success => 0, error => 'missing_index' });
		}

    } elsif ($path eq '/api/move') {
        if ($data && defined $data->{x} && defined $data->{y}) {
            Commands::run("move " . $data->{x} . " " . $data->{y});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/ai') {
        if ($data && $data->{mode}) {
            Commands::run("ai " . $data->{mode});
            send_json($client, { success => 1 });
        }
    } elsif ($path eq '/api/config/save') {
        if ($data && $data->{config}) {
            save_config_changes($data->{config});
            send_json($client, { success => 1 });
        }
    } else {
        send_404($client);
    }
}

# ============================================================================
# SEÇÃO 13: FUNÇÕES DE RESPOSTA HTTP
# ============================================================================

sub send_html {
    my ($client) = @_;
    my $html = get_dashboard_html();
    
    my $html_bytes = encode_utf8($html);
    
    print $client "HTTP/1.1 200 OK\r\n";
    print $client "Content-Type: text/html; charset=utf-8\r\n";
    print $client "Content-Length: " . length($html_bytes) . "\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    print $client $html_bytes;
}

sub send_json {
    my ($client, $data) = @_;
    
    # Garante que $data não é undef
    $data = {} unless defined $data;
    
    my $json;
    my $json_bytes = eval { JSON->new->utf8->encode($data) };

    if ($@) {
        $json_bytes = encode_utf8('{"error":"JSON encoding error: ' . $@ . '"}');
    }

    # Garante que a string de bytes não tenha a flag UTF-8 ligada para o cálculo do tamanho
    Encode::_utf8_off($json_bytes);
    my $content_length = length($json_bytes);

    # Envia headers e corpo usando syswrite para garantir envio correto de bytes
    eval {
        # Prepara todos os headers
        my $headers = "HTTP/1.1 200 OK\r\n";
        $headers .= "Content-Type: application/json; charset=utf-8\r\n";
        $headers .= "Content-Length: $content_length\r\n";
        $headers .= "Access-Control-Allow-Origin: *\r\n";
        $headers .= "Connection: close\r\n";
        $headers .= "\r\n";
        
        # Converte headers para bytes também
        my $headers_bytes = $headers;
        Encode::_utf8_off($headers_bytes);
        # Usa syswrite para garantir envio correto de bytes
        syswrite($client, $headers_bytes);
        syswrite($client, $json_bytes);
        
        # Força flush para garantir que tudo foi enviado
        $client->flush();
    };
    
    # Se houver erro, tenta enviar uma resposta de erro simples
    if ($@) {
        eval {
            my $error_json = '{"error":"Internal server error"}';
            my $error_bytes = encode_utf8($error_json); Encode::_utf8_off($error_bytes);
            my $error_length = length($error_bytes);
            print $client "HTTP/1.1 500 Internal Server Error\r\n";
            print $client "Content-Type: application/json; charset=utf-8\r\n";
            print $client "Content-Length: $error_length\r\n";
            print $client "Connection: close\r\n";
            print $client "\r\n";
            print $client $error_bytes;
            $client->flush();
        };
    }
}

sub send_404 {
    my ($client) = @_;
    my $html = '<html><body><h1>404 Not Found</h1></body></html>';
    
    print $client "HTTP/1.1 404 Not Found\r\n";
    print $client "Content-Type: text/html\r\n";
    print $client "Content-Length: " . length($html) . "\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    print $client $html;
}

sub send_204 {
    my ($client) = @_;
    # 204 No Content - resposta padrão para favicon quando não existe
    print $client "HTTP/1.1 204 No Content\r\n";
    print $client "Content-Length: 0\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    $client->flush();
}

# ============================================================================
# SEÇÃO 14: HANDLERS DE CHAT E MENSAGENS
# ============================================================================

# Cache para evitar duplicação de mensagens (últimas 5 segundos)
my %recent_chat_cache = ();
my $CHAT_CACHE_TIME = 5;

# Adiciona uma mensagem de chat ao histórico
# Aplica normalização de encoding e verifica duplicação antes de adicionar
# Parâmetros:
#   $type: Tipo da mensagem ('public', 'private', 'party', 'guild', 'self')
#   $name: Nome do remetente
#   $text: Texto da mensagem
sub _push_chat {
    my ($type, $name, $text) = @_;
    $text //= '';
    # Remove quebras de linha e caracteres de controle
    $text =~ s/\r?\n/ /g;
    $text =~ s/[\x00-\x1F\x7F]//g;
    
    # Normaliza strings para corrigir problemas de encoding (ABNT-2)
    $text = normalize_string($text) if $text;
    $name = normalize_string($name) if $name;
    
    # Garante que o nome não esteja vazio após normalização
    $name = '' unless $name && $name ne '';
    
    # Não adiciona mensagem vazia
    return unless $text && $text ne '';
    
    # Verifica duplicação: mesma mensagem do mesmo tipo nos últimos 5 segundos
    # Isso evita que a mesma mensagem apareça múltiplas vezes (alguns hooks podem ser chamados várias vezes)
    my $current_time = time();
    my $cache_key = "$type|$name|$text";
    
    # Limpa cache expirado
    foreach my $key (keys %recent_chat_cache) {
        if ($current_time - $recent_chat_cache{$key}{time} > $CHAT_CACHE_TIME) {
            delete $recent_chat_cache{$key};
        }
    }
    
    # Verifica se já existe mensagem similar recente
    if (exists $recent_chat_cache{$cache_key}) {
        my $cached = $recent_chat_cache{$cache_key};
        # Se é a mesma mensagem e foi adicionada recentemente, ignora (evita duplicação)
        if (($current_time - $cached->{time}) < 2) {
            return;
        }
    }
    
    # Adiciona ao cache
    $recent_chat_cache{$cache_key} = {
        time => $current_time,
        type => $type,
        name => $name,
        message => $text
    };
    
    push @chat_messages, { 
        time => $current_time, 
        type => $type,      # 'public', 'private', 'party', 'guild', 'self'
        category => $type,  # Mesma categoria para facilitar filtragem
        name => $name, 
        message => $text 
    };
    shift @chat_messages if @chat_messages > $max_chat;
}
sub onChatPublic  { 
    my (undef,$a)=@_; 
    return unless $a;
    
    # O hook packet_pubMsg envia: { pubMsgUser => $chatMsgUser, pubMsg => $parsed_msg, MsgUser => $chatMsgUser, Msg => $parsed_msg }
    my $user_name = $a->{pubMsgUser} || $a->{MsgUser} || 'PUB';
    my $message = $a->{pubMsg} || $a->{Msg} || $a->{msg} || '';
    
    # Se a mensagem está vazia, não adiciona
    return unless $message && $message ne '';
    
    # Verifica se é sua própria mensagem (comparando com o nome do personagem)
    # Se for, trata como 'self' em vez de 'public' para evitar duplicação
    my $is_self = 0;
    if ($char && $char->can('name')) {
        my $char_name = eval { $char->name() } || '';
        $char_name = normalize_string($char_name) if $char_name;
        my $normalized_user = normalize_string($user_name) if $user_name;
        if ($char_name && $normalized_user && $char_name eq $normalized_user) {
            $is_self = 1;
        }
    }
    
    # Adiciona como 'self' se for sua mensagem, senão como 'public'
    _push_chat($is_self ? 'self' : 'public', $user_name, $message);
}
sub onChatPrivate {
    my (undef,$a)=@_; 
    if ($a) {
        # O hook packet_privMsg envia: { privMsgUser => $privMsgUser, privMsg => $parsed_msg, MsgUser => $privMsgUser, Msg => $parsed_msg }
        my $user_name = $a->{privMsgUser} || $a->{MsgUser} || 'PM';
        my $message = $a->{privMsg} || $a->{Msg} || $a->{msg} || '';
        _push_chat('private', $user_name, $message) if $message;
    }
}
sub onChatSelf    {
    my (undef,$a)=@_; 
    return unless $a;
    
    # O hook packet_selfChat envia: { user => $chatMsgUser, msg => $chatMsg }
    # IMPORTANTE: O hook só é chamado se defined $chatMsgUser, mas $chatMsg pode ser undef se o parsing falhar
    # No código do OpenKore (src/Network/Receive.pm linha 11452-11455):
    # Plugins::callHook('packet_selfChat', { user => $chatMsgUser, msg => $chatMsg });
    # Onde $chatMsg é a mensagem ANTES do solveMessage (ainda pode ter códigos de cor, etc)
    
    my $user_name = $a->{user};
    my $message = $a->{msg} || $a->{Msg} || '';
    
    # Se não tem mensagem, tenta extrair de outros campos possíveis
    if (!$message || $message eq '') {
        # Tenta pegar de outros campos possíveis
        $message = $a->{message} || $a->{Message} || $a->{text} || $a->{Text} || '';
        
        # Se ainda não tem, e o user contém " : ", tenta extrair (formato "Nome : mensagem")
        if (!$message && $user_name && $user_name =~ /^(.*?) : (.*)$/) {
            $user_name = $1;
            $message = $2;
        }
    }
    
    # Remove códigos de cor do RO (^[0-9A-Fa-f]{6}) se existirem
    $message =~ s/\^[0-9A-Fa-f]{6}//g if $message;
    
    # Se ainda não tem mensagem, não adiciona
    return unless $message && $message ne '';
    
    # Normaliza o nome do usuário - se estiver vazio ou undefined, usa "Você"
    if (!$user_name || $user_name eq '') {
        $user_name = 'Você';
    } else {
        # Normaliza o nome para corrigir encoding
        $user_name = normalize_string($user_name);
        # Se após normalização ficou vazio, usa "Você"
        $user_name = 'Você' unless $user_name && $user_name ne '';
    }
    
    # Adiciona a mensagem
    _push_chat('self', $user_name, $message);
}
sub onChatParty   {
    my (undef,$a)=@_; 
    if ($a) {
        # O hook packet_partyMsg envia: { MsgUser => $chatMsgUser, Msg => $parsed_msg, RawMsg => $chatMsg }
        my $user_name = $a->{MsgUser} || 'PT';
        my $message = $a->{Msg} || $a->{msg} || '';
        _push_chat('party', $user_name, $message) if $message;
    }
}
sub onChatGuild   {
    my (undef,$a)=@_; 
    if ($a) {
        # O hook packet_guildMsg envia: { MsgUser => $chatMsgUser, Msg => $parsed_msg, RawMsg => $chatMsg }
        my $user_name = $a->{MsgUser} || 'GD';
        my $message = $a->{Msg} || $a->{msg} || '';
        _push_chat('guild', $user_name, $message) if $message;
    }
}


sub onLogMessage {
    # Assinatura correta para o hook de Log nas builds atuais:
    my ($type, $domain, $level, $verbosity, $message, @rest) = @_;
    return unless defined $message;

    # Filtros básicos pra não poluir:
    return if $message eq '' || $message =~ /^\s+$/;       # vazio/espaco
    return if $message =~ /^[01]\s*$/;                     # evita verbosidade 0/1
    return if length($message) <= 1 && $message !~ /[A-Za-zÀ-ÿ0-9]/;

    my $clean = $message;
    $clean =~ s/\r?\n/ /g;          # 1 linha
    $clean =~ s/[\x00-\x1F\x7F]//g; # remove control chars
    $clean =~ s/^\s+|\s+$//g;       # remove espaços no início/fim
    return if $clean eq '';          # se ficou vazio após limpeza
    
    # Normaliza a string para corrigir problemas de encoding (ex: "VocÃª" -> "Você")
    $clean = normalize_string($clean);
    return if $clean eq '';          # se ficou vazio após normalização

    # Normaliza o nome do domínio
    my $domain_name = (defined $domain && $domain ne '') ? $domain : 'console';
    $domain_name = normalize_string($domain_name) if $domain_name;
    
    # Categoriza a mensagem por tipo e domínio (replicando o console do OpenKore)
    my $msg_type = 'console';  # padrão: console do OpenKore
    my $msg_category = 'info'; # padrão: informação
    
    # Detecta mensagens do LatamChecksum
    if ($clean =~ /LatamChecksum/i || $domain_name =~ /LatamChecksum/i) {
        $msg_type = 'latamchecksum';
        $msg_category = 'checksum';
    }
    # Detecta mensagens de chat do jogo (não devem vir por aqui, mas por segurança)
    elsif ($type && ($type eq 'chat' || $type eq 'privMsg' || $type eq 'partyMsg' || $type eq 'guildMsg')) {
        $msg_type = 'chat';
        $msg_category = $type;
    }
    # Detecta mensagens de console do OpenKore por domínio (replicando categorias do OpenKore)
    elsif ($domain_name) {
        $msg_type = 'console';
        # Categoriza por domínio para cores diferentes (baseado nos domínios conhecidos do OpenKore)
        if ($domain_name =~ /^(sendPacket|packetParser|parseMsg|parseMsg_damage|parseMsg_presence)/i) {
            $msg_category = 'packet';
        } elsif ($domain_name =~ /^(move|route|ai_move)/i) {
            $msg_category = 'movement';
        } elsif ($domain_name =~ /^(error|warning)/i || ($type && $type eq 'error')) {
            $msg_category = 'error';
        } elsif ($domain_name =~ /^(debug|ai_attack|ai_autoCart|parseInput|portalRecord)/i || ($type && $type eq 'debug')) {
            $msg_category = 'debug';
        } elsif ($domain_name =~ /^(attackMon|attackMonMiss|attacked|attackedMiss|drop|exp|exp2|inventory|skill|selfSkill|useItem|equip|storage|deal|sold|npc|party|teleport|connection|startup|system|success|info|list)/i) {
            $msg_category = 'info';
        } else {
            $msg_category = 'info';
        }
    }

    # Verifica duplicação usando o cache
    my $current_time = time();
    my $cache_key = "$msg_type|$msg_category|$domain_name|$clean";
    
    # Limpa cache expirado
    foreach my $key (keys %recent_chat_cache) {
        if ($current_time - $recent_chat_cache{$key}{time} > $CHAT_CACHE_TIME) {
            delete $recent_chat_cache{$key};
        }
    }
    
    # Verifica se já existe mensagem similar recente (evita duplicação)
    if (exists $recent_chat_cache{$cache_key}) {
        my $cached = $recent_chat_cache{$cache_key};
        # Se é a mesma mensagem e foi adicionada recentemente (menos de 1 segundo), ignora
        if (($current_time - $cached->{time}) < 1) {
            return;
        }
    }
    
    # Adiciona ao cache
    $recent_chat_cache{$cache_key} = {
        time => $current_time,
        type => $msg_type,
        category => $msg_category,
        name => $domain_name,
        message => $clean
    };

    push @chat_messages, {
        time    => $current_time,
        type    => $msg_type,        # 'chat', 'console', 'latamchecksum'
        category => $msg_category,   # 'packet', 'movement', 'error', 'debug', 'info', 'checksum'
        name    => $domain_name,
        message => $clean
    };
    shift @chat_messages if @chat_messages > $max_chat;
}

# ============================================================================
# SEÇÃO 15: FUNÇÕES DE COLETA DE DADOS DO JOGO
# ============================================================================
# Estas funções coletam e formatam dados do estado atual do jogo
# para serem enviados via API JSON ao dashboard web.
# ============================================================================

# Coleta todos os dados do jogo em uma única estrutura para a API
# Usa cache para melhorar performance (atualiza a cada 0.5 segundos)
# Retorna: Hash com character, map, inventory, skills e timestamp
sub get_all_data {
    my $current_time = time();
    
    # Garante que retorna uma estrutura válida mesmo se houver erros
    my $character_data = {};
    my $map_data = {};
    my $inventory_data = {};
    my $cart_data = {};
    my $skills_data = {};
    
    eval {
        # Usa cache para melhor performance (evita recalcular dados a cada requisição)
        # Cache dura 0.5 segundos (cache_duration)
        if ($current_time - $cache{last_update} < $cache{cache_duration}) {
            $character_data = $cache{last_character_data} || {};
            $map_data = $cache{last_map_data} || {};
        } else {
            $cache{last_update} = $current_time;
            $character_data = get_character_data() || {};
            $map_data = get_map_data() || {};
            $cache{last_character_data} = $character_data;
            $cache{last_map_data} = $map_data;
        }
        
        $inventory_data = get_inventory_data() || {};
        $cart_data = get_cart_data() || {};
        $skills_data = get_skills_data() || {};
    };
    
    # Se houver erro, retorna estrutura vazia mas válida
    if ($@) {
        $character_data = {} unless $character_data;
        $map_data = {} unless $map_data;
        $inventory_data = {} unless $inventory_data;
        $cart_data = {} unless $cart_data;
        $skills_data = {} unless $skills_data;
    }
    
    return {
        character => $character_data,
        map => $map_data,
        inventory => $inventory_data,
        cart => $cart_data,
        skills => $skills_data,
        timestamp => $current_time
    };
}

# Coleta dados do personagem atual (HP, SP, EXP, stats, etc)
# Retorna: Hash com todas as informações do personagem formatadas para a API
sub get_character_data {
	return {} unless $char;
	
	my $job_name = '-';
	# Tenta obter jobID (com 'I' maiúsculo) - campo padrão do OpenKore
	# Verifica múltiplas variações do campo para compatibilidade com diferentes servidores
	my $jobID = 0;
	if (defined $char->{jobID} && $char->{jobID} > 0) {
		$jobID = $char->{jobID};
	} elsif (defined $char->{jobId} && $char->{jobId} > 0) {
		$jobID = $char->{jobId};
	} elsif (defined $char->{type} && $char->{type} > 0) {
		# Alguns servidores usam 'type' para jobID
		$jobID = $char->{type};
	}
	
	if ($jobID && $jobID > 0) {
		# Busca o nome da classe na tabela jobs_lut
		if (exists $jobs_lut{$jobID} && defined $jobs_lut{$jobID} && $jobs_lut{$jobID} ne '') {
			$job_name = normalize_string($jobs_lut{$jobID});
		} else {
			# Se não encontrou na tabela, usa o ID como fallback
			$job_name = "Job_$jobID";
		}
	}
	
	# Calcula estatísticas de combate
	my $total_stats = 0;
	my @stat_values = ();
	if (defined $char->{str}) {
		$total_stats += _i($char->{str}) + _i($char->{agi}) + _i($char->{vit})
					+ _i($char->{int}) + _i($char->{dex}) + _i($char->{luk});
		@stat_values = (_i($char->{str}), _i($char->{agi}), _i($char->{vit}),
						_i($char->{int}), _i($char->{dex}), _i($char->{luk}));
	}

    
    my %data = ( # Nomes já devem estar normalizados pelo OpenKore
        name => $char->{name} || 'N/A',
        level => $char->{lv} || 0,
        job => $job_name,
        job_level => $char->{lv_job} || 0,
        hp => $char->{hp} || 0,
        hp_max => $char->{hp_max} || 0,
        sp => $char->{sp} || 0,
        sp_max => $char->{sp_max} || 0,
        exp => $char->{exp} || 0,
        exp_max => $char->{exp_max} || 0,
        exp_job => $char->{exp_job} || 0,
        exp_job_max => $char->{exp_job_max} || 0,
        zeny => $char->{zeny} || 0,
        weight => $char->{weight} || 0,
        weight_max => $char->{weight_max} || 0,
        points_free => $char->{points_free} || 0,
        points_skill => $char->{points_skill} || 0,
        total_stats => $total_stats,
        stat_values => \@stat_values,
    );
    
    $data{stats} = {
        str => $char->{str} || 0,
        agi => $char->{agi} || 0,
        vit => $char->{vit} || 0,
        int => $char->{int} || 0,
        dex => $char->{dex} || 0,
        luk => $char->{luk} || 0,
    };
    
    # Status effects
    $data{status} = {
        poisoned => $char->{statuses}{POISON} ? 1 : 0,
        cursed => $char->{statuses}{CURSE} ? 1 : 0,
        silenced => $char->{statuses}{SILENCE} ? 1 : 0,
        blinded => $char->{statuses}{BLIND} ? 1 : 0,
    };
    
	$data{hp_percent}     = _i($data{hp_max})     ? int((_i($data{hp})     / _i($data{hp_max}))     * 100) : 0;
	$data{sp_percent}     = _i($data{sp_max})     ? int((_i($data{sp})     / _i($data{sp_max}))     * 100) : 0;
	$data{exp_percent}    = _i($data{exp_max})    ? sprintf('%.2f', (_i($data{exp})    / _i($data{exp_max}))    * 100) : 0;
	$data{exp_job_percent}= _i($data{exp_job_max})? sprintf('%.2f', (_i($data{exp_job})/ _i($data{exp_job_max})) * 100) : 0;
	$data{weight_percent} = _i($data{weight_max}) ? int((_i($data{weight}) / _i($data{weight_max})) * 100) : 0;

    
    return \%data;
}

# ============================================================================
# SEÇÃO 16: FUNÇÕES DE DADOS ESPECÍFICOS (MAPA, INVENTÁRIO, SKILLS, ETC)
# ============================================================================

# Coleta dados do mapa atual (nome, dimensões, posição do char, players, monstros, NPCs, portais)
# Retorna: Hash com informações do mapa e entidades presentes
sub get_map_data {
    return {} unless $field;

    my %data = (
        name   => $field->baseName() || 'N/A',
        width  => _i($field->width()),
        height => _i($field->height()),
    );

    if ($char) {
        $data{char_x} = _i($char->{pos_to}{x} // $char->{pos}{x});
        $data{char_y} = _i($char->{pos_to}{y} // $char->{pos}{y});
    } else {
        $data{char_x} = 0;
        $data{char_y} = 0;
    }

    my @players;
    if ($playersList && $playersList->can('getItems')) {
        foreach my $player (@{ $playersList->getItems() || [] }) {
            next unless $player;
            push @players, {
                name  => normalize_string($player->name() || ''),
                x     => _i($player->{pos_to}{x} // $player->{pos}{x}),
                y     => _i($player->{pos_to}{y} // $player->{pos}{y}),
                level => _i($player->{lv}),
                job   => (defined $player->{jobId}
                          ? ($jobs_lut{ $player->{jobId} } // $player->{jobId})
                          : ''),
            };
        }
    }
    $data{players} = \@players;

    my @monsters;
    if ($monstersList && $monstersList->can('getItems')) {
        foreach my $monster (@{ $monstersList->getItems() || [] }) {
            next unless $monster;
            my $hp     = _i($monster->{hp});
            my $hp_max = _i($monster->{hp_max});
            push @monsters, {
                name       => normalize_string($monster->name() || ''),
                nameID     => _i($monster->{nameID}),
                x          => _i($monster->{pos_to}{x} // $monster->{pos}{x}),
                y          => _i($monster->{pos_to}{y} // $monster->{pos}{y}),
                hp         => $hp,
                hp_max     => $hp_max,
                level      => _i($monster->{lv}),
                hp_percent => $hp_max ? int(($hp / $hp_max) * 100) : 0,
            };
        }
    }
    $data{monsters} = \@monsters;

    my @npcs;
    if ($npcsList && $npcsList->can('getItems')) {
        foreach my $npc (@{ $npcsList->getItems() || [] }) {
            next unless $npc;
            push @npcs, {
                name => normalize_string($npc->name() || 'NPC'),
                x    => _i($npc->{pos}{x}),
                y    => _i($npc->{pos}{y}),
            };
        }
    }
    $data{npcs} = \@npcs;

    my @portals;
    if ($portalsList && $portalsList->can('getItems')) {
        foreach my $portal (@{ $portalsList->getItems() || [] }) {
            next unless $portal;
            push @portals, {
                name => normalize_string($portal->name() || 'Portal'),
                x    => _i($portal->{pos}{x}),
                y    => _i($portal->{pos}{y}),
            };
        }
    }
    $data{portals} = \@portals;

    $data{ai_state}    = eval { AI::state() }   // 'unknown';
    $data{ai_sequence} = eval { AI::action() }  // '';

    return \%data;
}

# Coleta dados do inventário do personagem
# Retorna: Hash com lista de itens, quantidade total e valor total estimado
sub get_inventory_data {
    my @items;
    my $total_value = 0;

    if ($char && $char->inventory()) {
        my $pos = 0;
        my $items_ref = eval { $char->inventory()->getItems() };
        if ($items_ref && ref($items_ref) eq 'ARRAY') {
            foreach my $item (@{$items_ref}) {
                next unless $item;
                
                # Usa get_item_name() que já faz toda a lógica corretamente (igual consolebridge.pl)
                # Isso garante nomes corretos com encoding adequado
                my $name = get_item_name($item);
                
                my $type = eval { $item->{type} } // 0;
                my $equipped = eval { $item->{equipped} } ? 1 : 0;
                my $amount = eval { $item->{amount} } // 1;
                my $idx = eval { $item->{invIndex} // $item->{index} // $item->{binID} } // $pos;
                my $nameID = eval { $item->{nameID} } // 0;
                my $identified = eval { $item->{identified} } ? 1 : 0;

                # Heurística simples de categoria para organização no dashboard
                # Categorias: 'equipped', 'equipable', 'consumable', 'other'
                my $category = 'other';
                if ($equipped) { 
                    $category = 'equipped'  # Item atualmente equipado
                } elsif ($type == 4 || $type == 5 || $name =~ /(Sword|Bow|Dagger|Shield|Armor|Hat|Boot|Robe|Manteau|Accessory|Elmo|Arco|Adaga|Escudo|Armadura|Chapéu|Bota|Capa|Acessório)/i) {
                    $category = 'equipable';  # Item que pode ser equipado
                } elsif ($type == 3 || $name =~ /(Potion|Poção|Scroll|Comida|Food|Flecha|Arrow|Garrafa|Bottle)/i) {
                    $category = 'consumable';  # Item consumível (poções, comida, etc)
                }

                my $estimated_price = estimate_item_price($item);
                $total_value += $estimated_price * $amount;

                push @items, {
                    name        => $name,
                    nameID      => $nameID,
                    amount      => $amount,
                    type        => $type,
                    identified  => $identified ? JSON::true : JSON::false,
                    equipped    => $equipped ? JSON::true : JSON::false,
                    index       => int($idx),
                    category    => $category,
                    price       => $estimated_price,
                    total_price => $estimated_price * $amount,
                };
                $pos++;
            }
        }
    }

    return {
        items       => \@items,
        count       => scalar(@items),
        total_value => $total_value,
    };
}

# Coleta dados do carrinho do personagem (se tiver carrinho equipado)
# Retorna: Hash com lista de itens, quantidade total, valor total e informações do carrinho
# Retorna estrutura vazia se o personagem não tiver carrinho ou carrinho não estiver pronto
sub get_cart_data {
    my @items = ();
    my $total_value = 0;
    my $has_cart = 0;
    my $items_count = 0;
    my $items_max = 0;
    my $weight = 0;
    my $weight_max = 0;
    
    # Verifica se o personagem tem carrinho e se está pronto
    if ($char && eval { $char->cartActive } && eval { $char->cart && $char->cart->isReady() }) {
        $has_cart = 1;
        
        # Obtém informações do carrinho
        $items_count = eval { $char->cart->items() } || 0;
        $items_max = eval { $char->cart->items_max() } || 0;
        $weight = eval { $char->cart->{weight} } || 0;
        $weight_max = eval { $char->cart->{weight_max} } || 0;
        
        # Obtém itens do carrinho
        my $items_ref = eval { $char->cart->getItems() };
        if ($items_ref && ref($items_ref) eq 'ARRAY') {
            my $pos = 0;
            foreach my $item (@{$items_ref}) {
                next unless $item;
                
                # Usa get_item_name() que já faz toda a lógica corretamente (igual consolebridge.pl)
                my $name = get_item_name($item);
                
                my $type = eval { $item->{type} } // 0;
                my $amount = eval { $item->{amount} } // 1;
                my $idx = eval { $item->{invIndex} // $item->{index} // $item->{binID} } // $pos;
                my $nameID = eval { $item->{nameID} } // 0;
                my $identified = eval { $item->{identified} } ? 1 : 0;
                
                # Heurística simples de categoria (mesma lógica do inventário)
                my $category = 'other';
                if ($type == 4 || $type == 5 || $name =~ /(Sword|Bow|Dagger|Shield|Armor|Hat|Boot|Robe|Manteau|Accessory|Elmo|Arco|Adaga|Escudo|Armadura|Chapéu|Bota|Capa|Acessório)/i) {
                    $category = 'equipable';
                } elsif ($type == 3 || $name =~ /(Potion|Poção|Scroll|Comida|Food|Flecha|Arrow|Garrafa|Bottle)/i) {
                    $category = 'consumable';
                }
                
                my $estimated_price = estimate_item_price($item);
                $total_value += $estimated_price * $amount;
                
                push @items, {
                    name        => $name,
                    nameID      => $nameID,
                    amount      => $amount,
                    type        => $type,
                    identified  => $identified ? JSON::true : JSON::false,
                    index       => int($idx),
                    category    => $category,
                    price       => $estimated_price,
                    total_price => $estimated_price * $amount,
                };
                $pos++;
            }
        }
    }
    
    return {
        has_cart    => $has_cart ? JSON::true : JSON::false,
        items       => \@items,
        count       => scalar(@items),
        total_value => $total_value,
        items_count => $items_count,
        items_max   => $items_max,
        weight      => $weight,
        weight_max  => $weight_max,
        weight_percent => ($weight_max > 0) ? int(($weight / $weight_max) * 100) : 0,
    };
}

# Estima o preço de um item baseado em heurísticas simples
# Esta é uma estimativa básica - não usa dados reais de mercado
# Retorna: Preço estimado em zeny
sub estimate_item_price {
    my ($item) = @_;
    return 0 unless $item;
    
    # Estimativa básica de preço baseado no tipo e nome do item
    # Valores são aproximados e podem ser ajustados conforme necessário
    my $price = 0;
    my $name = get_item_name($item);
    
    if ($name =~ /Potion|Potão/i) {
        $price = 50;
    } elsif ($name =~ /Arrow|Flecha/i) {
        $price = 10;
    } elsif ($name =~ /Ore|Minério/i) {
        $price = 100;
    } elsif ($name =~ /Gem|Gema/i) {
        $price = 1000;
    } else {
        $price = 10; # preço padrão
    }
    
    return $price;
}

# ============================================================================
# SEÇÃO 17: FUNÇÕES DE ESTATÍSTICAS E SESSÃO
# ============================================================================

# Coleta dados de todas as skills do personagem
# Retorna: Hash com lista de skills, quantidade total e custo total de SP
# Usa Skill->getName() para obter nomes localizados corretamente
sub get_skills_data {
    my @skills = ();
    my $total_sp_cost = 0;
    
    return { skills => \@skills, count => 0, total_sp_cost => 0 } unless ($char && $char->{skills} && ref($char->{skills}) eq 'HASH');
    
    foreach my $handle (keys %{$char->{skills}}) {
        my $skill = $char->{skills}{$handle};
        next unless $skill && ref($skill) eq 'HASH';
        
        my ($skill_name, $IDN, $targetType) = ("Unknown Skill", 0, 0);
        
        # EXATAMENTE como consolebridge.pl: tenta obter o nome usando Skill->new(handle => $handle)->getName()
        # Isso garante nomes localizados corretos (PT-BR) com encoding adequado
        eval {
            require Skill;
            my $skill_obj = new Skill(handle => $handle);
            if ($skill_obj) {
                $skill_name = normalize_string($skill_obj->getName() || '');
                $IDN = $skill_obj->getIDN() // 0;
                $targetType = $skill_obj->getTargetType() // 0;
            }
        };
        
        # Se falhou ou não retornou nome válido, usa fallbacks (igual consolebridge.pl)
        if ($@ || !$skill_name || $skill_name eq 'Unknown Skill' || $skill_name eq '' || $skill_name =~ /skill_not_found/i) {
            if (defined $skill->{name} && $skill->{name} ne "") {
                $skill_name = normalize_string($skill->{name});
                $skill_name =~ s/\s*\([^)]*\)//g;
            } elsif ($handle) {
                $skill_name = normalize_string($handle);
            } elsif (defined $skill->{ID}) {
                $skill_name = "Skill_" . $skill->{ID};
            }
            $IDN = $skill->{ID} // 0;
            $targetType = $skill->{targetType} // $skill->{target} // 0;
        }

        # Remove informações entre parênteses (ex: "Skill Name (ID: 123)" -> "Skill Name")
        $skill_name =~ s/\s*\([^)]*\)//g if $skill_name;
        
        my $sp_cost = $skill->{sp} || 0;
        $total_sp_cost += $sp_cost;
        
        push @skills, {
            name => $skill_name,
            level => $skill->{lv} // 0,
            sp => $sp_cost,
            handle => normalize_string($handle // ""),
            id => $IDN,
            target_type => $targetType,
            upgradable => $skill->{up} // 0,
            max_level => $skill->{max_lv} || 10,
        };
    }
    
    # Ordena skills por nome (alfabeticamente)
    @skills = sort { $a->{name} cmp $b->{name} } @skills;
    
    return {
        skills => \@skills,
        count => scalar(@skills),
        total_sp_cost => $total_sp_cost,
    };
}

# Coleta estatísticas da sessão atual (desde o início do plugin)
# Inclui: EXP ganha, zeny ganho, levels up, kills, deaths, items coletados, etc
# Retorna: Hash com todas as estatísticas da sessão formatadas
sub get_session_stats {
    # Usa build_experience_stats para obter dados detalhados de EXP
    my $exp_stats = build_experience_stats();
    
    my $current_time = time();
    my $uptime = $current_time - $session_stats{start_time};  # Tempo desde o início da sessão
    my $exp_gained = 0;
    my $zeny_gained = 0;
    my $levels_gained = 0;
    my $job_levels_gained = 0;
    
    if ($char) {
        $exp_gained = ($char->{exp} || 0) - $session_stats{exp_start};
        $zeny_gained = ($char->{zeny} || 0) - $session_stats{zeny_start};
        $levels_gained = ($char->{lv} || 0) - ($session_stats{base_level_start} || 0);
        $job_levels_gained = ($char->{lv_job} || 0) - ($session_stats{job_level_start} || 0);
    }
    
    my $exp_per_hour = $uptime > 0 ? int(($exp_gained / $uptime) * 3600) : 0;
    my $zeny_per_hour = $uptime > 0 ? int(($zeny_gained / $uptime) * 3600) : 0;
    
    # Calcula estatísticas por minuto
    my $time_since_last = $current_time - $session_stats{last_update};
    my $kills_per_minute = $time_since_last > 0 ? ($session_stats{kills} / $time_since_last) * 60 : 0;
    my $skills_per_minute = $time_since_last > 0 ? ($session_stats{skills_used} / $time_since_last) * 60 : 0;
    
    $session_stats{last_update} = $current_time;
    
    # CORREÇÃO: Usar as variáveis do hash session_stats em vez de variáveis globais
    my $efficiency = $session_stats{deaths} > 0 ? 
        sprintf("%.2f", $session_stats{kills} / $session_stats{deaths}) : 
        $session_stats{kills};
    
    # Combina dados básicos com dados detalhados de experiência
    my %stats = (
        uptime => int($uptime),
        exp_gained => $exp_gained,
        zeny_gained => $zeny_gained,
        exp_per_hour => $exp_per_hour,
        zeny_per_hour => $zeny_per_hour,
        kills => $session_stats{kills},
        deaths => $session_stats{deaths},
        items_collected => $session_stats{items_collected},
        damage_dealt => $session_stats{damage_dealt},
        damage_received => $session_stats{damage_received},
        skills_used => $session_stats{skills_used},
        levels_gained => $levels_gained,
        job_levels_gained => $job_levels_gained,
        kills_per_minute => sprintf("%.2f", $kills_per_minute),
        skills_per_minute => sprintf("%.2f", $skills_per_minute),
        efficiency => $efficiency,
    );
    
    # Adiciona dados detalhados de experiência se disponíveis
    if ($exp_stats && ref($exp_stats) eq 'HASH') {
        $stats{experience_details} = $exp_stats;
    }
    
    return \%stats;
}

sub get_monsters_list {
    my @monsters = ();
    
    if ($monstersList && $monstersList->can('getItems')) {
        eval {
            my $items = $monstersList->getItems() || [];
            foreach my $monster (@$items) {
                next unless $monster;
                
                eval {
                    my $dist = 0;
                    if ($char && $char->{pos_to} && $monster->{pos_to}) {
                        $dist = int(Utils::distance($char->{pos_to}, $monster->{pos_to}) || 0);
                    }
                    my $mhp  = _i($monster->{hp} || 0);
                    my $mmax = _i($monster->{hp_max} || 0);
                    my $hp_percent = $mmax > 0 ? int(($mhp / $mmax) * 100) : 0;
                    
                    # Normaliza o nome do monstro usando função auxiliar
                    my $name = get_monster_name($monster);
                
                    push @monsters, {
                        name       => $name,
                        nameID     => _i($monster->{nameID} || 0),
                        level      => _i($monster->{lv} || 0),
                        hp         => $mhp,
                        hp_max     => $mmax,
                        hp_percent => $hp_percent,
                        distance   => $dist,
                    };
                };
                # Ignora erros individuais e continua processando outros monstros
            }
        };
        # Ignora erros gerais e retorna lista vazia se necessário
    }
    
    # Ordena por distância
    @monsters = sort { $a->{distance} <=> $b->{distance} } @monsters;
    
    return { monsters => \@monsters };
}

# ============================================================================
# SEÇÃO 18: FUNÇÕES DE INFORMAÇÕES DE CONTA E INSTÂNCIAS
# ============================================================================

sub get_target_info {
    # Resolve alvo atual por múltiplas heurísticas:
    # 1) ID que o char está atacando (comum em builds recentes)
    # 2) Fallbacks conhecidos em estruturas internas
    # 3) Último recurso: variável de pacote (se existir) sem importar
    my $t;

    if ($char) {
        # 1) ID de alvo que o char está atacando (normalmente um GUID de ator)
        if ($char->{attackTarget} && $monstersList && $monstersList->can('getByID')) {
            my $cand = eval { $monstersList->getByID($char->{attackTarget}) };
            $t = $cand if $cand;
        }

        # 2) Alguns forks guardam referência direta
        if (!$t && $char->{target} && ref $char->{target}) {
            $t = $char->{target};
        }
    }

    # 3) Se existir uma variável global (não exportada), use-a sem importar
    if (!$t && defined $Globals::target && ref $Globals::target) {
        $t = $Globals::target;
    }

    # Sem alvo - retorna estrutura válida mesmo sem alvo
    unless ($t && ref $t) {
        return {
            exists => JSON::false,
            name => '',
            nameID => 0,
            level => 0,
            hp => 0,
            hp_max => 0,
            hp_percent => 0,
            distance => 0,
        };
    }

    # Distância
    my $dist = 0;
    if ($char && $char->{pos_to} && $t->{pos_to}) {
        $dist = int(Utils::distance($char->{pos_to}, $t->{pos_to}) || 0);
    }

    # HP e bounds (conserta typo hp_max)
    my $thp  = _i($t->{hp});
    my $tmax = _i($t->{hp_max});

    # Obtém nome do monstro de forma segura usando função auxiliar
    my $tname = normalize_string(get_monster_name($t));
    
    # Garante que todos os valores são numéricos válidos
    my $tnameID = get_monster_nameID($t);
    my $tlevel = _i($t->{lv} || 0);
    $thp = _i($thp || 0);
    $tmax = _i($tmax || 0);
    $dist = int($dist || 0);

    return {
        name       => $tname || '',
        nameID     => $tnameID,
        level      => $tlevel,
        hp         => $thp,
        hp_max     => $tmax,
        hp_percent => $tmax > 0 ? int(($thp / $tmax) * 100) : 0,
        distance   => $dist,
        exists     => JSON::true,
    };
}




# Retorna informações básicas de configuração do OpenKore
# Retorna: Hash com username, server e char
sub get_config_info {
    my %cfg = (
        username => $config{username} // 'N/A',
        server   => $config{master}   // 'N/A',
        char     => $config{char}     // 'N/A',
    );
    return \%cfg;
}

# ============================================================================
# SEÇÃO 19: FUNÇÕES DE PROXY E COMUNICAÇÃO ENTRE INSTÂNCIAS
# ============================================================================

# Identifica qual conta está rodando analisando o caminho do control folder
# Extrai informações de Ue-Kore0/Conta1, Ue-Kore3/Conta2, etc
# Retorna: ($kore_id, $account_id) - ex: ("Ue-Kore0", "Conta1")
sub get_account_info {
    my $account_id = 'N/A';
    my $kore_id = 'N/A';
    
    if (@Settings::controlFolders && defined $Settings::controlFolders[0]) {
        my $control_path = $Settings::controlFolders[0];
        # Tenta extrair Ue-Kore0/Conta1, Ue-Kore3/Conta2, etc do caminho
        if ($control_path =~ /[\/\\](Ue-Kore\d+)[\/\\](Conta\d+)/i) {
            $kore_id = $1;
            $account_id = $2;
        } elsif ($control_path =~ /[\/\\](Conta\d+)/i) {
            $account_id = $1;
            if ($control_path =~ /[\/\\](Ue-Kore\d+)/i) {
                $kore_id = $1;
            }
        }
    }
    
    return ($kore_id, $account_id);
}

# Retorna informações da instância atual (porta, personagem, mapa, etc)
# Usado pela página central para listar instâncias disponíveis
# Retorna: Hash com informações da instância atual
sub get_current_instance_info {
    my ($kore_id, $account_id) = get_account_info();
    
    my %info = (
        port => $port,
        host => $host,
        char_name => ($char && $char->{name}) ? normalize_string($char->{name}) : 'N/A',
        char_level => ($char && $char->{lv}) ? $char->{lv} : 0,
        map_name => ($field) ? $field->baseName() : 'N/A',
        kore_id => $kore_id,
        account_id => $account_id,
        account_label => "$kore_id - $account_id",
        username => $config{username} // 'N/A',
    );
    return \%info;
}

# Detecta e retorna lista de todas as instâncias do OpenKore disponíveis
# Tenta conectar nas portas comuns (8889-8894) para detectar outras instâncias
# Retorna: Hash com lista de instâncias detectadas (incluindo a atual)
sub get_available_instances {
    my @instances = ();
    
    # Adiciona a instância atual primeiro
    my ($kore_id, $account_id) = get_account_info();
    push @instances, {
        port => $port,
        host => $host,
        char_name => ($char && $char->{name}) ? normalize_string($char->{name}) : 'N/A',
        char_level => ($char && $char->{lv}) ? $char->{lv} : 0,
        map_name => ($field) ? $field->baseName() : 'N/A',
        kore_id => $kore_id,
        account_id => $account_id,
        account_label => "$kore_id - $account_id",
        username => $config{username} // 'N/A',
        active => JSON::true,
    };
    
    # Tenta detectar outras instâncias nas portas comuns
    # Sistema de portas:
    # - 8888: Página central (não detecta aqui, apenas contas específicas)
    # - Ue-Kore0: 8889, 8890, 8891 (Conta1, Conta2, Conta3)
    # - Ue-Kore3: 8892, 8893, 8894 (Conta1, Conta2, Conta3)
    my @common_ports = (8889, 8890, 8891, 8892, 8893, 8894);
    foreach my $test_port (@common_ports) {
        next if $test_port == $port; # Já temos esta instância
        
        # Tenta fazer uma requisição rápida para verificar se há instância rodando
        # Usa timeout curto (0.5s) para não bloquear o loop principal
        my $test_socket = eval {
            IO::Socket::INET->new(
                PeerHost => $host,
                PeerPort => $test_port,
                Proto    => 'tcp',
                Timeout  => 0.5
            );
        };
        
        if ($test_socket) {
            # Tenta fazer uma requisição GET simples
            eval {
                # Configura socket para bloquear temporariamente para enviar
                $test_socket->blocking(1);
                
                # Envia requisição
                my $request = "GET /api/current-instance HTTP/1.1\r\n";
                $request .= "Host: $host:$test_port\r\n";
                $request .= "Connection: close\r\n\r\n";
                
                print $test_socket $request;
                $test_socket->flush();
                
                # Muda para não-bloqueante para ler
                $test_socket->blocking(0);
                
                # Aguarda resposta
                my $response = '';
                my $start = time();
                my $timeout = 1.5; # Aumentado para 1.5 segundos
                my $header_received = 0;
                
                while (time() - $start < $timeout) {
                    my $buf;
                    my $bytes = sysread($test_socket, $buf, 4096);
                    
                    if (defined $bytes && $bytes > 0) {
                        $response .= $buf;
                        
                        # Verifica se recebeu o cabeçalho completo
                        if (!$header_received && $response =~ /\r\n\r\n/) {
                            $header_received = 1;
                            # Pequeno delay para garantir que todo o JSON foi enviado
                            select(undef, undef, undef, 0.1);
                        }
                        
                        # Se já recebeu o header, tenta ler mais uma vez e encerra
                        if ($header_received) {
                            select(undef, undef, undef, 0.05);
                            my $more_bytes = sysread($test_socket, $buf, 4096);
                            if (defined $more_bytes && $more_bytes > 0) {
                                $response .= $buf;
                            }
                            last;
                        }
                    } elsif (defined $bytes && $bytes == 0) {
                        # Conexão fechada
                        last;
                    } elsif (!defined $bytes) {
                        # Erro ou wouldblock
                        if ($! != POSIX::EWOULDBLOCK && $! != POSIX::EAGAIN) {
                            last;
                        }
                    }
                    select(undef, undef, undef, 0.01);
                }
                
                # Verifica se recebeu resposta HTTP 200
                if ($response =~ /HTTP\/1\.1\s+200/) {
                    # Extrai o corpo JSON (depois de \r\n\r\n)
                    my $json_body = '';
                    if ($response =~ /\r\n\r\n(.*)/s) {
                        $json_body = $1;
                        # Remove espaços em branco no início/fim
                        $json_body =~ s/^\s+|\s+$//g;
                    }
                    
                    # Tenta parsear JSON
                    if ($json_body && $json_body =~ /^\{/) {
                        my $data = eval { JSON->new->utf8->decode($json_body) };
                        if ($data && ref $data eq 'HASH' && defined $data->{char_name}) {
                            push @instances, {
                                port => $test_port,
                                host => $host,
                                char_name => normalize_string($data->{char_name} || 'N/A'),
                                char_level => $data->{char_level} || 0,
                                map_name => $data->{map_name} || 'N/A',
                                kore_id => $data->{kore_id} || 'N/A',
                                account_id => $data->{account_id} || 'N/A',
                                account_label => $data->{account_label} || ($data->{kore_id} || 'N/A') . ' - ' . ($data->{account_id} || 'N/A'),
                                username => $data->{username} || 'N/A',
                                active => JSON::true,
                            };
                        }
                    }
                }
            };
            
            eval { close($test_socket); };
        }
    }
    
    return { instances => \@instances };
}

# Faz proxy de requisição GET para outra instância do OpenKore
# Permite que a página central (8888) acesse dados de outras contas
# Parâmetros:
#   $client: Socket do cliente que fez a requisição
#   $target_port: Porta da instância alvo
#   $target_path: Caminho da requisição na instância alvo
sub handle_proxy_request {
    my ($client, $target_port, $target_path) = @_;
    
    # Evita loop infinito (não pode fazer proxy para si mesmo)
    if ($target_port == $port) {
        send_404($client);
        return;
    }
    
    # Conecta à instância alvo via socket TCP
    my $target_socket = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $target_port,
        Proto    => 'tcp',
        Timeout  => 1
    );
    
    unless ($target_socket) {
        send_json($client, { error => 'Instância não disponível' });
        return;
    }
    
    # Faz a requisição
    eval {
        print $target_socket "GET /$target_path HTTP/1.1\r\n";
        print $target_socket "Host: $host:$target_port\r\n";
        print $target_socket "Connection: close\r\n\r\n";
        
        my $response = '';
        $target_socket->blocking(0);
        my $start = time();
        while (time() - $start < 2) {
            my $buf;
            my $bytes = sysread($target_socket, $buf, 4096);
            if ($bytes > 0) {
                $response .= $buf;
            } else {
                last;
            }
            select(undef, undef, undef, 0.01);
        }
        
        # Extrai o corpo JSON da resposta
        if ($response =~ /\r\n\r\n(.*)/s) {
            my $json_body = $1;
            send_json($client, eval { JSON->new->utf8->decode($json_body) });
        } else {
            send_json($client, { error => 'Resposta inválida' });
        }
    };
    
    if ($@) {
        send_json($client, { error => 'Erro ao conectar: ' . $@ });
    }
    
    close($target_socket);
}

# Faz proxy de requisição POST para outra instância do OpenKore
# Similar a handle_proxy_request, mas para requisições POST (ações)
# Parâmetros:
#   $client: Socket do cliente que fez a requisição
#   $target_port: Porta da instância alvo
#   $target_path: Caminho da requisição na instância alvo
#   $body: Corpo da requisição POST (JSON)
sub handle_proxy_post_request {
    my ($client, $target_port, $target_path, $body) = @_;
    
    # Evita loop infinito (não pode fazer proxy para si mesmo)
    if ($target_port == $port) {
        send_404($client);
        return;
    }
    
    # Conecta à instância alvo via socket TCP
    my $target_socket = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $target_port,
        Proto    => 'tcp',
        Timeout  => 1
    );
    
    unless ($target_socket) {
        send_json($client, { error => 'Instância não disponível' });
        return;
    }
    
    # Faz a requisição POST
    eval {
        my $body_length = length($body);
        print $target_socket "POST /$target_path HTTP/1.1\r\n";
        print $target_socket "Host: $host:$target_port\r\n";
        print $target_socket "Content-Type: application/json\r\n";
        print $target_socket "Content-Length: $body_length\r\n";
        print $target_socket "Connection: close\r\n\r\n";
        print $target_socket $body;
        
        my $response = '';
        $target_socket->blocking(0);
        my $start = time();
        while (time() - $start < 2) {
            my $buf;
            my $bytes = sysread($target_socket, $buf, 4096);
            if ($bytes > 0) {
                $response .= $buf;
            } else {
                last;
            }
            select(undef, undef, undef, 0.01);
        }
        
        # Extrai o corpo JSON da resposta
        if ($response =~ /\r\n\r\n(.*)/s) {
            my $json_body = $1;
            send_json($client, eval { JSON->new->utf8->decode($json_body) });
        } else {
            send_json($client, { error => 'Resposta inválida' });
        }
    };
    
    if ($@) {
        send_json($client, { error => 'Erro ao conectar: ' . $@ });
    }
    
    close($target_socket);
}

# ============================================================================
# SEÇÃO 20: FUNÇÕES DE ITENS E CONFIGURAÇÃO
# ============================================================================

# Retorna detalhes de um item específico do inventário pelo índice
# Parâmetros:
#   $index: Índice do item no inventário
# Retorna: Hash com detalhes do item ou erro se não encontrado
sub get_item_details {
	my ($index) = @_;
	if ($char && $char->inventory()) {
		my $items = $char->inventory()->getItems();
		my $it = $items->[$index];
		if ($it) {
			my $idx = $it->{invIndex} // $it->{index} // $it->{binID} // $index;
			my $data = {
				name        => $it->name() || '',
				nameID      => _i($it->{nameID}),
				amount      => _i($it->{amount} // 1),
				type        => _i($it->{type}),
				identified  => $it->{identified} ? JSON::true : JSON::false,
				equipped    => $it->{equipped}   ? JSON::true : JSON::false,
				index       => _i($idx),
				description => get_item_description($it),
			};
            $data->{name} = normalize_string($data->{name});
            return $data;
		}
	}
	return { error => 'Item não encontrado' };

}

# Gera descrição textual de um item
# Retorna: String com informações básicas do item (ID, tipo, identificado, equipado)
sub get_item_description {
    my ($item) = @_;
    # Descrição básica do item (pode ser expandida no futuro)
    my $desc = "Item ID: " . normalize_string($item->{nameID} || 'N/A');
    $desc .= " | Tipo: " . ($item->{type} || 'N/A');
    $desc .= " | Identificado: " . ($item->{identified} ? 'Sim' : 'Não');
    $desc .= " | Equipado: " . ($item->{equipped} ? 'Sim' : 'Não');
    
    return $desc;
}

# Salva alterações de configuração do OpenKore
# Parâmetros:
#   $config_changes: Hash com chaves e valores a serem atualizados em %config
# Nota: Esta função apenas atualiza a variável %config em memória
#       Para persistir, seria necessário salvar em arquivo (não implementado)
sub save_config_changes {
    my ($config_changes) = @_;
    return unless ref $config_changes eq 'HASH';
    for my $key (keys %$config_changes) {
        $config{$key} = $config_changes->{$key} if defined $config_changes->{$key};
    }
}

# ============================================================================
# SEÇÃO 21: SISTEMA DE TRACKING DE MONSTROS MORTO E DROPS
# ============================================================================
# Implementação similar ao consolebridge.pl para tracking detalhado
# ============================================================================

# Hook para detectar quando um monstro desaparece (antes de ser removido)
sub on_monster_disappeared {
    my ($self, $args) = @_;
    return unless $args && $args->{monster};
    
    my $monster = $args->{monster};
    my $monster_id = eval { $monster->{ID} } // undef;
    return unless $monster_id;
    
    my $nameID = get_monster_nameID($monster);
    my $name = normalize_string(get_monster_name($monster));
    
    my $level = _i($monster->{lv});
    my $is_dead = (eval { $monster->{dead} } || 0) ? 1 : 0;
    
    my $dmgFromYou = eval { $monster->{dmgFromYou} } || 0;
    my $dmgFromParty = eval { $monster->{dmgFromParty} } || 0;
    
    # Sempre atualiza o cache de ataque, mesmo se não tiver nameID ou name
    $monster_attack_cache{$monster_id} = {
        name => $name || "Unknown Monster",
        nameID => $nameID,
        level => $level,
        last_attack_time => time(),
        dead => $is_dead,
        dmgFromYou => $dmgFromYou,
        dmgFromParty => $dmgFromParty,
    };
    
    # Se o monstro morreu, adiciona ao cache de monstros mortos recentes
    # Isso permite associar drops aos monstros mesmo antes do ganho de EXP ser detectado
    if ($is_dead) {
        $last_target_id = $monster_id;
        
        # Adiciona ao cache de monstros mortos recentes
        my $is_your_kill = ($dmgFromYou >= $dmgFromParty) ? 1 : 0;
        my $kill_time = time();
        $recent_killed_monsters{$monster_id} = {
            name => normalize_string($name || "Unknown Monster"),
            nameID => $nameID,
            level => $level,
            kill_time => $kill_time,
            is_your_kill => $is_your_kill,
        };
        
        # Limita o tamanho do cache
        if (scalar(keys %recent_killed_monsters) > 50) {
            my @sorted_keys = sort {
                ($recent_killed_monsters{$a}->{kill_time} || 0) <=> 
                ($recent_killed_monsters{$b}->{kill_time} || 0)
            } keys %recent_killed_monsters;
            for (my $i = 0; $i < 25 && $i < @sorted_keys; $i++) {
                delete $recent_killed_monsters{$sorted_keys[$i]};
            }
        }
    }
}

# Hook para detectar ganhos de EXP
sub on_stat_info {
    my ($self, $args) = @_;
    return unless $char && defined $char->{exp};
    
    my $current_exp = $char->{exp} || 0;
    my $current_level = $char->{lv} || 0;
    my $last_level = $session_stats{last_level} || $current_level;
    
    # Se o nível aumentou, apenas atualiza referências (o ganho de EXP já foi detectado antes)
    if ($current_level > $last_level) {
        $last_exp = $current_exp;
        $session_stats{last_level} = $current_level;
    } elsif ($last_exp > 0 && $current_exp > $last_exp) {
        # Ganho normal de EXP (sem level up)
        my $exp_gained = $current_exp - $last_exp;
        if ($exp_gained > 0) {
            register_monster_kill($exp_gained);
        }
        $last_exp = $current_exp;
    } elsif ($last_exp == 0 && $current_exp > 0) {
        # Primeira detecção de EXP (inicialização)
        $last_exp = $current_exp;
        $session_stats{last_level} = $current_level;
    } elsif ($current_exp < $last_exp && $current_level == $last_level) {
        # EXP diminuiu sem level up (pode ser reset ou erro) - atualiza last_exp mas não registra kill
        $last_exp = $current_exp;
    } else {
        # Atualiza last_exp mesmo se não houver ganho (para manter sincronizado)
        $last_exp = $current_exp;
    }
}

# Hook para detectar quando um item é coletado
sub on_item_gathered {
    my ($self, $args) = @_;
    return unless $args && $args->{item};
    
    # O hook passa o nome do item como string, não o objeto
    my $item_name_str = $args->{item};
    my $amount = $args->{amount} || 1;
    
    return unless $item_name_str && $item_name_str ne "";
    
    # Normaliza o nome do item
    my $item_name = normalize_string($item_name_str);
    # Não rejeita se o nome estiver vazio - pode ser um item desconhecido mas ainda válido
    $item_name = $item_name_str unless $item_name && $item_name ne "";
    return unless $item_name && $item_name ne "";
    
    # Busca o item no inventário para obter o nameID
    my $item_nameID = 0;
    
    if ($char && $char->inventory()) {
        my $items_ref = eval { $char->inventory()->getItems() };
        if ($items_ref && ref($items_ref) eq 'ARRAY') {
            # Procura o item pelo nome (busca do final para o início, pois o mais recente está no final)
            for (my $i = $#$items_ref; $i >= 0; $i--) {
                my $inv_item = $items_ref->[$i];
                next unless $inv_item;
                
                my $inv_name = get_item_name($inv_item);
                my $inv_name_original = '';
                eval {
                    if (blessed($inv_item) && $inv_item->can('name')) {
                        $inv_name_original = $inv_item->name() || '';
                    } elsif (defined $inv_item->{name}) {
                        $inv_name_original = eval { $inv_item->{name} } || '';
                    }
                };
                
                # Compara tanto o nome normalizado quanto o original
                if ($inv_name && (
                    $inv_name eq $item_name ||
                    ($inv_name_original && $inv_name_original eq $item_name_str)
                )) {
                    if (defined $inv_item->{nameID}) {
                        $item_nameID = _i($inv_item->{nameID});
                    } elsif (defined $inv_item->{binID}) {
                        $item_nameID = _i($inv_item->{binID});
                    }
                    last;
                }
            }
        }
    }
    
    # Se não encontrou o nameID, tenta buscar pelo nome original também (busca mais ampla)
    if ($item_nameID == 0 && $char && $char->inventory()) {
        my $items_ref = eval { $char->inventory()->getItems() };
        if ($items_ref && ref($items_ref) eq 'ARRAY') {
            # Busca reversa (do final para o início)
            for (my $i = $#$items_ref; $i >= 0; $i--) {
                my $inv_item = $items_ref->[$i];
                next unless $inv_item;
                
                my $inv_name = get_item_name($inv_item);
                my $inv_name_original = '';
                eval {
                    if (blessed($inv_item) && $inv_item->can('name')) {
                        $inv_name_original = $inv_item->name() || '';
                    } elsif (defined $inv_item->{name}) {
                        $inv_name_original = eval { $inv_item->{name} } || '';
                    }
                };
                
                # Compara sem normalização também (pode ser que o nome original bata)
                if ($inv_name && (
                    $inv_name eq $item_name_str ||
                    $inv_name eq $item_name ||
                    ($inv_name_original && $inv_name_original eq $item_name_str)
                )) {
                    if (defined $inv_item->{nameID}) {
                        $item_nameID = _i($inv_item->{nameID});
                    } elsif (defined $inv_item->{binID}) {
                        $item_nameID = _i($inv_item->{binID});
                    }
                    last;
                }
            }
        }
    }
    
    # Tenta associar o item a um monstro morto recentemente
    my $monster_name = "Unknown Monster";
    my $monster_nameID = 0;
    my $monster_level = 0;
    my $is_your_drop = 1;  # Por padrão, assume que é seu drop
    my $found_monster = 0;
    
    my $current_time = time();
    
    # Verifica se está em party com compartilhamento de itens ativado
    # Se sim, o padrão muda: assume que é drop da party a menos que prove o contrário
    my $in_party_with_sharing = 0;
    if ($char && $char->{party} && ref($char->{party}) eq 'HASH' && $char->{party}{joined}) {
        my $party_item_pickup = $char->{party}{itemPickup} // 0;
        if ($party_item_pickup > 0) {
            $in_party_with_sharing = 1;
            # Se está em party com compartilhamento, assume drop da party por padrão
            $is_your_drop = 0;
        }
    }
    
    # Procura no cache de monstros mortos recentes (últimos 5 segundos)
    # Prioriza o último monstro morto, mas busca o mais recente se não encontrar
    my $most_recent_kill = undef;
    my $most_recent_time = 0;
    
    # Primeiro tenta o last_target_id (mais provável)
    if ($last_target_id && exists $recent_killed_monsters{$last_target_id}) {
        my $killed = $recent_killed_monsters{$last_target_id};
        if ($killed && ref($killed) eq 'HASH') {
            my $kill_age = $current_time - ($killed->{kill_time} || 0);
            if ($kill_age <= $RECENT_KILL_CACHE_TIME) {
                $most_recent_kill = $killed;
                $most_recent_time = $killed->{kill_time} || 0;
                $found_monster = 1;
            }
        }
    }
    
    # Se não encontrou ou encontrou um muito antigo, procura o mais recente
    if (!$found_monster || ($most_recent_time > 0 && ($current_time - $most_recent_time) > 2)) {
        foreach my $key (keys %recent_killed_monsters) {
            my $killed = $recent_killed_monsters{$key};
            next unless $killed && ref($killed) eq 'HASH';
            
            my $kill_time = $killed->{kill_time} || 0;
            my $kill_age = $current_time - $kill_time;
            
            if ($kill_age <= $RECENT_KILL_CACHE_TIME && $kill_time > $most_recent_time) {
                $most_recent_kill = $killed;
                $most_recent_time = $kill_time;
                $found_monster = 1;
            }
        }
    }
    
    # Se encontrou um monstro, usa os dados dele
    # Garante que o nome está normalizado (pode ter sido armazenado antes da correção)
    if ($found_monster && $most_recent_kill) {
        $monster_name = normalize_string($most_recent_kill->{name} || "Unknown Monster");
        $monster_nameID = $most_recent_kill->{nameID} || 0;
        $monster_level = $most_recent_kill->{level} || 0;
        $is_your_drop = $most_recent_kill->{is_your_kill} ? 1 : 0;
    }
    
    # Se não encontrou monstro no cache mas está em party com compartilhamento,
    # verifica se há algum kill seu recente no histórico para determinar se é drop próprio
    if (!$found_monster && $in_party_with_sharing) {
        # Verifica se há algum kill seu nos últimos 10 segundos no cache
        my $has_recent_your_kill = 0;
        foreach my $key (keys %recent_killed_monsters) {
            my $killed = $recent_killed_monsters{$key};
            next unless $killed && ref($killed) eq 'HASH';
            
            if (($current_time - $killed->{kill_time}) <= 10 && $killed->{is_your_kill}) {
                $has_recent_your_kill = 1;
                last;
            }
        }
        
        # Se não há kill seu no cache, verifica também no histórico de kills
        if (!$has_recent_your_kill && @monsters_Killed > 0) {
            foreach my $entry (@monsters_Killed) {
                next unless $entry && ref($entry) eq 'HASH';
                if (defined $entry->{last_kill_time} && 
                    ($current_time - $entry->{last_kill_time}) <= 30) {
                    $has_recent_your_kill = 1;
                    last;
                }
            }
        }
        
        # Se encontrou kill seu recente, assume que é drop próprio
        if ($has_recent_your_kill) {
            $is_your_drop = 1;
        }
        # Caso contrário, mantém como drop da party (já definido acima)
    }
    
    # Registra o drop no array apropriado
    # Registra mesmo se não encontrou nameID - pode ser atualizado depois
    register_item_drop($item_name, $item_nameID, $amount, $monster_name, $monster_nameID, $monster_level, $is_your_drop);
    $session_stats{items_collected} += $amount;
    
    # Se não encontrou o nameID, tenta buscar novamente após um pequeno delay
    # (o item pode ainda não estar no inventário quando o hook é chamado)
    if ($item_nameID == 0 && $char && $char->inventory()) {
        # Tenta buscar novamente após 0.5 segundos (em um timer futuro)
        # Por enquanto, registra sem nameID - será atualizado na próxima busca
    }
}

# Hook para contar desconexões
sub on_disconnected {
    $dc_count++;
}

# Registra um kill de monstro no histórico
# Esta função é chamada quando detecta ganho de EXP, tentando identificar qual monstro foi morto
# Usa múltiplas estratégias de busca (cache de ataque, monsters_old, lista atual) para identificar o monstro
# Parâmetros:
#   $exp_gained: Quantidade de EXP ganha (usada para identificar o kill)
sub register_monster_kill {
    my ($exp_gained) = @_;
    
    my $monster_name = "Unknown Monster";
    my $monster_nameID = 0;
    my $monster_level = 0;
    my $is_your_kill = 1;  # Assume que é seu kill por padrão
    my $found_in_cache = 0;
    
    # Estratégia 1: Tenta encontrar no cache usando last_target_id (prioridade máxima)
    if ($last_target_id && exists $monster_attack_cache{$last_target_id}) {
        my $cached = $monster_attack_cache{$last_target_id};
        my $current_time = time();
        # Aceita se estiver marcado como dead OU se foi atacado muito recentemente (últimos 2 segundos)
        if ($cached->{dead} || (($current_time - $cached->{last_attack_time}) <= 2)) {
            $monster_name = $cached->{name} || "Unknown Monster";
            $monster_nameID = $cached->{nameID} || 0;
            $monster_level = $cached->{level} || 0;
            my $dmgFromYou = $cached->{dmgFromYou} || 0;
            my $dmgFromParty = $cached->{dmgFromParty} || 0;
            $is_your_kill = ($dmgFromYou >= $dmgFromParty) ? 1 : 0;
            $found_in_cache = 1;
            # Marca como dead se ainda não estiver marcado
            $cached->{dead} = 1;
            delete $monster_attack_cache{$last_target_id};
        }
    }
    
    # Estratégia 2: Se não encontrou, procura em qualquer monstro morto recentemente no cache
    # Busca em todos os monstros atacados nos últimos 5 segundos
    if (!$found_in_cache) {
        my $current_time = time();
        foreach my $cached_id (keys %monster_attack_cache) {
            my $cached = $monster_attack_cache{$cached_id};
            next unless $cached && ref($cached) eq 'HASH';
            # Aceita se estiver marcado como dead OU se foi atacado muito recentemente (últimos 2 segundos)
            next unless $cached->{dead} || (($current_time - $cached->{last_attack_time}) <= 2);
            
            # Se foi atacado nos últimos 5 segundos, assume que é o kill
            if (($current_time - $cached->{last_attack_time}) <= 5) {
                $monster_name = normalize_string($cached->{name} || "Unknown Monster");
                $monster_nameID = $cached->{nameID} || 0;
                $monster_level = $cached->{level} || 0;
                my $dmgFromYou = $cached->{dmgFromYou} || 0;
                my $dmgFromParty = $cached->{dmgFromParty} || 0;
                $is_your_kill = ($dmgFromYou >= $dmgFromParty) ? 1 : 0;
                $last_target_id = $cached_id;
                $found_in_cache = 1;
                # Marca como dead se ainda não estiver marcado
                $cached->{dead} = 1;
                delete $monster_attack_cache{$cached_id};
                last;
            }
        }
    }
    
    # Estratégia 3: Tenta encontrar em monsters_old (hash global do OpenKore com monstros removidos)
    if (!$found_in_cache && $last_target_id && exists $monsters_old{$last_target_id}) {
        my $old_monster = $monsters_old{$last_target_id};
        if ($old_monster && $old_monster->{dead}) {
            $monster_nameID = get_monster_nameID($old_monster);
            $monster_level = _i($old_monster->{lv});
            $monster_name = normalize_string(get_monster_name($old_monster));
            $monster_name = "Unknown Monster" unless $monster_name;
            
            my $dmgFromYou = eval { $old_monster->{dmgFromYou} } || 0;
            my $dmgFromParty = eval { $old_monster->{dmgFromParty} } || 0;
            $is_your_kill = ($dmgFromYou >= $dmgFromParty) ? 1 : 0;
            $found_in_cache = 1;
        }
    }
    
    # Estratégia 4: Fallback - procura no cache de monstros atacados recentemente
    # Mesmo que não estejam marcados como dead, se foi atacado muito recentemente, assume que é o kill
    if (!$found_in_cache && $last_target_id && exists $monster_attack_cache{$last_target_id}) {
        my $cached = $monster_attack_cache{$last_target_id};
        my $current_time = time();
        # Se foi atacado nos últimos 3 segundos, assume que é o kill
        if (($current_time - $cached->{last_attack_time}) <= 3) {
            $monster_name = normalize_string($cached->{name} || "Unknown Monster");
            $monster_nameID = $cached->{nameID} || 0;
            $monster_level = $cached->{level} || 0;
            my $dmgFromYou = $cached->{dmgFromYou} || 0;
            my $dmgFromParty = $cached->{dmgFromParty} || 0;
            $is_your_kill = ($dmgFromYou >= $dmgFromParty) ? 1 : 0;
            $found_in_cache = 1;
            # Marca como dead e remove do cache
            $cached->{dead} = 1;
            delete $monster_attack_cache{$last_target_id};
        }
    }
    
    # Estratégia 5: Último fallback - procura na lista atual de monstros
    # O monstro pode ainda estar na lista mas já ter morrido (HP muito baixo)
    if (!$found_in_cache && $last_target_id && $monstersList && $monstersList->can('getByID')) {
        my $monster = eval { $monstersList->getByID($last_target_id) };
        if ($monster) {
            # Verifica se o monstro está morto (HP = 0 ou muito baixo)
            my $monster_hp = _i($monster->{hp} || 0);
            my $monster_hp_max = _i($monster->{hp_max} || 1);
            # Se HP está muito baixo (menos de 5% ou igual a 0), assume que morreu
            if ($monster_hp <= 0 || ($monster_hp_max > 0 && ($monster_hp / $monster_hp_max) < 0.05)) {
                $monster_nameID = get_monster_nameID($monster);
                $monster_level = _i($monster->{lv});
                $monster_name = normalize_string(get_monster_name($monster));
                $monster_name = "Unknown Monster" unless $monster_name;
                
                # Tenta obter dmgFromYou do cache de ataque ou do monstro
                my $dmgFromYou = 0;
                if (exists $monster_attack_cache{$last_target_id}) {
                    $dmgFromYou = eval { $monster_attack_cache{$last_target_id}->{dmgFromYou} } || 0;
                } else {
                    $dmgFromYou = eval { $monster->{dmgFromYou} } || 0;
                }
                my $dmgFromParty = eval { $monster->{dmgFromParty} } || 0;
                $is_your_kill = ($dmgFromYou >= $dmgFromParty) ? 1 : 0;
                $found_in_cache = 1;
            }
        }
    }
    
    # Agora que identificou o monstro, registra no histórico apropriado
    # Separa entre seus kills e kills da party baseado em dmgFromYou vs dmgFromParty
    my $target_array = $is_your_kill ? \@monsters_Killed : \@monsters_Killed_party;
    my $found = 0;
    
    # Tenta encontrar entrada existente pelo nameID (busca mais precisa)
    if ($monster_nameID > 0) {
        foreach my $entry (@$target_array) {
            if ($entry && ref($entry) eq 'HASH' && $entry->{nameID} == $monster_nameID) {
                $entry->{count}++;
                $entry->{exp_gained} += $exp_gained;
                $entry->{last_kill_time} = time();
                if ($monster_level > 0) {
                    $entry->{level} = $monster_level;
                }
                if ($monster_name && $monster_name ne "Unknown Monster") {
                    $entry->{name} = $monster_name;
                }
                $found = 1;
                last;
            }
        }
    }
    
    # Se não encontrou pelo nameID, tenta encontrar pelo nome (fallback)
    if (!$found && $monster_name && $monster_name ne "Unknown Monster") {
        foreach my $entry (@$target_array) {
            if ($entry && ref($entry) eq 'HASH' && $entry->{name} eq $monster_name) {
                $entry->{count}++;
                $entry->{exp_gained} += $exp_gained;
                $entry->{last_kill_time} = time();
                if ($monster_nameID > 0) {
                    $entry->{nameID} = $monster_nameID;
                }
                if ($monster_level > 0) {
                    $entry->{level} = $monster_level;
                }
                $found = 1;
                last;
            }
        }
    }
    
    # Último recurso: se é "Unknown Monster", tenta agrupar por EXP similar
    # Agrupa kills desconhecidos que dão EXP similar (tolerância de 5%)
    if (!$found && $monster_name eq "Unknown Monster" && $exp_gained > 0) {
        my $tolerance = int($exp_gained * 0.05);  # Tolerância de 5% na EXP
        foreach my $entry (@$target_array) {
            next unless $entry && ref($entry) eq 'HASH';
            if ($entry->{name} eq "Unknown Monster" && $entry->{nameID} == 0) {
                # Calcula EXP média por kill desta entrada
                my $entry_exp_per_kill = ($entry->{count} > 0) ? 
                    int($entry->{exp_gained} / $entry->{count}) : 0;
                # Se a EXP é similar (dentro da tolerância), agrupa
                if ($entry_exp_per_kill > 0 && abs($exp_gained - $entry_exp_per_kill) <= $tolerance) {
                    $entry->{count}++;
                    $entry->{exp_gained} += $exp_gained;
                    $entry->{last_kill_time} = time();
                    $found = 1;
                    last;
                }
            }
        }
    }
    
    if (!$found) {
        push @$target_array, {
            nameID => $monster_nameID,
            name => normalize_string($monster_name),
            count => 1,
            level => $monster_level,
            exp_gained => $exp_gained,
            first_kill_time => time(),
            last_kill_time => time(),
        };
    }
    
    # Armazena no cache de monstros mortos recentes para associar drops aos monstros
    # Sempre armazena, mesmo se for "Unknown Monster", para permitir associação de drops
    # Garante que o nome está normalizado para evitar problemas de encoding
    my $kill_time = time();
    my $cache_key = $last_target_id || "kill_${kill_time}_${monster_nameID}";
    $recent_killed_monsters{$cache_key} = {
        name => normalize_string($monster_name),
        nameID => $monster_nameID,
        level => $monster_level,
        kill_time => $kill_time,
        is_your_kill => $is_your_kill,
    };
    
    # Limita o tamanho do cache para evitar crescimento infinito
    if (scalar(keys %recent_killed_monsters) > 50) {
        # Remove entradas mais antigas
        my @sorted_keys = sort {
            ($recent_killed_monsters{$a}->{kill_time} || 0) <=> 
            ($recent_killed_monsters{$b}->{kill_time} || 0)
        } keys %recent_killed_monsters;
        # Remove as 25 mais antigas
        for (my $i = 0; $i < 25 && $i < @sorted_keys; $i++) {
            delete $recent_killed_monsters{$sorted_keys[$i]};
        }
    }
    
    $session_stats{kills}++;
}

# Registra um item dropado no histórico
# Agrupa drops por item e monstro, separando entre seus drops e drops da party
# Parâmetros:
#   $item_name: Nome do item
#   $item_nameID: ID do item (0 se desconhecido)
#   $amount: Quantidade coletada
#   $monster_name: Nome do monstro que dropou
#   $monster_nameID: ID do monstro (0 se desconhecido)
#   $monster_level: Nível do monstro
#   $is_your_drop: 1 se foi drop de seu kill, 0 se foi drop da party
sub register_item_drop {
    my ($item_name, $item_nameID, $amount, $monster_name, $monster_nameID, $monster_level, $is_your_drop) = @_;
    
    # Aceita itens mesmo sem nome (pode ser "Unknown Item" mas ainda é um drop válido)
    return unless $item_name && $item_name ne "";
    
    my $target_array = $is_your_drop ? \@items_dropped_your : \@items_dropped_party;
    my $found = 0;
    
    # Busca mais precisa: por nameID do item E nameID do monstro
    if ($item_nameID > 0 && $monster_nameID > 0) {
        foreach my $entry (@$target_array) {
            if ($entry && ref($entry) eq 'HASH' && 
                $entry->{nameID} == $item_nameID && 
                $entry->{monster_nameID} == $monster_nameID) {
                $entry->{amount} += $amount;
                $entry->{last_drop_time} = time();
                if ($monster_level > 0) {
                    $entry->{monster_level} = $monster_level;
                }
                $found = 1;
                last;
            }
        }
    }
    
    # Busca por nameID do item apenas (ignora monstro se um dos dois for desconhecido)
    if (!$found && $item_nameID > 0) {
        foreach my $entry (@$target_array) {
            if ($entry && ref($entry) eq 'HASH' && $entry->{nameID} == $item_nameID) {
                # Agrupa se o monstro for desconhecido em uma das entradas
                if ($entry->{monster_nameID} == 0 || $monster_nameID == 0) {
                    $entry->{amount} += $amount;
                    $entry->{last_drop_time} = time();
                    if ($monster_nameID > 0 && $entry->{monster_nameID} == 0) {
                        $entry->{monster_nameID} = $monster_nameID;
                        $entry->{monster_name} = $monster_name;
                        $entry->{monster_level} = $monster_level;
                    }
                    $found = 1;
                    last;
                }
            }
        }
    }
    
    # Busca por nome do item (fallback quando nameID não está disponível)
    if (!$found && $item_name && $item_name ne "Unknown Item") {
        foreach my $entry (@$target_array) {
            if ($entry && ref($entry) eq 'HASH' && $entry->{name} eq $item_name) {
                # Agrupa se ambos têm o mesmo monstro OU ambos têm monstro desconhecido
                if (($monster_nameID > 0 && $entry->{monster_nameID} == $monster_nameID) ||
                    ($monster_nameID == 0 && $entry->{monster_nameID} == 0)) {
                    $entry->{amount} += $amount;
                    $entry->{last_drop_time} = time();
                    if ($monster_nameID > 0 && $entry->{monster_nameID} == 0) {
                        $entry->{monster_nameID} = $monster_nameID;
                        $entry->{monster_name} = $monster_name;
                        $entry->{monster_level} = $monster_level;
                    }
                    if ($item_nameID > 0 && $entry->{nameID} == 0) {
                        $entry->{nameID} = $item_nameID;
                    }
                    $found = 1;
                    last;
                }
            }
        }
    }
    
    if (!$found) {
        push @$target_array, {
            nameID => $item_nameID,
            name => $item_name,
            amount => $amount,
            monster_nameID => $monster_nameID,
            monster_name => $monster_name,
            monster_level => $monster_level,
            first_drop_time => time(),
            last_drop_time => time(),
        };
    }
}

# Limpa cache expirado no loop principal
# Remove entradas antigas dos caches para evitar crescimento infinito de memória
# - monster_attack_cache: Remove monstros não atacados há mais de CACHE_EXPIRE_TIME segundos
# - recent_killed_monsters: Remove monstros mortos há mais de RECENT_KILL_CACHE_TIME segundos
sub cleanup_expired_cache {
    my $current_time = time();
    foreach my $id (keys %monster_attack_cache) {
        if ($current_time - $monster_attack_cache{$id}{last_attack_time} > $CACHE_EXPIRE_TIME) {
            delete $monster_attack_cache{$id};
        }
    }
    foreach my $key (keys %recent_killed_monsters) {
        if ($current_time - $recent_killed_monsters{$key}{kill_time} > $RECENT_KILL_CACHE_TIME) {
            delete $recent_killed_monsters{$key};
        }
    }
}

# ============================================================================
# SEÇÃO 22: FUNÇÕES BUILDERS PARA API
# ============================================================================
# Funções que constroem dados detalhados para exportação via API
# ============================================================================

# Constrói estatísticas detalhadas de experiência (base e job)
# Calcula EXP ganha, EXP por hora, tempo estimado para próximo nível, etc
# Usa variáveis globais do OpenKore ($totalBaseExp, $totalJobExp, $startTime_EXP)
# Retorna: Hash com todas as estatísticas de experiência formatadas
sub build_experience_stats {
    my %stats;
    
    return \%stats unless $char;
    
    # Usa as variáveis globais do OpenKore (já atualizadas automaticamente pelo sistema)
    # $startTime_EXP: Timestamp de quando começou a ganhar EXP (usado para calcular EXP/hora)
    my $current_time = time();
    my $w_sec = 0;
    if (defined $startTime_EXP && $startTime_EXP > 0) {
        $w_sec = int($current_time - $startTime_EXP);  # Tempo decorrido em segundos
    }
    
    # EXP atual do personagem (base e job)
    my $current_base_exp = $char->{exp} || 0;
    my $current_job_exp = $char->{exp_job} || 0;
    
    # EXP máxima necessária para próximo nível (base e job)
    my $base_exp_max = $char->{exp_max} || 0;
    my $job_exp_max = $char->{exp_job_max} || 0;
    
    # EXP ganha desde o início da sessão (calcula diferença entre atual e inicial)
    my $sessionBaseExpGained = 0;
    my $sessionJobExpGained = 0;
    
    if ($initialBaseExp > 0 && $current_base_exp >= $initialBaseExp) {
        $sessionBaseExpGained = $current_base_exp - $initialBaseExp;
    } elsif ($initialBaseExp == 0 && $current_base_exp > 0) {
        $sessionBaseExpGained = $current_base_exp;
    }
    
    if ($initialJobExp > 0 && $current_job_exp >= $initialJobExp) {
        $sessionJobExpGained = $current_job_exp - $initialJobExp;
    } elsif ($initialJobExp == 0 && $current_job_exp > 0) {
        $sessionJobExpGained = $current_job_exp;
    }
    
    # EXP necessária para próximo nível
    my $baseExpNext = 0;
    my $jobExpNext = 0;
    
    if ($base_exp_max > 0 && $current_base_exp < $base_exp_max) {
        $baseExpNext = $base_exp_max - $current_base_exp;
    }
    
    if ($job_exp_max > 0 && $current_job_exp < $job_exp_max) {
        $jobExpNext = $job_exp_max - $current_job_exp;
    }
    
    # EXP por hora (calcula baseado no tempo decorrido e EXP total ganha)
    # $totalBaseExp e $totalJobExp são variáveis globais atualizadas pelo OpenKore
    my $perHourBaseExp = 0;
    my $perHourJobExp = 0;
    
    if ($w_sec > 0) {
        # Fórmula: (EXP total / tempo em segundos) * 3600 segundos por hora
        $perHourBaseExp = int(($totalBaseExp || 0) / $w_sec * 3600);
        $perHourJobExp = int(($totalJobExp || 0) / $w_sec * 3600);
    }
    
    # Tempo estimado para próximo nível (baseado na EXP/hora atual)
    # Se EXP/hora > 0, calcula quanto tempo falta para alcançar a EXP máxima
    my $levelupBaseEstimation = "0s";
    my $levelupJobEstimation = "0s";
    
    if ($base_exp_max && $perHourBaseExp > 0) {
        my $EstB_sec = int(($base_exp_max - $current_base_exp) / ($perHourBaseExp / 3600));
        $levelupBaseEstimation = format_time($EstB_sec);
    }
    
    if ($job_exp_max && $perHourJobExp > 0) {
        my $EstJ_sec = int(($job_exp_max - $current_job_exp) / ($perHourJobExp / 3600));
        $levelupJobEstimation = format_time($EstJ_sec);
    }
    
    # Zeny ganho desde o início
    my $zenyMade = 0;
    if ($char && defined $char->{zeny}) {
        my $current_zeny = $char->{zeny} || 0;
        my $start_zeny = $startingzeny || 0;
        if ($start_zeny > 0 && $current_zeny >= $start_zeny) {
            $zenyMade = $current_zeny - $start_zeny;
        } elsif ($start_zeny == 0 && $current_zeny > 0) {
            $zenyMade = $current_zeny;
        }
    }
    
    # Zeny por hora
    my $perHourZeny = 0;
    if ($w_sec > 0) {
        $perHourZeny = int($zenyMade / $w_sec * 3600);
    }
    
    # Formata tempo de botting
    my $bottingTime = format_time($w_sec);
    
    # Death count
    my $deathCount = $char->{deathCount} || 0;
    
    # Delta HP (não implementado no OpenKore padrão, retorna 0)
    my $deltaHp = 0;
    
    # Total EXP base e job
    my $totalBaseExp_value = $totalBaseExp || 0;
    my $totalJobExp_value = $totalJobExp || 0;
    
    %stats = (
        baseExpNext => $baseExpNext,
        bottingTime => $bottingTime,
        deathCount => $deathCount,
        deltaHp => $deltaHp,
        disconnectCount => $dc_count,
        jobExpNext => $jobExpNext,
        levelupBaseEstimation => $levelupBaseEstimation,
        levelupJobEstimation => $levelupJobEstimation,
        perHourBaseExp => $perHourBaseExp,
        perHourJobExp => $perHourJobExp,
        perHourZeny => $perHourZeny,
        sessionBaseExpGained => $sessionBaseExpGained,
        sessionJobExpGained => $sessionJobExpGained,
        time => $current_time,
        totalBaseExp => $totalBaseExp_value,
        totalJobExp => $totalJobExp_value,
        zenyMade => $zenyMade,
    );
    
    return \%stats;
}

# Constrói histórico de monstros mortos
sub build_monster_kills_history {
    my @history_list_your = ();
    foreach my $entry (@monsters_Killed) {
        next unless $entry && ref($entry) eq 'HASH';
        next if ($entry->{name} eq "" && $entry->{nameID} == 0);
        
        push @history_list_your, {
            nameID => $entry->{nameID} || 0,
            name => normalize_string($entry->{name} || "Unknown Monster"),
            count => $entry->{count} || 0,
            level => $entry->{level} || 0,
            exp_gained => $entry->{exp_gained} || 0,
            exp_per_kill => ($entry->{count} && $entry->{count} > 0) ? 
                int(($entry->{exp_gained} || 0) / $entry->{count}) : 0,
            first_kill_time => $entry->{first_kill_time} || time(),
            last_kill_time => $entry->{last_kill_time} || time(),
        };
    }
    
    my @history_list_party = ();
    foreach my $entry (@monsters_Killed_party) {
        next unless $entry && ref($entry) eq 'HASH';
        next if ($entry->{name} eq "" && $entry->{nameID} == 0);
        
        push @history_list_party, {
            nameID => $entry->{nameID} || 0,
            name => normalize_string($entry->{name} || "Unknown Monster"),
            count => $entry->{count} || 0,
            level => $entry->{level} || 0,
            exp_gained => $entry->{exp_gained} || 0,
            exp_per_kill => ($entry->{count} && $entry->{count} > 0) ? 
                int(($entry->{exp_gained} || 0) / $entry->{count}) : 0,
            first_kill_time => $entry->{first_kill_time} || time(),
            last_kill_time => $entry->{last_kill_time} || time(),
        };
    }
    
    @history_list_your = sort {
        $b->{count} <=> $a->{count} || 
        $b->{exp_gained} <=> $a->{exp_gained}
    } @history_list_your;
    
    @history_list_party = sort {
        $b->{count} <=> $a->{count} || 
        $b->{exp_gained} <=> $a->{exp_gained}
    } @history_list_party;
    
    my $index = 0;
    foreach my $entry (@history_list_your) {
        $entry->{index} = $index;
        $entry->{id} = $entry->{nameID};
        $index++;
    }
    
    $index = 0;
    foreach my $entry (@history_list_party) {
        $entry->{index} = $index;
        $entry->{id} = $entry->{nameID};
        $index++;
    }
    
    my $total_kills_your = 0;
    my $total_exp_your = 0;
    foreach my $entry (@history_list_your) {
        $total_kills_your += $entry->{count};
        $total_exp_your += $entry->{exp_gained};
    }
    
    my $total_kills_party = 0;
    my $total_exp_party = 0;
    foreach my $entry (@history_list_party) {
        $total_kills_party += $entry->{count};
        $total_exp_party += $entry->{exp_gained};
    }
    
    return {
        monsters_your_kills => \@history_list_your,
        total_kills_your => $total_kills_your,
        total_exp_gained_your => $total_exp_your,
        unique_monsters_your => scalar(@history_list_your),
        
        monsters_party_kills => \@history_list_party,
        total_kills_party => $total_kills_party,
        total_exp_gained_party => $total_exp_party,
        unique_monsters_party => scalar(@history_list_party),
        
        total_kills => $total_kills_your + $total_kills_party,
        total_exp_gained => $total_exp_your + $total_exp_party,
        unique_monsters => scalar(@history_list_your) + scalar(@history_list_party),
        
        last_update => time(),
    };
}

# Constrói histórico de drops de itens formatado para a API
# Separa entre drops de seus kills e drops da party
# Retorna: Hash com listas separadas, totais e estatísticas
sub build_items_drops_history {
    my @drops_list_your = ();
    foreach my $entry (@items_dropped_your) {
        next unless $entry && ref($entry) eq 'HASH';
        # Aceita itens que tenham nome OU amount > 0 (mesmo que seja "Unknown Item")
        next if (($entry->{name} eq "" || !defined $entry->{name}) && 
                 $entry->{nameID} == 0 && 
                 ($entry->{amount} || 0) == 0);
        
        push @drops_list_your, {
            nameID => $entry->{nameID} || 0,
            name => ($entry->{name} && $entry->{name} ne "") ? $entry->{name} : "Unknown Item",
            amount => $entry->{amount} || 0,
            monster_nameID => $entry->{monster_nameID} || 0,
            monster_name => $entry->{monster_name} || "Unknown Monster",
            monster_level => $entry->{monster_level} || 0,
            first_drop_time => $entry->{first_drop_time} || time(),
            last_drop_time => $entry->{last_drop_time} || time(),
        };
    }
    
    my @drops_list_party = ();
    foreach my $entry (@items_dropped_party) {
        next unless $entry && ref($entry) eq 'HASH';
        # Aceita itens que tenham nome OU amount > 0 (mesmo que seja "Unknown Item")
        next if (($entry->{name} eq "" || !defined $entry->{name}) && 
                 $entry->{nameID} == 0 && 
                 ($entry->{amount} || 0) == 0);
        
        push @drops_list_party, {
            nameID => $entry->{nameID} || 0,
            name => ($entry->{name} && $entry->{name} ne "") ? $entry->{name} : "Unknown Item",
            amount => $entry->{amount} || 0,
            monster_nameID => $entry->{monster_nameID} || 0,
            monster_name => $entry->{monster_name} || "Unknown Monster",
            monster_level => $entry->{monster_level} || 0,
            first_drop_time => $entry->{first_drop_time} || time(),
            last_drop_time => $entry->{last_drop_time} || time(),
        };
    }
    
    # Ordena por quantidade coletada (decrescente), depois por última vez coletado (mais recente primeiro)
    # Isso facilita visualização no dashboard (itens mais coletados aparecem primeiro)
    @drops_list_your = sort {
        $b->{amount} <=> $a->{amount} || 
        $b->{last_drop_time} <=> $a->{last_drop_time}
    } @drops_list_your;
    
    @drops_list_party = sort {
        $b->{amount} <=> $a->{amount} || 
        $b->{last_drop_time} <=> $a->{last_drop_time}
    } @drops_list_party;
    
    # Adiciona índice
    my $index = 0;
    foreach my $entry (@drops_list_your) {
        $entry->{index} = $index;
        $entry->{id} = $entry->{nameID};
        $index++;
    }
    
    $index = 0;
    foreach my $entry (@drops_list_party) {
        $entry->{index} = $index;
        $entry->{id} = $entry->{nameID};
        $index++;
    }
    
    # Calcula totais e itens únicos
    # Total amount: soma de todas as quantidades coletadas
    # Unique items: conta itens diferentes (usa nameID se disponível, senão usa nome)
    my $total_amount_your = 0;
    my $unique_items_your = 0;
    my %unique_items_hash_your = ();
    foreach my $entry (@drops_list_your) {
        $total_amount_your += $entry->{amount};
        # Usa nameID como chave única se disponível, senão usa o nome
        my $key = $entry->{nameID} > 0 ? $entry->{nameID} : $entry->{name};
        $unique_items_hash_your{$key} = 1 unless exists $unique_items_hash_your{$key};
    }
    $unique_items_your = scalar(keys %unique_items_hash_your);
    
    my $total_amount_party = 0;
    my $unique_items_party = 0;
    my %unique_items_hash_party = ();
    foreach my $entry (@drops_list_party) {
        $total_amount_party += $entry->{amount};
        my $key = $entry->{nameID} > 0 ? $entry->{nameID} : $entry->{name};
        $unique_items_hash_party{$key} = 1 unless exists $unique_items_hash_party{$key};
    }
    $unique_items_party = scalar(keys %unique_items_hash_party);
    
    return {
        items_your_drops => \@drops_list_your,
        total_amount_your => $total_amount_your,
        unique_items_your => $unique_items_your,
        
        items_party_drops => \@drops_list_party,
        total_amount_party => $total_amount_party,
        unique_items_party => $unique_items_party,
        
        total_amount => $total_amount_your + $total_amount_party,
        unique_items => $unique_items_your + $unique_items_party,
        
        last_update => time(),
    };
}

# Constrói informações da guilda formatadas para a API
# Similar ao consolebridge.pl - tenta múltiplas estruturas de dados do OpenKore
# Retorna: Hash com informações da guilda, membros, aliados, inimigos, etc
sub build_guild {
    my %info;

    if (%::guild && $::guild{name}) {
        my @guild_members = ();
        
        # Tenta múltiplas possíveis chaves para membros (estrutura varia entre versões do OpenKore)
        my $members_ref = undef;
        
        # Estratégia 1: Tenta como array primeiro
        if ($::guild{member} && ref($::guild{member}) eq 'ARRAY') {
            $members_ref = $::guild{member};
        } elsif ($::guild{members} && ref($::guild{members}) eq 'ARRAY') {
            $members_ref = $::guild{members};
        } elsif ($::guild{memberList} && ref($::guild{memberList}) eq 'ARRAY') {
            $members_ref = $::guild{memberList};
        }
        # Estratégia 2: Tenta como hash (converte para array)
        elsif ($::guild{member} && ref($::guild{member}) eq 'HASH') {
            $members_ref = [values %{$::guild{member}}];
        } elsif ($::guild{members} && ref($::guild{members}) eq 'HASH') {
            $members_ref = [values %{$::guild{members}}];
        }
        # Estratégia 3: Tenta através de método getMembers se disponível (objeto blessed)
        elsif (blessed($::guild) && $::guild->can('getMembers')) {
            eval {
                my $members_obj = $::guild->getMembers();
                if ($members_obj && ref($members_obj) eq 'ARRAY') {
                    $members_ref = $members_obj;
                } elsif ($members_obj && ref($members_obj) eq 'HASH') {
                    $members_ref = [values %$members_obj];
                }
            };
        }
        # Estratégia 4: Última tentativa - procura por qualquer chave que contenha "member"
        if (!$members_ref) {
            for my $key (keys %::guild) {
                next unless $key =~ /member/i;
                my $val = $::guild{$key};
                if (ref($val) eq 'ARRAY' && @$val > 0) {
                    if (@$val > 0 && ref($val->[0]) eq 'HASH') {
                        my $has_name = 0;
                        for my $name_key (qw(name Name NAME charName char_name)) {
                            if (defined $val->[0]{$name_key}) {
                                $has_name = 1;
                                last;
                            }
                        }
                        if ($has_name) {
                            $members_ref = $val;
                            last;
                        }
                    }
                } elsif (ref($val) eq 'HASH' && keys %$val > 0) {
                    my @vals = values %$val;
                    if (@vals > 0 && ref($vals[0]) eq 'HASH') {
                        my $has_name = 0;
                        for my $name_key (qw(name Name NAME charName char_name)) {
                            if (defined $vals[0]{$name_key}) {
                                $has_name = 1;
                                last;
                            }
                        }
                        if ($has_name) {
                            $members_ref = [values %$val];
                            last;
                        }
                    }
                }
            }
        }
        
        # Se encontrou referência de membros, processa
        if ($members_ref && @$members_ref > 0) {
            for my $member (@$members_ref) {
                next unless $member && ref($member) eq 'HASH';
                
                # Tenta encontrar o nome do membro em várias chaves possíveis
                my $member_name_key = undef;
                for my $name_key (qw(name Name NAME charName char_name)) {
                    if (defined $member->{$name_key} && $member->{$name_key} ne '') {
                        $member_name_key = $name_key;
                        last;
                    }
                }
                next unless $member_name_key;

                my $member_name = normalize_string($member->{$member_name_key} || 'Desconhecido');
                my $member_job = $member->{jobID} // $member->{job} // $member->{jobId} // 0;
                my $member_level = $member->{lv} // $member->{level} // $member->{Level} // 0;
                my $member_contribution = $member->{contribution} // $member->{contrib} // 0;
                my $member_online = ($member->{online} // $member->{Online} // 0) ? 1 : 0;
                my $member_title = normalize_string('Membro');

                if (defined $member->{position} && $::guild{positions} && ref($::guild{positions}) eq 'ARRAY') {
                    my $pos_index = $member->{position};
                    if ($pos_index >= 0 && $pos_index < @{$::guild{positions}} && 
                        $::guild{positions}[$pos_index] && 
                        $::guild{positions}[$pos_index]{title}) {
                        $member_title = normalize_string($::guild{positions}[$pos_index]{title});
                    }
                }

                my $normalized_member_name = normalize_string($member->{$member_name_key} // '');
                my $normalized_master = normalize_string($::guild{master} // '');
                if ($normalized_member_name && $normalized_master && 
                    $normalized_member_name eq $normalized_master && 
                    $member_title eq normalize_string('Membro')) {
                    $member_title = normalize_string('Líder');
                } elsif ($member->{title} && $member->{title} ne '' && $member_title eq normalize_string('Membro')) {
                    $member_title = normalize_string($member->{title});
                }

                push @guild_members, {
                    name => $member_name,
                    job => $member_job,
                    level => $member_level,
                    contribution => $member_contribution,
                    online => $member_online,
                    title => $member_title,
                };
            }
        }

        my $max_members = ($char && $char->{guild} && $char->{guild}{max_member}) ?
                          $char->{guild}{max_member} : ($::guild{maxMember} // $::guild{max_member} // 0);
        my $connect_members = ($char && $char->{guild} && $char->{guild}{connect_member}) ?
                              $char->{guild}{connect_member} : ($::guild{conMember} // $::guild{connect_member} // 0);

        $info{guild_info} = {
            name => normalize_string($::guild{name}),
            level => $::guild{lv} // 0,
            exp => $::guild{exp} // 0,
            exp_next => $::guild{exp_next} // 0,
            master => normalize_string($::guild{master} // ''),
            members => $members_ref ? scalar(@$members_ref) : 0,
            max_members => $max_members,
            connect_member => $connect_members,
            members_list => \@guild_members,
        };
    } elsif ($char && $char->{guild} && ref($char->{guild}) eq 'HASH' && $char->{guild}{name}) {
        # Tenta também buscar membros de $char->{guild} se disponível
        my @guild_members = ();
        my $char_members_ref = undef;
        
        if ($char->{guild}{member} && ref($char->{guild}{member}) eq 'ARRAY') {
            $char_members_ref = $char->{guild}{member};
        } elsif ($char->{guild}{members} && ref($char->{guild}{members}) eq 'ARRAY') {
            $char_members_ref = $char->{guild}{members};
        } elsif ($char->{guild}{memberList} && ref($char->{guild}{memberList}) eq 'ARRAY') {
            $char_members_ref = $char->{guild}{memberList};
        } elsif ($char->{guild}{member} && ref($char->{guild}{member}) eq 'HASH') {
            $char_members_ref = [values %{$char->{guild}{member}}];
        } elsif ($char->{guild}{members} && ref($char->{guild}{members}) eq 'HASH') {
            $char_members_ref = [values %{$char->{guild}{members}}];
        }
        
        if ($char_members_ref && @$char_members_ref > 0) {
            for my $member (@$char_members_ref) {
                next unless $member && ref($member) eq 'HASH';
                
                my $member_name_key = undef;
                for my $name_key (qw(name Name NAME charName char_name)) {
                    if (defined $member->{$name_key} && $member->{$name_key} ne '') {
                        $member_name_key = $name_key;
                        last;
                    }
                }
                next unless $member_name_key;
                
                my $member_name = normalize_string($member->{$member_name_key} || 'Desconhecido');
                my $normalized_master = normalize_string($char->{guild}{master} // '');
                my $normalized_member_name = normalize_string($member->{$member_name_key} // '');
                my $member_title = normalize_string('Membro');
                
                if ($normalized_member_name && $normalized_master && 
                    $normalized_member_name eq $normalized_master) {
                    $member_title = normalize_string('Líder');
                } elsif ($member->{title} && $member->{title} ne '') {
                    $member_title = normalize_string($member->{title});
                }
                
                push @guild_members, {
                    name => $member_name,
                    job => $member->{jobID} // $member->{job} // $member->{jobId} // 0,
                    level => $member->{lv} // $member->{level} // $member->{Level} // 0,
                    contribution => $member->{contribution} // $member->{contrib} // 0,
                    online => ($member->{online} // $member->{Online} // 0) ? 1 : 0,
                    title => $member_title,
                };
            }
        }
        
        $info{guild_info} = {
            name => normalize_string($char->{guild}{name}),
            level => $char->{guild}{lv} // 0,
            exp => $char->{guild}{exp} // 0,
            exp_next => $char->{guild}{exp_next} // 0,
            master => normalize_string($char->{guild}{master} // ''),
            members => $char->{guild}{members_count} // scalar(@guild_members),
            max_members => $char->{guild}{max_member} // 0,
            connect_member => $char->{guild}{connect_member} // 0,
            members_list => \@guild_members,
        };
    }

    return \%info;
}

# Constrói informações da party formatadas para a API
# Extrai dados dos membros da party, configurações de compartilhamento, etc
# Retorna: Hash com informações da party e lista de membros
sub build_party {
    my %info;
    if ($char && $char->{party} && ref($char->{party}) eq 'HASH') {
        my @party_members = ();
        # $char->{party}{users} é um hash onde cada chave é um ID de membro
        if ($char->{party}{users} && ref($char->{party}{users}) eq 'HASH') {
            for my $ID (keys %{$char->{party}{users}}) {
                my $p = $char->{party}{users}{$ID};
                next unless $p && (ref($p) eq 'Actor::Party' || ref($p) eq 'HASH');
                
                my $name = normalize_string($p->{name} || 'Desconhecido');
                my $level = $p->{lv} // 0;
                my $jobID = $p->{jobID} || 'Desconhecido';
                my $map = normalize_string($p->{map} || '???');
                my $online = $p->{online} ? 1 : 0;
                my $admin = $p->{admin} ? 1 : 0;
                my $position = $admin ? normalize_string('Lider') : normalize_string('Membro');
                
                push @party_members, {
                    name => $name,
                    level => $level,
                    job => $jobID,
                    map => $map,
                    online => $online,
                    admin => $admin,
                    position => $position,
                };
            }
        }
        
        $info{party_info} = {
            name => normalize_string($char->{party}{name} // ''),
            members => scalar @party_members,
            members_list => \@party_members,
            exp_share => $char->{party}{share} // 0,
            item_pickup => $char->{party}{itemPickup} // 0,
            item_division => $char->{party}{itemDivision} // 0,
        };
    }
    return \%info;
}

# ============================================================================
# SEÇÃO 23: FUNÇÕES GETTERS PARA API
# ============================================================================
# Wrappers que retornam dados formatados para a API
# ============================================================================

sub get_experience_stats {
    return build_experience_stats();
}

sub get_monster_kills_history {
    return build_monster_kills_history();
}

sub get_items_drops_history {
    return build_items_drops_history();
}

sub get_guild_data {
    return build_guild();
}

sub get_party_data {
    return build_party();
}

# ============================================================================
# SEÇÃO 24: GERAÇÃO DO HTML DO DASHBOARD
# ============================================================================
# Retorna o HTML completo do dashboard web, incluindo:
# - HTML estrutural
# - CSS inline com tema dark moderno
# - JavaScript para comunicação com a API e atualização em tempo real
# ============================================================================

sub get_dashboard_html {
    return q{<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenKore Dashboard</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Fira+Code:wght@400;500&display=swap" rel="stylesheet">
    
    <style>
        :root {
            /* Tema Escuro (padrão) */
            --bg-primary: #0D1117;
            --bg-secondary: #161B22;
            --bg-tertiary: #21262D;
            --border-primary: #30363D;
            --text-primary: #C9D1D9;
            --text-secondary: #8B949E;
            --text-tertiary: #58A6FF;
            
            /* Cores Vibrantes (do original) */
            --hp-gradient: linear-gradient(90deg, #ff4444, #ff6b6b);
            --sp-gradient: linear-gradient(90deg, #4444ff, #6b6bff);
            --exp-gradient: linear-gradient(90deg, #44ff44, #6bff6b);
            --weight-gradient: linear-gradient(90deg, #ffaa00, #ffcc00);
            
            --ai-off-bg: #ff4444;
            --ai-off-text: #fff;
            --ai-on-bg: #44ff44;
            --ai-on-text: #000;
            --ai-auto-bg: #ffaa00;
            --ai-auto-text: #000;
            
            --accent-green: #3FB950;
            --accent-red: #DA3633;
            --accent-yellow: #E3B341;
            --accent-purple: #A371F7;
            --accent-blue: #388BFD;
            
            --font-primary: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            --font-mono: 'Fira Code', 'Consolas', 'Courier New', monospace;
        }
        
        /* Tema Claro - Cores mais suaves (não muito claras) */
        body.light-theme {
            --bg-primary: #F5F7FA;
            --bg-secondary: #E8ECF1;
            --bg-tertiary: #D6DCE3;
            --border-primary: #C4CBD4;
            --text-primary: #1F2937;
            --text-secondary: #4B5563;
            --text-tertiary: #0969DA;
            
            /* Cores Vibrantes mantidas (mas com ajustes para contraste) */
            --hp-gradient: linear-gradient(90deg, #ff4444, #ff6b6b);
            --sp-gradient: linear-gradient(90deg, #4444ff, #6b6bff);
            --exp-gradient: linear-gradient(90deg, #44ff44, #6bff6b);
            --weight-gradient: linear-gradient(90deg, #ffaa00, #ffcc00);
            
            --ai-off-bg: #ff4444;
            --ai-off-text: #fff;
            --ai-on-bg: #44ff44;
            --ai-on-text: #000;
            --ai-auto-bg: #ffaa00;
            --ai-auto-text: #000;
            
            --accent-green: #2DA44E;
            --accent-red: #CF222E;
            --accent-yellow: #D4A72C;
            --accent-purple: #8250DF;
            --accent-blue: #0969DA;
        }
        
        /* Ajustes para elementos mobile no tema claro */
        body.light-theme .mobile-header-title {
            background: rgba(245, 247, 250, 0.98) !important;
            backdrop-filter: blur(20px);
            box-shadow: 0 2px 20px rgba(0,0,0,0.08);
            border-bottom: 1px solid var(--border-primary);
        }
        
        body.light-theme .mobile-account-selector {
            background: rgba(245, 247, 250, 0.98) !important;
            backdrop-filter: blur(20px);
            box-shadow: 0 2px 20px rgba(0,0,0,0.08);
            border-bottom: 1px solid var(--border-primary);
        }
        
        body.light-theme .mobile-navbar {
            background: rgba(245, 247, 250, 0.98) !important;
            backdrop-filter: blur(20px);
            box-shadow: 0 -2px 20px rgba(0,0,0,0.08);
            border-top: 1px solid var(--border-primary);
        }
        
        /* Ajustes para elementos mobile no tema escuro (garantir consistência) */
        body:not(.light-theme) .mobile-header-title {
            background: rgba(13, 17, 23, 0.98) !important;
            backdrop-filter: blur(20px);
            box-shadow: 0 2px 20px rgba(0,0,0,0.3);
            border-bottom: 1px solid var(--border-primary);
        }
        
        body:not(.light-theme) .mobile-account-selector {
            background: rgba(13, 17, 23, 0.98) !important;
            backdrop-filter: blur(20px);
            box-shadow: 0 2px 20px rgba(0,0,0,0.3);
            border-bottom: 1px solid var(--border-primary);
        }
        
        body:not(.light-theme) .mobile-navbar {
            background: rgba(13, 17, 23, 0.98) !important;
            backdrop-filter: blur(20px);
            box-shadow: 0 -2px 20px rgba(0,0,0,0.3);
            border-top: 1px solid var(--border-primary);
        }
        
        /* Ajustes para canvas do mapa */
        body:not(.light-theme) .map-canvas-container {
            background: #000;
        }
        
        body.light-theme .map-canvas-container {
            background: #E8ECF1;
        }
        
        * { margin: 0; padding: 0; box-sizing: border-box; }
        
        body {
            font-family: var(--font-primary);
            background: var(--bg-primary);
            color: var(--text-primary);
            font-size: 14px;
        }
        
        .dashboard-layout {
            display: flex;
            height: 100vh;
        }

        /* --- Barra Lateral (Desktop) --- */
        .sidebar {
            width: 280px;
            height: 100vh;
            background: var(--bg-secondary);
            border-right: 1px solid var(--border-primary);
            display: flex;
            flex-direction: column;
            padding: 20px;
            overflow-y: auto;
            position: fixed;
            left: 0;
            top: 0;
            flex-shrink: 0;
        }
        
        .sidebar-header {
            display: flex;
            align-items: center;
            gap: 10px;
            font-size: 1.1em;
            font-weight: 600;
            margin-bottom: 20px;
            white-space: nowrap;
            min-width: fit-content;
        }
        
        /* Seletor de Conta */
        .account-selector {
            display: flex;
            align-items: center;
            gap: 8px;
            margin-bottom: 15px;
            padding: 10px;
            background: var(--bg-tertiary);
            border-radius: 8px;
            border: 1px solid var(--border-primary);
        }
        
        .account-selector-label {
            font-size: 0.85em;
            color: var(--text-secondary);
            font-weight: 600;
            white-space: nowrap;
        }
        
        .account-select {
            flex: 1;
            background: var(--bg-primary);
            border: 1px solid var(--border-primary);
            border-radius: 6px;
            padding: 8px 12px;
            color: var(--text-primary);
            font-size: 0.9em;
            font-weight: 500;
            cursor: pointer;
            transition: all 0.3s ease;
        }
        
        .account-select:hover {
            border-color: var(--accent-blue);
        }
        
        .account-select:focus {
            outline: none;
            border-color: var(--accent-blue);
            box-shadow: 0 0 0 3px rgba(56, 139, 253, 0.1);
        }
        
        .account-select option {
            background: var(--bg-primary);
            color: var(--text-primary);
        }
        
        .mobile-header-title {
            display: none; /* Oculto no desktop */
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            padding: 15px;
            background: var(--bg-secondary);
            backdrop-filter: blur(20px);
            border-bottom: 1px solid var(--border-primary);
            text-align: center;
            font-size: 1.1em;
            font-weight: 600;
            color: var(--text-primary);
            align-items: center;
            justify-content: center;
            gap: 10px;
            z-index: 1000;
            box-shadow: 0 2px 20px rgba(0,0,0,0.3);
        }
        
        /* Mobile Header - Tema Escuro (padrão) */
        body:not(.light-theme) .mobile-header-title {
            background: rgba(13, 17, 23, 0.98);
            box-shadow: 0 2px 20px rgba(0,0,0,0.3);
        }
        
        /* Mobile Header - Tema Claro */
        body.light-theme .mobile-header-title {
            background: rgba(245, 247, 250, 0.98);
            box-shadow: 0 2px 20px rgba(0,0,0,0.08);
        }
        
        .mobile-header-title .status-dot {
            width: 10px;
            height: 10px;
        }
        
        .mobile-account-selector {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            padding: 10px 15px;
            background: var(--bg-secondary);
            backdrop-filter: blur(20px);
            border-bottom: 1px solid var(--border-primary);
            z-index: 999;
            box-shadow: 0 2px 20px rgba(0,0,0,0.3);
        }
        
        /* Mobile Account Selector - Tema Escuro (padrão) */
        body:not(.light-theme) .mobile-account-selector {
            background: rgba(13, 17, 23, 0.98);
            box-shadow: 0 2px 20px rgba(0,0,0,0.3);
        }
        
        /* Mobile Account Selector - Tema Claro */
        body.light-theme .mobile-account-selector {
            background: rgba(245, 247, 250, 0.98);
            box-shadow: 0 2px 20px rgba(0,0,0,0.08);
        }
        
        .mobile-account-selector .account-select {
            width: 100%;
        }
        
        @media (max-width: 900px) {
            .mobile-header-title {
                display: flex; /* Mostra no mobile */
            }
            .mobile-account-selector {
                display: block;
                /* O top será ajustado dinamicamente via JavaScript baseado na altura do header-title */
            }
            /* Ajusta o padding do main-content para não ficar escondido atrás dos elementos fixos */
            .main-content {
                padding-top: 0; /* Será ajustado dinamicamente via JavaScript */
            }
        }
        
        .status-dot {
            width: 12px;
            height: 12px;
            border-radius: 50%;
            background: var(--accent-green);
            box-shadow: 0 0 10px var(--accent-green);
            transition: background 0.3s;
        }
        
        .status-dot.error {
            background: var(--accent-red);
            box-shadow: 0 0 10px var(--accent-red);
        }

        .ai-controls {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 8px;
            margin-bottom: 24px;
        }

        .ai-btn {
            padding: 12px 8px;
            border: 2px solid transparent;
            border-radius: 12px;
            cursor: pointer;
            font-weight: 700;
            font-size: 0.8em;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            line-height: 1.4;
            min-height: 60px;
            text-align: center;
            white-space: normal;
            word-wrap: break-word;
            width: 100%;
            box-sizing: border-box;
            position: relative;
            overflow: hidden;
            box-shadow: 0 2px 8px rgba(0,0,0,0.2);
            backdrop-filter: blur(10px);
        }
        
        .ai-btn > * {
            position: relative;
            z-index: 1;
        }
        
        .ai-btn::before {
            content: '';
            position: absolute;
            top: 0;
            left: -100%;
            width: 100%;
            height: 100%;
            background: linear-gradient(90deg, transparent, rgba(255,255,255,0.3), transparent);
            transition: left 0.5s;
        }
        
        .ai-btn:hover::before {
            left: 100%;
        }
        
        .ai-btn:hover {
            transform: translateY(-3px) scale(1.02);
            box-shadow: 0 6px 20px rgba(0,0,0,0.4);
        }
        
        .ai-btn:active {
            transform: translateY(-1px) scale(0.98);
        }
        
        .ai-btn.off { 
            background: linear-gradient(135deg, #ff4444 0%, #ff6b6b 100%);
            color: #fff;
            border-color: rgba(255,255,255,0.3);
            box-shadow: 0 2px 8px rgba(255,68,68,0.3);
        }
        
        .ai-btn.off:hover {
            box-shadow: 0 6px 20px rgba(255,68,68,0.5);
            background: linear-gradient(135deg, #ff5555 0%, #ff7b7b 100%);
        }
        
        .ai-btn.on { 
            background: linear-gradient(135deg, #44ff44 0%, #6bff6b 100%);
            color: #000;
            border-color: rgba(0,0,0,0.2);
            box-shadow: 0 2px 8px rgba(68,255,68,0.3);
        }
        
        .ai-btn.on:hover {
            box-shadow: 0 6px 20px rgba(68,255,68,0.5);
            background: linear-gradient(135deg, #55ff55 0%, #7bff7b 100%);
        }
        
        .ai-btn.auto { 
            background: linear-gradient(135deg, #ffaa00 0%, #ffcc00 100%);
            color: #000;
            border-color: rgba(0,0,0,0.2);
            box-shadow: 0 2px 8px rgba(255,170,0,0.3);
        }
        
        .ai-btn.auto:hover {
            box-shadow: 0 6px 20px rgba(255,170,0,0.5);
            background: linear-gradient(135deg, #ffbb11 0%, #ffdd11 100%);
        }

        /* Botão de Alternância de Tema */
        .theme-toggle {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            width: 100%;
            padding: 12px 16px;
            margin-bottom: 20px;
            background: var(--bg-tertiary);
            border: 2px solid var(--border-primary);
            border-radius: 8px;
            cursor: pointer;
            font-weight: 600;
            font-size: 0.9em;
            color: var(--text-primary);
            transition: all 0.3s ease;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        
        .theme-toggle:hover {
            background: var(--bg-secondary);
            border-color: var(--accent-blue);
            transform: translateY(-2px);
            box-shadow: 0 4px 8px rgba(0,0,0,0.15);
        }
        
        .theme-toggle:active {
            transform: translateY(0);
        }
        
        .theme-toggle-icon {
            font-size: 1.2em;
            transition: transform 0.3s ease;
        }
        
        .theme-toggle:hover .theme-toggle-icon {
            transform: rotate(180deg);
        }
        
        body.light-theme .theme-toggle {
            box-shadow: 0 2px 4px rgba(0,0,0,0.05);
        }
        
        body.light-theme .theme-toggle:hover {
            box-shadow: 0 4px 8px rgba(0,0,0,0.1);
        }
        
        /* Botão de tema no mobile - versão compacta */
        .theme-toggle-mobile {
            display: none; /* Oculto no desktop */
            width: 100%;
            padding: 10px 12px;
            margin-top: 12px;
            background: var(--bg-tertiary);
            border: 2px solid var(--border-primary);
            border-radius: 8px;
            cursor: pointer;
            font-weight: 600;
            font-size: 0.85em;
            color: var(--text-primary);
            transition: all 0.3s ease;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            justify-content: center;
            align-items: center;
            gap: 8px;
        }
        
        .theme-toggle-mobile:hover {
            background: var(--bg-secondary);
            border-color: var(--accent-blue);
            transform: translateY(-2px);
            box-shadow: 0 4px 8px rgba(0,0,0,0.15);
        }
        
        .theme-toggle-mobile:active {
            transform: translateY(0);
        }
        
        .theme-toggle-mobile-icon {
            font-size: 1.1em;
            transition: transform 0.3s ease;
        }
        
        .theme-toggle-mobile:hover .theme-toggle-mobile-icon {
            transform: rotate(180deg);
        }
        
        @media (max-width: 900px) {
            .theme-toggle-mobile {
                display: flex; /* Mostra no mobile */
            }
        }
        
        .sidebar-section {
            margin-bottom: 20px;
        }
        
        /* Estilos específicos para a seção de comandos no sidebar */
        #cardCommands .chat-input-group {
            width: 100%;
            margin-top: 12px;
        }
        
        #cardCommands .chat-input {
            flex: 1;
            min-width: 120px; /* Largura mínima para o input */
        }
        
        #cardCommands .send-btn {
            min-width: 60px;
            padding: 8px 12px;
            flex-shrink: 0;
        }

        .sidebar-section-title {
            font-size: 0.9em;
            font-weight: 600;
            color: var(--text-secondary);
            margin-bottom: 15px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .char-info {
            display: flex;
            flex-direction: column;
            gap: 10px;
            font-size: 0.95em;
        }
        .char-info .info-row {
            display: flex;
            justify-content: space-between;
        }
        .char-info .label { color: var(--text-secondary); }
        .char-info .value { font-weight: 600; color: var(--text-primary); }
        .char-info .value.zeny { color: var(--accent-yellow); }

        .vitals {
            display: flex;
            flex-direction: column;
            gap: 12px;
        }
        
        .vital .progress-label {
            display: flex;
            justify-content: space-between;
            font-size: 0.8em;
            color: var(--text-secondary);
            margin-bottom: 4px;
        }
        .vital .value { font-weight: 600; color: var(--text-primary); }
        
        .progress-bar {
            width: 100%;
            height: 10px;
            background: var(--bg-tertiary);
            border-radius: 5px;
            overflow: hidden;
        }
        .progress-fill {
            height: 100%;
            transition: width 0.3s;
            font-size: 0;
        }

        .progress-fill.hp { background: var(--hp-gradient); }
        .progress-fill.sp { background: var(--sp-gradient); }
        .progress-fill.exp { background: var(--exp-gradient); }
        .progress-fill.weight { background: var(--weight-gradient); }

        .stats-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 10px;
        }
        .stat-box {
            background: var(--bg-tertiary);
            padding: 10px;
            border-radius: 6px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .stat-box-label {
            font-weight: 600;
            color: var(--text-secondary);
        }
        .stat-box-value {
            font-size: 1.2em;
            font-weight: 700;
            color: var(--text-primary);
        }
        .stat-upgrade-btn {
            background: var(--accent-green);
            color: #fff;
            border: none;
            width: 20px;
            height: 20px;
            border-radius: 50%;
            cursor: pointer;
            font-weight: 700;
            display: none; /* JS controla */
        }
        .stat-upgrade-btn.show { display: block; }
        
        .session-stats {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 10px;
        }
        .session-stat {
            background: var(--bg-tertiary);
            padding: 12px;
            border-radius: 6px;
            text-align: center;
        }
        .session-stat-value {
            font-size: 1.3em;
            font-weight: 700;
            color: var(--accent-green);
        }
        .session-stat-label {
            font-size: 0.8em;
            color: var(--text-secondary);
            margin-top: 3px;
        }
        
        .command-panel {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 8px;
            margin-bottom: 12px;
        }
        .cmd-btn {
            background: var(--bg-tertiary);
            border: 1px solid var(--border-primary);
            color: var(--text-secondary);
            padding: 10px;
            border-radius: 5px;
            cursor: pointer;
            font-size: 0.9em;
            font-weight: 500;
            text-align: left;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .cmd-btn:hover {
            border-color: var(--text-secondary);
            color: var(--text-primary);
        }
        .chat-input-group {
            display: flex;
            gap: 8px;
            align-items: stretch;
        }
        .chat-input {
            flex: 1;
            min-width: 0; /* Permite que o input encolha */
            background: var(--bg-primary);
            border: 1px solid var(--border-primary);
            color: var(--text-primary);
            padding: 8px 12px;
            border-radius: 6px;
            font-family: var(--font-primary);
            font-size: 0.9em;
        }
        .chat-input:focus {
            outline: none;
            border-color: var(--accent-blue);
        }
        .send-btn {
            background: var(--accent-blue);
            color: #fff;
            border: none;
            padding: 8px 16px;
            min-width: 60px; /* Largura mínima para o botão não ficar espremido */
            border-radius: 6px;
            cursor: pointer;
            font-weight: 600;
            white-space: nowrap; /* Evita quebra de linha no texto */
            flex-shrink: 0; /* Não permite que o botão encolha */
        }
        .send-btn:hover {
            background: var(--accent-blue-dark);
        }

        /* --- Conteúdo Principal --- */
        .main-content {
            flex: 1;
            overflow-y: auto;
            padding: 24px;
            margin-left: 280px; /* Largura da sidebar */
        }
        
        .main-grid {
            display: grid;
            grid-template-columns: minmax(0, 1.2fr) minmax(0, 1fr);
            gap: 20px;
        }
        
        .main-grid.three-columns {
            grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(0, 1fr);
        }
        
        @media (min-width: 1600px) {
            .main-grid {
                grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(0, 1fr);
            }
        }
        
        .main-column {
            display: flex;
            flex-direction: column;
            gap: 20px;
        }
        
        .main-column-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
        }
        
        @media (max-width: 1200px) {
            .main-column-grid {
                grid-template-columns: 1fr;
            }
        }

        .card {
            background: var(--bg-secondary);
            border: 1px solid var(--border-primary);
            border-radius: 8px;
            display: flex;
            flex-direction: column;
            overflow: hidden; /* Para conter o mapa/chat */
        }
        
        /* Card de Header para Mobile */
        .mobile-header-card {
            display: none; /* Oculto no desktop */
        }
        
        /* Ajuste específico para o card-title do mobile-header-card */
        .mobile-header-card .card-title {
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            gap: 15px;
            width: 100%;
        }
        
        .mobile-char-info {
            display: flex;
            flex-direction: column;
            align-items: flex-start;
            flex: 1;
            min-width: 0; /* Permite que o conteúdo encolha se necessário */
        }
        
        .mobile-char-job {
            font-size: 0.85em;
            color: var(--text-secondary);
            margin-top: 2px;
        }
        
        .mobile-header-card .card-title .value {
            margin-left: auto;
            flex-shrink: 0;
            white-space: nowrap;
            text-align: right;
            align-self: flex-start;
            padding-top: 2px; /* Alinha verticalmente com o nome */
        }
        
        /* Card de Comandos Mobile */
        .mobile-commands-card {
            display: none; /* Oculto no desktop */
        }
        
        .mobile-command-panel {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 10px;
            margin-bottom: 15px;
        }
        
        .mobile-cmd-btn {
            background: var(--bg-tertiary);
            border: 1px solid var(--border-primary);
            border-radius: 10px;
            padding: 12px 8px;
            cursor: pointer;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            gap: 6px;
            min-height: 70px;
            position: relative;
            overflow: hidden;
        }
        
        .mobile-cmd-btn::before {
            content: '';
            position: absolute;
            top: 0;
            left: -100%;
            width: 100%;
            height: 100%;
            background: linear-gradient(90deg, transparent, rgba(68,255,68,0.2), transparent);
            transition: left 0.5s;
        }
        
        .mobile-cmd-btn:active::before {
            left: 100%;
        }
        
        .mobile-cmd-btn:hover {
            background: rgba(68,255,68,0.1);
            border-color: var(--accent-green);
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(68,255,68,0.2);
        }
        
        .mobile-cmd-btn:active {
            transform: translateY(0) scale(0.95);
        }
        
        .mobile-cmd-btn .cmd-icon {
            font-size: 24px;
            line-height: 1;
        }
        
        .mobile-cmd-btn .cmd-label {
            font-size: 11px;
            font-weight: 600;
            color: var(--text-secondary);
            text-align: center;
        }
        
        .mobile-cmd-btn:hover .cmd-label {
            color: var(--accent-green);
        }
        
        .mobile-command-input-group {
            display: flex;
            gap: 10px;
            align-items: center;
        }
        
        .mobile-command-input {
            flex: 1;
            background: var(--bg-tertiary);
            border: 1px solid var(--border-primary);
            border-radius: 8px;
            padding: 12px 15px;
            color: var(--text-primary);
            font-size: 14px;
            transition: all 0.3s ease;
        }
        
        .mobile-command-input:focus {
            outline: none;
            border-color: var(--accent-green);
            box-shadow: 0 0 0 3px rgba(68,255,68,0.1);
        }
        
        .mobile-command-input::placeholder {
            color: var(--text-secondary);
        }
        
        .mobile-send-btn {
            background: linear-gradient(135deg, var(--accent-green) 0%, #55ff55 100%);
            border: none;
            border-radius: 8px;
            padding: 12px 20px;
            cursor: pointer;
            color: #000;
            font-weight: 700;
            font-size: 16px;
            transition: all 0.3s ease;
            min-width: 50px;
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 2px 8px rgba(68,255,68,0.3);
        }
        
        .mobile-send-btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(68,255,68,0.4);
            background: linear-gradient(135deg, #55ff55 0%, #66ff66 100%);
        }
        
        .mobile-send-btn:active {
            transform: translateY(0) scale(0.95);
        }

        .card-title {
            font-size: 1.1em;
            font-weight: 600;
            padding: 14px 18px;
            border-bottom: 1px solid var(--border-primary);
            display: flex;
            justify-content: space-between;
            align-items: center;
            user-select: none;
        }
        .card-title > span {
            cursor: pointer;
            flex: 1;
        }
        .card-title .value {
            font-size: 0.85em;
            font-weight: 500;
            color: var(--text-secondary);
        }
        .card-title .pts { color: var(--accent-green); font-weight: 600; }
        
        /* Botão de atualização nos cards */
        .card-title-actions {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .refresh-btn {
            background: transparent;
            border: 1px solid var(--border-primary);
            color: var(--text-secondary);
            padding: 6px 10px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.85em;
            transition: all 0.3s ease;
            display: flex;
            align-items: center;
            gap: 4px;
            min-width: 32px;
            height: 28px;
            justify-content: center;
        }
        .refresh-btn:hover {
            background: var(--bg-tertiary);
            border-color: var(--accent-blue);
            color: var(--accent-blue);
        }
        .refresh-btn:active {
            transform: scale(0.95);
        }
        .refresh-btn.refreshing {
            animation: spin 1s linear infinite;
        }
        .refresh-btn .refresh-icon {
            font-size: 1em;
            line-height: 1;
        }
        @keyframes spin {
            from { transform: rotate(0deg); }
            to { transform: rotate(360deg); }
        }
        
        /* Mobile: botão maior e mais visível */
        @media (max-width: 900px) {
            .card-title {
                padding: 12px 15px;
            }
            .card-title-actions {
                gap: 10px;
            }
            .refresh-btn {
                padding: 8px 12px;
                font-size: 0.9em;
                min-width: 40px;
                height: 32px;
                border-width: 2px;
            }
            .refresh-btn .refresh-icon {
                font-size: 1.1em;
            }
            .card-title .value {
                font-size: 0.8em;
            }
        }

        .card-content {
            padding: 18px;
        }
        .card.no-padding .card-content {
            padding: 0;
        }

        /* --- Card de Alvo --- */
        .card.target-card {
            background: #3a2222;
            border-color: var(--accent-red);
        }
        
        /* Target Card - Tema Claro */
        body.light-theme .card.target-card {
            background: #ffe8e8;
            border-color: var(--accent-red);
        }
        
        body.light-theme .target-name {
            color: #cf222e;
        }
        .target-display {
            display: flex;
            align-items: center;
            gap: 20px;
        }
        .target-icon {
            font-size: 2em;
            padding-left: 5px;
        }
        .target-info { flex: 1; }
        .target-name {
            font-size: 1.3em;
            font-weight: 700;
            color: #ffb8b8;
        }
        .target-details {
            display: flex;
            gap: 15px;
            font-size: 0.9em;
            color: var(--text-secondary);
        }
        .target-details .value { color: var(--text-primary); }

        /* --- Card do Mapa --- */
        #mapContainer {
            position: relative;
            width: 100%;
            max-height: 480px; /* Altura controlada */
            min-height: 300px;
            background: #000;
            cursor: crosshair;
            display: flex;
            align-items: center;
            justify-content: center;
            overflow: hidden;
        }
        #mapCanvas {
            position: absolute;
            /* JS vai setar width/height e style.width/height */
        }
        .map-info {
            position: absolute;
            top: 10px;
            left: 10px;
            background: rgba(0,0,0,0.8);
            padding: 8px 12px;
            border-radius: 5px;
            font-size: 0.85em;
            z-index: 10;
            color: #fff;
        }
        
        /* Map Info - Tema Escuro (padrão) */
        body:not(.light-theme) .map-info {
            background: rgba(0,0,0,0.8);
            color: #fff;
        }
        
        /* Map Info - Tema Claro */
        body.light-theme .map-info {
            background: rgba(245, 247, 250, 0.95);
            color: var(--text-primary);
            border: 1px solid var(--border-primary);
        }
        
        .map-footer {
            display: grid;
            grid-template-columns: 1fr 1fr 1fr;
            border-top: 1px solid var(--border-primary);
            background: var(--bg-secondary);
        }
        .map-footer-stat {
            padding: 10px;
            text-align: center;
            border-right: 1px solid var(--border-primary);
        }
        .map-footer-stat:last-child { border-right: none; }
        .map-footer-stat .value { font-size: 1.2em; font-weight: 600; color: var(--text-primary); }
        .map-footer-stat .label { font-size: 0.75em; color: var(--text-secondary); text-transform: uppercase; }
        
        /* --- Card do Chat --- */
        .chat-container {
            background: var(--bg-primary);
            height: 400px;
            overflow-y: auto;
            font-family: var(--font-mono);
            font-size: 0.85em;
            padding: 10px;
        }
        .chat-entry {
            padding: 2px 4px;
            word-wrap: break-word;
            line-height: 1.5;
        }
        .chat-entry .time { color: var(--text-secondary); margin-right: 8px; }
        .chat-entry .name { font-weight: 600; margin-right: 8px; }
        
        /* Cores por tipo de mensagem - Chat */
        .chat-entry.public { color: var(--text-primary); }
        .chat-entry.public .name { color: var(--accent-blue); font-weight: 600; }
        .chat-entry.public::before { content: '💬 '; margin-right: 4px; }
        
        .chat-entry.private { color: var(--accent-purple); }
        .chat-entry.private .name { color: #ddaaff; font-weight: 600; }
        .chat-entry.private::before { content: '🔒 '; margin-right: 4px; }
        
        .chat-entry.party { color: var(--accent-green); }
        .chat-entry.party .name { color: #66ff99; font-weight: 600; }
        .chat-entry.party::before { content: '👥 '; margin-right: 4px; }
        
        .chat-entry.guild { color: var(--accent-yellow); }
        .chat-entry.guild .name { color: #ffdd66; font-weight: 600; }
        .chat-entry.guild::before { content: '🏰 '; margin-right: 4px; }
        
        .chat-entry.self { color: #aaff66; }
        .chat-entry.self .name { color: #88ff88; font-weight: 600; }
        .chat-entry.self::before { content: '💭 '; margin-right: 4px; }
        
        /* Cores por categoria - Console OpenKore */
        .chat-entry.console { color: #999; }
        .chat-entry.console.packet .name { color: #4a9eff; }      /* Azul para packets */
        .chat-entry.console.packet { color: #7bb3ff; }
        .chat-entry.console.movement .name { color: #66ff66; }   /* Verde para movimento */
        .chat-entry.console.movement { color: #99ff99; }
        .chat-entry.console.error .name { color: #ff4444; }      /* Vermelho para erros */
        .chat-entry.console.error { color: #ff6666; }
        .chat-entry.console.debug .name { color: #ffaa00; }      /* Laranja para debug */
        .chat-entry.console.debug { color: #ffcc66; }
        .chat-entry.console.info .name { color: #aaaaaa; }        /* Cinza para info */
        .chat-entry.console.info { color: #cccccc; }
        
        /* Cores - LatamChecksum */
        .chat-entry.latamchecksum .name { color: #ff6b9d; }       /* Rosa para LatamChecksum */
        .chat-entry.latamchecksum { color: #ff8fb3; }
        .chat-entry.latamchecksum.checksum { color: #ffb3d1; }

        .chat-input-group.chat-sender {
            padding: 10px;
            border-top: 1px solid var(--border-primary);
        }

        /* --- Card de Inventário --- */
        .inventory-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(70px, 1fr));
            gap: 10px;
            max-height: 450px;
            overflow-y: auto;
        }
        .item {
            position: relative;
            background: var(--bg-primary);
            border: 1px solid var(--border-primary);
            border-radius: 6px;
            padding: 8px;
            text-align: center;
            cursor: pointer;
            transition: all 0.2s;
        }
        .item:hover {
            border-color: var(--accent-blue);
            transform: translateY(-2px);
        }
        .item-icon {
            width: 40px;
            height: 40px;
            margin: 0 auto 5px;
            display: flex;
            align-items: center;
            justify-content: center;
            background: rgba(0,0,0,0.3);
            border-radius: 4px;
        }
        .item-icon img { max-width: 100%; max-height: 100%; }
        .item-name {
            font-size: 0.75em;
            color: var(--text-primary);
            margin-bottom: 3px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .item-amount { font-size: 0.8em; color: var(--text-secondary); font-weight: 500; }
        
        .item-badge {
            position: absolute;
            top: 4px; left: 4px;
            background: var(--accent-yellow);
            color: var(--bg-primary);
            font-size: 8px;
            font-weight: 700;
            padding: 1px 3px;
            border-radius: 3px;
            letter-spacing: .3px;
        }
        
        .item.consumable { border-left: 3px solid var(--accent-green); }
        .item.equipable  { border-left: 3px solid var(--accent-blue); }
        .item.other      { border-left: 3px solid var(--text-secondary); }
        .item.equipped   { border: 1px solid var(--accent-yellow); background: rgba(227, 179, 65, 0.1); }
        
        /* --- Menu de Contexto --- */
        .context-menu {
            position: fixed;
            background: var(--bg-tertiary);
            border: 1px solid var(--border-primary);
            border-radius: 8px;
            padding: 6px;
            z-index: 10000;
            box-shadow: 0 4px 20px rgba(0,0,0,0.5);
        }
        .context-menu-item {
            padding: 8px 15px;
            cursor: pointer;
            border-radius: 4px;
            font-size: 0.9em;
            color: var(--text-primary);
        }
        .context-menu-item:hover {
            background: var(--accent-blue);
            color: #fff;
        }
        .context-menu-item.danger { color: #ff8b8b; }
        .context-menu-item.danger:hover { background: var(--accent-red); color: #fff; }

        /* --- Outros Cards (Skills, Monstros) --- */
        .skills-list, .monsters-list {
            display: flex;
            flex-direction: column;
            gap: 10px;
            max-height: 450px;
            overflow-y: auto;
        }
        .skill-item, .monster-item {
            background: var(--bg-primary);
            border: 1px solid var(--border-primary);
            padding: 10px 12px;
            border-radius: 6px;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }
        .skill-name, .monster-name {
            font-weight: 600;
            color: var(--text-primary);
        }
        .skill-details, .monster-details {
            font-size: 0.85em;
            color: var(--text-secondary);
        }
        .skill-btn {
            padding: 5px 10px;
            border: 1px solid var(--accent-green);
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.8em;
            background: rgba(63, 185, 80, 0.1);
            color: var(--accent-green);
            font-weight: 600;
        }
        .monster-item .monster-hp {
            width: 60px;
            text-align: right;
            color: var(--accent-green);
        }
        .monster-item .monster-distance {
            width: 50px;
            text-align: right;
            color: var(--accent-yellow);
        }
        
        /* --- Tabs --- */
        .tabs-container {
            display: flex;
            flex-direction: column;
            gap: 10px;
        }
        .tabs {
            display: flex;
            justify-content: center;
            gap: 8px;
            border-bottom: 1px solid var(--border-primary);
            padding-bottom: 8px;
        }
        .tab-btn {
            background: transparent;
            border: none;
            color: var(--text-secondary);
            padding: 8px 16px;
            cursor: pointer;
            font-size: 0.9em;
            font-weight: 500;
            border-radius: 6px;
            transition: all 0.3s ease;
        }
        .tab-btn:hover {
            background: var(--bg-tertiary);
            color: var(--text-primary);
        }
        .tab-btn.active {
            background: var(--accent-blue);
            color: #fff;
        }
        .tab-content {
            display: block;
        }
        
        /* --- Listas de Kills e Drops --- */
        .monster-kills-list, .item-drops-list {
            display: flex;
            flex-direction: column;
            gap: 8px;
            max-height: 450px;
            overflow-y: auto;
        }
        .kill-item, .drop-item {
            background: var(--bg-primary);
            border: 1px solid var(--border-primary);
            padding: 12px;
            border-radius: 6px;
            display: grid;
            grid-template-columns: 1fr auto auto;
            gap: 10px;
            align-items: center;
        }
        .kill-item-name, .drop-item-name {
            font-weight: 600;
            color: var(--text-primary);
        }
        .kill-item-details, .drop-item-details {
            font-size: 0.85em;
            color: var(--text-secondary);
            display: flex;
            flex-direction: column;
            gap: 4px;
        }
        .kill-item-stats, .drop-item-stats {
            text-align: right;
            font-size: 0.9em;
        }
        .kill-item-stats .count {
            font-weight: 700;
            color: var(--accent-green);
        }
        .kill-item-stats .exp {
            color: var(--accent-yellow);
        }
        .drop-item-stats .amount {
            font-weight: 700;
            color: var(--accent-purple);
        }
        
        /* --- Informações de Guilda e Party --- */
        #guildInfo, #partyInfo {
            display: flex;
            flex-direction: column;
            gap: 15px;
        }
        .guild-header, .party-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding-bottom: 10px;
            border-bottom: 1px solid var(--border-primary);
        }
        .guild-header-info, .party-header-info {
            display: flex;
            flex-direction: column;
            gap: 5px;
        }
        .guild-header-info .label, .party-header-info .label {
            font-size: 0.8em;
            color: var(--text-secondary);
        }
        .guild-header-info .value, .party-header-info .value {
            font-weight: 600;
            color: var(--text-primary);
        }
        .members-list {
            display: flex;
            flex-direction: column;
            gap: 8px;
            max-height: 300px;
            overflow-y: auto;
        }
        .member-item {
            background: var(--bg-primary);
            border: 1px solid var(--border-primary);
            padding: 10px;
            border-radius: 6px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .member-item.online {
            border-left: 3px solid var(--accent-green);
        }
        .member-item.offline {
            border-left: 3px solid var(--text-secondary);
        }
        .member-name {
            font-weight: 600;
            color: var(--text-primary);
        }
        .member-details {
            font-size: 0.85em;
            color: var(--text-secondary);
        }
        .member-status {
            font-size: 0.8em;
            padding: 4px 8px;
            border-radius: 4px;
            background: var(--bg-tertiary);
        }
        .member-status.online {
            background: rgba(63, 185, 80, 0.2);
            color: var(--accent-green);
        }
        
        /* --- Estatísticas de EXP --- */
        #experienceStats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
        }
        .exp-stat {
            background: var(--bg-primary);
            border: 1px solid var(--border-primary);
            padding: 12px;
            border-radius: 6px;
            text-align: center;
        }
        .exp-stat-label {
            font-size: 0.8em;
            color: var(--text-secondary);
            margin-bottom: 5px;
        }
        .exp-stat-value {
            font-size: 1.3em;
            font-weight: 700;
            color: var(--accent-green);
        }
        
        /* --- Scrollbar --- */
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-primary); }
        ::-webkit-scrollbar-thumb { background: var(--bg-tertiary); border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: var(--border-primary); }
        
        /* --- Responsividade --- */
        @media (max-width: 1200px) {
            /* Colapsa para 1 coluna se a tela for muito estreita */
            .main-grid {
                grid-template-columns: 1fr;
            }
        }
        
        @media (max-width: 900px) {
            .dashboard-layout {
                flex-direction: column;
            }
            .sidebar {
                display: none; /* Oculta sidebar no mobile */
            }
            .main-content {
                margin-left: 0;
                width: 100%;
                padding: 10px;
            }
            .main-grid {
                grid-template-columns: 1fr; /* Força coluna única */
                gap: 10px;
            }
            
            /* Mostra o card de header no mobile */
            .mobile-header-card {
                display: block;
            }
            .mobile-header-card .card-content {
                padding: 15px;
            }
            
            /* Mostra o card de comandos no mobile */
            .mobile-commands-card {
                display: block;
            }
            
            .mobile-command-panel {
                grid-template-columns: repeat(4, 1fr);
                gap: 8px;
            }
            .card-title {
                padding: 12px 15px;
            }
            .card-content {
                padding: 15px;
            }
            
            .chat-container {
                height: 300px;
                font-size: 0.8em;
                padding: 8px;
            }
            .chat-entry {
                padding: 4px 2px;
                line-height: 1.4;
            }
            .chat-entry .time {
                font-size: 0.85em;
                margin-right: 4px;
            }
            .chat-entry .name {
                font-size: 0.9em;
            }
            .chat-entry::before {
                font-size: 0.9em;
            }
            .inventory-grid, .skills-list, .monsters-list, .monster-kills-list, .item-drops-list {
                max-height: 300px;
            }
            
            .kill-item, .drop-item {
                grid-template-columns: 1fr;
                gap: 8px;
            }
            .kill-item-stats, .drop-item-stats {
                text-align: left;
            }
            
            #experienceStats {
                grid-template-columns: repeat(2, 1fr);
            }
            
            .tabs {
                flex-wrap: wrap;
            }
            
            /* Mostra Stats e Comandos como cards no mobile */
            .mobile-card-stats, .mobile-card-session, .mobile-card-commands {
                display: block;
            }
        }
        
        /* Mobile Navbar */
        .mobile-navbar {
            display: none;
            position: fixed;
            bottom: 0;
            left: 0;
            right: 0;
            background: var(--bg-secondary);
            border-top: 1px solid var(--border-primary);
            box-shadow: 0 -2px 20px rgba(0,0,0,0.3);
            z-index: 1000;
            backdrop-filter: blur(20px);
        }
        
        /* Mobile Navbar - Tema Escuro (padrão) */
        body:not(.light-theme) .mobile-navbar {
            background: rgba(13, 17, 23, 0.98);
            box-shadow: 0 -2px 20px rgba(0,0,0,0.3);
        }
        
        /* Mobile Navbar - Tema Claro */
        body.light-theme .mobile-navbar {
            background: rgba(245, 247, 250, 0.98);
            box-shadow: 0 -2px 20px rgba(0,0,0,0.08);
        }
        
        .mobile-navbar-content {
            display: flex;
            align-items: center;
            padding: 8px 12px;
            overflow-x: auto;
            overflow-y: hidden;
            -webkit-overflow-scrolling: touch;
            scrollbar-width: none;
            scroll-behavior: smooth;
            scroll-snap-type: x mandatory;
            gap: 8px;
        }
        
        .mobile-navbar-content::-webkit-scrollbar {
            display: none;
        }
        
        /* Indicador visual de scroll (gradiente nas bordas) */
        .mobile-navbar {
            position: relative;
        }
        .mobile-navbar::before,
        .mobile-navbar::after {
            content: '';
            position: absolute;
            top: 0;
            bottom: 0;
            width: 25px;
            pointer-events: none;
            z-index: 1001;
            transition: opacity 0.3s ease;
        }
        .mobile-navbar::before {
            left: 0;
            background: linear-gradient(to right, rgba(13, 17, 23, 0.98), rgba(13, 17, 23, 0.5), transparent);
        }
        .mobile-navbar::after {
            right: 0;
            background: linear-gradient(to left, rgba(13, 17, 23, 0.98), rgba(13, 17, 23, 0.5), transparent);
        }
        .mobile-navbar.scroll-start::before {
            opacity: 0;
        }
        .mobile-navbar.scroll-end::after {
            opacity: 0;
        }
        
        .mobile-nav-item {
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            padding: 6px 12px;
            cursor: pointer;
            transition: all 0.3s ease;
            border-radius: 12px;
            min-width: 65px;
            width: auto;
            flex-shrink: 0;
            position: relative;
            scroll-snap-align: start;
        }
        
        /* Ajustes para telas muito pequenas (320px) */
        @media (max-width: 360px) {
            .mobile-navbar-content {
                padding: 8px 8px;
                gap: 6px;
            }
            .mobile-nav-item {
                min-width: 55px;
                padding: 6px 8px;
            }
            .mobile-nav-label {
                font-size: 9px;
            }
            .mobile-nav-icon {
                font-size: 20px;
            }
        }
        
        .mobile-nav-item:hover {
            background: rgba(255,255,255,0.05);
            transform: translateY(-2px);
        }
        
        .mobile-nav-item.active {
            background: rgba(68,255,68,0.15);
            border: 1px solid rgba(68,255,68,0.3);
        }
        
        .mobile-nav-icon {
            font-size: 24px;
            margin-bottom: 4px;
            transition: transform 0.3s ease;
        }
        
        .mobile-nav-item:hover .mobile-nav-icon {
            transform: scale(1.1);
        }
        
        .mobile-nav-label {
            font-size: 10px;
            font-weight: 600;
            color: var(--text-secondary);
            text-align: center;
            transition: color 0.3s ease;
        }
        
        .mobile-nav-item.active .mobile-nav-label {
            color: var(--accent-green);
        }
        
        .mobile-nav-badge {
            position: absolute;
            top: 4px;
            right: 8px;
            background: var(--accent-red);
            color: #fff;
            font-size: 9px;
            font-weight: 700;
            padding: 2px 5px;
            border-radius: 10px;
            min-width: 16px;
            text-align: center;
            line-height: 1.2;
        }
        
        @media (max-width: 900px) {
            .mobile-navbar {
                display: block;
            }
            
            .main-content {
                padding-bottom: 70px; /* Espaço para a navbar */
            }
        }
        
    </style>
</head>
<body>

    <div class="dashboard-layout">
        
        <nav class="sidebar">
            <div class="sidebar-header">
                <span class="status-dot" id="statusDot"></span>
                <span>OpenKore Dashboard V2.0 PRO</span>
            </div>
            
            <div class="account-selector">
                <span class="account-selector-label">Conta:</span>
                <select class="account-select" id="accountSelect" onchange="switchAccount()">
                    <option value="">Carregando...</option>
                </select>
            </div>
            
            <div class="ai-controls">
                <button class="ai-btn off" onclick="setAI('off')">AI<br>OFF </button>
                <button class="ai-btn on" onclick="setAI('manual')">AI<br>MANUAL</button>
                <button class="ai-btn auto" onclick="setAI('auto')">AI<br>AI AUTO</button>
            </div>
            
            <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle" title="Alternar entre tema escuro e claro">
                <span class="theme-toggle-icon" id="themeIcon">🌙</span>
                <span id="themeText">Tema Escuro</span>
            </button>
            
            <div class="sidebar-section">
                <div class="sidebar-section-title">Personagem</div>
                
                <div class="char-info">
                    <div class="info-row">
                        <span class="label">Nome</span>
                        <span class="value" id="charName">-</span>
                    </div>
                    <div class="info-row">
                        <span class="label">Classe</span>
                        <span class="value" id="charJob">-</span>
                    </div>
                    <div class="info-row">
                        <span class="label">Level</span>
                        <span class="value" id="charLevel">-</span>
                    </div>
                    <div class="info-row">
                        <span class="label">Zeny</span>
                        <span class="value zeny" id="charZeny">-</span>
                    </div>
                </div>
                
                <hr style="border: 0; border-top: 1px solid var(--border-primary); margin: 20px 0;">
                
                <div class="vitals">
                    <div class="vital">
                        <div class="progress-label">
                            <span>HP</span>
                            <span class="value" id="hpValue">-/-</span>
                        </div>
                        <div class="progress-bar">
                            <div class="progress-fill hp" id="hpBar"></div>
                        </div>
                    </div>
                    <div class="vital">
                        <div class="progress-label">
                            <span>SP</span>
                            <span class="value" id="spValue">-/-</span>
                        </div>
                        <div class="progress-bar">
                            <div class="progress-fill sp" id="spBar"></div>
                        </div>
                    </div>
                    <div class="vital">
                        <div class="progress-label">
                            <span>EXP Base</span>
                            <span class="value" id="expValue">0%</span>
                        </div>
                        <div class="progress-bar">
                            <div class="progress-fill exp" id="expBar"></div>
                        </div>
                    </div>
                    <div class="vital">
                        <div class="progress-label">
                            <span>EXP Job</span>
                            <span class="value" id="expJobValue">0%</span>
                        </div>
                        <div class="progress-bar">
                            <div class="progress-fill exp" id="expJobBar"></div>
                        </div>
                    </div>
                    <div class="vital">
                        <div class="progress-label">
                            <span>Peso</span>
                            <span class="value" id="weightValue">-/-</span>
                        </div>
                        <div class="progress-bar">
                            <div class="progress-fill weight" id="weightBar"></div>
                        </div>
                    </div>
                </div>
            </div>
            
            <div class="sidebar-section">
                <div class="sidebar-section-title">
                    Atributos (Pts: <span id="statPoints" style="color: var(--accent-green);">0</span>)
                </div>
                <div class="stats-grid">
                    <div class="stat-box">
                        <div>
                            <div class="stat-box-label">STR</div>
                            <div class="stat-box-value" id="statStr">0</div>
                        </div>
                        <button class="stat-upgrade-btn" id="btnStr" onclick="upgradeStat('str')">+</button>
                    </div>
                    <div class="stat-box">
                        <div>
                            <div class="stat-box-label">AGI</div>
                            <div class="stat-box-value" id="statAgi">0</div>
                        </div>
                        <button class="stat-upgrade-btn" id="btnAgi" onclick="upgradeStat('agi')">+</button>
                    </div>
                    <div class="stat-box">
                        <div>
                            <div class="stat-box-label">VIT</div>
                            <div class="stat-box-value" id="statVit">0</div>
                        </div>
                        <button class="stat-upgrade-btn" id="btnVit" onclick="upgradeStat('vit')">+</button>
                    </div>
                    <div class="stat-box">
                        <div>
                            <div class="stat-box-label">INT</div>
                            <div class="stat-box-value" id="statInt">0</div>
                        </div>
                        <button class="stat-upgrade-btn" id="btnInt" onclick="upgradeStat('int')">+</button>
                    </div>
                    <div class="stat-box">
                        <div>
                            <div class="stat-box-label">DEX</div>
                            <div class="stat-box-value" id="statDex">0</div>
                        </div>
                        <button class="stat-upgrade-btn" id="btnDex" onclick="upgradeStat('dex')">+</button>
                    </div>
                    <div class="stat-box">
                        <div>
                            <div class="stat-box-label">LUK</div>
                            <div class="stat-box-value" id="statLuk">0</div>
                        </div>
                        <button class="stat-upgrade-btn" id="btnLuk" onclick="upgradeStat('luk')">+</button>
                    </div>
                </div>
            </div>
            
            <div class="sidebar-section" id="cardCommands">
                <div class="sidebar-section-title">Comandos</div>
                <div class="command-panel">
                    <button class="cmd-btn" onclick="sendCommand('pause')">⏸️ Pause</button>
                    <button class="cmd-btn" onclick="sendCommand('reload all')">🔄 Reload</button>
                    <button class="cmd-btn" onclick="sendCommand('s')">📊 Status</button>
                    <button class="cmd-btn" onclick="sendCommand('i')">🎒 Inv</button>
                    <button class="cmd-btn" onclick="sendCommand('skills')">✨ Skills</button>
                    <button class="cmd-btn" onclick="sendCommand('exp')">📈 EXP</button>
                    <button class="cmd-btn" onclick="sendCommand('relog')">🔌 Relog</button>
                    <button class="cmd-btn" onclick="sendCommand('respawn')">💀 Respawn</button>
                </div>
                <div class="chat-input-group">
                    <input type="text" class="chat-input" id="customCommand" placeholder="Comando..." onkeypress="if(event.key==='Enter')sendCustomCommand()">
                    <button class="send-btn" onclick="sendCustomCommand()">Run</button>
                </div>
            </div>
            
        </nav>
        
        <main class="main-content">
        
            <div class="mobile-header-title">
                <span class="status-dot" id="statusDotMobile"></span>
                <span>Ué? Dashboard V2.0 PRO !?</span>
            </div>
        
            <div class="mobile-account-selector">
                <select class="account-select" id="accountSelectMobile" onchange="switchAccount()">
                    <option value="">Carregando...</option>
                </select>
            </div>
        
            <div class="card mobile-header-card" id="cardCharMobile">
                <div class="card-title" onclick="toggleCard('cardCharMobile')">
                    <div class="mobile-char-info">
                        <span><span id="charNameMobile">-</span> (<span id="charLevelMobile">-</span>)</span>
                        <span class="mobile-char-job" id="charJobMobile">-</span>
                    </div>
                    <span class="value" id="charZenyMobile">- Zeny</span>
                </div>
                <div class="card-content">
                    <div class="ai-controls">
                        <button class="ai-btn off" onclick="setAI('off')">AI OFF</button>
                        <button class="ai-btn on" onclick="setAI('manual')">AI MANUAL</button>
                        <button class="ai-btn auto" onclick="setAI('auto')">AI AUTO</button>
                    </div>
                    
                    <button class="theme-toggle-mobile" onclick="toggleTheme()" id="themeToggleMobile" title="Alternar entre tema escuro e claro">
                        <span class="theme-toggle-mobile-icon" id="themeIconMobile">🌙</span>
                        <span id="themeTextMobile">Tema Escuro</span>
                    </button>
                    
                    <div class="vitals">
                        <div class="vital">
                            <div class="progress-label">
                                <span>HP</span>
                                <span class="value" id="hpValueMob">-/-</span>
                            </div>
                            <div class="progress-bar">
                                <div class="progress-fill hp" id="hpBarMob"></div>
                            </div>
                        </div>
                        <div class="vital">
                            <div class="progress-label">
                                <span>SP</span>
                                <span class="value" id="spValueMob">-/-</span>
                            </div>
                            <div class="progress-bar">
                                <div class="progress-fill sp" id="spBarMob"></div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
            
            <div class="card mobile-commands-card" id="cardCommandsMobile">
                <div class="card-title" onclick="toggleCard('cardCommandsMobile')">
                    <span>⚡ Comandos</span>
                </div>
                <div class="card-content">
                    <div class="mobile-command-panel">
                        <button class="mobile-cmd-btn" onclick="sendCommand('pause')">
                            <span class="cmd-icon">⏸️</span>
                            <span class="cmd-label">Pause</span>
                        </button>
                        <button class="mobile-cmd-btn" onclick="sendCommand('reload all')">
                            <span class="cmd-icon">🔄</span>
                            <span class="cmd-label">Reload</span>
                        </button>
                        <button class="mobile-cmd-btn" onclick="sendCommand('s')">
                            <span class="cmd-icon">📊</span>
                            <span class="cmd-label">Status</span>
                        </button>
                        <button class="mobile-cmd-btn" onclick="sendCommand('i')">
                            <span class="cmd-icon">🎒</span>
                            <span class="cmd-label">Inv</span>
                        </button>
                        <button class="mobile-cmd-btn" onclick="sendCommand('skills')">
                            <span class="cmd-icon">✨</span>
                            <span class="cmd-label">Skills</span>
                        </button>
                        <button class="mobile-cmd-btn" onclick="sendCommand('exp')">
                            <span class="cmd-icon">📈</span>
                            <span class="cmd-label">EXP</span>
                        </button>
                        <button class="mobile-cmd-btn" onclick="sendCommand('relog')">
                            <span class="cmd-icon">🔌</span>
                            <span class="cmd-label">Relog</span>
                        </button>
                        <button class="mobile-cmd-btn" onclick="sendCommand('respawn')">
                            <span class="cmd-icon">💀</span>
                            <span class="cmd-label">Respawn</span>
                        </button>
                    </div>
                    <div class="mobile-command-input-group">
                        <input type="text" class="mobile-command-input" id="customCommandMobile" placeholder="Digite um comando..." onkeypress="if(event.key==='Enter')sendCustomCommandMobile()">
                        <button class="mobile-send-btn" onclick="sendCustomCommandMobile()">
                            <span>▶</span>
                        </button>
                    </div>
                </div>
            </div>
            
            <div class="card target-card" id="targetCard" style="display: none;">
                <div class="card-content">
                    <div class="target-display">
                        <div class="target-icon">🎯</div>
                        <div class="target-info">
                            <div class="target-name" id="targetName">-</div>
                            <div class="target-details">
                                <span>Lv: <span id="targetLevel" class="value">-</span></span>
                                <span>Dist: <span id="targetDistance" class="value">-</span>m</span>
                            </div>
                        </div>
                        <div class="vital" style="flex-basis: 200px;">
                            <div class="progress-label">
                                <span>HP</span>
                                <span class="value" id="targetHpValue">-/-</span>
                            </div>
                            <div class="progress-bar">
                                <div class="progress-fill hp" id="targetHpBar"></div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <div class="main-grid" id="mainGrid">
            
                <div class="main-column">
                    <div class="main-column-grid">
                        <div class="card no-padding" id="cardMap">
                            <div class="card-title" onclick="toggleCard('cardMap')">
                                <span>Mapa</span>
                                <span class="value" id="mapName">-</span>
                            </div>
                            <div class="card-content">
                                <div id="mapContainer">
                                    <div class="map-info">
                                        <div>Pos: <span id="mapPos">0, 0</span></div>
                                        <div>AI: <span id="aiState">-</span></div>
                                    </div>
                                    <canvas id="mapCanvas"></canvas>
                                </div>
                                <div class="map-footer">
                                    <div class="map-footer-stat">
                                        <div class="value" id="playersCount">0</div>
                                        <div class="label">Players</div>
                                    </div>
                                    <div class="map-footer-stat">
                                        <div class="value" id="monstersCount">0</div>
                                        <div class="label">Monstros</div>
                                    </div>
                                    <div class="map-footer-stat">
                                        <div class="value" id="portalsCount">0</div>
                                        <div class="label">Portais</div>
                                    </div>
                                </div>
                            </div>
                        </div>
                        
                        <div class="card" id="cardMonsters">
                            <div class="card-title" onclick="toggleCard('cardMonsters')">
                                <span>Monstros Próximos</span>
                            </div>
                            <div class="card-content">
                                <div class="monsters-list" id="monstersList"></div>
                            </div>
                        </div>
                    </div>
                    
                    <div class="card no-padding" id="cardChat">
                        <div class="card-title" onclick="toggleCard('cardChat')">
                            <span>Chat / Console</span>
                        </div>
                        <div class="card-content">
                            <div class="tabs-container">
                                <div class="tabs">
                                    <button class="tab-btn" onclick="switchChatTab('chat', event)">💬 Chat</button>
                                    <button class="tab-btn active" onclick="switchChatTab('console', event)">⚙️ Console</button>
                                    <button class="tab-btn" onclick="switchChatTab('latamchecksum', event)">🔐 LatamChecksum</button>
                                </div>
                                <div class="tab-content" id="chatTab" style="display: none;">
                                    <div class="chat-container" id="chatContainer"></div>
                                </div>
                                <div class="tab-content" id="consoleTab" style="display: block;">
                                    <div class="chat-container" id="consoleContainer"></div>
                                </div>
                                <div class="tab-content" id="latamchecksumTab" style="display: none;">
                                    <div class="chat-container" id="latamchecksumContainer"></div>
                                </div>
                            </div>
                        </div>
                        <div class="chat-input-group chat-sender">
                            <input type="text" class="chat-input" id="chatInput" placeholder="Enviar mensagem..." onkeypress="if(event.key==='Enter')sendChat()">
                            <button class="send-btn" onclick="sendChat()">Enviar</button>
                        </div>
                    </div>
                </div>
                
                <div class="main-column">
                    <div class="card" id="cardInv">
                        <div class="card-title">
                            <span onclick="toggleCard('cardInv')">Inventário</span>
                            <div class="card-title-actions">
                                <span class="value">(<span id="invCount">0</span> itens)</span>
                                <button class="refresh-btn" onclick="event.stopPropagation(); refreshInventory(event)" title="Atualizar Inventário">
                                    <span class="refresh-icon">🔄</span>
                                </button>
                            </div>
                        </div>
                        <div class="card-content">
                            <div class="tabs-container">
                                <div class="tabs">
                                    <button class="tab-btn active" id="inventoryTabPersonal" onclick="switchInventoryTab('personal', event)">🎒 Pessoal</button>
                                    <button class="tab-btn" id="inventoryTabCart" onclick="switchInventoryTab('cart', event)" style="display: none;">🛒 Carrinho</button>
                                </div>
                                <div class="tab-content" id="inventoryPersonalTab" style="display: block;">
                                    <div class="inventory-grid" id="inventoryGrid"></div>
                                </div>
                                <div class="tab-content" id="inventoryCartTab" style="display: none;">
                                    <div class="cart-info" id="cartInfo" style="display: none; margin-bottom: 10px; padding: 10px; background: var(--bg-tertiary); border-radius: 6px; font-size: 0.85em;">
                                        <div style="display: flex; justify-content: space-between; margin-bottom: 5px;">
                                            <span>Itens: <span id="cartItemsCount">0</span>/<span id="cartItemsMax">0</span></span>
                                            <span>Peso: <span id="cartWeight">0</span>/<span id="cartWeightMax">0</span> (<span id="cartWeightPercent">0</span>%)</span>
                                        </div>
                                    </div>
                                    <div class="inventory-grid" id="cartGrid"></div>
                                    <div id="cartEmpty" style="text-align: center; padding: 20px; color: var(--text-secondary); display: none;">
                                        <div style="font-size: 2em; margin-bottom: 10px;">🛒</div>
                                        <div>Nenhum carrinho ativo ou carrinho vazio</div>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                    
                    <div class="card" id="cardSkills">
                        <div class="card-title" onclick="toggleCard('cardSkills')">
                            <span>Skills</span>
                            <span class="value pts">Pts: <span id="skillPoints">0</span></span>
                        </div>
                        <div class="card-content">
                            <div class="skills-list" id="skillsList"></div>
                        </div>
                    </div>
                    
                    <div class="card" id="cardGuild">
                        <div class="card-title">
                            <span onclick="toggleCard('cardGuild')">Guilda</span>
                            <div class="card-title-actions">
                                <span class="value" id="guildName">-</span>
                                <button class="refresh-btn" onclick="event.stopPropagation(); refreshGuild()" title="Atualizar Informações da Guilda">
                                    <span class="refresh-icon">🔄</span>
                                </button>
                            </div>
                        </div>
                        <div class="card-content">
                            <div id="guildInfo"></div>
                        </div>
                    </div>
                    
                    <div class="card" id="cardParty">
                        <div class="card-title">
                            <span onclick="toggleCard('cardParty')">Party</span>
                            <div class="card-title-actions">
                                <span class="value" id="partyName">-</span>
                                <button class="refresh-btn" onclick="event.stopPropagation(); refreshParty()" title="Atualizar Informações da Party">
                                    <span class="refresh-icon">🔄</span>
                                </button>
                            </div>
                        </div>
                        <div class="card-content">
                            <div id="partyInfo"></div>
                        </div>
                    </div>
                </div>
                
                <div class="main-column">
                    <div class="card" id="cardMonsterKills">
                        <div class="card-title">
                            <span onclick="toggleCard('cardMonsterKills')">Histórico de Kills</span>
                            <div class="card-title-actions">
                                <span class="value">Total: <span id="totalKills">0</span></span>
                                <button class="refresh-btn" onclick="event.stopPropagation(); refreshMonsterKills()" title="Atualizar Histórico de Kills">
                                    <span class="refresh-icon">🔄</span>
                                </button>
                            </div>
                        </div>
                        <div class="card-content">
                            <div class="tabs-container">
                                <div class="tabs">
                                    <button class="tab-btn active" onclick="switchKillsTab('your', event)">Seus Kills</button>
                                    <button class="tab-btn" onclick="switchKillsTab('party', event)">Party Kills</button>
                                </div>
                                <div class="tab-content" id="killsYourTab">
                                    <div class="monster-kills-list" id="monsterKillsYourList"></div>
                                </div>
                                <div class="tab-content" id="killsPartyTab" style="display: none;">
                                    <div class="monster-kills-list" id="monsterKillsPartyList"></div>
                                </div>
                            </div>
                        </div>
                    </div>
                    
                    <div class="card" id="cardItemDrops">
                        <div class="card-title">
                            <span onclick="toggleCard('cardItemDrops')">Drops de Itens</span>
                            <div class="card-title-actions">
                                <span class="value">Total: <span id="totalDrops">0</span></span>
                                <button class="refresh-btn" onclick="event.stopPropagation(); refreshItemDrops()" title="Atualizar Drops de Itens">
                                    <span class="refresh-icon">🔄</span>
                                </button>
                            </div>
                        </div>
                        <div class="card-content">
                            <div class="tabs-container">
                                <div class="tabs">
                                    <button class="tab-btn active" onclick="switchDropsTab('your', event)">Seus Drops</button>
                                    <button class="tab-btn" onclick="switchDropsTab('party', event)">Party Drops</button>
                                </div>
                                <div class="tab-content" id="dropsYourTab">
                                    <div class="item-drops-list" id="itemDropsYourList"></div>
                                </div>
                                <div class="tab-content" id="dropsPartyTab" style="display: none;">
                                    <div class="item-drops-list" id="itemDropsPartyList"></div>
                                </div>
                            </div>
                        </div>
                    </div>
                    
                    <div class="card" id="cardExperience">
                        <div class="card-title">
                            <span onclick="toggleCard('cardExperience')">Estatísticas de EXP</span>
                            <div class="card-title-actions">
                                <button class="refresh-btn" onclick="event.stopPropagation(); refreshExperience()" title="Atualizar Estatísticas de EXP">
                                    <span class="refresh-icon">🔄</span>
                                </button>
                            </div>
                        </div>
                        <div class="card-content">
                            <div id="experienceStats"></div>
                        </div>
                    </div>
                </div>

            </div>
        </main>
        
        <!-- Mobile Navbar -->
        <!-- Botões organizados na ordem dos cards de cima para baixo -->
        <nav class="mobile-navbar">
            <div class="mobile-navbar-content">
                <!-- 1. Personagem (cardCharMobile) -->
                <div class="mobile-nav-item active" onclick="scrollToSection('char', event)">
                    <div class="mobile-nav-icon">👤</div>
                    <div class="mobile-nav-label">Personagem</div>
                </div>
                <!-- 2. Comandos (cardCommandsMobile) -->
                <div class="mobile-nav-item" onclick="scrollToSection('commands', event)">
                    <div class="mobile-nav-icon">⚡</div>
                    <div class="mobile-nav-label">Comandos</div>
                </div>
                <!-- 3. Mapa (cardMap) -->
                <div class="mobile-nav-item" onclick="scrollToSection('map', event)">
                    <div class="mobile-nav-icon">🗺️</div>
                    <div class="mobile-nav-label">Mapa</div>
                </div>
                <!-- 4. Monstros (cardMonsters) -->
                <div class="mobile-nav-item" onclick="scrollToSection('monsters', event)">
                    <div class="mobile-nav-icon">👹</div>
                    <div class="mobile-nav-label">Monstros</div>
                    <span class="mobile-nav-badge" id="monstersBadge" style="display: none;">0</span>
                </div>
                <!-- 5. Chat (cardChat) -->
                <div class="mobile-nav-item" onclick="scrollToSection('chat', event)">
                    <div class="mobile-nav-icon">💬</div>
                    <div class="mobile-nav-label">Chat</div>
                </div>
                <!-- 6. Inventário (cardInv) -->
                <div class="mobile-nav-item" onclick="scrollToSection('inventory', event)">
                    <div class="mobile-nav-icon">🎒</div>
                    <div class="mobile-nav-label">Inventário</div>
                    <span class="mobile-nav-badge" id="invBadge" style="display: none;">0</span>
                </div>
                <!-- 7. Skills (cardSkills) -->
                <div class="mobile-nav-item" onclick="scrollToSection('skills', event)">
                    <div class="mobile-nav-icon">✨</div>
                    <div class="mobile-nav-label">Skills</div>
                </div>
                <!-- 8. Kills (cardMonsterKills) -->
                <div class="mobile-nav-item" onclick="scrollToSection('kills', event)">
                    <div class="mobile-nav-icon">⚔️</div>
                    <div class="mobile-nav-label">Kills</div>
                </div>
                <!-- 9. Drops (cardItemDrops) -->
                <div class="mobile-nav-item" onclick="scrollToSection('drops', event)">
                    <div class="mobile-nav-icon">💎</div>
                    <div class="mobile-nav-label">Drops</div>
                </div>
            </div>
        </nav>
    </div>

    <script>
        let mapData = null;
        const canvas = document.getElementById('mapCanvas');
        const ctx = canvas.getContext('2d');
        const mapImg = new Image();
        let mapImageLoaded = false;
        let contextMenu = null;
        
        // --- Gerenciamento de Múltiplas Instâncias ---
        let currentInstancePort = null;
        let availableInstances = [];
        
        // Obtém a porta atual da URL
        function getCurrentPort() {
            const port = window.location.port;
            return port ? parseInt(port) : 8888;
        }
        
        // Carrega porta salva ou usa a atual (8888 é a central)
        function loadSavedInstance() {
            const saved = localStorage.getItem('dashboardInstance');
            const currentPort = getCurrentPort();
            
            // Se estiver na porta 8888 (central), sempre usa null para detectar automaticamente
            if (currentPort === 8888) {
                currentInstancePort = null; // Será definido ao detectar instâncias
            } else if (saved) {
                currentInstancePort = parseInt(saved);
            } else {
                // Se não há porta salva e não está na central, usa a porta atual
                currentInstancePort = currentPort;
            }
        }
        
        // Salva porta selecionada
        function saveInstance(port) {
            currentInstancePort = port;
            localStorage.setItem('dashboardInstance', port.toString());
        }
        
        // Detecta instâncias disponíveis
        async function detectInstances() {
            try {
                const response = await fetch('/api/instances', {
                    method: 'GET',
                    headers: { 'Accept': 'application/json' },
                    cache: 'no-cache'
                });
                
                if (!response.ok) {
                    throw new Error(`HTTP ${response.status}`);
                }
                
                const data = await response.json();
                const newInstances = data.instances || [];
                
                // Verifica se houve mudança nas instâncias
                const instancesChanged = JSON.stringify(availableInstances.map(i => i.port).sort()) !== 
                                       JSON.stringify(newInstances.map(i => i.port).sort());
                
                availableInstances = newInstances;
                populateAccountSelector();
                
                // Se estiver na porta 8888 (central) e não há seleção, usa a primeira disponível
                const isCentral = getCurrentPort() === 8888;
                
                if (isCentral) {
                    // Na página central, sempre usa a primeira conta disponível se não houver seleção
                    if (!currentInstancePort && availableInstances.length > 0) {
                        switchAccount(availableInstances[0].port);
                    } else if (currentInstancePort) {
                        // Verifica se a instância selecionada ainda existe
                        const stillExists = availableInstances.some(i => i.port === currentInstancePort);
                        if (!stillExists && availableInstances.length > 0) {
                            // Instância não existe mais, muda para a primeira disponível
                            switchAccount(availableInstances[0].port);
                        } else {
                            // Mantém seleção atual
                            const select = document.getElementById('accountSelect');
                            const selectMobile = document.getElementById('accountSelectMobile');
                            if (select) select.value = currentInstancePort;
                            if (selectMobile) selectMobile.value = currentInstancePort;
                        }
                    }
                } else {
                    // Se estiver em uma porta específica, usa essa porta
                    if (!currentInstancePort) {
                        currentInstancePort = getCurrentPort();
                        saveInstance(currentInstancePort);
                    }
                    const select = document.getElementById('accountSelect');
                    const selectMobile = document.getElementById('accountSelectMobile');
                    if (select) select.value = currentInstancePort;
                    if (selectMobile) selectMobile.value = currentInstancePort;
                }
                
                // Se houve mudança e estamos monitorando, atualiza o dashboard
                if (instancesChanged) {
                    if (currentInstancePort) {
                        updateDashboard();
                    }
                    // Se uma nova instância foi adicionada, mostra no console
                    const newCount = availableInstances.length;
                    if (newCount > 0) {
                        console.log(`✓ ${newCount} conta(s) detectada(s): ${availableInstances.map(i => i.account_label || i.char_name).join(', ')}`);
                    }
                }
            } catch (error) {
                // Não loga erros de conexão constantemente para não poluir o console
                if (!error.message.includes('Failed to fetch') && !error.message.includes('ERR_CONNECTION_REFUSED')) {
                    console.error('Erro ao detectar instâncias:', error);
                }
                // Se falhar, mantém as instâncias já detectadas
            }
        }
        
        // Popula o seletor de contas
        function populateAccountSelector() {
            const select = document.getElementById('accountSelect');
            const selectMobile = document.getElementById('accountSelectMobile');
            
            if (!select || !selectMobile) return;
            
            // Limpa opções
            select.innerHTML = '';
            selectMobile.innerHTML = '';
            
            if (availableInstances.length === 0) {
                const option = document.createElement('option');
                option.value = '';
                option.textContent = 'Nenhuma instância encontrada';
                select.appendChild(option);
                selectMobile.appendChild(option.cloneNode(true));
                return;
            }
            
            // Ordena instâncias: primeiro por kore_id, depois por account_id
            availableInstances.sort((a, b) => {
                if (a.kore_id !== b.kore_id) {
                    return (a.kore_id || '').localeCompare(b.kore_id || '');
                }
                return (a.account_id || '').localeCompare(b.account_id || '');
            });
            
            availableInstances.forEach(instance => {
                // Mostra apenas o identificador da conta: "Ue-Kore0 Conta1", "Ue-Kore3 Conta2", etc
                const accountLabel = instance.account_label || `${instance.kore_id || 'N/A'} ${instance.account_id || 'N/A'}`;
                const label = accountLabel.replace(/ - /g, ' '); // Remove hífen, deixa só espaço
                const option = document.createElement('option');
                option.value = instance.port;
                option.textContent = label;
                option.setAttribute('data-kore', instance.kore_id || '');
                option.setAttribute('data-account', instance.account_id || '');
                if (instance.port === currentInstancePort) {
                    option.selected = true;
                }
                select.appendChild(option);
                selectMobile.appendChild(option.cloneNode(true));
            });
        }
        
        // Alterna entre contas
        function switchAccount(port) {
            if (!port) {
                const select = document.getElementById('accountSelect');
                const selectMobile = document.getElementById('accountSelectMobile');
                port = select ? select.value : (selectMobile ? selectMobile.value : null);
            }
            
            if (!port || port === '') return;
            
            const portNum = parseInt(port);
            const currentPort = getCurrentPort();
            
            // Se selecionou uma conta diferente da porta atual, redireciona para a porta específica
            if (portNum !== currentPort) {
                // Redireciona para a porta específica da conta selecionada (atualiza a própria página)
                window.location.replace(`http://localhost:${portNum}`);
                return;
            }
            
            // Se já estiver na porta específica selecionada, apenas atualiza os dados
            saveInstance(portNum);
            
            // Sincroniza ambos seletores
            const select = document.getElementById('accountSelect');
            const selectMobile = document.getElementById('accountSelectMobile');
            if (select) select.value = portNum;
            if (selectMobile) selectMobile.value = portNum;
            
            // Força atualização completa do dashboard
            setTimeout(() => {
                updateDashboard();
            }, 100);
        }
        
        // Função helper para fazer requisições com proxy se necessário
        async function apiGet(path) {
            try {
                const port = currentInstancePort;
                const currentPort = getCurrentPort();
                
                // Se estiver na página central (8888) e não há porta selecionada, retorna vazio
                if (currentPort === 8888 && !port) {
                    return {};
                }
                
                // Se estiver na página central e há porta selecionada, usa proxy
                if (currentPort === 8888 && port && port !== 8888) {
                    // Usa proxy para outra instância
                    const response = await fetch(`/api/proxy/${port}/${path.replace(/^\//, '')}`, {
                        method: 'GET',
                        headers: { 'Accept': 'application/json' },
                        cache: 'no-cache'
                    });
                    
                    if (!response.ok) {
                        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
                    }
                    
                    return await response.json();
                } else if (!port || port === currentPort) {
                    // Usa a instância atual diretamente
                    const response = await fetch(path, {
                        method: 'GET',
                        headers: { 'Accept': 'application/json' },
                        cache: 'no-cache'
                    });
                    
                    if (!response.ok) {
                        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
                    }
                    
                    return await response.json();
                } else {
                    // Usa proxy para outra instância
                    const response = await fetch(`/api/proxy/${port}/${path.replace(/^\//, '')}`, {
                        method: 'GET',
                        headers: { 'Accept': 'application/json' },
                        cache: 'no-cache'
                    });
                    
                    if (!response.ok) {
                        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
                    }
                    
                    return await response.json();
                }
            } catch (error) {
                // Se for erro de conexão, retorna objeto vazio em vez de lançar erro
                if (error.message.includes('Failed to fetch') || 
                    error.message.includes('ERR_CONNECTION_REFUSED') ||
                    error.message.includes('ERR_CONTENT_LENGTH_MISMATCH')) {
                    console.warn(`Erro ao buscar ${path}:`, error.message);
                    return {};
                }
                throw error;
            }
        }
        
        // Função helper para POST com proxy
        async function apiPostWithProxy(url, data) {
            const port = currentInstancePort;
            const currentPort = getCurrentPort();
            
            // Se estiver na página central (8888) e não há porta selecionada, retorna erro
            if (currentPort === 8888 && !port) {
                return { error: 'Nenhuma conta selecionada' };
            }
            
            // Se estiver na página central e há porta selecionada, usa proxy
            if (currentPort === 8888 && port && port !== 8888) {
                // Usa proxy POST para outra instância
                const path = url.replace(/^\//, '');
                return fetch(`/api/proxy/${port}/${path}`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(data)
                }).then(r => r.json()).catch((error) => {
                    console.error('Erro ao fazer POST via proxy:', error);
                    return { error: 'Erro ao conectar à instância' };
                });
            } else if (!port || port === currentPort) {
                return apiPost(url, data);
            } else {
                // Usa proxy POST para outra instância
                const path = url.replace(/^\//, '');
                return fetch(`/api/proxy/${port}/${path}`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(data)
                }).then(r => r.json()).catch((error) => {
                    console.error('Erro ao fazer POST via proxy:', error);
                    return { error: 'Erro ao conectar à instância' };
                });
            }
        }
        
        // --- Função de Alternância de Tema ---
        function toggleTheme() {
            const body = document.body;
            const themeIcon = document.getElementById('themeIcon');
            const themeText = document.getElementById('themeText');
            const themeIconMobile = document.getElementById('themeIconMobile');
            const themeTextMobile = document.getElementById('themeTextMobile');
            
            // Alterna a classe light-theme no body
            body.classList.toggle('light-theme');
            
            // Atualiza o ícone e texto baseado no tema atual (desktop e mobile)
            const isLight = body.classList.contains('light-theme');
            const icon = isLight ? '☀️' : '🌙';
            const text = isLight ? 'Tema Claro' : 'Tema Escuro';
            
            if (themeIcon) {
                themeIcon.textContent = icon;
            }
            if (themeText) {
                themeText.textContent = text;
            }
            if (themeIconMobile) {
                themeIconMobile.textContent = icon;
            }
            if (themeTextMobile) {
                themeTextMobile.textContent = text;
            }
            
            // Salva a preferência no localStorage
            localStorage.setItem('dashboardTheme', isLight ? 'light' : 'dark');
        }
        
        // Carrega o tema salvo ao carregar a página
        function loadTheme() {
            const savedTheme = localStorage.getItem('dashboardTheme');
            const isLight = savedTheme === 'light';
            const icon = isLight ? '☀️' : '🌙';
            const text = isLight ? 'Tema Claro' : 'Tema Escuro';
            
            if (isLight) {
                document.body.classList.add('light-theme');
            } else {
                document.body.classList.remove('light-theme');
            }
            
            // Atualiza ambos os botões (desktop e mobile)
            const themeIcon = document.getElementById('themeIcon');
            const themeText = document.getElementById('themeText');
            const themeIconMobile = document.getElementById('themeIconMobile');
            const themeTextMobile = document.getElementById('themeTextMobile');
            
            if (themeIcon) themeIcon.textContent = icon;
            if (themeText) themeText.textContent = text;
            if (themeIconMobile) themeIconMobile.textContent = icon;
            if (themeTextMobile) themeTextMobile.textContent = text;
        }
        
        // Inicializa o tema ao carregar
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', loadTheme);
        } else {
            loadTheme();
        }
        
        // Inicializa
        loadSavedInstance();
        detectInstances();
        // Re-detecta instâncias mais frequentemente para detectar mudanças
        setInterval(detectInstances, 5000); // Re-detecta a cada 5s
        
        // Configura scroll horizontal do navbar mobile
        function setupMobileNavbarScroll() {
            const navbar = document.querySelector('.mobile-navbar');
            const content = document.querySelector('.mobile-navbar-content');
            if (!navbar || !content) return;
            
            function updateScrollIndicators() {
                const scrollLeft = content.scrollLeft;
                const scrollWidth = content.scrollWidth;
                const clientWidth = content.clientWidth;
                const maxScroll = scrollWidth - clientWidth;
                
                // Remove classes anteriores
                navbar.classList.remove('scroll-start', 'scroll-end');
                
                // Adiciona classes baseado na posição do scroll
                if (scrollLeft <= 5) {
                    navbar.classList.add('scroll-start');
                }
                if (scrollLeft >= maxScroll - 5) {
                    navbar.classList.add('scroll-end');
                }
            }
            
            // Atualiza indicadores no scroll
            content.addEventListener('scroll', updateScrollIndicators);
            
            // Atualiza indicadores no resize
            window.addEventListener('resize', updateScrollIndicators);
            
            // Atualiza inicialmente
            updateScrollIndicators();
        }
        
        // Inicializa scroll do navbar quando o DOM estiver pronto
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', setupMobileNavbarScroll);
        } else {
            setupMobileNavbarScroll();
        }
        
        // Configura posicionamento fixo dos elementos do header mobile
        function setupMobileHeaderFixed() {
            const headerTitle = document.querySelector('.mobile-header-title');
            const accountSelector = document.querySelector('.mobile-account-selector');
            const mainContent = document.querySelector('.main-content');
            
            if (!headerTitle || !accountSelector || !mainContent) return;
            
            function updateMobileHeaderPositions() {
                // Só ajusta no mobile (largura <= 900px)
                if (window.innerWidth > 900) {
                    accountSelector.style.top = '';
                    mainContent.style.paddingTop = '';
                    return;
                }
                
                // Calcula altura do header-title
                const headerHeight = headerTitle.offsetHeight;
                
                // Posiciona account-selector logo abaixo do header-title
                accountSelector.style.top = headerHeight + 'px';
                
                // Calcula altura total dos elementos fixos (header + selector)
                const accountHeight = accountSelector.offsetHeight;
                const totalFixedHeight = headerHeight + accountHeight;
                
                // Ajusta padding-top do main-content para não ficar escondido
                mainContent.style.paddingTop = (totalFixedHeight + 10) + 'px';
            }
            
            // Atualiza posições inicialmente
            updateMobileHeaderPositions();
            
            // Atualiza posições no resize
            window.addEventListener('resize', updateMobileHeaderPositions);
            
            // Observa mudanças no DOM (caso os elementos sejam modificados)
            const observer = new MutationObserver(updateMobileHeaderPositions);
            if (headerTitle) observer.observe(headerTitle, { attributes: true, childList: true, subtree: true });
            if (accountSelector) observer.observe(accountSelector, { attributes: true, childList: true, subtree: true });
        }
        
        // Inicializa posicionamento fixo do header mobile
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', setupMobileHeaderFixed);
        } else {
            setupMobileHeaderFixed();
        }
        
        // Verifica se a conta atual mudou (por exemplo, se o personagem mudou)
        let lastCharName = null;
        setInterval(() => {
            if (currentInstancePort) {
                apiGet('/api/current-instance').then(info => {
                    if (info && info.char_name && info.char_name !== 'N/A') {
                        if (lastCharName && lastCharName !== info.char_name) {
                            // Personagem mudou, pode ser que a conta mudou
                            console.log('Personagem detectado mudou, re-detectando instâncias...');
                            detectInstances();
                        }
                        lastCharName = info.char_name;
                    }
                }).catch(() => {});
            }
        }, 3000); // Verifica a cada 3s
        
        // --- Loop Principal de Atualização ---
        setInterval(updateDashboard, 1000);
        updateDashboard();
        
        // --- Funções de UI ---
        
        // Colapsa/expande cards
        function toggleCard(cardId) {
            const card = document.getElementById(cardId);
            const content = card.querySelector('.card-content');
            if (content) {
                const isMinimized = content.style.display === 'none';
                content.style.display = isMinimized ? '' : 'none';
                // Adiciona uma classe para estilização futura, se necessário
                card.classList.toggle('minimized', !isMinimized);
            }
        }
        
        // Fecha o menu de contexto
        document.addEventListener('click', () => {
            if (contextMenu) {
                contextMenu.remove();
                contextMenu = null;
            }
        });
        
        // Mostra menu de contexto para itens
        function showContextMenu(e, item) {
            e.preventDefault();
            e.stopPropagation();
            if (contextMenu) contextMenu.remove();

            contextMenu = document.createElement('div');
            contextMenu.className = 'context-menu';

            const actions = [
                { label: 'Usar', action: () => apiPostWithProxy('/api/item/use', { index: item.index }) },
                { label: item.equipped ? 'Desequipar' : 'Equipar',
                  action: () => apiPostWithProxy(item.equipped ? '/api/item/unequip' : '/api/item/equip', { index: item.index }) },
                { label: 'Dropar...', danger: true, action: async () => {
                    let q = prompt(`Quantidade para dropar (máx ${item.amount}):`, '1');
                    if (q === null) return;
                    q = parseInt(q, 10);
                    if (isNaN(q) || q < 1) q = 1;
                    if (q > item.amount) q = item.amount;
                    await apiPostWithProxy('/api/item/drop', { index: item.index, amount: q });
                }},
            ];

            actions.forEach(a => {
                const div = document.createElement('div');
                div.className = 'context-menu-item' + (a.danger ? ' danger' : '');
                div.textContent = a.label;
                div.onclick = ev => { ev.stopPropagation(); a.action(); if (contextMenu) contextMenu.remove(); contextMenu = null; };
                contextMenu.appendChild(div);
            });
            
            // Posicionamento inteligente
            document.body.appendChild(contextMenu);
            const rect = contextMenu.getBoundingClientRect();
            let x = e.pageX, y = e.pageY;
            if (x + rect.width > window.innerWidth) {
                x = window.innerWidth - rect.width - 5;
            }
            if (y + rect.height > window.innerHeight) {
                y = window.innerHeight - rect.height - 5;
            }
            contextMenu.style.left = x + 'px';
            contextMenu.style.top = y + 'px';
        }

        
        // --- Funções de Atualização de Dados ---
        
        async function updateDashboard() {
            try {
                // Otimizado para buscar todos os dados essenciais de uma vez
                // Usa Promise.allSettled para não falhar completamente se uma requisição falhar
                const results = await Promise.allSettled([
                    apiGet('/api/all'),
                    apiGet('/api/stats'),
                    apiGet('/api/monsters'),
                    apiGet('/api/target')
                ]);
                
                const data = results[0].status === 'fulfilled' ? results[0].value : {};
                const stats = results[1].status === 'fulfilled' ? results[1].value : {};
                const monsters = results[2].status === 'fulfilled' ? results[2].value : { monsters: [] };
                const target = results[3].status === 'fulfilled' ? results[3].value : {};
                
                if (data.character) updateCharacter(data.character);
                if (data.map) updateMap(data.map);
                if (data.inventory) updateInventory(data.inventory);
                if (data.cart) updateCart(data.cart);
                if (data.skills) updateSkills(data.skills);
                if (monsters.monsters) updateMonstersList(monsters.monsters);
                if (target) updateTarget(target);
                
                // Chat tem sua própria busca para ser mais leve
                updateChat().catch(() => {}); // Ignora erros de chat
                
                // Atualiza dados adicionais (menos frequentes)
                updateAdditionalData().catch(() => {}); // Ignora erros
                
                // Verifica se pelo menos uma requisição funcionou
                const hasData = results.some(r => r.status === 'fulfilled' && r.value && Object.keys(r.value).length > 0);
                if (hasData) {
                    document.getElementById('statusDot')?.classList.remove('error');
                    document.getElementById('statusDotMobile')?.classList.remove('error');
                } else {
                    document.getElementById('statusDot')?.classList.add('error');
                    document.getElementById('statusDotMobile')?.classList.add('error');
                }
            } catch (error) {
                console.error('Erro ao atualizar dashboard:', error);
                document.getElementById('statusDot')?.classList.add('error');
                document.getElementById('statusDotMobile')?.classList.add('error');
            }
        }
        
        // Atualiza dados adicionais (kills, drops, guild, party, exp) - menos frequente
        let lastAdditionalUpdate = 0;
        const ADDITIONAL_UPDATE_INTERVAL = 5000; // 5 segundos
        async function updateAdditionalData() {
            const now = Date.now();
            if (now - lastAdditionalUpdate < ADDITIONAL_UPDATE_INTERVAL) return;
            lastAdditionalUpdate = now;
            
            try {
                const results = await Promise.allSettled([
                    apiGet('/api/monster-kills'),
                    apiGet('/api/item-drops'),
                    apiGet('/api/guild'),
                    apiGet('/api/party'),
                    apiGet('/api/experience')
                ]);
                
                if (results[0].status === 'fulfilled' && results[0].value) {
                    updateMonsterKills(results[0].value);
                }
                if (results[1].status === 'fulfilled' && results[1].value) {
                    updateItemDrops(results[1].value);
                }
                if (results[2].status === 'fulfilled' && results[2].value) {
                    updateGuild(results[2].value);
                }
                if (results[3].status === 'fulfilled' && results[3].value) {
                    updateParty(results[3].value);
                }
                if (results[4].status === 'fulfilled' && results[4].value) {
                    updateExperience(results[4].value);
                }
            } catch (error) {
                // Silenciosamente ignora erros
            }
        }
        
        function updateCharacter(char) {
            if (!char || !char.stats) return;
            
            // Sidebar (Desktop)
            document.getElementById('charName').textContent = char.name || '-';
            document.getElementById('charJob').textContent = char.job || '-';
            document.getElementById('charLevel').textContent = `${char.level} / ${char.job_level}`;
            document.getElementById('charZeny').textContent = (char.zeny || 0).toLocaleString('pt-BR');
            
            document.getElementById('hpValue').textContent = `${char.hp}/${char.hp_max}`;
            document.getElementById('spValue').textContent = `${char.sp}/${char.sp_max}`;
            document.getElementById('expValue').textContent = `${char.exp_percent}%`;
            document.getElementById('expJobValue').textContent = `${char.exp_job_percent}%`;
            document.getElementById('weightValue').textContent = `${char.weight}/${char.weight_max}`;
            
            updateProgressBar('hpBar', char.hp_percent);
            updateProgressBar('spBar', char.sp_percent);
            updateProgressBar('expBar', char.exp_percent);
            updateProgressBar('expJobBar', char.exp_job_percent);
            updateProgressBar('weightBar', char.weight_percent);
            
            // Header (Mobile)
            document.getElementById('charNameMobile').textContent = char.name || '-';
            document.getElementById('charLevelMobile').textContent = `Lv. ${char.level}`;
            document.getElementById('charJobMobile').textContent = char.job || '-';
            document.getElementById('charZenyMobile').textContent = (char.zeny || 0).toLocaleString('pt-BR') + ' Z';
            
            document.getElementById('hpValueMob').textContent = `${char.hp}/${char.hp_max}`;
            document.getElementById('spValueMob').textContent = `${char.sp}/${char.sp_max}`;

            updateProgressBar('hpBarMob', char.hp_percent);
            updateProgressBar('spBarMob', char.sp_percent);
            
            // Stats (Ambos)
            const statPoints = char.points_free || 0;
            const skillPoints = char.points_skill || 0;
            
            document.getElementById('statPoints').textContent = statPoints;
            document.getElementById('skillPoints').textContent = skillPoints;
            
            const stats = ['Str', 'Agi', 'Vit', 'Int', 'Dex', 'Luk'];
            stats.forEach(s => {
                const statId = s.toLowerCase();
                document.getElementById('stat' + s).textContent = char.stats[statId] || 0;
                const btn = document.getElementById('btn' + s);
                if (btn) {
                    btn.classList.toggle('show', statPoints > 0);
                }
            });
        }
        
        // NOTE: A função 'text' foi removida pois o novo layout não a utiliza
        function updateProgressBar(id, percent) {
            const bar = document.getElementById(id);
            if (bar) {
                bar.style.width = Math.min(parseFloat(percent) || 0, 100) + '%';
            }
        }
        
        function updateMap(map) {
            if (!map) return;
            
            mapData = map; // Salva para uso no clique e desenho
            document.getElementById('mapName').textContent = map.name || '-';
            document.getElementById('mapPos').textContent = `${map.char_x}, ${map.char_y}`;
            document.getElementById('aiState').textContent = map.ai_state || '-';
            
            document.getElementById('playersCount').textContent = (map.players || []).length;
            document.getElementById('monstersCount').textContent = (map.monsters || []).length;
            document.getElementById('portalsCount').textContent = (map.portals || []).length;
            
            // Lógica de carregamento e desenho do mapa
            if (map.name && (!mapImg.src || !mapImg.src.includes(map.name))) {
                mapImageLoaded = false;
                mapImg.src = `https://www.divine-pride.net/img/map/original/${map.name}`;
                mapImg.onload = () => { mapImageLoaded = true; drawMap(); };
                mapImg.onerror = () => { mapImageLoaded = false; drawMap(); };
            } else {
                drawMap();
            }
        }
        
        function drawMap() {
            if (!mapData || !canvas) return;
            
            const container = document.getElementById('mapContainer');
            if (!container) return;
            
            const cw = container.offsetWidth;
            const ch = container.offsetHeight;
            
            // Limpa canvas
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            
            if (mapImageLoaded && mapImg.complete && mapImg.naturalWidth > 0) {
                canvas.width = mapImg.naturalWidth;
                canvas.height = mapImg.naturalHeight;
                const scale = Math.min(cw / canvas.width, ch / canvas.height);
                canvas.style.width = (canvas.width * scale) + 'px';
                canvas.style.height = (canvas.height * scale) + 'px';
                ctx.drawImage(mapImg, 0, 0);
            } else {
                // Fallback: Desenha grid simples
                const w = mapData.width || 100;
                const h = mapData.height || 100;
                canvas.width = w;
                canvas.height = h;
                const scale = Math.min(cw / w, ch / h);
                canvas.style.width = (w * scale) + 'px';
                canvas.style.height = (h * scale) + 'px';
                
                ctx.fillStyle = '#0D1117';
                ctx.fillRect(0, 0, canvas.width, canvas.height);
                ctx.strokeStyle = 'rgba(255,255,255,0.1)';
                ctx.lineWidth = 1;
                for (let i = 0; i <= 10; i++) {
                    const x = (canvas.width / 10) * i;
                    const y = (canvas.height / 10) * i;
                    ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, canvas.height); ctx.stroke();
                    ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(canvas.width, y); ctx.stroke();
                }
            }
            
            // Funções de escala (Y é invertido no RO)
            const scaleX = canvas.width / (mapData.width || 1);
            const scaleY = canvas.height / (mapData.height || 1);
            const sx = (x) => x * scaleX;
            const sy = (y) => (mapData.height - y) * scaleY;
            
            // Desenha Portais
            if (mapData.portals) {
                ctx.fillStyle = 'rgba(163, 113, 247, 0.7)'; // roxo
                ctx.strokeStyle = '#fff';
                ctx.lineWidth = 1;
                mapData.portals.forEach(p => {
                    const x = sx(p.x || 0); const y = sy(p.y || 0);
                    ctx.beginPath(); ctx.arc(x, y, 6, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
                });
            }
            
            // Desenha Monstros
            if (mapData.monsters) {
                ctx.fillStyle = 'rgba(218, 54, 51, 0.8)'; // vermelho
                mapData.monsters.forEach(m => {
                    const x = sx(m.x || 0); const y = sy(m.y || 0);
                    ctx.beginPath(); ctx.arc(x, y, 4, 0, Math.PI * 2); ctx.fill();
                });
            }
            
            // Desenha Players
            if (mapData.players) {
                ctx.fillStyle = 'rgba(56, 139, 253, 0.8)'; // azul
                mapData.players.forEach(p => {
                    const x = sx(p.x || 0); const y = sy(p.y || 0);
                    ctx.beginPath(); ctx.arc(x, y, 4, 0, Math.PI * 2); ctx.fill();
                });
            }
            
            // Desenha Personagem
            const cx = sx(mapData.char_x || 0);
            const cy = sy(mapData.char_y || 0);
            ctx.fillStyle = 'rgba(63, 185, 80, 0.5)'; // verde
            ctx.beginPath(); ctx.arc(cx, cy, 10, 0, Math.PI * 2); ctx.fill();
            ctx.fillStyle = '#3FB950';
            ctx.beginPath(); ctx.arc(cx, cy, 6, 0, Math.PI * 2); ctx.fill();
            ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; ctx.stroke();
        }
        
        // Clique no Mapa
        canvas.addEventListener('click', (e) => {
            if (!mapData) return;
            const rect = canvas.getBoundingClientRect();
            // Converte de coordenadas do canvas (style) para coordenadas do mapa (width/height)
            const canvasX = (e.clientX - rect.left) * (canvas.width / rect.width);
            const canvasY = (e.clientY - rect.top) * (canvas.height / rect.height);
            
            // Converte de coordenadas do canvas (pixels) para coordenadas do jogo (células)
            const scaleX = mapData.width / canvas.width;
            const scaleY = mapData.height / canvas.height;
            const x = Math.floor(canvasX * scaleX);
            const y = mapData.height - Math.floor(canvasY * scaleY); // Y invertido
            
            apiPostWithProxy('/api/move', { x, y });
        });
        
        function updateInventory(inv) {
            if (!inv) return;
            const grid = document.getElementById('inventoryGrid');
            if (!grid) return;
            
            const count = inv.count || 0;
            document.getElementById('invCount').textContent = count;
            
            // Atualiza badge mobile
            const invBadge = document.getElementById('invBadge');
            if (invBadge) {
                if (count > 0) {
                    invBadge.textContent = count > 99 ? '99+' : count;
                    invBadge.style.display = 'block';
                } else {
                    invBadge.style.display = 'none';
                }
            }
            grid.innerHTML = ''; // Limpa

            if (inv.items && inv.items.length > 0) {
                inv.items.forEach(item => {
                    const div = document.createElement('div');
                    const classes = ['item', item.category];
                    if (item.equipped) classes.push('equipped');
                    div.className = classes.join(' ');
                    
                    div.onclick = (e) => {
                        // Simula um clique esquerdo para 'Usar'
                        e.stopPropagation();
                        if (contextMenu) contextMenu.remove(); contextMenu = null;
                        apiPostWithProxy('/api/item/use', { index: item.index });
                    };
                    div.oncontextmenu = (e) => showContextMenu(e, item);

                    const badge = item.equipped ? `<span class="item-badge">E</span>` : '';
                    const iconUrl = `https://static.divine-pride.net/images/items/item/${item.nameID}.png`;

                    div.innerHTML = `
                        ${badge}
                        <div class="item-icon"><img src="${iconUrl}" loading="lazy" onerror="this.style.display='none'"></div>
                        <div class="item-name" title="${item.name}">${item.name}</div>
                        <div class="item-amount">x${item.amount}</div>
                    `;
                    grid.appendChild(div);
                });
            }
        }
        
        function updateCart(cart) {
            if (!cart) return;
            const cartTabBtn = document.getElementById('inventoryTabCart');
            const cartInfo = document.getElementById('cartInfo');
            const cartGrid = document.getElementById('cartGrid');
            const cartEmpty = document.getElementById('cartEmpty');
            
            if (!cartTabBtn || !cartGrid || !cartEmpty) return;
            
            // Mostra/oculta aba do carrinho baseado em has_cart
            if (cart.has_cart) {
                cartTabBtn.style.display = 'inline-block';
                
                // Atualiza informações do carrinho
                if (cartInfo) {
                    document.getElementById('cartItemsCount').textContent = cart.items_count || 0;
                    document.getElementById('cartItemsMax').textContent = cart.items_max || 0;
                    document.getElementById('cartWeight').textContent = cart.weight || 0;
                    document.getElementById('cartWeightMax').textContent = cart.weight_max || 0;
                    document.getElementById('cartWeightPercent').textContent = cart.weight_percent || 0;
                    cartInfo.style.display = 'block';
                }
                
                cartGrid.innerHTML = '';
                
                if (cart.items && cart.items.length > 0) {
                    cartEmpty.style.display = 'none';
                    cart.items.forEach(item => {
                        const div = document.createElement('div');
                        div.className = ['item', item.category].join(' ');
                        
                        div.onclick = (e) => {
                            e.stopPropagation();
                            if (contextMenu) contextMenu.remove(); contextMenu = null;
                            apiPostWithProxy('/api/item/use', { index: item.index, from: 'cart' });
                        };
                        div.oncontextmenu = (e) => showContextMenu(e, item);

                        const iconUrl = `https://static.divine-pride.net/images/items/item/${item.nameID}.png`;

                        div.innerHTML = `
                            <div class="item-icon"><img src="${iconUrl}" loading="lazy" onerror="this.style.display='none'"></div>
                            <div class="item-name" title="${item.name}">${item.name}</div>
                            <div class="item-amount">x${item.amount}</div>
                        `;
                        cartGrid.appendChild(div);
                    });
                } else {
                    cartEmpty.style.display = 'block';
                }
            } else {
                cartTabBtn.style.display = 'none';
                // Se estiver na aba do carrinho e não tiver carrinho, volta para pessoal
                if (document.getElementById('inventoryCartTab').style.display !== 'none') {
                    switchInventoryTab('personal', null);
                }
            }
        }
        
        function switchInventoryTab(tab, evt) {
            if (evt) evt.stopPropagation();
            
            const personalTab = document.getElementById('inventoryPersonalTab');
            const cartTab = document.getElementById('inventoryCartTab');
            const personalBtn = document.getElementById('inventoryTabPersonal');
            const cartBtn = document.getElementById('inventoryTabCart');
            
            if (tab === 'personal') {
                if (personalTab) personalTab.style.display = 'block';
                if (cartTab) cartTab.style.display = 'none';
                if (personalBtn) personalBtn.classList.add('active');
                if (cartBtn) cartBtn.classList.remove('active');
            } else if (tab === 'cart') {
                if (personalTab) personalTab.style.display = 'none';
                if (cartTab) cartTab.style.display = 'block';
                if (personalBtn) personalBtn.classList.remove('active');
                if (cartBtn) cartBtn.classList.add('active');
            }
        }
        
        function updateSkills(skills) {
            if (!skills) return;
            const list = document.getElementById('skillsList');
            if (!list) return;
            
            const skillPoints = parseInt(document.getElementById('skillPoints').textContent) || 0;
            list.innerHTML = '';
            
            if (skills.skills && skills.skills.length > 0) {
                skills.skills.forEach(skill => {
                    const div = document.createElement('div');
                    div.className = 'skill-item';
                    
                    const upgradeBtn = skillPoints > 0 ? 
                        `<button class="skill-btn" onclick="upgradeSkill('${skill.handle}')">+ Upar</button>` :
                        '';
                    
                    div.innerHTML = `
                        <div>
                            <div class="skill-name">${skill.name}</div>
                            <div class="skill-details">Lv. ${skill.level} | SP: ${skill.sp}</div>
                        </div>
                        ${upgradeBtn}
                    `;
                    list.appendChild(div);
                });
            }
        }
        
        function updateMonstersList(monsters) {
            const list = document.getElementById('monstersList');
            if (!list) return;
            
            list.innerHTML = '';
            
            const count = monsters ? monsters.length : 0;
            
            // Atualiza badge mobile
            const monstersBadge = document.getElementById('monstersBadge');
            if (monstersBadge) {
                if (count > 0) {
                    monstersBadge.textContent = count > 99 ? '99+' : count;
                    monstersBadge.style.display = 'block';
                } else {
                    monstersBadge.style.display = 'none';
                }
            }
            
            if (monsters && monsters.length > 0) {
                monsters.slice(0, 15).forEach(monster => { // Limita a 15
                    const div = document.createElement('div');
                    div.className = 'monster-item';
                    const hpPercent = monster.hp_max > 0 ? (monster.hp / monster.hp_max * 100).toFixed(0) : 0;
                    
                    div.innerHTML = `
                        <div>
                            <div class="monster-name">${monster.name}</div>
                            <div class="monster-details">Lv. ${monster.level}</div>
                        </div>
                        <div>
                            <div class="monster-hp">${hpPercent}%</div>
                            <div class="monster-distance">${monster.distance}m</div>
                        </div>
                    `;
                    list.appendChild(div);
                });
            } else {
                list.innerHTML = '<div style="color: var(--text-secondary); text-align: center; font-size: 0.9em;">Nenhum monstro por perto.</div>';
            }
        }
        
        function updateTarget(target) {
            const card = document.getElementById('targetCard');
            if (!card) return;
            
            if (target && target.exists === true) {
                card.style.display = 'block';
                document.getElementById('targetName').textContent = target.name;
                document.getElementById('targetLevel').textContent = target.level || '-';
                document.getElementById('targetDistance').textContent = target.distance || '-';
                
                const hpPercent = target.hp_max > 0 ? (target.hp / target.hp_max * 100) : 0;
                document.getElementById('targetHpValue').textContent = `${target.hp}/${target.hp_max}`;
                updateProgressBar('targetHpBar', hpPercent);
            } else {
                card.style.display = 'none';
            }
        }
        
        // Variável para controlar qual aba está ativa
        let activeChatTab = 'console';
        
        // Função para trocar de aba
        function switchChatTab(tab, evt) {
            const event = evt || window.event;
            activeChatTab = tab;
            
            // Remove active de todos os botões
            document.querySelectorAll('#cardChat .tab-btn').forEach(btn => btn.classList.remove('active'));
            
            // Esconde todos os containers
            document.getElementById('chatTab').style.display = 'none';
            document.getElementById('consoleTab').style.display = 'none';
            document.getElementById('latamchecksumTab').style.display = 'none';
            
            // Mostra a aba selecionada
            if (tab === 'chat') {
                document.getElementById('chatTab').style.display = 'block';
                document.querySelectorAll('#cardChat .tab-btn')[0].classList.add('active');
            } else if (tab === 'console') {
                document.getElementById('consoleTab').style.display = 'block';
                document.querySelectorAll('#cardChat .tab-btn')[1].classList.add('active');
            } else if (tab === 'latamchecksum') {
                document.getElementById('latamchecksumTab').style.display = 'block';
                document.querySelectorAll('#cardChat .tab-btn')[2].classList.add('active');
            }
            
            // Atualiza a aba ativa
            if (event && event.target) {
                event.target.classList.add('active');
            }
            
            // Força atualização do chat para a aba selecionada
            updateChat();
        }
        
        async function updateChat() {
            try {
                const data = await apiGet('/api/chat');
                if (!data || !data.messages || data.messages.length === 0) {
                    return;
                }

                // Filtra mensagens por tipo de aba e remove mensagens vazias
                let filteredMessages = [];
                let container = null;
                
                if (activeChatTab === 'chat') {
                    // Aceita todos os tipos de chat do jogo: public, private, party, guild, self
                    filteredMessages = data.messages.filter(msg => 
                        (msg.type === 'public' || 
                         msg.type === 'private' || 
                         msg.type === 'party' || 
                         msg.type === 'guild' || 
                         msg.type === 'self') &&
                        msg.message && 
                        msg.message.trim() !== ''
                    );
                    container = document.getElementById('chatContainer');
                } else if (activeChatTab === 'console') {
                    // Filtra mensagens de console e remove vazias
                    filteredMessages = data.messages.filter(msg => 
                        msg.type === 'console' && 
                        msg.message && 
                        msg.message.trim() !== ''
                    );
                    container = document.getElementById('consoleContainer');
                } else if (activeChatTab === 'latamchecksum') {
                    // Filtra mensagens do LatamChecksum e remove vazias
                    filteredMessages = data.messages.filter(msg => 
                        msg.type === 'latamchecksum' && 
                        msg.message && 
                        msg.message.trim() !== ''
                    );
                    container = document.getElementById('latamchecksumContainer');
                }
                
                if (!container || filteredMessages.length === 0) {
                    return;
                }

                // Otimização: só atualiza se houver mensagens novas
                const latestTimestamp = filteredMessages[filteredMessages.length - 1].time;
                const timestampKey = `lastChatTimestamp_${activeChatTab}`;
                if (latestTimestamp === window[timestampKey]) {
                    return;
                }
                window[timestampKey] = latestTimestamp;
                
                const shouldScroll = container.scrollHeight - container.scrollTop <= container.clientHeight + 50;
                
                // Remove duplicatas baseado em timestamp + mensagem (últimas 100 mensagens)
                const seenMessages = new Set();
                const uniqueMessages = [];
                for (let i = filteredMessages.length - 1; i >= 0 && uniqueMessages.length < 100; i--) {
                    const msg = filteredMessages[i];
                    const msgKey = `${msg.time}_${msg.name}_${msg.message}`;
                    if (!seenMessages.has(msgKey)) {
                        seenMessages.add(msgKey);
                        uniqueMessages.unshift(msg);
                    }
                }
                
                const newHtml = uniqueMessages.map(msg => {
                    const time = new Date(msg.time * 1000).toLocaleTimeString('pt-BR', { 
                        hour: '2-digit', 
                        minute: '2-digit', 
                        second: '2-digit' 
                    });
                    const msgType = msg.type || 'console';
                    const category = msg.category || msg.type || 'info';
                    
                    // Para mensagens de chat do jogo, usa o tipo diretamente (public, private, party, guild, self)
                    // Para console/latamchecksum, usa tipo + categoria (replicando o console do OpenKore)
                    let entryClass = msgType;
                    if (msgType !== 'public' && msgType !== 'private' && 
                        msgType !== 'party' && msgType !== 'guild' && 
                        msgType !== 'self') {
                        entryClass = `${msgType} ${category}`;
                    }
                    
                    // Formatação similar ao console do OpenKore: [time] domain: message
                    const name = msg.name && msg.name.trim() !== '' ? msg.name : '';
                    const message = (msg.message || '').trim();
                    
                    // Escapa HTML para segurança
                    const escapeHtml = (text) => {
                        if (!text) return '';
                        return String(text)
                            .replace(/&/g, '&amp;')
                            .replace(/</g, '&lt;')
                            .replace(/>/g, '&gt;')
                            .replace(/"/g, '&quot;')
                            .replace(/'/g, '&#039;');
                    };
                    
                    const nameHtml = name ? `<span class="name">${escapeHtml(name)}:</span>` : '';
                    const messageHtml = escapeHtml(message);
                    
                    return `<div class="chat-entry ${entryClass}">
                                <span class="time">[${time}]</span>
                                ${nameHtml}
                                <span class="message">${messageHtml}</span>
                            </div>`;
                }).join('');
                
                // Evita "flicker" se o conteúdo for o mesmo
                if (container.innerHTML !== newHtml) {
                    container.innerHTML = newHtml;
                }
                
                if (shouldScroll) {
                    container.scrollTop = container.scrollHeight;
                }
            } catch (e) {
                // Silenciosamente ignora erros de chat para não poluir o console
                // console.error("Erro ao atualizar chat:", e);
            }
        }
        
        // --- Ações de API (POST) ---
        
        async function sendCommand(cmd) {
            try {
                const response = await apiPostWithProxy('/api/command', { command: cmd });
                if (response && response.success === false) {
                    console.warn('Erro ao executar comando:', response.error || 'Erro desconhecido');
                }
            } catch (error) {
                console.error('Erro ao enviar comando:', error);
            }
        }
        
        function sendCustomCommand() {
            const input = document.getElementById('customCommand');
            if (input && input.value && input.value.trim()) {
                const command = input.value.trim();
                // Envia o comando exatamente como digitado (Commands::run processa internamente)
                // Commands::run suporta múltiplos comandos separados por ;;
                sendCommand(command);
                input.value = '';
                // Foca no input novamente para facilitar envio de múltiplos comandos
                setTimeout(() => input.focus(), 50);
            }
        }
        
        function sendCustomCommandMobile() {
            const input = document.getElementById('customCommandMobile');
            if (input && input.value && input.value.trim()) {
                const command = input.value.trim();
                sendCommand(command);
                input.value = '';
                setTimeout(() => input.focus(), 50);
            }
        }
        
        async function sendChat() {
            const input = document.getElementById('chatInput');
            if (input && input.value.trim()) {
                await apiPostWithProxy('/api/chat/send', { message: input.value.trim() });
                input.value = '';
            }
        }
        
        function scrollToSection(section, event) {
            // Remove active de todos os itens
            document.querySelectorAll('.mobile-nav-item').forEach(item => {
                item.classList.remove('active');
            });
            
            // Adiciona active ao item clicado
            const clickedItem = event ? event.target.closest('.mobile-nav-item') : null;
            if (clickedItem) {
                clickedItem.classList.add('active');
            }
            
            // Scroll suave para a seção
            let targetId = '';
            switch(section) {
                case 'char':
                    targetId = 'cardCharMobile';
                    break;
                case 'map':
                    targetId = 'cardMap';
                    break;
                case 'inventory':
                    targetId = 'cardInv';
                    break;
                case 'monsters':
                    targetId = 'cardMonsters';
                    break;
                case 'chat':
                    targetId = 'cardChat';
                    break;
                case 'skills':
                    targetId = 'cardSkills';
                    break;
                case 'commands':
                    targetId = 'cardCommandsMobile';
                    break;
                case 'kills':
                    targetId = 'cardMonsterKills';
                    break;
                case 'drops':
                    targetId = 'cardItemDrops';
                    break;
            }
            
            const element = document.getElementById(targetId);
            if (element) {
                element.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        }
        
        async function setAI(mode) {
            await apiPostWithProxy('/api/ai', { mode });
        }
        
        async function upgradeStat(stat) {
            await apiPostWithProxy('/api/stat/upgrade', { stat });
        }
        
        async function upgradeSkill(handle) {
            await apiPostWithProxy('/api/skill/upgrade', { skill: handle });
        }
        
        // Funções de atualização dos novos cards
        // Variáveis globais para armazenar dados (para atualizar total dinamicamente)
        let currentKillsData = null;
        let currentDropsData = null;
        
        function updateMonsterKills(data) {
            if (!data) return;
            
            // Armazena dados para atualizar total quando trocar de tab
            currentKillsData = data;
            
            // Calcula total baseado no tab ativo
            updateKillsTotal();
            
            // Atualiza lista de seus kills
            const yourList = document.getElementById('monsterKillsYourList');
            if (yourList && data.monsters_your_kills) {
                yourList.innerHTML = '';
                // Remove limite de 20 itens para mostrar todos
                data.monsters_your_kills.forEach(monster => {
                    const div = document.createElement('div');
                    div.className = 'kill-item';
                    div.innerHTML = `
                        <div>
                            <div class="kill-item-name">${monster.name || 'Unknown'}</div>
                            <div class="kill-item-details">Lv. ${monster.level || 0} | EXP/kill: ${(monster.exp_per_kill || 0).toLocaleString('pt-BR')}</div>
                        </div>
                        <div class="kill-item-stats">
                            <div class="count">${monster.count || 0}x</div>
                            <div class="exp">${(monster.exp_gained || 0).toLocaleString('pt-BR')} EXP</div>
                        </div>
                    `;
                    yourList.appendChild(div);
                });
                if (data.monsters_your_kills.length === 0) {
                    yourList.innerHTML = '<div style="color: var(--text-secondary); text-align: center; padding: 20px;">Nenhum kill registrado ainda.</div>';
                }
            }
            
            // Atualiza lista de party kills
            const partyList = document.getElementById('monsterKillsPartyList');
            if (partyList && data.monsters_party_kills) {
                partyList.innerHTML = '';
                // Remove limite de 20 itens para mostrar todos
                data.monsters_party_kills.forEach(monster => {
                    const div = document.createElement('div');
                    div.className = 'kill-item';
                    div.innerHTML = `
                        <div>
                            <div class="kill-item-name">${monster.name || 'Unknown'}</div>
                            <div class="kill-item-details">Lv. ${monster.level || 0} | EXP/kill: ${(monster.exp_per_kill || 0).toLocaleString('pt-BR')}</div>
                        </div>
                        <div class="kill-item-stats">
                            <div class="count">${monster.count || 0}x</div>
                            <div class="exp">${(monster.exp_gained || 0).toLocaleString('pt-BR')} EXP</div>
                        </div>
                    `;
                    partyList.appendChild(div);
                });
                if (data.monsters_party_kills.length === 0) {
                    partyList.innerHTML = '<div style="color: var(--text-secondary); text-align: center; padding: 20px;">Nenhum kill da party registrado ainda.</div>';
                }
            }
        }
        
        // Atualiza o total de kills baseado no tab ativo
        function updateKillsTotal() {
            if (!currentKillsData) return;
            
            // Verifica qual tab está ativo
            const yourTab = document.getElementById('killsYourTab');
            const isYourTabActive = yourTab && yourTab.style.display !== 'none';
            
            // Calcula total baseado no tab ativo
            let totalKills = 0;
            if (isYourTabActive) {
                // Tab "Seus Kills" ativo - mostra apenas seus kills
                totalKills = currentKillsData.total_kills_your || 0;
            } else {
                // Tab "Party Kills" ativo - mostra apenas party kills
                totalKills = currentKillsData.total_kills_party || 0;
            }
            
            document.getElementById('totalKills').textContent = totalKills.toLocaleString('pt-BR');
        }
        
        // Atualiza o total de drops baseado no tab ativo
        function updateDropsTotal() {
            if (!currentDropsData) return;
            
            // Verifica qual tab está ativo
            const yourTab = document.getElementById('dropsYourTab');
            const isYourTabActive = yourTab && yourTab.style.display !== 'none';
            
            // Calcula total baseado no tab ativo
            let totalDrops = 0;
            if (isYourTabActive) {
                // Tab "Seus Drops" ativo - mostra apenas seus drops
                totalDrops = currentDropsData.total_amount_your || 0;
            } else {
                // Tab "Party Drops" ativo - mostra apenas party drops
                totalDrops = currentDropsData.total_amount_party || 0;
            }
            
            document.getElementById('totalDrops').textContent = totalDrops.toLocaleString('pt-BR');
        }
        
        function updateItemDrops(data) {
            if (!data) return;
            
            // Armazena dados para atualizar total quando trocar de tab
            currentDropsData = data;
            
            // Calcula total baseado no tab ativo
            updateDropsTotal();
            
            // Atualiza lista de seus drops
            const yourList = document.getElementById('itemDropsYourList');
            if (yourList && data.items_your_drops) {
                yourList.innerHTML = '';
                // Remove limite de 20 itens para mostrar todos
                data.items_your_drops.forEach(item => {
                    const div = document.createElement('div');
                    div.className = 'drop-item';
                    div.innerHTML = `
                        <div>
                            <div class="drop-item-name">${item.name || 'Unknown Item'}</div>
                            <div class="drop-item-details">De: ${item.monster_name || 'Unknown'} (Lv. ${item.monster_level || 0})</div>
                        </div>
                        <div class="drop-item-stats">
                            <div class="amount">x${(item.amount || 0).toLocaleString('pt-BR')}</div>
                        </div>
                    `;
                    yourList.appendChild(div);
                });
                if (data.items_your_drops.length === 0) {
                    yourList.innerHTML = '<div style="color: var(--text-secondary); text-align: center; padding: 20px;">Nenhum drop registrado ainda.</div>';
                }
            }
            
            // Atualiza lista de party drops
            const partyList = document.getElementById('itemDropsPartyList');
            if (partyList && data.items_party_drops) {
                partyList.innerHTML = '';
                // Remove limite de 20 itens para mostrar todos
                data.items_party_drops.forEach(item => {
                    const div = document.createElement('div');
                    div.className = 'drop-item';
                    div.innerHTML = `
                        <div>
                            <div class="drop-item-name">${item.name || 'Unknown Item'}</div>
                            <div class="drop-item-details">De: ${item.monster_name || 'Unknown'} (Lv. ${item.monster_level || 0})</div>
                        </div>
                        <div class="drop-item-stats">
                            <div class="amount">x${(item.amount || 0).toLocaleString('pt-BR')}</div>
                        </div>
                    `;
                    partyList.appendChild(div);
                });
                if (data.items_party_drops.length === 0) {
                    partyList.innerHTML = '<div style="color: var(--text-secondary); text-align: center; padding: 20px;">Nenhum drop da party registrado ainda.</div>';
                }
            }
        }
        
        function updateGuild(data) {
            if (!data || !data.guild_info) {
                document.getElementById('guildName').textContent = 'Sem Guilda';
                document.getElementById('guildInfo').innerHTML = '<div style="color: var(--text-secondary); text-align: center; padding: 20px;">Você não está em uma guilda.</div>';
                return;
            }
            
            const guild = data.guild_info;
            document.getElementById('guildName').textContent = guild.name || '-';
            
            const guildInfo = document.getElementById('guildInfo');
            if (!guildInfo) return;
            
            let html = `
                <div class="guild-header">
                    <div class="guild-header-info">
                        <div class="label">Nível</div>
                        <div class="value">${guild.level || 0}</div>
                    </div>
                    <div class="guild-header-info">
                        <div class="label">Membros</div>
                        <div class="value">${guild.connect_member || 0} / ${guild.max_members || 0}</div>
                    </div>
                    <div class="guild-header-info">
                        <div class="label">Líder</div>
                        <div class="value">${guild.master || '-'}</div>
                    </div>
                </div>
            `;
            
            if (guild.members_list && guild.members_list.length > 0) {
                html += '<div class="members-list">';
                guild.members_list.forEach(member => {
                    const onlineClass = member.online ? 'online' : 'offline';
                    html += `
                        <div class="member-item ${onlineClass}">
                            <div>
                                <div class="member-name">${member.name || 'Unknown'}</div>
                                <div class="member-details">Lv. ${member.level || 0} | ${member.title || 'Membro'}</div>
                            </div>
                            <div class="member-status ${onlineClass}">${member.online ? 'Online' : 'Offline'}</div>
                        </div>
                    `;
                });
                html += '</div>';
            } else {
                html += '<div style="color: var(--text-secondary); text-align: center; padding: 20px;">Nenhum membro carregado.</div>';
            }
            
            guildInfo.innerHTML = html;
        }
        
        function updateParty(data) {
            if (!data || !data.party_info) {
                document.getElementById('partyName').textContent = 'Sem Party';
                document.getElementById('partyInfo').innerHTML = '<div style="color: var(--text-secondary); text-align: center; padding: 20px;">Você não está em uma party.</div>';
                return;
            }
            
            const party = data.party_info;
            document.getElementById('partyName').textContent = party.name || 'Sem Nome';
            
            const partyInfo = document.getElementById('partyInfo');
            if (!partyInfo) return;
            
            let html = `
                <div class="party-header">
                    <div class="party-header-info">
                        <div class="label">Membros</div>
                        <div class="value">${party.members || 0}</div>
                    </div>
                    <div class="party-header-info">
                        <div class="label">Compartilhamento EXP</div>
                        <div class="value">${party.exp_share ? 'Sim' : 'Não'}</div>
                    </div>
                    <div class="party-header-info">
                        <div class="label">Compartilhamento Itens</div>
                        <div class="value">${party.item_pickup ? 'Sim' : 'Não'}</div>
                    </div>
                </div>
            `;
            
            if (party.members_list && party.members_list.length > 0) {
                html += '<div class="members-list">';
                party.members_list.forEach(member => {
                    const onlineClass = member.online ? 'online' : 'offline';
                    html += `
                        <div class="member-item ${onlineClass}">
                            <div>
                                <div class="member-name">${member.name || 'Unknown'}</div>
                                <div class="member-details">Lv. ${member.level || 0} | ${member.map || '???'} | ${member.position || 'Membro'}</div>
                            </div>
                            <div class="member-status ${onlineClass}">${member.online ? 'Online' : 'Offline'}</div>
                        </div>
                    `;
                });
                html += '</div>';
            } else {
                html += '<div style="color: var(--text-secondary); text-align: center; padding: 20px;">Nenhum membro carregado.</div>';
            }
            
            partyInfo.innerHTML = html;
        }
        
        function updateExperience(data) {
            if (!data) return;
            
            const expStats = document.getElementById('experienceStats');
            if (!expStats) return;
            
            expStats.innerHTML = `
                <div class="exp-stat">
                    <div class="exp-stat-label">EXP Base/hora</div>
                    <div class="exp-stat-value">${(data.perHourBaseExp || 0).toLocaleString('pt-BR')}</div>
                </div>
                <div class="exp-stat">
                    <div class="exp-stat-label">EXP Job/hora</div>
                    <div class="exp-stat-value">${(data.perHourJobExp || 0).toLocaleString('pt-BR')}</div>
                </div>
                <div class="exp-stat">
                    <div class="exp-stat-label">Zeny/hora</div>
                    <div class="exp-stat-value">${(data.perHourZeny || 0).toLocaleString('pt-BR')}</div>
                </div>
                <div class="exp-stat">
                    <div class="exp-stat-label">EXP Base Ganha</div>
                    <div class="exp-stat-value">${(data.sessionBaseExpGained || 0).toLocaleString('pt-BR')}</div>
                </div>
                <div class="exp-stat">
                    <div class="exp-stat-label">EXP Job Ganha</div>
                    <div class="exp-stat-value">${(data.sessionJobExpGained || 0).toLocaleString('pt-BR')}</div>
                </div>
                <div class="exp-stat">
                    <div class="exp-stat-label">Tempo Botting</div>
                    <div class="exp-stat-value">${data.bottingTime || '0s'}</div>
                </div>
                <div class="exp-stat">
                    <div class="exp-stat-label">Mortes</div>
                    <div class="exp-stat-value">${data.deathCount || 0}</div>
                </div>
                <div class="exp-stat">
                    <div class="exp-stat-label">Desconexões</div>
                    <div class="exp-stat-value">${data.disconnectCount || 0}</div>
                </div>
            `;
        }
        
        // Funções para atualizar cards individualmente
        let isRefreshingInventory = false;
        async function refreshInventory(evt) {
            // Previne múltiplas chamadas simultâneas
            if (isRefreshingInventory) return;
            
            const btn = evt ? evt.target.closest('.refresh-btn') : null;
            if (btn) {
                isRefreshingInventory = true;
                btn.classList.add('refreshing');
                try {
                    // Usa endpoint específico do inventário em vez de /api/all para evitar loop
                    const data = await apiGet('/api/inventory');
                    if (data) {
                        updateInventory(data);
                    }
                    // Também atualiza o carrinho se necessário
                    const cartData = await apiGet('/api/cart');
                    if (cartData) {
                        updateCart(cartData);
                    }
                } catch (error) {
                    console.error('Erro ao atualizar inventário:', error);
                } finally {
                    setTimeout(() => {
                        if (btn) btn.classList.remove('refreshing');
                        isRefreshingInventory = false;
                    }, 500);
                }
            }
        }
        
        async function refreshMonsterKills() {
            const btn = event.target.closest('.refresh-btn');
            if (btn) {
                btn.classList.add('refreshing');
                try {
                    const data = await apiGet('/api/monster-kills');
                    if (data) {
                        updateMonsterKills(data);
                    }
                } catch (error) {
                    console.error('Erro ao atualizar histórico de kills:', error);
                } finally {
                    setTimeout(() => {
                        if (btn) btn.classList.remove('refreshing');
                    }, 500);
                }
            }
        }
        
        async function refreshItemDrops() {
            const btn = event.target.closest('.refresh-btn');
            if (btn) {
                btn.classList.add('refreshing');
                try {
                    const data = await apiGet('/api/item-drops');
                    if (data) {
                        updateItemDrops(data);
                    }
                } catch (error) {
                    console.error('Erro ao atualizar drops:', error);
                } finally {
                    setTimeout(() => {
                        if (btn) btn.classList.remove('refreshing');
                    }, 500);
                }
            }
        }
        
        async function refreshExperience() {
            const btn = event.target.closest('.refresh-btn');
            if (btn) {
                btn.classList.add('refreshing');
                try {
                    const data = await apiGet('/api/experience');
                    if (data) {
                        updateExperience(data);
                    }
                } catch (error) {
                    console.error('Erro ao atualizar estatísticas de EXP:', error);
                } finally {
                    setTimeout(() => {
                        if (btn) btn.classList.remove('refreshing');
                    }, 500);
                }
            }
        }
        
        async function refreshGuild() {
            const btn = event.target.closest('.refresh-btn');
            if (btn) {
                btn.classList.add('refreshing');
                try {
                    const data = await apiGet('/api/guild');
                    if (data) {
                        updateGuild(data);
                    }
                } catch (error) {
                    console.error('Erro ao atualizar informações da guilda:', error);
                } finally {
                    setTimeout(() => {
                        if (btn) btn.classList.remove('refreshing');
                    }, 500);
                }
            }
        }
        
        async function refreshParty() {
            const btn = event.target.closest('.refresh-btn');
            if (btn) {
                btn.classList.add('refreshing');
                try {
                    const data = await apiGet('/api/party');
                    if (data) {
                        updateParty(data);
                    }
                } catch (error) {
                    console.error('Erro ao atualizar informações da party:', error);
                } finally {
                    setTimeout(() => {
                        if (btn) btn.classList.remove('refreshing');
                    }, 500);
                }
            }
        }
        
        // Funções para alternar tabs
        function switchKillsTab(tab, evt) {
            const event = evt || window.event;
            document.querySelectorAll('#cardMonsterKills .tab-btn').forEach(btn => btn.classList.remove('active'));
            document.getElementById('killsYourTab').style.display = tab === 'your' ? 'block' : 'none';
            document.getElementById('killsPartyTab').style.display = tab === 'party' ? 'block' : 'none';
            if (event && event.target) {
                event.target.classList.add('active');
            } else {
                document.querySelectorAll('#cardMonsterKills .tab-btn')[tab === 'your' ? 0 : 1].classList.add('active');
            }
            // Atualiza o total quando trocar de tab
            updateKillsTotal();
        }
        
        function switchDropsTab(tab, evt) {
            const event = evt || window.event;
            document.querySelectorAll('#cardItemDrops .tab-btn').forEach(btn => btn.classList.remove('active'));
            document.getElementById('dropsYourTab').style.display = tab === 'your' ? 'block' : 'none';
            document.getElementById('dropsPartyTab').style.display = tab === 'party' ? 'block' : 'none';
            if (event && event.target) {
                event.target.classList.add('active');
            } else {
                document.querySelectorAll('#cardItemDrops .tab-btn')[tab === 'your' ? 0 : 1].classList.add('active');
            }
            // Atualiza o total quando trocar de tab
            updateDropsTotal();
        }
        
        // Função helper genérica para POST
        async function apiPost(url, data) {
            try {
                const response = await fetch(url, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(data)
                });
                return await response.json();
            } catch (error) {
                console.error('API POST Error:', error);
            }
        }
    </script>
</body>
</html>};
}

1;		