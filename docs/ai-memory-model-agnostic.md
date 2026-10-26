# Memória e conversas independentes do modelo

## Objetivo

Manter transcrições e contexto durável fora do provider/modelo selecionado. A conversa pode continuar depois de reiniciar o app ou trocar entre OpenAI e LM Studio. Os registros são arquivos JSON comuns; as preferências e decisões duráveis ficam em Markdown editável.

## App macOS

- Transcrições são gravadas em `~/Library/Application Support/PocketWiki/AI Memory/session-<uuid>.json`.
- Ao iniciar, o app restaura a sessão mais recente. **Limpar** e **Reset** começam outra sessão; os arquivos anteriores continuam disponíveis no diretório.
- O histórico recente (até 12 mensagens e 8.000 caracteres) acompanha cada nova pergunta, preservando os papéis `user` e `assistant` quando o modelo muda.
- `MEMORY.md`, no mesmo diretório, começa vazio e pode ser editado pelo usuário. Até 4.000 caracteres dela acompanham cada pergunta. Ela não é reescrita por um modelo.
- Cada resposta registra `provider_id` e `model_id` como metadados opcionais. O conteúdo não depende desses campos. Mensagens de sistema e raciocínio interno do modelo não são persistidos.
- O registro local fica no Mac. O conteúdo enviado ao provider segue a configuração de provider escolhida no app.

## Conexão opcional com o servidor ai-memory

