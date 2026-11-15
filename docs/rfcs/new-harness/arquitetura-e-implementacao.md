# New Harness — arquitetura e implementação proposta

Estado: Draft · versão 0.2.0 · 2026-11-01. Este documento explica como implementar as RFCs 0002–0016; nenhum endpoint novo descrito aqui já está implementado.

## Produto e fronteiras

A aba IA passa a ser a superfície de trabalho com agentes e conhecimento do PocketWiki: selecionar ambiente/projeto, conversar, acompanhar execução, revisar alterações e reutilizar conhecimento com proveniência. A wiki continua sendo a fonte documental; memória guarda histórico; execução pertence ao ambiente que possui os arquivos.

O t3code é referência de comportamento, não uma dependência de runtime. O PocketWiki mantém SwiftUI no macOS e o cockpit web atual. Não há proposta de portar Electron/React Native, introduzir um serviço t3code paralelo ou trocar o PocketKernel pelo backend deles.

```text
Cockpit web / SwiftUI
    │ contrato harness.v1; credencial de sessão, nunca token de provider
    ▼
Fachada PocketWiki (Node ou HTTP nativo) ─── Pocket Memory + MCP Evidence
    │ autorização delegada vinculada ao principal/environment
    ▼
PocketKernel: comandos → ledger/outbox → efeitos → adapters
    ├── provider inference → bridge atual → MiddlewareAuth → OpenAI/LM Studio
    ├── agent opcional → CLI no environment → arquivos/Git/PTY do environment
    └── MCP de orquestração e integração GitHub
```

MiddlewareAuth guarda autenticação e perfis; PocketKernel decide e executa o harness; PocketWiki guarda wiki, memória e UI. O bridge existente é compatibilidade de inferência, não um agente que pode editar arquivos. A RFC-0001 e o contrato `10_pocketkernel_addon.md` continuam normativos quanto à propriedade de processos e dados.

## Base encontrada no código

Leitura local feita na revisão `9762bed79b51791e5115366470d8ee472d8e6d8e`, branch original `AI-MEMORY`. O `main` remoto observado possui a mesma árvore de arquivos e um commit de merge adicional (`3c579b5d91ce572a12cfac8dac4c07d7efe63d16`).

| Área atual | Evidência local | Evolução |
| --- | --- | --- |
| Shell adaptável da IA | `Sources/PocketWikiMac/Views/LocalAIWorkspaceShell.swift` | integrar módulos por slots, preservar compacto/regular |
| Chat | `Stores/LocalAIChatSession.swift`, `Services/PocketKernelClient.swift` | substituir espera de resposta final por projeção durável quando negociado |
| Catálogo/configuração | `LocalAIView.swift`, `MiddlewareAuthClient.swift` | bindings por run e capabilities do adapter |
| Sessões portáveis | `Stores/PortableConversationStore.swift` | preservar import/export v1; adicionar mapping para thread/namespace |
| Memória | `src/memory/store.mjs`, `PocketMemoryStore.swift` | namespace, CAS da nota e proveniência sem perder JSON/MEMORY.md |
| MCP Evidence | `src/mcp/pocketwiki-mcp-server.mjs` | preservar leitura; controle de agentes em outro servidor MCP |
| Add-ons | `PocketKernelAddonManager.swift`, builders em `script/` | release composta fixada por ref/hash; não instalar versão móvel |
| Testes existentes | `package.json`, `script/ci.sh`, testes Swift | manter regressão e adicionar E2E de navegador e app real |

`isStreaming` no cliente atual não implica transporte incremental: `query()` usa `URLSession.data(for:)` e parseia a resposta inteira. `cancel()` cancela a Task local e não confirma interrupção no servidor. Esses dois pontos não devem ser mascarados por uma UI nova.

## Contratos transversais 0.2.0

Os [contratos de integração](contratos-integracao-v0.2.md) são parte normativa dos cabeçalhos das RFCs. Definem snapshots persistidos paginados, contexto preparado/retido/resolvido, ações revisáveis e aprovação, bootstrap local, pareamento/renovação/revogação e leitura de histórico. Cada RFC define os tipos e operações próprios; E0 gera schemas dessas definições, sem completar lacunas por adivinhação.

Envelope de comando autenticado: `{protocol_major:int=1,command_id:uuid,environment_id:uuid,expected_revision:int,operation:OperationID,input:OperationInput}`. OperationID é enum das operações declaradas em cada bloco de interface de domínio (exclui view.reduce local); OperationInput é união discriminada por esse ID. Campos desconhecidos são rejeitados. ID e hash não são credenciais. canonicalização para idempotência usa RFC 8785 JCS do envelope, excluindo command_id; mesmo ID/hash retorna receipt existente e payload diferente retorna ERR_CONFLICT.

