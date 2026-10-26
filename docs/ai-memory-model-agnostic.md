# Memória e conversas independentes do modelo

## Objetivo

Manter transcrições e contexto durável fora do provider/modelo selecionado. A conversa pode continuar depois de reiniciar o app ou trocar entre OpenAI e LM Studio. Os registros são arquivos JSON comuns; as preferências e decisões duráveis ficam em Markdown editável.

## Primeiro corte no PocketWiki

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
```

O servidor precisa estar rodando separadamente com o endpoint `/mcp`. Em instalações sem autenticação no loopback, o token pode ficar vazio. O PocketWiki só habilita essa conexão quando URL, workspace e projeto estão preenchidos. O nome do projeto é o escopo do ai-memory, não o ID de projeto do MiddlewareAuth.

Antes de cada pergunta, o app chama `memory_query` e lê até três páginas relevantes por `memory_read_page`. O conteúdo recuperado entra no contexto com o caminho de origem. Para capturar a conversa, envia eventos `session-start`, `user-prompt-submit`, `assistant-response` e `stop` a `/hook/batch`; **Limpar** e **Reset** enviam `session-end`. A resposta entra como evento de extensão `pocketwiki`, já que o protocolo `stop` de `agent=other` não armazena texto do assistente. O servidor consolida as observações em páginas segundo sua própria política.

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

1. Navegador de sessões com busca, restauração e exportação/importação de JSON/Markdown.
2. Ação explícita para promover um trecho confirmado à memória durável, sempre com revisão do usuário.
3. Opcionalmente apontar o arquivo de memória para uma pasta do wiki sincronizada entre dispositivos, mantendo o padrão local como default.
4. Mostrar o estado da fila de eventos e permitir reenviar sem esperar o próximo prompt ou a reabertura do chat.

## Referência

O desenho usa como referência o [ai-memory](https://github.com/akitaonrails/ai-memory), projeto público sob [licença MIT](https://github.com/akitaonrails/ai-memory/blob/main/LICENSE): arquivos Markdown como fonte legível, captura separada do provider e recuperação por um contexto portátil. Este branch não incorpora nem copia código do ai-memory; usa sua interface MCP documentada e adapta a sessão local ao fluxo PocketKernel do PocketWiki. O MVP não instala hooks para CLIs externos nem embute o servidor Rust no app.
