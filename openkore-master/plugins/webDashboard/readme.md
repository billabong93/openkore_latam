# 🎮 webDashboard V2.0 PRO

<div align="center">

![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)
![OpenKore](https://img.shields.io/badge/OpenKore-Compatible-green.svg)
![License](https://img.shields.io/badge/license-Open%20Source-orange.svg)
![Platform](https://img.shields.io/badge/platform-Web-lightgrey.svg)

**Dashboard Web Profissional para OpenKore com Interface Moderna e Responsiva**

[Features](#-features) • [Instalação](#-instalação) • [Uso](#-uso) • [API](#-api-documentation) • [Suporte](#-suporte)

</div>

---

## 📋 Índice

- [Sobre](#-sobre)
- [Features](#-features)
- [Preview](#-preview)
- [Instalação](#-instalação)
- [Uso](#-uso)
- [Múltiplas Instâncias](#-múltiplas-instâncias)
- [API Documentation](#-api-documentation)
- [Arquitetura](#-arquitetura)
- [Troubleshooting](#-troubleshooting)
- [Roadmap](#-roadmap)
- [Contribuindo](#-contribuindo)
- [Créditos](#-créditos)
- [Licença](#-licença)

---

## 🎯 Sobre

O **webDashboard V2.0 PRO** é um plugin completo para OpenKore que fornece uma interface web moderna e profissional para monitorar e controlar seu bot em tempo real. Com suporte total para múltiplas contas, tema claro/escuro e interface responsiva otimizada para desktop e mobile.

### Por que usar?

- ✅ **Monitoramento em Tempo Real**: Veja tudo que acontece com seu bot instantaneamente
- ✅ **Controle Total**: Execute comandos, gerencie inventário, controle AI sem sair do navegador
- ✅ **Múltiplas Contas**: Gerencie todas as suas contas de um único lugar
- ✅ **Mobile-First**: Interface otimizada para smartphones e tablets
- ✅ **Sem Dependências Externas**: Servidor HTTP integrado, não precisa instalar nada além do plugin

---

## ✨ Features

### 📊 Monitoramento Completo

<details>
<summary><b>📈 Informações do Personagem</b></summary>

- **Stats em Tempo Real**: HP, SP, EXP Base/Job, Peso, Zeny
- **Atributos**: STR, AGI, VIT, INT, DEX, LUK com botões de upgrade
- **Barras de Progresso Animadas**: Visualização clara de todos os status
- **Pontos Disponíveis**: Stats e Skills points sempre visíveis
</details>

<details>
<summary><b>🗺️ Mapa Interativo</b></summary>

- **Mapa Real**: Carrega imagem do mapa do Divine Pride
- **Visualização Completa**: Players, monstros, NPCs, portais
- **Interativo**: Clique no mapa para mover o personagem
- **Informações**: Posição atual, estado da AI, contadores
</details>

<details>
<summary><b>🎒 Gerenciamento de Itens</b></summary>

- **Inventário Pessoal**: Grid visual com ícones do Divine Pride
- **Carrinho**: Suporte completo com informações de peso e capacidade
- **Categorização**: Equipados, equipáveis, consumíveis
- **Ações Rápidas**: Menu de contexto (usar, equipar, desequipar, dropar)
- **Atualização Manual**: Botão de refresh para forçar atualização
</details>

<details>
<summary><b>✨ Skills</b></summary>

- **Lista Completa**: Todas as skills com level e custo de SP
- **Upgrade Direto**: Botão de upar quando há pontos disponíveis
- **Nomes Localizados**: Nomes em PT-BR (usando sistema do OpenKore)
</details>

<details>
<summary><b>💬 Chat e Console</b></summary>

- **Três Abas**: Chat do Jogo, Console OpenKore, LatamChecksum
- **Filtros por Tipo**: Public, Private, Party, Guild, Self
- **Cores por Categoria**: Packets, Movement, Errors, Debug, Info
- **Envio de Mensagens**: Input integrado para chat público
- **Auto-scroll**: Acompanha mensagens novas automaticamente
</details>

### 📈 Estatísticas Avançadas

<details>
<summary><b>⚔️ Histórico de Kills</b></summary>

- **Separação Inteligente**: Seus kills vs Kills da party
- **Informações Completas**: Nome, level, quantidade, EXP ganha, EXP por kill
- **Ordenação**: Por quantidade de kills e EXP total
- **Atualização em Tempo Real**: Detecta kills automaticamente
</details>

<details>
<summary><b>💎 Histórico de Drops</b></summary>

- **Separação Inteligente**: Seus drops vs Drops da party
- **Associação com Monstros**: Mostra de qual monstro dropou
- **Quantidade Total**: Contador de itens coletados
- **Atualização Automática**: Detecta drops instantaneamente
</details>

<details>
<summary><b>📊 Experiência e Progresso</b></summary>

- **EXP por Hora**: Base e Job calculados automaticamente
- **Zeny por Hora**: Ganho de zeny estimado
- **Tempo de Botting**: Contador de tempo online
- **Mortes e Desconexões**: Tracking completo
- **Tempo para Level Up**: Estimativa baseada na EXP/hora atual
</details>

### 👥 Informações de Grupo

<details>
<summary><b>🏰 Guilda</b></summary>

- **Informações Gerais**: Nome, level, EXP, líder
- **Lista de Membros**: Nome, level, título, status online/offline
- **Atualização Automática**: Solicita dados da guilda periodicamente
- **Refresh Manual**: Botão para forçar atualização
</details>

<details>
<summary><b>👥 Party</b></summary>

- **Configurações**: EXP share, item pickup, item division
- **Membros**: Nome, level, mapa, status online/offline
- **Posição**: Líder ou membro
- **Refresh Manual**: Botão para atualizar informações
</details>

### 🎮 Controles Interativos

<details>
<summary><b>🤖 Controle de AI</b></summary>

- **3 Modos**: OFF, MANUAL, AUTO
- **Botões Grandes**: Fácil de clicar, com cores distintivas
- **Feedback Visual**: Estado atual sempre visível
</details>

<details>
<summary><b>⚡ Comandos Rápidos</b></summary>

- **8 Atalhos**: Pause, Reload, Status, Inventory, Skills, EXP, Relog, Respawn
- **Console Customizado**: Execute qualquer comando do OpenKore
- **Histórico**: Suporte a múltiplos comandos (;;)
</details>

<details>
<summary><b>📊 Ações Rápidas</b></summary>

- **Stats**: Upgrade direto dos atributos
- **Skills**: Upgrade de skills com um clique
- **Itens**: Usar, equipar, desequipar, dropar via menu
- **Movimento**: Clique no mapa para mover
</details>

### 🌐 Múltiplas Instâncias

<details>
<summary><b>🔄 Sistema Inteligente</b></summary>

- **Auto-detecção**: Encontra todas as instâncias automaticamente
- **Seletor de Conta**: Dropdown com identificação clara
- **Troca Rápida**: Mude de conta instantaneamente
- **Página Central**: Porta 8888 para gerenciar tudo
- **Portas Automáticas**: Sistema de mapeamento 8889-8894
</details>

### 📱 Mobile-First Design

<details>
<summary><b>📲 Interface Otimizada</b></summary>

- **Navbar Inferior**: Scroll horizontal com todos os cards
- **Cards Colapsáveis**: Economize espaço na tela
- **Controles Touch**: Botões maiores, gestos suportados
- **Grid Adaptativo**: Layout reorganiza automaticamente
- **Header Fixo**: Informações importantes sempre visíveis
</details>

### 🎨 Personalização

<details>
<summary><b>🌓 Temas</b></summary>

- **Tema Escuro**: Padrão, confortável para uso noturno
- **Tema Claro**: Alternativa para ambientes claros
- **Alternância Rápida**: Botão de toggle no sidebar e mobile
- **Persistência**: Salva preferência no localStorage
</details>

---

## 🖼️ Preview

### Desktop
![Dashboard Desktop](screenshots/desktop.png)
*Tema escuro - Visão geral do dashboard*

### Mobile
![Dashboard Mobile](screenshots/mobile.png)
*Interface otimizada para smartphones*

### Mapa Interativo
![Mapa](screenshots/map.png)
*Mapa com visualização de entidades*

### Múltiplas Contas
![Multi-Account](screenshots/multi-account.png)
*Gerenciamento de múltiplas instâncias*

> **Nota**: Adicione suas próprias screenshots na pasta `screenshots/`

---

## 📥 Instalação

### Requisitos

- OpenKore (qualquer versão recente)
- Perl 5.10 ou superior (geralmente já incluído no OpenKore)
- Navegador moderno (Chrome, Firefox, Edge, Safari)

### Instalação Simples

1. **Download do Plugin**
```bash
   # Clone o repositório ou baixe o arquivo
   cd openkore/plugins
   wget https://raw.githubusercontent.com/seu-repo/webDashboard.pl
```

2. **Ou copie manualmente**
   - Copie `webDashboard.pl` para a pasta `plugins/` do seu OpenKore

3. **Reinicie o OpenKore**
   - O plugin será carregado automaticamente
   - Verifique no console: `[webDashboard] Servidor iniciado na porta XXXX!`

### Verificação

Se tudo estiver correto, você verá:
```
[webDashboard] Iniciando servidor web...
[webDashboard] Servidor iniciado na porta 8889 para Ue-Kore0 Conta1!
[webDashboard] Acesse: http://localhost:8889
```

---

## 🚀 Uso

### Acesso Básico

#### Uma Conta
Se você usa apenas uma conta:
```
http://localhost:PORTA
```
A porta é exibida no console ao iniciar o OpenKore.

#### Múltiplas Contas
Se você usa múltiplas contas, acesse a **página central**:
```
http://localhost:8888
```

### Sistema de Portas

O plugin usa um sistema inteligente de mapeamento de portas:

| Configuração | Porta |
|-------------|-------|
| Página Central | 8888 |
| Ue-Kore0 Conta1 | 8889 |
| Ue-Kore0 Conta2 | 8890 |
| Ue-Kore0 Conta3 | 8891 |
| Ue-Kore3 Conta1 | 8892 |
| Ue-Kore3 Conta2 | 8893 |
| Ue-Kore3 Conta3 | 8894 |

> **Nota**: O plugin detecta automaticamente qual conta está rodando baseado no caminho do `control folder`.

### Navegação

#### Desktop
- Use o **sidebar esquerdo** para informações do personagem e controles
- O **conteúdo principal** mostra mapa, inventário, chat, etc
- Clique nos **títulos dos cards** para colapsar/expandir

#### Mobile
- Use a **navbar inferior** para navegar entre seções
- Scroll horizontal para acessar todos os cards
- **Header fixo** mostra informações essenciais
- **Botões maiores** para facilitar o toque

### Atalhos de Teclado

Quando no input de comandos:
- `Enter` - Envia comando
- `Escape` - Limpa input

### Dicas de Uso

1. **Mapa Interativo**: Clique em qualquer ponto do mapa para mover seu personagem
2. **Menu de Contexto**: Clique com botão direito em itens para ações rápidas
3. **Refresh Manual**: Use os botões 🔄 para forçar atualização de dados específicos
4. **Tema**: Alterne entre claro/escuro conforme iluminação ambiente
5. **Mobile**: Deslize a navbar inferior para acessar mais opções rapidamente

---

## 🌐 Múltiplas Instâncias

### Como Funciona

O plugin detecta automaticamente todas as instâncias do OpenKore rodando e permite alternar entre elas:
```
┌─────────────────┐
│  Página Central │  ← http://localhost:8888
│    (porta 8888) │     (detecta todas as contas)
└────────┬────────┘
         │
    ┌────┴────┐
    ↓         ↓
┌────────┐ ┌────────┐
│ Conta1 │ │ Conta2 │  ← Portas específicas (8889-8894)
│  8889  │ │  8890  │     (acesso direto a cada conta)
└────────┘ └────────┘
```

### Página Central (8888)

A página central oferece:
- **Seletor de Conta**: Dropdown com todas as contas detectadas
- **Detecção Automática**: Atualiza a lista a cada 5 segundos
- **Troca Instantânea**: Mude de conta sem recarregar a página
- **Status Online**: Mostra quais contas estão ativas

### Acesso Direto

Você também pode acessar cada conta diretamente pela sua porta:
```
http://localhost:8889  (Primeira conta)
http://localhost:8890  (Segunda conta)
etc...
```

### Sistema de Proxy

Quando na página central, o plugin usa um sistema de proxy interno para comunicar com outras instâncias:
- **GET**: Busca dados de outras contas
- **POST**: Envia comandos para outras contas
- **Transparente**: Você não precisa se preocupar com isso!

---

## 📡 API Documentation

O plugin expõe uma API RESTful completa para integração.

### Endpoints GET

#### Dados Gerais

| Endpoint | Descrição | Resposta |
|----------|-----------|----------|
| `/api/all` | Todos os dados (otimizado) | `{ character, map, inventory, cart, skills, timestamp }` |
| `/api/character` | Informações do personagem | `{ name, level, job, hp, sp, exp, stats, ... }` |
| `/api/map` | Dados do mapa atual | `{ name, width, height, char_x, char_y, players, monsters, npcs, portals }` |
| `/api/inventory` | Inventário pessoal | `{ items: [...], count, total_value }` |
| `/api/cart` | Carrinho (se disponível) | `{ has_cart, items: [...], weight, ... }` |
| `/api/skills` | Lista de skills | `{ skills: [...], count, total_sp_cost }` |
| `/api/chat` | Histórico de chat | `{ messages: [...] }` |

#### Estatísticas

| Endpoint | Descrição | Resposta |
|----------|-----------|----------|
| `/api/stats` | Estatísticas da sessão | `{ uptime, exp_gained, kills, deaths, ... }` |
| `/api/monsters` | Monstros próximos | `{ monsters: [...] }` |
| `/api/target` | Alvo atual | `{ name, level, hp, distance, exists }` |
| `/api/monster-kills` | Histórico de kills | `{ monsters_your_kills, monsters_party_kills, totals }` |
| `/api/item-drops` | Histórico de drops | `{ items_your_drops, items_party_drops, totals }` |
| `/api/experience` | Estatísticas de EXP | `{ perHourBaseExp, perHourJobExp, bottingTime, ... }` |

#### Grupo

| Endpoint | Descrição | Resposta |
|----------|-----------|----------|
| `/api/guild` | Informações da guilda | `{ guild_info: { name, level, members_list, ... } }` |
| `/api/party` | Informações da party | `{ party_info: { name, members, members_list, ... } }` |

#### Instâncias

| Endpoint | Descrição | Resposta |
|----------|-----------|----------|
| `/api/instances` | Lista todas as instâncias | `{ instances: [{ port, char_name, map_name, ... }] }` |
| `/api/current-instance` | Instância atual | `{ port, char_name, kore_id, account_id, ... }` |

#### Configuração

| Endpoint | Descrição | Resposta |
|----------|-----------|----------|
| `/api/config` | Configurações básicas | `{ username, server, char }` |

### Endpoints POST

#### Comandos

| Endpoint | Body | Descrição |
|----------|------|-----------|
| `/api/command` | `{ command: "pause" }` | Executa comando do OpenKore |
| `/api/chat/send` | `{ message: "Olá!" }` | Envia mensagem no chat público |

#### Skills e Stats

| Endpoint | Body | Descrição |
|----------|------|-----------|
| `/api/skill/upgrade` | `{ skill: "AL_HEAL" }` | Upa uma skill |
| `/api/stat/upgrade` | `{ stat: "str" }` | Upa um atributo |

#### Itens

| Endpoint | Body | Descrição |
|----------|------|-----------|
| `/api/item/use` | `{ index: 0 }` | Usa um item |
| `/api/item/equip` | `{ index: 0 }` | Equipa um item |
| `/api/item/unequip` | `{ index: 0 }` | Desequipa um item |
| `/api/item/drop` | `{ index: 0, amount: 1 }` | Dropa item(s) |

#### Controle

| Endpoint | Body | Descrição |
|----------|------|-----------|
| `/api/move` | `{ x: 100, y: 150 }` | Move para coordenadas |
| `/api/ai` | `{ mode: "auto" }` | Altera modo da AI |

#### Configuração

| Endpoint | Body | Descrição |
|----------|------|-----------|
| `/api/config/save` | `{ config: {...} }` | Salva configurações |

### Proxy (Múltiplas Instâncias)

Para acessar outra instância quando na página central:
```
GET  /api/proxy/8890/api/character
POST /api/proxy/8890/api/command
```

### Exemplos de Uso

#### JavaScript (Fetch API)
```javascript
// GET - Buscar personagem
fetch('/api/character')
  .then(res => res.json())
  .then(data => console.log(data));

// POST - Enviar comando
fetch('/api/command', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ command: 'pause' })
})
  .then(res => res.json())
  .then(data => console.log(data));
```

#### Python
```python
import requests

# GET
response = requests.get('http://localhost:8889/api/character')
data = response.json()
print(data)

# POST
response = requests.post('http://localhost:8889/api/command',
                        json={'command': 'pause'})
result = response.json()
print(result)
```

#### cURL
```bash
# GET
curl http://localhost:8889/api/character

# POST
curl -X POST http://localhost:8889/api/command \
  -H "Content-Type: application/json" \
  -d '{"command":"pause"}'
```

---

## 🏗️ Arquitetura

### Visão Geral
```
┌─────────────────────────────────────────────────────────────┐
│                     OpenKore Process                         │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │              webDashboard Plugin                       │ │
│  │                                                        │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  │ │
│  │  │ HTTP Server  │  │  API Layer   │  │   Hooks    │  │ │
│  │  │ (port 8889+) │←→│   (REST)     │←→│  (Events)  │  │ │
│  │  └──────────────┘  └──────────────┘  └────────────┘  │ │
│  │         ↑                  ↑                 ↑         │ │
│  └─────────┼──────────────────┼─────────────────┼─────────┘ │
│            │                  │                 │           │
│            ↓                  ↓                 ↓           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │         OpenKore Core (Globals, Commands, AI)       │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                          ↕
                   ┌─────────────┐
                   │   Browser   │
                   │  (Client)   │
                   └─────────────┘
```

### Componentes Principais

#### 1. HTTP Server
- **IO::Socket::INET**: Servidor HTTP não-bloqueante
- **Porta Dinâmica**: Detecta automaticamente porta disponível
- **Keep-Alive**: Mantém conexões para melhor performance

#### 2. API Layer
- **RESTful**: Endpoints GET e POST padronizados
- **JSON**: Serialização/deserialização automática
- **Cache**: Sistema de cache para reduzir processamento
- **Proxy**: Comunicação entre instâncias

#### 3. Hooks System
- **Event-Driven**: Responde a eventos do OpenKore
- **Non-Blocking**: Não interfere no loop principal
- **Selective**: Apenas hooks necessários registrados

#### 4. Data Processing
- **Encoding**: Normalização UTF-8/ISO-8859-1 (ABNT-2)
- **Aggregation**: Combina múltiplas fontes de dados
- **Filtering**: Remove duplicatas e dados inválidos

### Fluxo de Dados

#### Loop Principal
```
OpenKore MainLoop (1000ms)
    ↓
webDashboard::onLoop
    ↓
Checks for Client Requests
    ↓
Process Request → Get Data from Globals → Format JSON → Send Response
```

#### Event Handling
```
OpenKore Event (e.g., item_gathered)
    ↓
Plugin Hook (e.g., on_item_gathered)
    ↓
Update Internal State (e.g., @items_dropped_your)
    ↓
Available on next API call
```

### Performance

- **Update Interval**: 1s (ajustável)
- **Cache Duration**: 0.5s para dados estáticos
- **Max Chat History**: 500 mensagens
- **Max Inventory Items**: Unlimited (DOM virtual scrolling no cliente)

---

## 🔧 Troubleshooting

### Problemas Comuns

#### Plugin não carrega

**Problema**: Plugin não aparece no console
```
Solução:
1. Verifique se está na pasta plugins/
2. Verifique permissões do arquivo
3. Reinicie completamente o OpenKore
4. Verifique erros no console
```

#### Servidor não inicia

**Problema**: `[webDashboard] ERRO: Não foi possível iniciar servidor`
```
Solução:
1. Porta pode estar em uso - feche outras instâncias
2. Firewall pode estar bloqueando - adicione exceção
3. Tente especificar outra porta base no código
```

#### Dashboard não atualiza

**Problema**: Dados ficam parados
```
Solução:
1. Verifique se o OpenKore está conectado
2. Recarregue a página (F5)
3. Limpe o cache do navegador
4. Verifique console do navegador (F12)
```

#### Encoding errado (ç, á, ã, etc)

**Problema**: Caracteres especiais aparecem errados
```
Solução:
1. O plugin já normaliza automaticamente
2. Se ainda houver problemas, verifique config do OpenKore
3. Tente recarregar com Ctrl+F5
```

#### Múltiplas instâncias não detectadas

**Problema**: Seletor mostra apenas uma conta
```
Solução:
1. Aguarde 5 segundos (detecção automática)
2. Verifique se todas as instâncias estão rodando
3. Verifique se as portas estão corretas
4. Use F12 → Network para verificar chamadas API
```

#### Mapa não carrega

**Problema**: Mapa fica preto ou não carrega imagem
```
Solução:
1. Verifique conexão com internet (Divine Pride)
2. Mapa pode não existir no Divine Pride
3. Aguarde carregamento (pode demorar)
4. Fallback: Grid simples será exibido
```

### Logs e Debug

#### Ativar debug do plugin
```perl
# No arquivo webDashboard.pl, encontre:
use Log qw(message warning error debug);

# E use:
debug "Mensagem de debug\n", "webDashboard";
```

#### Console do Navegador
```javascript
// Abra F12 → Console
// Verifique erros JavaScript
// Verifique chamadas de rede (Network tab)
```

#### Verificar portas em uso
```bash
# Windows
netstat -ano | findstr :8888

# Linux/Mac
lsof -i :8888
```

---

## 🗺️ Roadmap

### Versão 2.1 (Próxima)

- [ ] Sistema de notificações push
- [ ] Gráficos de EXP/hora (Chart.js)
- [ ] Histórico de sessões (armazenamento local)
- [ ] Export de dados (CSV, JSON)
- [ ] Temas customizáveis

### Versão 2.2

- [ ] WebSocket para updates em tempo real
- [ ] Sistema de alertas configuráveis
- [ ] Logs avançados com filtros
- [ ] Suporte a plugins externos

### Versão 3.0

- [ ] Dashboard multiplayer (visualizar party)
- [ ] Integração com Discord
- [ ] Mobile app nativo
- [ ] Cloud sync (opcional)

### Ideias Futuras

- 🤔 Sistema de macros visuais
- 🤔 Editor de config integrado
- 🤔 Marketplace de temas
- 🤔 Inteligência artificial para análise

> **Sugestões?** Abra uma issue ou pull request!

---

## 🤝 Contribuindo

Contribuições são bem-vindas! Veja como você pode ajudar:

### Como Contribuir

1. **Fork** o repositório
2. Crie uma **branch** para sua feature (`git checkout -b feature/MinhaFeature`)
3. **Commit** suas mudanças (`git commit -m 'Adiciona MinhaFeature'`)
4. **Push** para a branch (`git push origin feature/MinhaFeature`)
5. Abra um **Pull Request**

### Diretrizes

- ✅ Mantenha o código limpo e comentado
- ✅ Teste em múltiplas resoluções (desktop e mobile)
- ✅ Siga o estilo de código existente
- ✅ Documente novas features no README
- ✅ Adicione comentários em PT-BR

### Reportar Bugs

Abra uma **Issue** com:
- Descrição do problema
- Passos para reproduzir
- Comportamento esperado vs atual
- Screenshots (se aplicável)
- Versão do OpenKore e navegador

### Sugerir Features

Abra uma **Issue** com label `enhancement`:
- Descrição detalhada da feature
- Casos de uso
- Mockups/wireframes (opcional)
- Impacto estimado

---

## 👨‍💻 Créditos

### Desenvolvimento

- **Criador Original**: [Celtos](https://openkore.com.br) - Versão inicial e conceito base
- **Modificado e Expandido por**: **JC** - [Ue?ComoAssim!?](https://discord.gg/uecomoassim)

### Versão 2.0 PRO - Melhorias

- ✨ Interface completamente redesenhada
- ✨ Sistema de múltiplas instâncias
- ✨ Suporte mobile responsivo
- ✨ Tema claro/escuro
- ✨ Histórico de kills e drops
- ✨ Informações de guilda e party
- ✨ API RESTful completa
- ✨ Sistema de cache e performance

### Tecnologias

- **Backend**: Perl 5, IO::Socket::INET
- **Frontend**: HTML5, CSS3 (Vanilla), JavaScript (ES6+)
- **APIs**: Divine Pride (mapas e ícones de itens)
- **Fonts**: Inter, Fira Code (Google Fonts)

### Comunidade

Agradecimentos especiais a todos os usuários do OpenKore.com.br e membros do Discord Ue?ComoAssim!? por feedback e sugestões.

---

## 📄 Licença

Este projeto é **Open Source** e está disponível sob a licença MIT.
```
MIT License

Copyright (c) 2024 Celtos & JC (Ue?ComoAssim!?)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 📞 Suporte

### Canais Oficiais

- 🌐 **Website**: [OpenKore.com.br](https://openkore.com.br)
- 💬 **Discord**: [Ue?ComoAssim!?](https://discord.gg/uecomoassim)
- 📧 **Email**: contato@openkore.com.br
- 🐛 **Issues**: [GitHub Issues](https://github.com/seu-repo/webDashboard/issues)

### FAQ

**P: É seguro usar este plugin?**  
R: Sim! O plugin roda localmente (localhost) e não envia dados para fora do seu computador.

**P: Funciona em qualquer servidor de Ragnarok?**  
R: Sim! O plugin é independente do servidor, funciona com qualquer servidor suportado pelo OpenKore.

**P: Preciso de conhecimento técnico?**  
R: Não! Basta copiar o arquivo e acessar pelo navegador.

**P: Posso usar em múltiplas contas?**  
R: Sim! O plugin detecta e gerencia automaticamente múltiplas instâncias.

**P: Funciona no mobile?**  
R: Sim! Interface 100% responsiva e otimizada para smartphones.

---

<div align="center">

**Desenvolvido com ❤️ pela comunidade OpenKore**

[⬆ Voltar ao topo](#-webdashboard-v20-pro)

</div>