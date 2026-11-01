# New Harness — arquitetura e implementação proposta

Estado: Draft · versão 0.1.0 · 2026-11-01. Este documento explica como implementar as RFCs 0002–0016; nenhum endpoint novo descrito aqui já está implementado.

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

## Contrato transversal v1 proposto

Todos os tipos são fechados e geram JSON Schema, tipos Swift e fixtures JS em E0. A serialização de wire usa `snake_case`. `uuid`, `sha1`, `sha256`, enums e limites obedecem aos cabeçalhos das RFCs. Nenhum campo `any` é permitido. IDs e hashes não são secrets.

```typescript
type HarnessError = {
  code: string; // enum fechado por operação na RFC correspondente
  message: string; // <=1024 bytes, redigida
  correlation_id: UUID;
  retryable: boolean;
};
type CommandReceipt = {
  command_id: UUID;
  receipt_id: UUID;
  environment_id: UUID;
  revision: number; // inteiro seguro >=0
  state: "accepted" | "duplicate" | "pending" | "succeeded" | "failed" | "uncertain";
  result_ref?: UUID;
};
type StreamEnvelope = {
  protocol_major: 1;
  event_id: UUID;
  environment_id: UUID;
  thread_id: UUID;
  seq: number; // monotônico por thread
  committed_at_ms: number;
  operation: string; // enum das operações registradas, não operação arbitrária
  payload_ref: UUID; // evento persistido, validado pelo schema da operação
  payload: HarnessEventPayload; // união fechada descrita no registro abaixo
};
```

O stream entrega `payload` inline como união discriminada pelo `operation` e schema de evento; `payload_ref` permite recuperar o mesmo evento persistido após truncamento. Não existe campo livre para objetos arbitrários. Cada módulo registra o schema de payload e a projeção no registro de E0; registro é por manifestos de módulos, sem editar uma switch global em cada lane.

| Fronteira | Entrada | Saída | Falha observável |
| --- | --- | --- | --- |
| `GET /v1/harness/capabilities` | sessão autenticada | `{protocol_major:1, protocol_minor:0, schema_sha256:sha256, environment_id:uuid, operations:array[string]}`; operations enum derivado dos manifestos; <=100 | 401/403/426/503, nunca iniciar login como efeito do probe |
| `POST /v1/harness/commands` | envelope tipado da RFC; command_id obrigatório | HTTP 202 com CommandReceipt; HTTP 200 se receipt já existe | 400/403/409/413/422/426/429/503/504; sem repetir intenção incerta |
| `GET /v1/harness/receipts/{command_id}` | UUID + identidade original | receipt atual com `result_ref` quando houver | 404 sem vazar intenção de outro principal; 503 preserva comando |
| `GET /v1/harness/results/{result_ref}` | UUID autorizado | união fechada dos resultados de RFCs; objeto de saída exato da operação | 404/403/426; resultado não disponível: 409 pending |
| `GET /v1/harness/threads/{id}/snapshot` | thread UUID autorizada | `{thread_id:uuid, revision:int, last_seq:int, modules:array[ModuleSnapshot]}` | 403/404/426/503; não buscar outra thread por fallback |
| `GET /v1/harness/threads/{id}/events?after_seq=N` | inteiro >=0, bearer e Last-Event-ID opcionais coerentes | SSE com ID seq, envelope e payload tipado, após commit | 409 cursor expirado, 401/403 revogado, 426 major incompatível |
| `GET /v1/harness/events/{payload_ref}` | evento UUID autorizado | envelope e payload originais | 403/404/410 se retenção expirou, pedir snapshot |

`ModuleSnapshot` é união discriminada `{module:<ID fechado>, data:<tipo de resultado da RFC>, revision:int}`. Somente módulos habilitados e autorizados aparecem. Subtipos são os `FeatureSnapshot` de cada RFC, não um mapa sem schema. Payload de evento usa o registro tipado: runtime→RuntimeEvent, providers→ProviderBinding, threads→TimelineItem, composer→ComposerDraft, permissions→PermissionRequest, workspaces→WorkspaceLease, checkpoints→Checkpoint, terminal→TerminalFrame, environments→EnvironmentConnection, orchestrator-mcp→MCPThreadSummary, handoffs→ThreadLineage, memory→MemoryHit, source-control→PullRequestLink, navigation→NavigationEntry, diagnostics→ComponentHealth. Mudanças adicionais exigem versão minor, schema e fixture novos antes de uso.

Streams são HTTP SSE com header Authorization, lidos por fetch/URLSession; não transportar bearer por query string. Heartbeat de 15000 ms serve a liveness, não altera lifecycle. Servidor retém conexão sem pedir histórico de todas as threads. Frame máximo 256 KiB; snapshot 4 MiB; leitura paginada no limite da RFC. Em caso de gap, pedir snapshot e depois aplicar apenas seq maior.