`CommandReceipt` = `{command_id:uuid,receipt_id:uuid,environment_id:uuid,revision:int,state:enum[accepted,pending,succeeded,failed,uncertain],duplicate:bool,result_ref:uuid?}`. `POST /v1/harness/commands` retorna 202 para intenção nova e 200 para duplicata. `GET /v1/harness/receipts/{command_id}` retorna esse tipo; `GET /v1/harness/results/{result_ref}` retorna a saída tipada da operação. Erros HTTP fechados desta fronteira: 400 ERR_INVALID, 403 ERR_FORBIDDEN, 404 ERR_NOT_FOUND, 409 ERR_CONFLICT/ERR_PENDING, 413 ERR_PAYLOAD_LIMIT, 426 ERR_INCOMPATIBLE, 429 ERR_RATE_LIMIT, 503 ERR_UNAVAILABLE, 504 ERR_TIMEOUT. Erros de domínio da RFC vêm no resultado failed. Nunca confundir receipt com projeção restaurável da tela.

`GET /v1/harness/capabilities` retorna `{protocol_major:1,protocol_minor:0,schema_sha256:sha256,environment_id:uuid,operations:OperationID[]}` (máximo 100; somente operações entregues/habilitadas). Snapshot e eventos seguem R1; operações somente de leitura usam `POST /v1/harness/query/{operation}` autenticado/no-store com entrada específica da RFC, sem exigir revisão ou criar receipt. O registry E0 classifica cada operação como read/mutation/bootstrap/local; queries e commands recusam operações da classe errada com ERR_INVALID.

`StreamEnvelope` = `{protocol_major:1,event_id:uuid,environment_id:uuid,thread_id:uuid?,seq:int,committed_at_ms:int,module:ModuleID,delivery:enum[inline,reference],payload_ref:uuid?,payload:ModuleEvent?}`. entity_key é chave canônica definida em R1, com até 1024 bytes. seq é monotônico por agregado stream (environment ou thread), sem comparar números de agregados diferentes. Inline exige payload e proíbe payload_ref; reference proíbe payload e exige recuperar referência autenticada. Evento emitido somente após commit. Heartbeat 15000 ms, frame 256 KiB, corpo referenciado 4 MiB. `ModuleEvent` é união fechada dos registros de estado definidos na RFC do módulo, com wrapper `{entity_type:TypeID,entity_key:string,change:enum[upsert,delete],value:EntityRecord?}`; upsert exige registro integral e delete proíbe value. Threads incluem ConversationMessage, RunRecord, QueueEntry, ThreadState e TimelineItem; não apenas texto do assistant. Em fila usar position/message_id; texto incremental usa offset_bytes/complete definidos em TimelineItem. Tipos admissíveis por módulo são os registros das coleções/singletons de seu FeatureSnapshot. Exceções de execução (RuntimeEvent, TerminalFrame) têm discriminador explícito no schema do módulo e não substituem projeção persistida.

As fachadas PocketWiki espelham caminhos `/v1/harness` em `/api/harness`. `owner` do registry define roteamento sem copiar store: memória/composer pertencem ao PocketWiki; runtime/execução ao Kernel. Sessão delegada é limitada por audience/principal/environment, nunca bearer administrativo compartilhado. Os endpoints públicos de pairing/refresh e internos do MiddlewareAuth são exceções sensíveis fora do dispatcher, definidos em R4. MiddlewareAuth real deve participar do gate E3 de sessão e do E6 completo.

## Implementação por repositório