O PocketWiki usa o [MCP HTTP oficial do ai-memory](https://github.com/akitaonrails/ai-memory/blob/main/docs/programmatic-memory.md). Configure no `.env` do app:

```sh
AI_MEMORY_SERVER_URL="http://127.0.0.1:49374"
AI_MEMORY_WORKSPACE="default"
AI_MEMORY_PROJECT="pocketwiki"
AI_MEMORY_AUTH_TOKEN="<chave-do-servidor>"
AI_MEMORY_WEB_TOKEN="<token-aleatorio-de-pelo-menos-16-caracteres>"
```

O servidor precisa estar rodando separadamente com o endpoint `/mcp`. Em instalações sem autenticação no loopback, o token pode ficar vazio. O PocketWiki só habilita essa conexão quando URL, workspace e projeto estão preenchidos. O nome do projeto é o escopo do ai-memory, não o ID de projeto do MiddlewareAuth.

Para testar localmente com a versão `3.2.2` usada na validação desta integração:

```sh
docker run -d --name ai-memory -p 127.0.0.1:49374:49374 \
  -v ai-memory-data:/data akitaonrails/ai-memory:3.2.2
curl -fsS http://127.0.0.1:49374/healthz
```

Nesse teste local, use `AI_MEMORY_SERVER_URL="http://127.0.0.1:49374"` e deixe `AI_MEMORY_AUTH_TOKEN` vazio. Para acesso por rede, configure autenticação e permissões conforme o [guia de instalação do ai-memory](https://github.com/akitaonrails/ai-memory/blob/main/docs/install.md). O volume `/data` mantém as páginas e observações depois de reiniciar o contêiner.

`AI_MEMORY_WEB_TOKEN` protege o proxy do cockpit, independentemente da chave do servidor ai-memory. Gere um valor longo (por exemplo, `openssl rand -hex 24`) e informe o mesmo token em **Configurações da IA → Token web do ai-memory** no navegador. O cockpit o mantém apenas na sessão da aba. Sem esse token configurado no servidor, as rotas web de memória ficam desabilitadas; o app macOS pode continuar usando o MCP diretamente. Quem tiver acesso ao cockpit e a esse token pode consultar a memória do workspace/projeto configurado, então publique o cockpit por HTTPS com controle de acesso se ele sair da sua máquina ou tailnet.

O servidor funciona sem provider LLM: cria resumos heurísticos de sessões e permite busca textual. Se quiser consolidação narrativa, configure um provider no processo do **servidor ai-memory**, separadamente do provider que responde no PocketWiki. Por exemplo, para um endpoint OpenAI compatível, são necessários `AI_MEMORY_LLM_PROVIDER=openai-compat`, `AI_MEMORY_LLM_BASE_URL` e `AI_MEMORY_LLM_MODEL`; não há modelo padrão seguro para esse provider. Essa configuração não altera o formato dos registros do PocketWiki nem prende a conversa a um modelo.

Para carregar um `.env` fora do checkout ao iniciar `server.mjs`, defina `POCKETWIKI_ENV_PATH=/caminho/para/.env` no ambiente do processo.

No cockpit web servido por `server.mjs`, a configuração com o token web habilita `POST /api/ai-memory/recall` e `POST /api/ai-memory/capture`. O servidor guarda a chave upstream e encaminha as chamadas ao `/mcp` e `/hook/batch`; `/api/config` expõe apenas `aiMemoryConfigured`. O browser persiste a sessão ativa em `localStorage` e arquiva a anterior ao clicar em **Nova**. Em **Sessões**, dá para retomar uma conversa arquivada, importar um `session-<uuid>.json` do app macOS ou um pacote exportado pelo cockpit, e exportar todas as sessões em JSON. A importação ignora IDs já presentes para não sobrescrever conversas. O próximo prompt inclui até 12 mensagens anteriores mesmo após recarregar a página, importar uma sessão ou trocar de provider/modelo. Os eventos pendentes ficam em `localStorage` até o servidor confirmar os `ingest_key` enviados; a aba precisa manter o token web em `sessionStorage` para reenviá-los após recarregar.

Os registros do browser e do app macOS usam campos compatíveis (`schema_version`, `id`, `created_at`, `updated_at`, `messages`, `provider_id`, `model_id`), mas ainda são armazenados em lugares distintos. A recuperação via ai-memory usa o mesmo workspace/projeto quando ambos apontam para o mesmo servidor.

Antes de cada pergunta, o app chama `memory_query` e lê até três páginas relevantes por `memory_read_page`. O conteúdo recuperado entra no contexto com o caminho de origem. Para capturar a conversa, envia eventos `session-start`, `user-prompt-submit`, `assistant-response` e `stop` a `/hook/batch`; **Limpar**, **Reset** e **Nova** enviam `session-end`. A resposta entra como evento de extensão `pocketwiki`, já que o protocolo `stop` de `agent=other` não armazena texto do assistente. O servidor consolida as observações em páginas segundo sua própria política.

No teste com o servidor oficial `3.2.2` sem LLM, os cinco eventos foram aceitos e o prompt apareceu numa página `sessions/<id>.md`, recuperável por `memory_query`. O texto da resposta **não** apareceu nessa página heurística, apesar de o evento `assistant-response` constar entre as observações. Por isso, os JSON locais são a fonte completa da conversa; a página gerada pelo servidor serve como memória pesquisável, não como backup integral da transcrição. Promover uma conclusão revisada a uma página durável por `memory_write_page` ainda depende de uma ação explícita.

Cada evento recebe um `ingest_key` estável e fica em `ai-memory-outbox.json` até o lote confirmar seu índice. O app tenta reenviar pendências no próximo envio ou ao abrir o chat. Os JSON locais continuam completos mesmo se o servidor estiver fora do ar. Erros de leitura não impedem a resposta, e falhas de entrega ficam visíveis no chat.

Essa integração usa o cliente MCP para recuperação e o endpoint de hooks para captura. Todas as chamadas levam `workspace` e `project`; o MCP segue JSON-RPC 2.0 e checa `error` e `result.isError`. O conteúdo da memória é histórico não confiável; a resposta precisa ser confirmada nas fontes da wiki quando isso importar. `memory_write_page` fica reservado para uma ação futura de promoção explícita de conhecimento revisado.

Exemplo do envelope da sessão (datas ISO 8601):

```json
{
  "schema_version": 1,
  "id": "0ce8f327-c7d3-4d5a-a633-8e46d6b922cf",
  "created_at": "2026-10-26T13:00:00Z",
  "updated_at": "2026-10-26T13:01:00Z",
  "messages": [
    {
      "role": "user",
      "content": "Como o PocketWiki carrega a base compartilhada?",
      "created_at": "2026-10-26T13:00:00Z",
      "provider_id": null,
      "model_id": null
    },
    {
      "role": "assistant",
      "content": "Pelo POCKETWIKI_REFERENCE_PATH configurado no servidor.",
      "created_at": "2026-10-26T13:00:06Z",
      "provider_id": "openai",
      "model_id": "gpt-5.5"
    }
  ]
}
```

## Próximos passos

1. Busca no navegador de sessões e exportação/importação adicional em Markdown.
2. Ação explícita para promover um trecho confirmado à memória durável, sempre com revisão do usuário.
3. Opcionalmente apontar o arquivo de memória para uma pasta do wiki sincronizada entre dispositivos, mantendo o padrão local como default.
4. Mostrar o estado da fila de eventos e permitir reenviar sem esperar o próximo prompt ou a reabertura do chat.

Validação rápida do servidor e do cockpit: `npm run test:ai-memory`.

## Referência

O desenho usa como referência o [ai-memory](https://github.com/akitaonrails/ai-memory), projeto público sob [licença MIT](https://github.com/akitaonrails/ai-memory/blob/main/LICENSE): arquivos Markdown como fonte legível, captura separada do provider e recuperação por um contexto portátil. Este branch não incorpora nem copia código do ai-memory; usa sua interface MCP documentada e adapta a sessão local ao fluxo PocketKernel do PocketWiki. O MVP não instala hooks para CLIs externos nem embute o servidor Rust no app.