As fachadas do PocketWiki espelham os caminhos em `/api/harness` com as mesmas regras e payloads. Elas verificam identidade e encaminham ao environment explícito. Nunca usam bearer privilegiado comum para transformar qualquer usuário web em administrador. Memória/composer locais usam o mesmo envelope, recibos e escopo da identidade, mas não passam a pertencer ao store do Kernel. O registro mantém `owner` e rota por operação. Rotas antigas `/api/memory/*` e `/v1/kernel` continuam disponíveis com seu contrato atual.

## Ações complementares e estado consultável

O método principal de cada RFC descreve a ação crítica e seus testes. O restante da superfície é implementado pelo mesmo dispatcher, com entradas/saídas abaixo, limites/erros da respectiva RFC e nenhum novo privilégio implícito. São contratos propostos, não escolhas deixadas ao implementador. Todos recebem `command_id`, `environment_id` e `expected_revision` no envelope quando alteram estado. Leituras usam `GET /v1/harness/query/{operation}` com parâmetros tipados e resultado correspondente; question/text com dado sensível usa POST autenticado e `Cache-Control: no-store`.

| RFC | Operação complementar | Entrada específica tipada | Saída específica tipada |
| --- | --- | --- | --- |
| 0003 | `providers.catalog` | `{project_id:uuid?}` | `{revision:int, bindings:ProviderBinding[], capabilities:ProviderCapabilities[]}` |
| 0004 | `threads.create` / `threads.list` | create `{project_id:uuid?,title:string<=200}`; list `{after_id:uuid?,limit:int1..100}` | create `ThreadState`; list `{threads:ThreadState[],next_id:uuid?}` |
| 0005 | `composer.stage` / `composer.draft.save` | stage `{thread_id:uuid,filename:string<=255,mime:enum[text/plain,text/markdown,image/png,image/jpeg],content_base64:string<=5592408}`; save `ComposerDraft` | stage `ContextReference`; save `{draft_id:uuid,revision:int}` |
| 0006 | `permissions.pending` / `permissions.mode` | pending `{thread_id:uuid}`; mode `{thread_id:uuid,mode:enum[supervised,edits,full]}` | pending `PermissionRequest[]`; mode `{effective_mode:enum[supervised,edits,full],revision:int}` |
| 0007 | `workspaces.release` / `workspaces.settings` | release `{lease_id:uuid,remove:bool}`; settings `{project_id:uuid?,patch:WorkspaceSettings,reset:bool}` | release `{state:enum[idle,retained,removed]}`; settings `WorkspaceSettings` |
| 0008 | `checkpoints.capture` / `checkpoints.preview` / `checkpoints.diff` | capture `{run_id:uuid,boundary:enum[before,after]}`; preview `{checkpoint_id:uuid}`; diff `{thread_id:uuid,scope:enum[turn,branch],run_id:uuid?,base_sha:sha1?}` | capture `Checkpoint`; preview `{checkpoint_id:uuid,preview_sha256:sha256,files:FileDelta[],workspace_revision:int}`; diff `{files:FileDelta[],patch:string<=2097152,truncated:bool}` |
| 0009 | `terminal.input` / `terminal.resize` / `terminal.close` / `terminal.read` | input `{terminal_id:uuid,data_base64:string<=87384}`; resize `{terminal_id:uuid,cols:int20..400,rows:int5..200}`; close `{terminal_id:uuid}`; read `{terminal_id:uuid,after_seq:int>=0}` | input/resize/close `TerminalState`; read `{state:TerminalState,frames:TerminalFrame[],next_seq:int}` |
| 0010 | `environments.challenge` / `environments.revoke` | challenge `{requested_scopes:enum[read,submit,approve,execute][]}`; revoke `{connection_id:uuid}` | challenge `{challenge_id:uuid,challenge_secret:string,server_fingerprint:sha256,expires_at_ms:int}` só para host autenticado; revoke `{revoked:bool}` |
| 0011 | tools `harness.thread.*` | entrada do MCPThreadCall da RFC, validada por tool | resultado da RFC; mutation retorna receipt sem esperar conclusão |
| 0012 | `handoffs.export` / `handoffs.import` | export `{handoff_id:uuid}`; import `{schema_version:1,source_environment_id:uuid,messages:HandoffMessage[],lineage:ThreadLineage,target_project_id:uuid?,package_sha256:sha256}` | export pacote dos mesmos campos; import `{handoff_id:uuid,thread_id:uuid,duplicate:bool}` |
| 0013 | `memory.capture_scoped` / `memory.note.get` / `memory.note.put` / `memory.map_legacy` | capture `{namespace:MemoryNamespace,events:LegacyCaptureEvent[]}`; get `{namespace:MemoryNamespace}`; put `{namespace:MemoryNamespace,content:string<=16384 bytes,expected_revision:int}`; map `{legacy_session_id:uuid,namespace:MemoryNamespace}` | capture `{accepted_keys:string[]}`; get/put `{content:string,revision:int}`; map `{mapped:bool,session_id:uuid}` |
| 0014 | `source_control.execute` / `source_control.links` | execute `{preview_id:uuid,action_sha256:sha256,head_sha:sha1,approval_id:uuid}`; links `{thread_id:uuid}` | execute `{action_id:uuid,state:enum[pending,succeeded,failed,uncertain]}`; links `PullRequestLink[]` |
| 0015 | `navigation.list` | `{project_id:uuid?,section:enum[active,pinned,archived],after_position:int?,after_id:uuid?,revision:int?,limit:int1..100}` | `{entries:NavigationEntry[],notifications:InboxNotification[],revision:int,next_position:int?,next_id:uuid?}` |
| 0016 | `diagnostics.export` | `{report_id:uuid,approval_preview_sha256:sha256}` | `{filename:string,sha256:sha256,size_bytes:int}`; arquivo só no diretório escolhido, download por referência autenticada |

