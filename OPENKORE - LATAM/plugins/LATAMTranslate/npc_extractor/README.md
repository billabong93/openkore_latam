### README.md

## Extrator de Dados CSV

Script para processar múltiplos arquivos CSV e extrair dados de uma coluna específica, gerando um arquivo JSON como saída.

### Dependências

Este script utiliza a biblioteca `pandas`. Para instalar, execute:

```bash
pip install pandas
```

### Uso

Execute o script via terminal. Ele exige três argumentos:

1.  `caminho_pasta`: A pasta onde os arquivos `.csv` estão localizados.
2.  `arquivo_saida`: O nome do arquivo `.json` que será criado.
3.  `--language`: A coluna de dados para extrair.

#### Sintaxe

```bash
python seu_script.py <caminho_pasta> <arquivo_saida> --language <idioma>
```

#### Opções de Idioma

-   `coreano`
-   `ingles`
-   `portugues`
-   `espanhol`

### Exemplo

Para processar os CSVs da pasta `C:/data/csv_files` (ou caminho local `.\`), extrair a coluna de dados em português e salvar o resultado como `strings.json`, o comando é:

```bash
python seu_script.py "C:/data/csv_files" "strings.json" --idioma portugues
```

### Detalhes de Processamento

-   **Entrada**: Lê todos os arquivos `.csv` na pasta especificada.
-   **Estrutura do CSV**: Espera que cada linha tenha o formato `chave,dado_b64_coreano,dado_b64_ingles,dado_b64_pt,dado_b64_es`.
-   **Decodificação**: Os dados da coluna de idioma selecionada são decodificados de Base64 para string UTF-8.
-   **Ordenação**: As chaves no JSON de saída são ordenadas primeiro por tamanho (crescente) e depois alfabeticamente.
-   **Encoding de Saída**:
    -   Para `--language ingles`, `portugues` ou `espanhol`, caracteres não-ASCII são convertidos para suas sequências de escape (`\uXXXX`).
    -   Para `--language coreano`, os caracteres são mantidos em seu formato original (UTF-8).
-   **Saída**: Um único arquivo `.json` contendo um objeto com todos os pares `chave: valor` extraídos e processados (strings.json na pasta pai à essa). O script informa o tempo total de execução.