No PocketKernel, usar Go e preservar os adapters existentes. O helper atualmente fixado pelo PocketWiki é `b0453b87ba06575bb5a8187b71e5baa07a843c36`; o `go.mod` dessa revisão declara Go 1.22 e yaml.v3, sem banco transacional. Para este draft, o ledger novo usa SQLite WAL com driver Go puro `modernc.org/sqlite v1.61.1`, store privado por environment e migrações versionadas. Essa versão exige Go >=1.26.0; E0 inclui explicitamente subir o piso do toolchain do Kernel de 1.22 para 1.26.0 e validar ambas arquiteturas com CGO_ENABLED=0. O módulo de PTY usa `github.com/creack/pty v1.1.24`; o rig browser usa `@playwright/test 1.64.1`, Node >=20 e Chromium da revisão vinculada ao pacote. Versões verificadas nos metadados dos registries em 2026-11-01: [sqlite](https://proxy.golang.org/modernc.org/sqlite/@v/v1.61.1.mod), [pty](https://proxy.golang.org/github.com/creack/pty/@v/v1.1.24.mod), [Playwright](https://registry.npmjs.org/@playwright/test/1.64.1).

Não decidir dependências de Go dentro de várias worktrees: E0 fixa essas versões e seus checksums, prova build/migração/rollback antes de liberar E1. Se uma versão falhar a matriz real, revisar este draft e seus locks em uma base serial, não improvisar dependências diferentes por lane. Sem esse gate capability harness.v1 fica desabilitada. A alternativa de manter JSON sem transação está descartada para receipt/outbox/projeção atômicos.

As mudanças do Kernel ficam no próprio repo. As issues deste milestone coordenam a entrega, mas não autorizam copiar seu store para PocketWiki. Cada lane do Kernel entrega um commit/PR no repo correto e um módulo cliente no PocketWiki quando necessário. Quando a etapa passa, registrar o SHA integrado de ambos. Atualizar o pin no builder do PocketWiki somente no E6, depois de validar o binário real, nunca apontando para branch ou ref inexistente.

No PocketWiki, criar fachadas JS e Swift pequenas, validando o mesmo corpus JSON. Não compartilhar domínio por cópia entre as linguagens. Tipos de wire podem ser gerados dos schemas; renderer e transporte continuam nativos. Módulos novos têm registro declarativo por ID com schemas, owner, actions, reducer e UI slot. E0 fixa a interface desse registro; Cada integrador de etapa registra serviços já entregues nos routers; E6 liga o shell de produção. Nenhuma lane de domínio altera arquivos globais.

Arquivos globais de integração: `server.mjs`, `wiki-cockpit.html`, `src/mcp/pocketwiki-mcp-server.mjs`, `Sources/PocketWikiMac/Views/LocalAIView.swift`, `LocalAIChatPanel.swift`, `LocalAISidePanels.swift`, `LocalAIWorkspaceShell.swift`, `Stores/LocalAIChatSession.swift`, `WikiAppStore.swift`, `Services/PocketWikiHTTPServer.swift`, `PocketKernelClient.swift`, `Package.swift`, `package.json`, `package-lock.json`, scripts de build/teste e workflow. Somente a lane de integração da etapa altera arquivos globais. Se uma dependência nova precisar de lockfile, pedir mudança ao integrador antes de abrir implementação paralela, sem cada lane editar o lock.

## Migração e rollout

1. Publicar documentação e contratos em draft; validar schemas/fixtures sem habilitar recurso em produção.
2. Entregar Kernel com harness.v1 aditivo. O cliente consulta capabilities e segue usando `/v1/kernel` quando não houver suporte. Não marcar como streaming um adapter que só responde inteiro.
3. Registrar sessões v1 em mapping para namespace/thread. Não alterar arquivos originais nem indexar legado sem escolha de projeto. Fazer import idempotente; só ativar sessão nova depois de persistir mapping completo.
4. Habilitar domínio e módulo visual por capability, com feature flag local `new_harness_enabled=false` inicial. A flag não concede autorização; policy server-side é obrigatória mesmo com UI escondida.
5. Validar web e macOS contra helper real integrado; depois atualizar pin/hash e empacotamento da release composta.
6. Para rollback de UI, desligar flag e usar legado; preservar dados v2 sem convertê-los destrutivamente para v1. Kernel com schema incompatível recusa startup de escrita e informa versão mínima, sem tentar downgrade silencioso.

Reter ledgers e mapeamentos após desabilitar UI. Atualizar migration schema por versão monotônica. Migração faz backup transacional local automático no diretório privado, valida contagens/hashes e só então troca ponteiro ativo. Se falhar, manter store anterior read-only e capability unavailable; nenhuma edição de arquivos de usuário para remediar migração.

## Licenças e contribuição

O [LICENSE do t3code](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/LICENSE) é MIT. Fork e modificação são permitidos, preservando os avisos exigidos quando houver cópia substancial. O [README analisado](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/README.md) incentiva forks, mas limita contribuições grandes ao upstream. A abertura para forks não deve ser confundida com aceite de PR de feature.

Este pacote contém especificações próprias e links de atribuição; não incorpora código deles. Antes de copiar qualquer componente, registrar arquivo, SHA, licença e notice, inclusive dependências transitivas. Não reproduzir marca, nome ou assets como identidade do PocketWiki. A inspiração ai-memory já documentada permanece implementação própria; não muda automaticamente para o protocolo atual do projeto externo.