`LegacyCaptureEvent` repete o formato existente: `{event:enum[session-start,user-prompt-submit,assistant-response,stop,session-end],session_id:uuid,ingest_key:string regex[A-Za-z0-9_-]{1,64},prompt:string?<=8000 caracteres,message:string?<=8000 caracteres,provider_id:string?<=120,model_id:string?<=120}`. Prompt e message são obrigatórios respectivamente para user-prompt-submit e assistant-response; outros eventos não carregam texto. Capture scoped aceita 1..32 eventos.

Segredos de challenge têm resposta excepcional de uso único, não entram em snapshot/export e não são persistidos em claro pelo servidor. Resultados normais nunca transportam tokens. Limites específicos de arrays de cada RFC prevalecem; os demais têm máximo 100 itens. Respostas que excedem orçamento paginam ou indicam truncamento explícito. Base64 é validado e o limite decodificado prevalece.

## Implementação por repositório

No PocketKernel, usar Go e preservar os adapters existentes. O helper atualmente fixado pelo PocketWiki é `b0453b87ba06575bb5a8187b71e5baa07a843c36`; o `go.mod` dessa revisão declara Go 1.22 e yaml.v3, sem banco transacional. Para este draft, o ledger novo usa SQLite WAL com driver Go puro `modernc.org/sqlite v1.61.1`, store privado por environment e migrações versionadas. Essa versão exige Go >=1.26.0; E0 inclui explicitamente subir o piso do toolchain do Kernel de 1.22 para 1.26.0 e validar ambas arquiteturas com CGO_ENABLED=0. O módulo de PTY usa `github.com/creack/pty v1.1.24`; o rig browser usa `@playwright/test 1.64.1`, Node >=20 e Chromium da revisão vinculada ao pacote. Versões verificadas nos metadados dos registries em 2026-11-01: [sqlite](https://proxy.golang.org/modernc.org/sqlite/@v/v1.61.1.mod), [pty](https://proxy.golang.org/github.com/creack/pty/@v/v1.1.24.mod), [Playwright](https://registry.npmjs.org/@playwright/test/1.64.1).

Não decidir dependências de Go dentro de várias worktrees: E0 fixa essas versões e seus checksums, prova build/migração/rollback antes de liberar E1. Se uma versão falhar a matriz real, revisar este draft e seus locks em uma base serial, não improvisar dependências diferentes por lane. Sem esse gate capability harness.v1 fica desabilitada. A alternativa de manter JSON sem transação está descartada para receipt/outbox/projeção atômicos.

As mudanças do Kernel ficam no próprio repo. As issues deste milestone coordenam a entrega, mas não autorizam copiar seu store para PocketWiki. Cada lane do Kernel entrega um commit/PR no repo correto e um módulo cliente no PocketWiki quando necessário. Quando a etapa passa, registrar o SHA integrado de ambos. Atualizar o pin no builder do PocketWiki somente no E6, depois de validar o binário real, nunca apontando para branch ou ref inexistente.

No PocketWiki, criar fachadas JS e Swift pequenas, validando o mesmo corpus JSON. Não compartilhar domínio por cópia entre as linguagens. Tipos de wire podem ser gerados dos schemas; renderer e transporte continuam nativos. Módulos novos têm registro declarativo por ID com schemas, owner, actions, reducer e UI slot. E0 fixa a interface desse registro; E6 liga os módulos aos arquivos globais existentes.

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
