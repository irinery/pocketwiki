# Correcoes Pendentes

## UI / identidade

- [x] Trocar o simbolo `§` da sidebar por um favicon/asset configuravel.
  - Aceite: a UI deve renderizar um favicon/imagem local quando existir, mantendo fallback visual simples caso o arquivo ainda nao tenha sido adicionado.

- [x] Reordenar as abas do topo e renomear `Cockpit` para `Dashboard`.
  - Sequencia desejada: `Dashboard`, `IA`, `Leitor`, `Mapa`, `Saude`, `Tempo`.
  - Aceite: labels, estado ativo, command palette e qualquer referencia interna devem usar `Dashboard`.

## Carregamento da wiki

- [x] Persistir a pasta da wiki apos o primeiro carregamento.
  - Aceite: quando o usuario abrir a wiki pela primeira vez, o app deve tentar reutilizar esse local nos proximos acessos, sem exigir nova selecao manual.
  - Nota: no browser puro isso depende de File System Access API/permission handle; quando servido pelo `server.mjs`, o `.env` continua sendo a fonte fixa.

## IA local

- [x] Trocar o campo manual de modelo por um dropdown alimentado pelo LM Studio.
  - Aceite: o app deve consultar `/api/ai/models`, listar modelos disponiveis e permitir escolher um deles sem digitar manualmente.
  - Aceite extra: se houver `LM_STUDIO_MODEL`, selecionar esse modelo por padrao quando existir na lista.

- [x] Ajustar o comportamento do input da IA.
  - Regra: `Enter` deve quebrar linha.
  - Regra: `Shift+Enter` deve enviar.
  - Aceite: o placeholder ou hint visivel deve informar esse atalho ao usuario.

## Revisao da wiki

- [x] Melhorar a aba `Saude` e adicionar uma area `Revisao`.
  - Aceite: alem da pontuacao, a tela deve mostrar melhorias acionaveis por prioridade.
  - Aceite: deve existir um prompt dedicado para LLM revisar a wiki e gerar pontos de melhoria.
  - Sugestao de arquivo: `prompts/wiki-review.md`.
  - Nota: essa revisao pode usar uma LLM diferente da IA local configurada no painel.
