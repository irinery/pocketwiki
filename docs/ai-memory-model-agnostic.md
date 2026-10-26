# Memoria portavel do PocketWiki

A conversa do PocketWiki fica em JSON legivel, com texto de usuario e assistente, timestamps e metadados opcionais de provider/modelo. O historico e a nota `MEMORY.md` entram no contexto da proxima pergunta mesmo quando o provider muda. O modelo usado nao define o formato nem a localizacao da memoria.

O desenho foi estudado a partir do [ai-memory](https://github.com/akitaonrails/ai-memory), publicado sob [licenca MIT](https://github.com/akitaonrails/ai-memory/blob/main/LICENSE): captura por evento, chave de ingestao estavel, busca e nota legivel. Esta implementacao e propria do PocketWiki. Ela nao inicia nem acessa o servidor ou o MCP oficial do ai-memory e nao incorpora seu codigo.

## Armazenamento

Por padrao, no macOS: `~/Library/Application Support/PocketWiki/AI Memory/`. Em Linux: `${XDG_DATA_HOME:-~/.local/share}/pocketwiki/memory/`. `POCKETWIKI_MEMORY_PATH` altera a pasta usada pelo servidor. O app macOS mantem ali `MEMORY.md`, `session-<uuid>.json` e a sessao ativa; o servidor grava eventos recebidos em `captures/session-<uuid>.json`. A busca le os dois formatos e evita mostrar duas copias da mesma sessao. Os arquivos de captura sao gravados atomicamente, com permissao `0600`; a pasta e criada com `0700`.

Cada sessao inclui `schema_version`, `id`, `created_at`, `updated_at`, `messages` e `events`. Mensagens tem `role`, `content`, `created_at`, `provider_id` e `model_id`. O provider/modelo serve para auditoria, nao para recuperar a conversa. Cada evento tem `ingest_key`; reenviar a mesma chave na mesma sessao retorna confirmacao sem duplicar a mensagem.

A busca atual e textual e local: normaliza acentos, pontua termos em mensagens e retorna ate tres trechos, mais o conteudo de `MEMORY.md` (ate 5 mil caracteres no total). Nao exige embeddings, LLM ou rede externa. A busca limita a leitura aos 500 registros mais recentes de ate 16 MiB cada; ela nao faz resumo automatico. A API limita gravacoes de `MEMORY.md` a 16 KiB.

## Configuracao

No `.env` do servidor PocketWiki:

```sh
POCKETWIKI_MEMORY_PATH="/caminho/privado/pocketwiki/memory"
POCKETWIKI_MEMORY_TOKEN="um-token-aleatorio-com-pelo-menos-16-caracteres"
```

O token e necessario porque `server.mjs` pode escutar na LAN. Com menos de 16 caracteres, as rotas de memoria ficam desabilitadas. Gere um valor com `openssl rand -hex 24`. O servidor nao inclui o token em `/api/config`.

No cockpit, informe o mesmo token em **Configuracoes da IA → Token da memoria PocketWiki**. Ele fica em `sessionStorage`; os eventos pendentes ficam no armazenamento local da aba ate a confirmacao. No app macOS, configure no mesmo `.env`:

```sh
POCKETWIKI_MEMORY_SERVER_URL="http://127.0.0.1:8787"
POCKETWIKI_MEMORY_TOKEN="o-mesmo-token"
```

Se o servidor usa outra porta ou host, ajuste a URL. Sem URL explicita, o app tenta `http://127.0.0.1:8787`. O app continua salvando seus JSON locais e lendo `MEMORY.md` quando a API esta indisponivel; a fila de eventos pendentes e reenviada na proxima abertura/envio. O app grava a fila em `pocket-memory-outbox.json`; eventos de uma eventual fila antiga destinada ao servidor oficial nao sao enviados a API nova.

## API interna

Todas as rotas abaixo exigem `Authorization: Bearer <POCKETWIKI_MEMORY_TOKEN>` e respondem com JSON:

- `POST /api/memory/capture` recebe `{ "events": [{ "event": "user-prompt-submit", "session_id": "<uuid>", "ingest_key": "<chave>", "prompt": "..." }] }` e retorna `accepted_keys`. Tambem aceita `session-start`, `assistant-response` (`message`), `stop` e `session-end`.
- `POST /api/memory/recall` recebe `{ "question": "..." }` e retorna `context` e `hits`.
- `GET /api/memory/note` retorna `{ "content": "..." }`; `PUT` recebe `{ "content": "..." }`.

Exemplo rapido com servidor rodando:

```sh
curl -sS -H "Authorization: Bearer $POCKETWIKI_MEMORY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"question":"VLAN IoT"}' http://127.0.0.1:8787/api/memory/recall
```

O `server.mjs` e o servidor HTTP nativo do app macOS implementam as mesmas rotas; o cockpit e o chat macOS usam essa API diretamente. Um MCP interno so passa a ser util se outro agente ou cliente MCP precisar consultar a mesma memoria; ele pode ser uma camada sobre estas rotas sem alterar o armazenamento.

## Validacao

`npm run test:memory` cobre persistencia, reenvio idempotente, lotes paralelos, autenticacao, reinicio do servidor, nota, importacao de sessao do Mac e continuidade do cockpit apos trocar de provider/modelo. `npm test` inclui essa suite. `npm run test:memory:swift` valida captura, idempotencia, nota e busca na implementacao nativa do macOS; `swift build --jobs 4` valida o app inteiro.
