# --- PLUGIN FEITO PARA AMIGOS DO FORUM OPENKORE.COM.BR
# --- AS DONATES NAO SAO APENAS PARA ATIVAR O BOT, e SIM PARA QUE EU POSSA SEGUIR AJUDANDO A COMUNIDADE.
# --- 
package autoBotControl;

use strict;
use Plugins;
use Globals;
use Log qw(message warning error);
use Utils;
use Commands;
use Time::HiRes qw(sleep);

Plugins::register('autoBotControl', 'Controla AI baseado no bot do jogo', \&unload);

my $hooks = Plugins::addHooks(
    ['mainLoop_post', \&checkLoop],
    ['packet/map_changed', \&onMapChange],
    ['packet/system_chat', \&onSystemChat],
    ['packet/npc_talk_continue', \&onNpcTalkContinue],
    ['packet/npc_talk_responses', \&onNpcTalkResponses],
    ['packet/npc_talk', \&onNpcTalk]  # Adicionado para detectar início do diálogo
);

# ================= CONFIG =================
my $itemID = '2200661';

my $checkInterval = 2;
my $npcDelayMin = 0.8;
my $npcDelayMax = 1.5;

my $itemCooldown = 8;   # segundos entre tentativas de item
# ==========================================

# ================= STATES =================
my $lastCheck = 0;
my $mapaMudouEm = 0;

my $botGameAtivo = 0;        # confirmado via system chat
my $esperandoConfirmacao = 0;

my $ultimaTentativaItem = 0;

my $aguardandoResposta = 0;
my $npcStep = 0;
my $lastNpcAction = 0;

my $itemSlotEncontrado = -1;

my $aiForcado = '';          # MANUAL / AUTO
my $currentMap = '';
my $configLockMap = '';      # Será carregado do config.txt

my $forcarDesativacao = 0;   # Flag para forçar tentativa de desativação
# ==========================================


sub unload {
    Plugins::delHooks($hooks);
    message "[autoBotControl] Plugin descarregado.\n";
}

# =========================================================

# Função para carregar o lockMap do config.txt
sub getLockMapFromConfig {
    if (open(my $fh, '<', Settings::getConfigFilename())) {
        while (my $line = <$fh>) {
            # Remove espaços e tabs do início e fim
            $line =~ s/^\s+|\s+$//g;
            
            # Procura por lockMap na configuração
            if ($line =~ /^lockMap\s+(.+)$/i) {
                my $mapa = $1;
                $mapa =~ s/\s+$//g;  # Remove espaços no final
                
                # Remove comentários se houver
                if ($mapa =~ /^(.*?)#/) {
                    $mapa = $1;
                    $mapa =~ s/\s+$//g;
                }
                
                message "[autoBotControl] LockMap carregado do config.txt: $mapa\n", "info";
                return $mapa;
            }
        }
        close($fh);
    }
    
    message "[autoBotControl] Não encontrou lockMap no config.txt\n", "warning";
    return '';
}

