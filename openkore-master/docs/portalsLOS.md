# Gerando `portalsLOS.txt` para tabelas ROla

Este pacote de tabelas (`tables/ROla`) inclui `portals.txt` com destinos para Morocc (por exemplo, `moc_fild07 -> morocc`), mas não traz um `portalsLOS.txt` pronto. A busca de rotas usa apenas as ligações com linha‑de‑visão gravadas em `portalsLOS.txt`; quando o arquivo está ausente, portais como os de Morocc não entram no grafo de caminhos e surgem mensagens como "Cannot calculate a route".

## Passo a passo para gerar o arquivo

1. **Use as tabelas corretas.** Inicie o OpenKore apontando para ROla, por exemplo:
   ```bash
   perl openkore.pl --tables=ROla
   ```
2. **Recompile os portais pelo console, usando a mesma pasta de tabelas que você carregou.** No prompt do OpenKore, digite:
   ```
   portals recompile
   ```
   O comando percorre cada mapa, calcula o custo de linha‑de‑visão entre pontos de entrada/saída e grava o resultado em `tables/ROla/portalsLOS.txt`.
   > ⚠️ Se você recompilar sem passar `--tables=ROla`, o arquivo será gravado em `tables/portalsLOS.txt` (pasta padrão) e o OpenKore continuará carregando um `portalsLOS.txt` vazio em `tables/ROla` — aí as rotas para Morocc seguem falhando mesmo após a recompilação.
3. **Verifique avisos sobre mapas ausentes.** Se faltarem arquivos de mapa (`*.fld2`) para alguma área usada pelos portais, o comando avisa quais mapas não puderam ser processados; nesses casos, copie os mapas faltantes para `fields/` e repita o `portals recompile` para evitar lacunas.

Após esses passos, o novo `portalsLOS.txt` ficará disponível e o cálculo de rota poderá usar as conexões até Morocc normalmente.
