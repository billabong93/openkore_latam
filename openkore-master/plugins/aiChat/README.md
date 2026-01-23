# Plugin AI Chat para OpenKore

Este plugin integra o OpenKore com modelos de Linguagem de IA, permitindo que seu bot converse naturalmente com outros jogadores, mantendo o contexto e utilizando informações do seu personagem (nome, classe, níveis, mapa).

## 1. Pré-requisitos e Instalação

Para usar o plugin, você precisará:

*   **OpenKore**: Versão atual.
*   **Node.js**: V16.x+ ([nodejs.org](https://nodejs.org/)).
*   **Módulos Perl (CPAN)**: Instale no terminal do OpenKore ou via `cpan`:
    ```bash
    cpan install LWP::UserAgent HTTP::Request JSON::Tiny
    ```
*   **Pacotes Node.js**: Na pasta `plugins/aiChat`, execute:
    ```bash
    npm install express node-fetch
    ```

1.  Copie a pasta `aiChat` para `openkore/plugins/`.
2.  Instale todos os pré-requisitos acima.

## 2. Configuração

### A. No plugin (`plugins/aiChat/config/config.txt` ou comandos `aichat set`)

Configure as opções no `plugins/aiChat/config/config.txt` ou via console do OpenKore (`aichat set <chave> <valor>`). Os comandos `aichat set` atualizam o arquivo automaticamente.

*   `aiChat_provider`: `openai` ou `deepseek` (padrão: `deepseek`)
*   `aiChat_model`: `gpt-3.5-turbo` ou `deepseek-chat` (ajustado ao `provider`)
*   `aiChat_prompt`: O prompt que define o comportamento da IA.
*   `aiChat_max_tokens`: Máx. tokens na resposta (padrão: `150`)
*   `aiChat_temperature`: Criatividade da IA (0.0-1.0, padrão: `0.6`)
*   `aiChat_typing_speed`: Velocidade de digitação em caracteres/segundo (padrão: `20`)
*   `aiChat_mob_database`: Habilita respostas usando o banco de dados de monstros/drops (`1` para habilitar, `0` para sempre recusar).
*   `aiChat_dropdb_refusal_chance`: Chance de recusar perguntas do banco de drops (0.0-1.0, padrão: `0.5`).
*   `aiChat_dropdb_question_limit`: Limite de perguntas sobre dropdb antes de recusar (padrão: `0` usa aleatório, ex: `2..4`).
*   `aiChat_min_packet_interval`: Intervalo mínimo entre pacotes enviados (em segundos, padrão: `0.6`).
*   `aiChat_conversation_limit`: Número de mensagens do jogador antes do bot encerrar o papo (padrão: `10`, `0` desativa, ex: `8..12`).
*   `aiChat_spam_question_limit`: Número de perguntas seguidas antes de recusar por spam (padrão: `3`, `0` desativa, ex: `3..5`).

### Banco de monstros/drops (`plugins/aiChat/config/mondb.txt`)

Você pode separar o banco em duas partes: uma com respostas garantidas e outra sujeita à chance de recusa. Use os marcadores abaixo em linhas próprias:

*   `[always]`: Tudo abaixo desta linha responde sempre (sem chance de recusa).
*   `[chance]`: Tudo abaixo desta linha segue a chance de recusa (`aiChat_dropdb_refusal_chance`).

Se não houver marcador, o comportamento padrão é `chance`.

Exemplo:

```
[always]
Poring: (Arredores de Prontera, prt_fild08) Jellopy, Carta Poring

[chance]
Orc Zumbi: (Caverna de Geffen, gef_dun01) Pele de Orc, Carta Orc Zumbi
```

### B. No Proxy Node.js (`api_proxy.js`)

O proxy usa a chave definida em `aiChat_api_key` no `config/config.txt`. Como alternativa, você pode definir a variável de ambiente `AICHAT_API_KEY` ou inserir a chave diretamente no `api_proxy.js`.

## 3. Uso

1.  **Inicie o bot e o proxy juntos**: Execute o script `start_openkore_e_proxy.bat` localizado na pasta `plugins/aiChat/`. Este script iniciará automaticamente o OpenKore e o servidor proxy Node.js em segundo plano.
2.  **Carregue o Plugin**: No console do OpenKore, digite `plugins load aiChat`.
3.  O bot agora responderá a mensagens privadas com a IA configurada.

### Comandos do Console (`aichat`)

*   `aichat help`: Mostra comandos.
*   `aichat status`: Status e infos do personagem.
*   `aichat config`: Configurações atuais.
*   `aichat set <chave> <valor>`: Define um valor.
*   `aichat provider <openai|deepseek>`: Altera o provedor.

## 4. Solução de Problemas

*   **`Error: listen EADDRINUSE: address already in use :::3000`**: Porta 3000 já em uso. Feche processos anteriores do proxy ou use `netstat -ano | findstr :3000` (Windows) / `lsof -i :3000` (Linux/macOS) para encontrar e encerrar o PID.
*   **Erros de `Can't locate module...`**: Módulos Perl ou Node.js não instalados. Verifique "Pré-requisitos".
*   **IA não responde / respostas ruins**: Verifique se o proxy está rodando, a chave de API em `api_proxy.js`, e ajuste o `prompt`, `max_tokens` e `temperature`.
*   **Informações do personagem incorretas**: Verifique os logs de depuração do OpenKore por `[aiChat] Dados do personagem atualizados:`.