sub checkLoop {
    return unless $net && $net->getState() == Network::IN_GAME;
    return unless $field;
    
    # Carrega lockMap do config.txt se ainda não carregou
    if ($configLockMap eq '') {
        $configLockMap = getLockMapFromConfig();
    }
    
    my $now = time;
    my $newMap = $field->baseName;

    # Verifica se o mapa mudou desde a última checagem
    if ($newMap ne $currentMap) {
        $currentMap = $newMap;
        message "[autoBotControl] Mapa detectado: $currentMap\n", "info";
        
        # IMPORTANTE: Resetar estado do botGame quando muda de mapa
        if ($configLockMap ne '' && $currentMap eq $configLockMap) {
            # Se entrou no lockMap, assume que precisa ativar
            $botGameAtivo = 0;  # Precisa ativar
            $forcarDesativacao = 0;
            message "[autoBotControl] Entrou no lockMap - tentando ATIVAR bot\n", "info";
        } else {
            # Se saiu do lockMap, força desativação
            $botGameAtivo = 1;  # Assume que está ativado para tentar desativar
            $forcarDesativacao = 1;  # Força tentativa de desativação
            message "[autoBotControl] Saiu do lockMap - forçando DESATIVAÇÃO do bot\n", "info";
        }
        $esperandoConfirmacao = 0;
        $ultimaTentativaItem = 0;
    }

    if ($aguardandoResposta) {
        checkNpcTimeout();
        return;
    }

    return if ($now - $lastCheck < $checkInterval);
    $lastCheck = $now;

    if ($mapaMudouEm > 0 && ($now - $mapaMudouEm) < 5) {
        return;
    }

    return unless $char && $char->inventory && $char->inventory->size() > 0;

    # ===== CONTROLE FORÇADO DE AI =====
    if ($configLockMap ne '' && $currentMap eq $configLockMap) {
        if ($aiForcado ne 'MANUAL') {
            message "[autoBotControl] No lockMap - Forçando AI MANUAL\n", "info";
            Commands::run("ai manual");
            $aiForcado = 'MANUAL';
        }
    } else {
        if ($aiForcado ne 'AUTO') {
            message "[autoBotControl] Fora do lockMap - Forçando AI AUTO\n", "info";
            Commands::run("ai auto");
            $aiForcado = 'AUTO';
        }
    }
    # =================================

    # ===== CONTROLE DO BOT DO JOGO =====

    # No lockMap → garantir ATIVADO
    if ($configLockMap ne '' && $currentMap eq $configLockMap) {
        if ($botGameAtivo == 0 && !$esperandoConfirmacao) {
            if (time - $ultimaTentativaItem >= $itemCooldown) {
                message "[autoBotControl] No lockMap - Bot não ativado. Tentando ATIVAR...\n", "success";
                buscarEUsarItem();
                $ultimaTentativaItem = time;
                $esperandoConfirmacao = 1;
            }
        } elsif ($botGameAtivo == 1) {
            # Já está ativado, só mostra status
            debug("[autoBotControl] Bot já ativado no lockMap\n");
        }
    }
    # Fora do lockMap → garantir DESATIVADO (sempre tentar até receber confirmação)
    else {
        # Se $forcarDesativacao estiver ativo ou se o bot estiver marcado como ativado
        if (($forcarDesativacao || $botGameAtivo == 1) && !$esperandoConfirmacao) {
            if (time - $ultimaTentativaItem >= $itemCooldown) {
                message "[autoBotControl] Fora do lockMap - Tentando DESATIVAR bot...\n", "success";
                buscarEUsarItem();
                $ultimaTentativaItem = time;
                $esperandoConfirmacao = 1;
            }
        } elsif ($botGameAtivo == 0) {
            # Já está desativado, só mostra status
            debug("[autoBotControl] Bot já desativado fora do lockMap\n");
        }
    }
    # ================================
}

# =========================================================

sub buscarEUsarItem {
    message "[autoBotControl] Buscando item no inventário...\n", "info";

    $itemSlotEncontrado = -1;
    
    # Método 1: Verificar slots diretamente
    for (my $i = 0; $i < @{$char->inventory->getItems()}; $i++) {
        my $item = $char->inventory->get($i);
        next unless $item;
        
        if (defined $item->{nameID} && $item->{nameID} eq $itemID) {
            $itemSlotEncontrado = $i;
            message "[autoBotControl] Item encontrado no slot $i (nameID: $item->{nameID})\n", "info";
            last;
        }
        
        # Também verifica pelo ID como string
        if (defined $item->{ID} && $item->{ID} eq $itemID) {
            $itemSlotEncontrado = $i;
            message "[autoBotControl] Item encontrado no slot $i (ID: $item->{ID})\n", "info";
            last;
        }
    }
    
    # Método 2: Tentar usar diretamente pelo ID
    if ($itemSlotEncontrado == -1) {
        message "[autoBotControl] Tentando usar item pelo ID diretamente: $itemID\n", "info";
        usarItemPeloID();
        return;
    }
    
    usarItem($itemSlotEncontrado);
}

sub usarItemPeloID {
    $aguardandoResposta = 1;
    $npcStep = 0;
    $lastNpcAction = time;
    
    # Tenta usar pelo ID diretamente
    Commands::run("is $itemID");
    message "[autoBotControl] Comando executado: is $itemID\n", "info";
}

sub usarItem {
    my ($slot) = @_;

    message "[autoBotControl] Usando item slot $slot\n", "info";

    $aguardandoResposta = 1;
    $npcStep = 0;
    $lastNpcAction = time;

    Commands::run("is $slot");
    message "[autoBotControl] Comando executado: is $slot\n", "info";

    $itemSlotEncontrado = -1;
}

