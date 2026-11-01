# RFC — Runtime durável, comandos e eventos

**Projeto:** PocketWiki / New Harness. (RFC-0002)
**Data:** 2026-11-01
**Issue:** [#23](https://github.com/irinery/pocketwiki/issues/23)
**Estado de evolução:** Draft
**Versão da RFC:** 0.1.0
**Status:** COMPLETO
**Fases:** 2 arquivos a gerar
**Gerado por:** Codex, sessão New Harness

> COMPLETO significa especificação do draft preenchida; não significa aprovação, implementação ou estabilidade pública. Todos os endpoints harness.v1, módulos e limites abaixo são propostas. O endpoint atual POST /v1/kernel permanece compatível. Primitivos deste cabeçalho: uuid = UUID RFC 4122 canônico minúsculo; sha1 = 40 hex; sha256 = 64 hex; int = inteiro JSON seguro 0..9007199254740991 salvo exit_code, que aceita -255..255; string = UTF-8; `?` = opcional/ausente, nunca null implícito; array[T] = lista homogênea; enum[...] = lista fechada. Timestamps são int em ms UTC. Campos desconhecidos de comando são rejeitados; campos opcionais novos em resposta exigem minor negociado. Fase pode ser implementada com este cabeçalho + seu bloco: tipos são repetidos deliberadamente.

> Tipo transversal `HarnessError = {code:string (enum da interface), message:string (0..1024 bytes redigidos), correlation_id:uuid, retryable:bool}`. Em wire, bool = boolean JSON. Identidade e scopes são obtidos do transporte autenticado, nunca de um campo user_id escolhido pelo cliente.

## 1. Visão Geral

### 1.1 Problema
O PocketKernelClient atual faz uma requisição POST e recebe a resposta completa. LocalAIChatSession.isStreaming representa espera local; cancelar a Task não comprova que o trabalho remoto parou. Não há neste cliente receipt durável nem cursor de eventos.

### 1.2 Solução
Registrar intenção e efeitos no PocketKernel antes de executar I/O, permitindo retomada, deduplicação e projeções recuperáveis.

O recorte desta RFC é: Ledger transacional, receipt, outbox, worker e recuperação de processo; API v1 adicional com snapshot e eventos. Não reimplementar o domínio no servidor Node nem no Swift.

### 1.3 Fora de escopo
Reescrever PocketKernel em TypeScript; introduzir Effect no Swift; migrar toda a wiki; garantir exactly-once para efeitos externos sem idempotência.

**Origem e adaptação:** comportamento observado nos documentos abaixo da revisão `5732bbee397f0a2b0e61d0c2e432f01dca6df3dc`. A implementação proposta é própria e mantém domínio em PocketKernel. Limites e políticas deste draft pertencem ao PocketWiki e não são transcrição dos defaults do t3code.

- [docs/internals/overview.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/internals/overview.md)
- [docs/orchestration-v2/testing-strategy.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/orchestration-v2/testing-strategy.md)

## 2. Mapa de Fases

| Fase | Arquivo | Nome do componente | Depende de | Paralelizável com |
| --- | --- | --- | --- | --- |
| 01 | 01_runtime_dominio.md | Contrato e serviço de domínio | NH-00 e NH-TEST (E0) | lanes backend da mesma etapa do plano, sem dependência entre elas |
| 02 | 02_runtime_cliente.md | Transporte/projeção e superfície cliente | 01 | lanes cliente da mesma etapa do plano, com diretórios exclusivos |

Arquivos de contrato serão gerados em `docs/technical-contract/new-harness/runtime/`; este draft entrega uma RFC inteira, não contratos parciais. A agenda global e os gates estão em `plano-worktrees.md`; cada fase só começa após dependências integradas no SHA base.

### Convenções globais
- PocketKernel é autoridade deste domínio; PocketWiki não lê store privado de integração externa.
- Auth por principal/environment + scope a cada ação. IDs de request e hashes não são credenciais.
- Erro de domínio serializa como `HarnessError {code:string, message:string, correlation_id:uuid, retryable:bool}`; message máximo 1024 bytes e redigida, code limitado à lista da fase.
- APIs propostas ficam sob `/v1/harness` no Kernel e `/api/harness` na fachada PocketWiki; o identificador canônico abaixo é a operação de domínio. E0 materializa em schemas o mapa de transporte definido na arquitetura, sem alterar semântica.
- Limites bytes são bytes UTF-8; limites em caracteres são Unicode scalars. Strings gerais 4096 bytes e arrays gerais 100 itens, salvo regra específica.

### Definition of Done global
- [ ] testes 01-01..01-04 e 02-01..02-04 executados através de interfaces reais
- [ ] JS e Swift aceitam/rejeitam o mesmo corpus de contratos
- [ ] revisão humana/técnica e E2E cumulativo no SHA integrado da etapa
- [ ] sem regressão em memória/sessões v1, wiki, MCP Evidence e modo externo
- [ ] nenhum secret em fixtures, logs, UI ou export

## 3.1 — Fase 01: Domínio e persistência

### O que é
Registrar intenção e efeitos no PocketKernel antes de executar I/O, permitindo retomada, deduplicação e projeções recuperáveis. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Ledger transacional, receipt, outbox, worker e recuperação de processo; API v1 adicional com snapshot e eventos. Não reimplementar o domínio no servidor Node nem no Swift.
- Persistir revisão/receipt e expor resultado tipado com erros observáveis.

**Fora do escopo deste componente:**
- Reescrever PocketKernel em TypeScript; introduzir Effect no Swift; migrar toda a wiki; garantir exactly-once para efeitos externos sem idempotência.
- Editar views existentes, rotas globais e scripts de CI nesta lane.

**Dependências repetidas:** NH-00 e NH-TEST (E0).

**Posse de arquivos:** PocketWiki: `src/harness/runtime/`, `Sources/PocketWikiMac/Services/Harness/Runtime/`, `Tests/Harness/runtime/`. PocketKernel (outro repo): novo módulo lógico `harness/runtime` e seus testes; adapter para store existente, sem substituir serviços privados de outro domínio.  Os paths são destinos propostos; arquivos atuais compartilhados só mudam pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 01-01 [caminho feliz]
dado: comando novo e worker disponível
quando: submeter e aguardar effect_finished
então: um receipt, uma execução e uma revisão persistida após reabrir o processo

TESTE 01-02 [falha]
dado: processo morre após iniciar efeito externo sem confirmação
quando: reiniciar contra o mesmo store
então: effect_uncertain visível e zero repetição automática do efeito

TESTE 01-03 [edge case]
dado: mesmo command_id enviado por 2 clientes
quando: aguardar os 2 receipts
então: mesmo receipt; hash divergente retorna ERR_CONFLICT sem novo efeito

TESTE 01-04 [segurança]
dado: thread de outro principal
quando: dispatch com identidade autenticada diferente
então: ERR_FORBIDDEN e nenhum evento/efeito criado

```

### Contratos de interface

```yaml
interface:
  id: IF-0002-01-1
  tipo: http
  nome: "runtime.dispatch"
  entrada:
    - campo: command_id
      tipo: "uuid"
      obrigatório: true
      validação: "UUID estável por intenção"
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread autorizado"
    - campo: expected_revision
      tipo: "int"
      obrigatório: true
      validação: ">= 0"
    - campo: operation
      tipo: "enum[submit,cancel,resume]"
      obrigatório: true
      validação: "lista fechada"
    - campo: text
      tipo: "string"
      obrigatório: true
      validação: "0..32768 bytes UTF-8; submit exige 1..32768"
    - campo: run_id
      tipo: "uuid?"
      obrigatório: false
      validação: "obrigatório em cancel/resume; ausente em submit"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: receipt_id
          tipo: "uuid"
        - campo: revision
          tipo: "int"
        - campo: state
          tipo: "enum[accepted,duplicate]"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONFLICT
          quando: "revision ou hash da intenção divergente"
          ação: "409; devolver revision atual, sem executar"
        - code: ERR_UNCERTAIN
          quando: "efeito sem confirmação após perda de processo"
          ação: "409; expor effect_id para reconciliação"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

O envelope de transporte de comando é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Interface de view é local e não cria um endpoint HTTP novo.

**Interface complementar: runtime.receipt**

```yaml
interface:
  id: IF-0002-01-2
  tipo: http
  nome: "runtime.receipt"
  entrada:
    - campo: command_id
      tipo: "uuid"
      obrigatório: true
      validação: "intenção do mesmo principal"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: receipt_id
          tipo: "uuid"
        - campo: revision
          tipo: "int"
        - campo: state
          tipo: "enum[accepted,duplicate,pending,succeeded,failed,uncertain]"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONFLICT
          quando: "revision ou hash da intenção divergente"
          ação: "409; devolver revision atual, sem executar"
        - code: ERR_UNCERTAIN
          quando: "efeito sem confirmação após perda de processo"
          ação: "409; expor effect_id para reconciliação"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: runtime.events**

```yaml
interface:
  id: IF-0002-01-3
  tipo: http
  nome: "runtime.events"
  entrada:
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread legível"
    - campo: after_seq
      tipo: "int"
      obrigatório: true
      validação: ">=0"
    - campo: limit
      tipo: "int"
      obrigatório: true
      validação: "1..100"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: events
          tipo: "array[RuntimeEvent]"
        - campo: next_seq
          tipo: "int"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONFLICT
          quando: "revision ou hash da intenção divergente"
          ação: "409; devolver revision atual, sem executar"
        - code: ERR_UNCERTAIN
          quando: "efeito sem confirmação após perda de processo"
          ação: "409; expor effect_id para reconciliação"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: RuntimeReceipt
campos:
  - nome: command_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: payload_sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: effect_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

```yaml
tipo: RuntimeEvent
campos:
  - nome: event_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: seq
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: kind
    tipo: "enum[intent_committed,effect_started,effect_finished,effect_uncertain,run_cancelled]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: effect_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

### Regras de comportamento

1. O input de runtime.dispatch repete command_id e expected_revision do envelope; valores devem ser idênticos, senão ERR_INVALID. A transação grava evento, projeção, receipt e efeito outbox juntos. Broadcast ocorre somente após commit; ack não significa trabalho concluído.
2. O writer serializa por environment; expected_revision divergente retorna ERR_CONFLICT. command_id igual e hash igual retorna o receipt anterior; hash diferente é conflito.
3. Worker marca started antes de I/O. Após crash, leitura idempotente pode repetir; execução de escrita com resultado desconhecido vira effect_uncertain e exige reconciliação, nunca replay cego.
4. Um cancel aceito fica cancellation_requested até confirmação do adapter. Run encerrado e finalização de diff são estados distintos.
5. Cursor seq monotônico por thread; cliente aplica snapshot revision e apenas eventos posteriores. Cursor expirado exige snapshot novo, sem limpar draft.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 1 MiB por comando; 32768 bytes de texto; 256 KiB por evento; 100 eventos por página; 100000 eventos por thread; 1 writer por environment; 30000 ms por efeito de leitura; 0 retries automáticos de escrita incerta; ack em até 5000 ms antes de resposta ERR_TIMEOUT.

**Como realizar:**

1. No PocketKernel, criar módulo interno harness/runtime com ledger, receipt/outbox e worker separados; utilizar transação do store do Kernel, com SQLite WAL como escolha proposta caso não exista store transacional compatível.
2. Adicionar GET /v1/harness/capabilities, POST /v1/harness/commands, GET /v1/harness/threads/{id}/snapshot e GET /v1/harness/threads/{id}/events?after_seq=N por SSE autenticado.
3. No PocketWiki, implementar transporte em src/harness/runtime/ e Services/Harness/Runtime/. Não mudar PocketKernelClient.query nesta worktree; o gate E6 faz a seleção por capability.

### Dependências desta fase

```yaml
- id: DEP-0002-01-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0002-01-2
  tipo: componente_interno
  nome: "PocketKernel"
  versão: "harness.v1 proposto"
  papel: "autoridade do domínio"
  fallback: "capability ausente: modo legado ou recurso indisponível; sem execução substituta"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface runtime.dispatch exercitáveis sem integração com shell compartilhado
- [ ] fixtures reais sanitizadas, falhas e relatório de execução com SHA base e final
- [ ] todos os testes 01-01 a 01-04 passando
- [ ] nenhum arquivo fora da posse da lane alterado; mudanças compartilhadas entregues como instrução ao integrador

## 3.2 — Fase 02: API, transporte e projeção cliente

### O que é
Superfície web e macOS do domínio, consumindo o contrato confirmado sem executar efeitos diretamente na view. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Mostrar resultado, origem e estado de sincronização; manter seleção/draft e solicitar ações explícitas pela fachada.
- Expor navegação por teclado, foco e estados acessíveis em web 390/900/1440px e janela macOS compacta/regular.

**Fora do escopo deste componente:**
- Reescrever PocketKernel em TypeScript; introduzir Effect no Swift; migrar toda a wiki; garantir exactly-once para efeitos externos sem idempotência.
- Executar subprocessos, ler filesystem local como substituto do servidor, acessar credencial de provider ou alterar regra de negócio.

**Dependências repetidas:** RFC-0002/01 + NH-00 + NH-TEST.

**Posse de arquivos:** `src/harness-ui/runtime/`, `Sources/PocketWikiMac/Views/Harness/Runtime/`, `Tests/HarnessUI/runtime/`.  Os paths são destinos propostos; arquivos atuais compartilhados só mudam pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 02-01 [caminho feliz]
dado: snapshot revision 10 e stream com seq 9,10,11
quando: reconectar cliente
então: somente seq 11 altera a projeção

TESTE 02-02 [falha]
dado: servidor legado sem harness.v1
quando: abrir IA
então: chat /v1/kernel funciona e controles de run durável ficam indisponíveis

TESTE 02-03 [edge case]
dado: ack chega antes do efeito
quando: renderizar receipt
então: UI mostra aceito, não concluído

TESTE 02-04 [segurança]
dado: frame com version major 2
quando: decodificar stream
então: ERR_INCOMPATIBLE visível e nenhum estado parcial aplicado

```

### Contratos de interface

```yaml
interface:
  id: IF-0002-02-1
  tipo: function
  nome: "runtime.view.reduce"
  entrada:
    - campo: previous
      tipo: "ViewState"
      obrigatório: true
      validação: "estado inicial ou revision válida"
    - campo: snapshot
      tipo: "FeatureSnapshot"
      obrigatório: true
      validação: "resultado tipado da fase 01; mesmo environment/thread"
    - campo: client_action
      tipo: "enum[open,refresh,submit,dismiss]"
      obrigatório: true
      validação: "evento local explícito"
    - campo: draft
      tipo: "string"
      obrigatório: true
      validação: "0..32768 bytes; conteúdo não confiável"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: view
          tipo: "ViewState"
        - campo: effect
          tipo: "enum[none,request,refresh]"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONFLICT
          quando: "revision ou hash da intenção divergente"
          ação: "409; devolver revision atual, sem executar"
        - code: ERR_UNCERTAIN
          quando: "efeito sem confirmação após perda de processo"
          ação: "409; expor effect_id para reconciliação"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

O envelope de transporte de comando é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Interface de view é local e não cria um endpoint HTTP novo.

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: RuntimeReceipt
campos:
  - nome: command_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: payload_sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: effect_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

```yaml
tipo: RuntimeEvent
campos:
  - nome: event_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: seq
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: kind
    tipo: "enum[intent_committed,effect_started,effect_finished,effect_uncertain,run_cancelled]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: effect_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

```yaml
tipo: FeatureSnapshot
campos:
  - nome: receipt_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: state
    tipo: "enum[accepted,duplicate]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

```yaml
tipo: ViewState
campos:
  - nome: environment_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: thread_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: status
    tipo: "enum[loading,ready,stale,error]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: draft
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: data
    tipo: "FeatureSnapshot?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: error
    tipo: "HarnessError?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

### Regras de comportamento

1. O input de runtime.dispatch repete command_id e expected_revision do envelope; valores devem ser idênticos, senão ERR_INVALID. A transação grava evento, projeção, receipt e efeito outbox juntos. Broadcast ocorre somente após commit; ack não significa trabalho concluído.
2. O writer serializa por environment; expected_revision divergente retorna ERR_CONFLICT. command_id igual e hash igual retorna o receipt anterior; hash diferente é conflito.
3. Worker marca started antes de I/O. Após crash, leitura idempotente pode repetir; execução de escrita com resultado desconhecido vira effect_uncertain e exige reconciliação, nunca replay cego.
4. Um cancel aceito fica cancellation_requested até confirmação do adapter. Run encerrado e finalização de diff são estados distintos.
5. Cursor seq monotônico por thread; cliente aplica snapshot revision e apenas eventos posteriores. Cursor expirado exige snapshot novo, sem limpar draft.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 1 MiB por comando; 32768 bytes de texto; 256 KiB por evento; 100 eventos por página; 100000 eventos por thread; 1 writer por environment; 30000 ms por efeito de leitura; 0 retries automáticos de escrita incerta; ack em até 5000 ms antes de resposta ERR_TIMEOUT.

No cliente: renderizar 100 itens por página; draft 32768 bytes; erro 1024 bytes; request HTTP 30000 ms; 0 retries cegos de mutação e 0 fallback para outra identidade. Deadlines específicos da fase 01 prevalecem. Timeout visual não cancela trabalho servidor por inferência.

**Como realizar:**

1. Consumir somente a fachada congelada runtime.dispatch; renderizar os campos da fase 01 em módulo independente, sem reabrir backend.
2. Implementar estado loading/ready/stale/error e draft por thread/environment. Acionar request por callback tipado; efeitos e autorização pertencem ao servidor.
3. Adicionar IDs de acessibilidade estáveis e cenário browser/macOS que abra o módulo através do slot de teste de E0. A ligação nos arquivos compartilhados é exclusiva do gate E6.

### Dependências desta fase

```yaml
- id: DEP-0002-02-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0002-02-2
  tipo: componente_interno
  nome: "RFC-0002 fase 01"
  versão: "0.1.0"
  papel: "serviço e projeção tipados"
  fallback: "cache de leitura stale e ação desabilitada"
  obrigatória: true
- id: DEP-0002-02-3
  tipo: biblioteca
  nome: "SwiftUI + módulos ES nativos"
  versão: "Swift 6 / package-lock.json do PocketWiki"
  papel: "renderização e transporte por fachada"
  fallback: "não substituir por framework novo nesta lane"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface runtime.view.reduce exercitáveis sem integração com shell compartilhado
- [ ] fixtures reais sanitizadas, falhas e relatório de execução com SHA base e final
- [ ] todos os testes 02-01 a 02-04 passando
- [ ] nenhum arquivo fora da posse da lane alterado; mudanças compartilhadas entregues como instrução ao integrador

## 4. Cenários de Falha Transversais

### Entrada inválida / malformada
Rejeitar antes de I/O com ERR_INVALID. Validar schema, byte limits, enum fechado e referências; manter última revisão e draft. Mensagem de erro redigida com correlation_id.

### Dependência indisponível ou lenta
Deadline explícito retorna ERR_TIMEOUT/ERR_UNAVAILABLE. UI indica pending/stale e oferece ação coerente. Se comando já foi aceito, consultar receipt; indisponibilidade não autoriza executar no cliente.

### Estado inconsistente entre fontes de dados
Autoridade é PocketKernel. Revisão confirmada vence cache; projeção divergente é reconstruída por snapshot/eventos e não pela seleção local. Corrupção é visível e não resulta em apagar histórico silenciosamente.

### Concorrência / race condition
Compare-and-swap por revision e idempotência por command_id/hash; escritor serializado no servidor. Resposta antiga de outra thread/environment é descartada sem afetar o draft atual.

### Exaustão de recurso
Aplicar limites da fase antes de alocar, interromper leitura no teto e responder ERR_INVALID/erro específico de limite. Disk-full ou descriptor indisponível retorna ERR_UNAVAILABLE, preservando arquivo anterior e receipt confirmado; não continuar efeito sem persistência.

### Segurança — entrada controlada por ator externo
Validar principal/environment/scope em toda interface. Paths canonicalizados com roots explícitos; textos, títulos, tool output e memória são conteúdo inerte. Não interpolar shell, HTML ou secrets em logs. Export e UI usam allowlist redigida.

### Timeout em operação normalmente rápida
Usar deadline numérico desta RFC com relógio injetável nos testes. Não inferir conclusão/cancelamento por tempo local; consultar estado durável e preservar intenção incerta até reconciliação.

## 5. Decisões e Restrições

| ID | Decisão | Motivo | Reversível |
| --- | --- | --- | --- |
| DEC-01 | Estado de evolução Draft, completude COMPLETO | revisar proposta sem confundir com implementação | sim |
| DEC-02 | Autoridade de domínio em PocketKernel | preservar RFC-0001 e limites dos add-ons | não |
| DEC-03 | Capability antes de habilitar ação | providers/ambientes têm garantias diferentes | não |
| DEC-04 | Implementação própria, referência t3code fixada por SHA | rastrear origem sem depender de main móvel | sim |
| DEC-05 | Etapa só avança com revisão e E2E integrado | validar a união das worktrees e os contratos | não |
| DEC-06 | Limites acima são proposta explícita do PocketWiki | manter comportamento testável e revisável | sim |

**Alternativas descartadas:**
- Copiar aplicação t3code inteira: descartada porque PocketWiki já tem UI Swift, servidor Node, PocketKernel e MiddlewareAuth com domínios próprios.
- Executar efeito direto no cliente: descartada por quebrar autoridade do environment e idempotência.
- Testar apenas reducers com eventos pré-normalizados: descartada porque não valida adapter, transporte e persistência reais.

Evolução após revisão: atualizar este mesmo documento para 0.2.0 com changelog de decisão, gerar os 2 contratos na ordem do mapa, implementar lanes do plano e só então propor estado Accepted. Mudança incompatível de wire exige protocol major novo; status COMPLETO não permite pular gate.
