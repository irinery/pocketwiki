# RFC-0002/01 — Contrato de domínio do runtime E1

Base examinada: PocketWiki `1176837a6091b4c10cf8600f1ca15dc650b970fe`; PocketKernel `582e216c13feb7485fa9620d9543b272ec3794b5`; MiddlewareAuth de referência `04f44f62126c785f7b28718d2eff837c28cb65df`. Este contrato descreve o recorte implementado e separa as exigências ainda pendentes. A [RFC-0002](../../../rfcs/new-harness/0002-runtime-duravel.md) e [R1–R7](../../../rfcs/new-harness/contratos-integracao-v0.2.md) continuam normativos; a issue #23 exige ambas as fases e gate cumulativo, não apenas estes arquivos.

## Autoridade e interfaces

PocketKernel é a autoridade de identidade, ACL, revisão, ledger, outbox, eventos, projeção e recovery. O cliente não executa efeitos nem substitui snapshot por resultado de comando. Em E1 o `thread_id` é agregado reservado pelo host com owner, não uma thread de produto. Bootstrap local E0 entrega bearer scoped por canal de processo; IDs e hashes não autorizam ações. R2/R3 e R5 descrevem dependências posteriores de contexto, aprovação e lifecycle, não portas fictícias desta fase. R4 remoto e MiddlewareAuth real pertencem à integração posterior; R6/R7 exigem evidência integrada por superfície e SHAs dos três repositórios.

| Interface | Entrada e resultado | Fronteira real |
| --- | --- | --- |
| `runtime.dispatch` | `HarnessCommand` major 1, `command_id`, `environment_id`, `expected_revision`, operation `runtime.dispatch` e input fechado `{command_id,thread_id,expected_revision,operation,text,run_id?}`. IDs/revisões repetidos devem coincidir. `submit` exige texto não vazio e não aceita run_id. | `POST /v1/harness/commands`; resposta HTTP `CommandReceipt` plano, distinto do Result `{receipt_id,revision,state: accepted\|duplicate}` obtido por referência de resultado. Ack confirma intenção, não conclusão. |
| `runtime.receipt` | `command_id` do principal; receipt com revisão e estado `accepted`, `pending`, `succeeded`, `failed` ou `uncertain`. | `GET /v1/harness/receipts/{command_id}`; consulta não cria efeito. |
| `runtime.events` | `thread_id`, `after_seq >= 0`, `limit` 1–100; retorna eventos e próximo cursor. | `GET /v1/harness/threads/{id}/events`; stream R1 autenticado em `GET /v1/harness/streams/thread/{id}?after_seq=...&modules=runtime`. |
| snapshot | `module=runtime`, `page_size` 1–100 e cursor opcional. Resposta `{module,data}` com `snapshot_id`, `revision`, `as_of_seq`, receipts e effects. | `GET /v1/harness/threads/{id}/snapshot`; leitura é projeção persistida, não resultado do comando. |
| resultado/capabilities | Resultado tipado por referência e negociação de versão/schema. | `GET /v1/harness/results/{ref}` e `GET /v1/harness/capabilities`. |

As variantes `cancel` e `resume` são validadas, mas retornam `ERR_UNAVAILABLE` antes da transação, sem receipt ou efeito. O lifecycle de run e confirmação por adapter são posteriores; não anunciar cancelamento ou retomada funcional. O único efeito E1 é `rig.temp_file.write`, executor mínimo do rig, não provider nem thread de produto.

A implementação serializa escrita, verifica owner e CAS, calcula hash canônico da intenção e grava receipt, evento, projeção e outbox em transação SQLite WAL/FULL; publica após commit. Mesmo `command_id` e hash retorna receipt anterior; hash diferente ou revisão divergente retorna `ERR_CONFLICT`. Worker registra início antes do I/O; após crash de escrita com resultado desconhecido, recovery expõe `effect_uncertain` sem replay automático. Não existe reconciliação automática de efeito incerto.

## Limites, erros e paginação

UUID canônico minúsculo; inteiros JSON seguros; strings em UTF-8. Comando até 1 MiB, texto até 32768 bytes, evento até 256 KiB, até 100000 eventos por thread e 100 por página; um writer por environment. RFC define deadline de efeito de leitura 30000 ms, ack 5000 ms e zero retry automático de escrita incerta. Entidade/página até 4 MiB. Snapshot fixa boundary e identidade; cursor opaco até 512 bytes, TTL 600000 ms, page size congelado, ordenação por coleção e ID, até 100 entidades somadas. `next_cursor` ausente termina; `null` é inválido. Retenção perdida retorna `ERR_CURSOR_EXPIRED`; reiniciar snapshot completo preservando draft. Eventos grandes usam entrega por referência autenticada quando suportada pelo transporte R1; não truncar.

Erros de domínio fechados: `ERR_INVALID`, `ERR_FORBIDDEN`, `ERR_TIMEOUT`, `ERR_UNAVAILABLE`, `ERR_INCOMPATIBLE`, `ERR_CONFLICT`, `ERR_UNCERTAIN`; leitura acrescenta `ERR_NOT_FOUND` e `ERR_CURSOR_EXPIRED`. `HarnessError` inclui code, message redigida até 1024 bytes, correlation_id e retryable. Em falha ambígua consultar receipt antes de decidir retry; nunca inferir conclusão por timeout.

## Wiring e evidência

Host Kernel: flags `-harness-db`, `-harness-auth-store`, `-harness-bootstrap-socket`, opcional `-harness-temp-root` para rig e `-harness-schema-sha256` alinhado ao schema integrado. Socket Unix privado de bootstrap reserva `{environment_id,thread_id,owner_principal_id}` e entrega/verifica credenciais. O integrador conecta transporte e serviço sem substituir `PocketKernelClient.query`; seleção no shell de produção é E6. Store schema 1 com eventos é recusado na migração para schema 2; histórico não é fabricado.

Os testes reais estão em `harness/runtime/runtime_test.go`: `Test0101ReceiptEffectProjectionPersistAcrossReopen` usa worker em subprocesso e reabertura; `Test0102CrashAfterExternalWriteRecoversUncertainWithoutReplay` mata subprocesso após I/O; `Test0103ConcurrentDuplicateAndPayloadConflict`, `Test0104DifferentPrincipalCannotDispatchOrRead` e `Test0105SnapshotPagesStayAtBoundaryAcrossConcurrentMutation` cobrem concorrência, isolamento e boundary no store. `internal/harnessauth/runtime_integration_test.go` cobre bootstrap/owner por HTTP. Esses testes isolados não substituem execução 01-01–01-05 por serviços/clientes reais e gate cumulativo. Consulte também `harness/runtime/EVIDENCE.md` no SHA Kernel acima; histórico de CI citado ali pertence a outro commit.

Validação documental nesta entrega: `go test ./harness/runtime ./internal/harnessauth -count=1 -timeout=120s` passou no Kernel `582e216c13feb7485fa9620d9543b272ec3794b5`. Não é execução do gate integrado nem cobre todos os repositórios.