# =========================================================

sub checkNpcTimeout {
    if ($aguardandoResposta && (time - $lastNpcAction) > 15) {
        warning "[autoBotControl] Timeout NPC - resetando diálogo\n";
        $aguardandoResposta = 0;
        $npcStep = 0;
        $esperandoConfirmacao = 0;
        $ultimaTentativaItem = time; # Reseta cooldown
    }
}

# =========================================================

sub onMapChange {
    $mapaMudouEm = time;
    
    # Resetar estados
    $esperandoConfirmacao = 0;
    $ultimaTentativaItem = 0;
    $aguardandoResposta = 0;
    $npcStep = 0;
    
    # Força reavaliação do AI
    $aiForcado = '';
    
    message "[autoBotControl] Mapa mudou - aguardando estabilizar...\n", "info";
}

# =========================================================

sub onSystemChat {
    my (undef, $args) = @_;
    my $msg = $args->{Msg};
    
    return unless defined $msg;
    
    message "[autoBotControl] System chat: $msg\n", "info";
    
    if ($msg =~ /Autoattack\s*:\s*Activated/i) {
        message "[autoBotControl] *** CONFIRMADO: Bot do jogo ATIVADO ***\n", "success";
        $botGameAtivo = 1;
        $forcarDesativacao = 0;  # Resetar flag de força
        $esperandoConfirmacao = 0;
        $aguardandoResposta = 0;
        $npcStep = 0;
    }
    elsif ($msg =~ /Autoattack\s*:\s*Deactivated/i) {
        message "[autoBotControl] *** CONFIRMADO: Bot do jogo DESATIVADO ***\n", "success";
        $botGameAtivo = 0;
        $forcarDesativacao = 0;  # Resetar flag de força
        $esperandoConfirmacao = 0;
        $aguardandoResposta = 0;
        $npcStep = 0;
    }
}

# =========================================================
# NPC DIALOG HANDLERS - CORRIGIDOS
# =========================================================

sub onNpcTalk {
    my (undef, $args) = @_;
    
    # Detecta início de diálogo NPC
    if ($aguardandoResposta && $npcStep == 0) {
        message "[autoBotControl] Diálogo NPC iniciado\n", "info";
    }
}

sub onNpcTalkContinue {
    my (undef, $args) = @_;

    return unless $aguardandoResposta && $npcStep == 0;
    
    # Aguarda um pouco antes de responder
    my $delay = $npcDelayMin + rand($npcDelayMax - $npcDelayMin);
    sleep($delay);
    
    # Envia diretamente ao servidor usando messageSender
    if ($messageSender && $talk{ID}) {
        $messageSender->sendTalkContinue($talk{ID});
        message "[autoBotControl] Enviando Talk Continue para servidor (NPC ID: $talk{ID})\n", "info";
    } else {
        # Fallback usando comando (não ideal)
        Commands::run("talk cont");
        message "[autoBotControl] Enviando Talk Continue via console\n", "info";
    }
    
    $npcStep = 1;
    $lastNpcAction = time;
}

sub onNpcTalkResponses {
    my (undef, $args) = @_;

    return unless $aguardandoResposta && $npcStep == 1;
    
    # Aguarda um pouco antes de responder
    my $delay = $npcDelayMin + rand($npcDelayMax - $npcDelayMin);
    sleep($delay);
    
    # Envia diretamente ao servidor usando messageSender
    if ($messageSender && $talk{ID}) {
        Commands::run("talk resp 0");
        message "[autoBotControl] Enviando Talk Response (opção 0) para servidor\n", "info";
    } else {
        # Fallback usando comando (não ideal)
        Commands::run("talk resp 0");
        message "[autoBotControl] Enviando Talk Response via console\n", "info";
    }
    
    $aguardandoResposta = 0;
    $npcStep = 0;
    $esperandoConfirmacao = 1;  # Agora espera confirmação do system chat
    message "[autoBotControl] Aguardando confirmação do system chat...\n", "info";
}

# =========================================================

sub debug {
    my ($msg) = @_;
    # Descomente para ver mensagens de debug
    # message("[DEBUG autoBotControl] $msg\n");
}

1;