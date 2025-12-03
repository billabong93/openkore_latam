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