# RFC-0006/01 — Contrato de domínio (draft 0.2.0)

Gerado da RFC-0006 0.2.0 e do cabeçalho normativo R1–R7. Não indica implementação ou gate aprovados.

> COMPLETO significa especificação do draft preenchida; não significa aprovação, implementação ou estabilidade pública. Todos os endpoints harness.v1, módulos e limites abaixo são propostas. O endpoint atual POST /v1/kernel permanece compatível. Primitivos deste cabeçalho: uuid = UUID RFC 4122 canônico minúsculo; sha1 = 40 hex; sha256 = 64 hex; int = inteiro JSON seguro 0..9007199254740991 salvo exit_code, que aceita -255..255; string = UTF-8; `?` = opcional/ausente, nunca null implícito; array[T] = lista homogênea; enum[...] = lista fechada. Timestamps são int em ms UTC. Campos desconhecidos de comando são rejeitados; campos opcionais novos em resposta exigem minor negociado. Tipos são repetidos por fase. Regras de transporte, paginação, sessão e canonicalização são normativas em contratos-integracao-v0.2.md, que integra o cabeçalho desta RFC.

> Tipo transversal `HarnessError = {code:string (enum da interface), message:string (0..1024 bytes redigidos), correlation_id:uuid, retryable:bool}`. Em wire, bool = boolean JSON. Identidade e scopes são obtidos do transporte autenticado, nunca de um campo user_id escolhido pelo cliente.


## 3.1 — Fase 01: Domínio e persistência

### O que é
Aplicar política server-side com solicitações vinculadas a run, ação, principal e validade. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Modos supervised, edits e full quando suportados; default proposto supervised; aprovação de comando/edição, recusa com motivo e perguntas com opções; revogação imediata.
- Persistir revisão/receipt e expor resultado tipado com erros observáveis.

**Fora do escopo deste componente:**
- Replicar auto-review proprietário de provider; autorização implícita por estar na tailnet; reutilizar aprovação em outra conta ou outro run.
- Editar views existentes, rotas globais e scripts de CI nesta lane.

**Dependências repetidas:** RFC-0002/01/02.

**Posse de arquivos:** PocketWiki: `src/harness/permissions/`, `Sources/PocketWikiMac/Services/Harness/Permissions/`, `Tests/Harness/permissions/`. PocketKernel (outro repo): novo módulo lógico `harness/permissions` e seus testes; adapter para store existente, sem substituir serviços privados de outro domínio.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 01-01 [caminho feliz]
dado: comando supervised pendente e identidade autorizada
quando: aprovar hash exibido
então: exatamente 1 execução e receipt de aprovação auditável

TESTE 01-02 [falha]
dado: callback live-only some após restart
quando: tentar responder
então: ERR_NOT_RESUMABLE; zero execução

TESTE 01-03 [edge case]
dado: 2 clientes respondem à mesma pendência
quando: aprovar e negar simultaneamente
então: apenas primeira revisão é aplicada; segunda ERR_CONFLICT

TESTE 01-04 [segurança]
dado: token válido sem scope de execução ou ação alterada
quando: aprovar
então: ERR_FORBIDDEN ou ERR_ACTION_CHANGED; zero efeito

TESTE 01-05 [integração]
dado: projeção válida com mais entidades que page_size e cache cliente apagado
quando: ler ao menos 2 páginas do mesmo snapshot enquanto ocorre mutação concorrente
então: snapshot consistente na boundary e evento posterior aplicado 1 vez, sem duplicação

TESTE 01-06 [integração]
dado: comando exibido com argv/cwd e hash canônico
quando: alterar ação no servidor antes de confirmar
então: ERR_ACTION_CHANGED e zero execução; pergunta sempre exibe texto completo

```

### Contratos de interface

```yaml
interface:
  id: IF-0006-01-1
  tipo: function
  nome: "permissions.respond"
  entrada:
    - campo: request_id
      tipo: "uuid"
      obrigatório: true
      validação: "pendência pertencente ao principal"
    - campo: request_revision
      tipo: "int"
      obrigatório: true
      validação: ">= 1; CAS"
    - campo: answer
      tipo: "enum[approve_once,deny,answer]"
      obrigatório: true
      validação: "tipo da pendência"
    - campo: text
      tipo: "string"
      obrigatório: true
      validação: "0..4096 bytes; answer exige texto ou option_id"
    - campo: option_id
      tipo: "string?"
      obrigatório: false
      validação: "ID dentre opções publicadas"
    - campo: action_sha256
      tipo: "sha256"
      obrigatório: true
      validação: "igual à ação exibida"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: request_id
          tipo: "uuid"
        - campo: status
          tipo: "enum[approved,denied,answered,expired,not_resumable]"
        - campo: revision
          tipo: "int"
        - campo: approval_id
          tipo: "uuid?"
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
        - code: ERR_ACTION_CHANGED
          quando: "hash diverge"
          ação: "409; invalidar decisão e pedir nova revisão"
        - code: ERR_NOT_RESUMABLE
          quando: "callback perdido"
          ação: "409; marcar not_resumable"
        - code: ERR_CONFLICT
          quando: "pendência já respondida"
          ação: "409; devolver estado atual"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

**Interface complementar: permissions.pending**

```yaml
interface:
  id: IF-0006-01-2
  tipo: function
  nome: "permissions.pending"
  entrada:
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread autorizada"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: requests
          tipo: "array[PermissionRequest]"
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
        - code: ERR_ACTION_CHANGED
          quando: "hash diverge"
          ação: "409; invalidar decisão e pedir nova revisão"
        - code: ERR_NOT_RESUMABLE
          quando: "callback perdido"
          ação: "409; marcar not_resumable"
        - code: ERR_CONFLICT
          quando: "pendência já respondida"
          ação: "409; devolver estado atual"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: permissions.mode**

```yaml
interface:
  id: IF-0006-01-3
  tipo: function
  nome: "permissions.mode"
  entrada:
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread autorizada"
    - campo: mode
      tipo: "enum[supervised,edits,full]"
      obrigatório: true
      validação: "lista fechada; scope próprio"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: effective_mode
          tipo: "enum[supervised,edits,full]"
        - campo: revision
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
        - code: ERR_ACTION_CHANGED
          quando: "hash diverge"
          ação: "409; invalidar decisão e pedir nova revisão"
        - code: ERR_NOT_RESUMABLE
          quando: "callback perdido"
          ação: "409; marcar not_resumable"
        - code: ERR_CONFLICT
          quando: "pendência já respondida"
          ação: "409; devolver estado atual"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: PermissionRequest
campos:
  - nome: request_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: run_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: node_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: kind
    tipo: "enum[command,edit,question,forge]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: action_sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: expires_at_ms
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: options
    tipo: "array[QuestionOption]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: action
    tipo: "PermissionAction"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: status
    tipo: "enum[pending,approved,denied,answered,expired,not_resumable]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: principal_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: QuestionOption
campos:
  - nome: id
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: label
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: ActionArgument
campos:
  - nome: value
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: EditPreview
campos:
  - nome: relative_path
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: before_sha256
    tipo: "sha256?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: after_sha256
    tipo: "sha256?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: patch
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: PermissionAction
campos:
  - nome: kind
    tipo: "enum[command,edit,question,forge]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: workspace_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: cwd_relative
    tipo: "string?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: argv
    tipo: "array[string]?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: edits
    tipo: "array[EditPreview]?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: question
    tipo: "string?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: options
    tipo: "array[QuestionOption]?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: forge
    tipo: "ForgePreview?"
    obrigatório: false
    default: "ausente"
    limite: "conforme contratos-integracao-v0.2.md"
```

```yaml
tipo: ForgePreview
campos:
  - nome: host
    tipo: "string"
    obrigatório: true
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: repository
    tipo: "string"
    obrigatório: true
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: operation
    tipo: "enum[link,create_draft,comment,review,merge]"
    obrigatório: true
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: pr_number
    tipo: "int?"
    obrigatório: false
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: head_sha
    tipo: "sha1"
    obrigatório: true
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: body
    tipo: "string"
    obrigatório: true
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: title
    tipo: "string?"
    obrigatório: false
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: base_branch
    tipo: "string?"
    obrigatório: false
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: head_branch
    tipo: "string?"
    obrigatório: false
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: review_event
    tipo: "enum[comment,approve,request_changes]?"
    obrigatório: false
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
  - nome: merge_method
    tipo: "enum[merge,squash,rebase]?"
    obrigatório: false
    default: "ausente"
    limite: "conforme R3 em contratos-integracao-v0.2.md"
```

### Snapshot persistido desta fase

```yaml
tipo: FeatureSnapshot
campos:
  - nome: snapshot_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: as_of_seq
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: next_cursor
    tipo: "string"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: requests
    tipo: "array[PermissionRequest]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

### Regras de comportamento

1. Autenticação do transporte não autoriza tool. Cada dispatch revalida principal, environment, root e scope. Negação tem precedência sobre full access.
2. Mode supervised exige aprovação para comando/edição; edits permite edição dentro de root; full permite ações no scope concedido. Se adapter não garante política solicitada, degradar para supervised com aviso antes do run.
3. Resposta vale uma vez para request_id+hash+run+node; ação alterada invalida pendência. Aprovação de filho aparece atribuída ao filho.
4. Callback live-only perdido em restart vira not_resumable; expirar não aprova. Pergunta de tarefa não é autorização de comando.
5. Revogar identidade bloqueia novas ações e respostas, fecha assinaturas e interrompe efeitos quando possível; efeito já concluído é registrado, não declarado desfeito.
6. PermissionAction é união fechada: command exige workspace_id,cwd_relative,argv; edit exige workspace_id,edits; question exige question,options; forge exige forge:ForgePreview. Campos de outras variantes são proibidos. argv 1..64 strings de até 4096 bytes; question 4096 bytes; edits até 100 paths, patch agregado até 65536 bytes. Não aprovar preview truncado; acima do teto rejeitar a solicitação.
7. action_sha256 = SHA-256 de RFC 8785 JCS de {principal_id,thread_id,run_id,node_id,action}. UI mostra exclusivamente action obtida do servidor, incluindo cwd e argumentos literais, e responde com esse hash. Conteúdo hostil é escapado, sem alteração dos bytes canônicos. approve_once retorna approval_id opaco vinculado a esse hash/identidade/run e consumível 1 vez; deny/answer não retornam approval_id.
8. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 100 pendências por environment; TTL 600000 ms; 10 opções por pergunta; 4096 bytes por resposta; 1 uso por aprovação; 0 aprovação automática após timeout.

**Como realizar:**

1. Implementar policy/requests no Kernel como consumidor de comandos duráveis; checar policy antes de produzir efeito.
2. Integrar callbacks reais de cada adapter sem inventar equivalência entre modos; MiddlewareAuth segue responsável pela identidade.
3. Criar painel de solicitação separado do composer; nunca misturar permission request e pergunta normal.

### Dependências desta fase

```yaml
- id: DEP-0006-01-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0006-01-2
  tipo: componente_interno
  nome: "RFC-0002 fases 01 e 02"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0006-01-3
  tipo: componente_interno
  nome: "PocketKernel"
  versão: "harness.v1 proposto"
  papel: "autoridade do domínio"
  fallback: "capability ausente: modo legado ou recurso indisponível; sem execução substituta"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface permissions.respond exercitáveis sem integração com shell compartilhado
- [ ] fixtures reais sanitizadas, falhas e relatório de execução com SHA base e final
- [ ] todos os testes 01-01 a 01-06 passando
- [ ] nenhum arquivo fora da posse da lane alterado; mudanças compartilhadas entregues como instrução ao integrador


---

# Contratos de integração — Draft 0.2.0

Este arquivo integra o cabeçalho normativo das RFCs 0002–0016. Define as interfaces entre domínios que E0 deve materializar em schemas/fixtures. É especificação, não implementação. `harness.v1` continua major 1/minor 0, pois 0.1.0 nunca foi uma versão pública implementada. As fases devem ser lidas com este cabeçalho compartilhado; não é permitido deduzir campos ausentes a partir da UI.

## R1 — Estado, resultado e recuperação

### Esclarecimentos normativos NH-00

- Campos comuns de `HarnessCommand` prevalecem como valores canônicos. Como RFC-0002 também mantém `command_id` e `expected_revision` dentro de `runtime.dispatch.input`, ambos devem ser iguais aos campos do envelope; divergência é `ERR_INVALID` antes de qualquer efeito. Os campos repetidos permanecem no wire para compatibilidade e `runtime.dispatch` é um comando fechado, não bloqueado.
- `obrigatório: false` permite omitir a propriedade. O sufixo `?` no tipo permite também o valor JSON `null` quando a propriedade aparece. Sem `?`, `null` é inválido mesmo para propriedades opcionais.
- `next_cursor` é opcional e não nullable em todos os snapshots e páginas: omitido encerra a paginação; `null` é `ERR_INVALID`. Nos blocos YAML, usar `tipo: "string"` com `obrigatório: false`.
- Em `navigation.update`, `read_through_seq` permanece obrigatório em todas as ações, conforme a lista de campos da interface; o valor só é aplicado quando `action=mark_read`. `before_thread_id` só é aceito em `reorder`.

`CommandReceipt` HTTP confirma intenção e corresponde ao schema fechado `httpCommandReceipt` da arquitetura. O nome legado de schema `commandReceipt` representa o `Result` de `runtime.dispatch` (`receipt_id`, `revision`, `state` accepted/duplicate), preservado no wire; `runtimeDispatchResult` é um alias desse schema. São formatos distintos e não intercambiáveis. `Result` contém o resultado tipado da operação. `FeatureSnapshot` contém a projeção durável do módulo e tem definição própria em cada RFC; resultado de `threads.message` nunca substitui histórico/fila. O snapshot inicial usa listas vazias e campos opcionais ausentes; não fabrica message_id/receipt_id.

`GET /v1/harness/threads/{thread_id}/snapshot?module=<module>&page_size=<1..100; default 100>&cursor=<cursor opcional>` devolve `{module:ModuleID,data:FeatureSnapshot}`. ModuleID é enum fechado dos 15 IDs de manifest.json. Para módulos de ambiente/projeto, usar `GET /v1/harness/environments/{environment_id}/snapshot?module=...&project_id=<uuid opcional>&cursor=...`; não inventar thread para listar ambientes/projetos. O servidor valida pertencimento e scopes antes de ler dados. page_size também vale para o endpoint de ambiente. IDs e parâmetros nunca substituem autorização.

Primeira página fixa `snapshot_id`, `revision`, `as_of_seq` e visão MVCC/cópia imutável. Cursor é opaco, até 512 bytes, vinculado a principal, environment, thread/projeto, módulo, snapshot e posição. TTL 600000 ms; page_size de 1..100, congelado no cursor, limita entidades somando todas as coleções e 4 MiB por página. Ordenação por nome de coleção e ID; fila por position/message_id, mensagens por source_seq/message_id. Campos singleton repetidos são idênticos em todas as páginas. `next_cursor` ausente encerra a leitura. Retenção de eventos posteriores à boundary é mantida durante TTL; se snapshot/retention se perder, responder 409 `ERR_CURSOR_EXPIRED` e reiniciar snapshot completo.

Cliente aplica a troca de estado somente após carregar todas as páginas. Enquanto carrega, armazena eventos posteriores à boundary, até 4 MiB; overflow descarta snapshot incompleto e reinicia. Após troca, deduplica por event_id/seq e aplica só seq > as_of_seq. IDs de threads/ambientes são parte da chave do cache. Snapshot velho nunca sobrescreve revisão nova. Perda de cache não apaga drafts locais.

Transporte HTTP: erro 400 `ERR_INVALID`, 403 `ERR_FORBIDDEN`, 404 `ERR_NOT_FOUND` (inclui recurso não visível), 409 `ERR_CURSOR_EXPIRED`, 426 `ERR_INCOMPATIBLE`, 503 `ERR_UNAVAILABLE`. Erros de snapshot são da fronteira de leitura, não precisam aparecer na lista de erros de uma mutação de outro domínio. SSE autenticado usa `GET /v1/harness/streams/{kind}/{aggregate_id}?after_seq=<int>&modules=<ModuleID separados por vírgula>`, kind=environment|thread. after_seq e Last-Event-ID, quando ambos presentes, devem coincidir; sem cursor, usar boundary do snapshot. Resposta text/event-stream, no-store; cursor perdido dá ERR_CURSOR_EXPIRED antes de abrir stream. Payload referenciado é recuperado por `GET /v1/harness/payloads/{payload_ref}` com mesma identidade/escopo. SSE usa ID seq e payload de evento tipado; offset_bytes de texto é UTF-8, contíguo, e ausência de trecho provoca resync. Snapshot pode exceder 1 frame SSE, mas uma entidade/evento acima de 256 KiB usa referência autenticada `payload_ref` no envelope com `payload` omitido; inline e referência exclusiva são discriminados por `delivery: inline|reference`. A leitura por payload_ref tem limite 4 MiB e mesma autorização. Nunca truncar evento silenciosamente.

Campos longos: ConversationMessage.content até 1 MiB para assistant e 32768 bytes para user; QueueEntry.text e ComposerDraft.text 32768 bytes; TimelineItem.text até 1 MiB; MemoryNote.content 16384 bytes; paths 4096 bytes; ContextSegment.content_base64 até 5592408 bytes, exclusivamente em resolve, não em snapshot. Limites específicos prevalecem sobre defaults gerais das RFCs.

Em E1/E2, autorização de IDs reservados usa o registro de agregados/ACL do host/runtime E0/E1, sem chamar threads ou workspaces futuros. Composer e memória não consultam serviços de outra lane E2. E3 associa esses IDs ao ciclo de vida de threads/workspaces reais, preservando owner e grants.

Chaves estáveis de projeção/evento (entity_key = JCS do valor/tupla abaixo, até 1024 bytes): RuntimeReceipt command_id; RuntimeEvent event_id; EffectRecord effect_id; ProviderBinding binding_id; ProviderCapabilities capability_id; ThreadState thread_id; ConversationMessage/QueueEntry message_id; RunRecord run_id; TimelineItem item_id; ComposerDraft draft_id; PermissionRequest request_id; ProjectRecord project_id; WorkspaceLease lease_id; WorkspaceSettings [environment_id,project_id ou null] do agregado; Checkpoint checkpoint_id; TerminalState terminal_id; EnvironmentConnection connection_id; MCPThreadSummary thread_id; ThreadLineage thread_id; MemoryNote [namespace.environment_id,namespace.project_id ou null,namespace.thread_id ou null]; PullRequestLink [host,repository,number]; ForgeAction preview_id; NavigationEntry thread_id; InboxNotification event_id; ComponentHealth component_id. A chave de `RuntimeEvent` é `JCS(event_id)`, incluindo as aspas JSON do UUID. Esta decisão é aditiva: os validadores E0 verificam a sintaxe JCS, mas ainda não vinculam `entity_key` ao valor de `event_id`; consumidores E1 devem produzir a chave canônica, e qualquer nova rejeição exige alteração e testes próprios. Posição/estado/versão nunca entram na chave. ProviderBinding.capability_id referencia ProviderCapabilities.capability_id; arrays não são ligados por índice. Campos repetidos de settings/thread são singulares do agregado; thread inexistente retorna 404, sem fabricar ThreadState. Terminal reidrata metadados por snapshot e bytes por terminal.read desde truncated_before, seguindo next_seq até output_cursor; exibe marcador de truncamento quando aplicável.

E0 registra os schemas de snapshot/evento de cada módulo. E1 materializa somente runtime; E2/E3 materializam seus módulos. Estado reconstruível de um módulo futuro não é prometido antes da etapa dele.

## R2 — Composer → thread → adapter

1. `composer.prepare` recebe pergunta e referências autorizadas, persiste bytes e retorna prepared_id, manifest_sha256, manifesto e expires_at_ms. Hash é SHA-256 de RFC 8785 JCS de `{environment_id,thread_id,principal_id,text,manifest}`; cada referência tem hash dos bytes. Sem referências, prepare é opcional.
2. `threads.message` recebe text + prepared_id + manifest_sha256 para enqueue/edit/steer com contexto. ID/hash são ambos presentes ou ambos ausentes. Não existem anexos implícitos herdados de outra thread. Alterar texto preparado exige novo prepare.
3. Kernel chama a porta `composer.pin` e `composer.resolve`, pela URL configurada do serviço de contexto do environment. Não aceita URL vinda da mensagem. Credencial de serviço delegada tem audience desse serviço e principal/environment/thread correspondentes. E0 fornece host local com bearer efêmero scoped; E3 acrescenta sessões remotas.
4. Persistir intenção de pin antes do I/O; pin é idempotente por command_id. Se crash ocorrer entre pin e aceitação de fila, reconciliar receipt e liberar pin órfão. Se resolve falhar, manter mensagem held e impedir chamada ao provider. Remoção/edição e término liberam pin via outbox idempotente. TTL sem pin: 86400000 ms.
5. PreparedContext mantém bytes imutáveis; hash da fonte é conferido ao preparar e ao aceitar nova intenção. Alteração posterior na fonte não muda contexto já aceito. Não reler arquivo vivo quando executar mensagem já enfileirada. Resume preserva o mesmo contexto; reenviar editado cria nova intenção.
6. Adapter recebe pergunta como mensagem user e referências como conteúdo atribuído `untrusted_content`; imagens usam canal de mídia apenas se suportado; threads valida capabilities do binding e retorna ERR_UNSUPPORTED antes de dispatch. Composer E2 valida somente formatos/bytes do staging, sem consultar providers da mesma etapa. Nunca elevar anexo para system/developer. Excluídos não aparecem no manifesto ou frames outbound.

`composer.resolve` retorna PreparedContext; erros fechados: ERR_INVALID (400), ERR_FORBIDDEN (403), ERR_CONTEXT_STALE (409: hash/texto/TTL), ERR_UNAVAILABLE (503), ERR_TIMEOUT (504). `composer.pin` retorna retained:bool e usa a mesma lista; retain=false é idempotente inclusive após liberação. Dados de contexto não entram nos logs de diagnóstico.

## R3 — Ação revisável e concessão de aprovação

PermissionAction é união discriminada por kind. PermissionRequest.kind deve ser igual a action.kind; options da request é igual a action.options para question e [] nas demais variantes. Command inclui argv literal, cwd relativo e workspace_id; edit inclui os patches completos e hashes before/after; question inclui texto e opções. forge inclui somente forge:ForgePreview. Campos de outra variante são proibidos. O servidor registra a ação imutável e calcula SHA-256/JCS de `{principal_id,thread_id,run_id,node_id,action}`. Não usar string renderizada, HTML ou texto redigido para gerar esse hash.

`permissions.pending` retorna requests com action completa e status. UI mostra esses dados, escapados, antes de habilitar decisão. Se preview excede 65536 bytes de patches/100 arquivos, negar criação com ERR_INVALID; não aprovar um resumo truncado. Command argv: 64 argumentos, 4096 bytes cada; pergunta: 4096 bytes e 10 opções.

`permissions.respond(approve_once)` retorna approval_id só depois do CAS bem-sucedido. Concessão é vinculada a principal/environment/thread/run/node/hash, validade até a pendência expirar e uso único. No consumo, checar novamente identidade, hash e estado; se ação mudou, ERR_ACTION_CHANGED, sem execução. Deny e answer não emitem concessão. O payload pode conter conteúdo sensível necessário à decisão; fica acessível só ao titular, e logs/export usam allowlist redigida.

Portas internas de permissões, entregues em E2 e autenticadas como serviço runtime (nunca aceitam identidade escolhida por cliente): `permissions.request({request_id:uuid,principal_id:uuid,environment_id:uuid,thread_id:uuid,run_id:uuid,node_id:uuid,action:PermissionAction,expires_at_ms:int}) -> PermissionRequest`; request_id idempotente, divergência dá ERR_CONFLICT. `permissions.consume({approval_id:uuid,principal_id:uuid,environment_id:uuid,thread_id:uuid,run_id:uuid,node_id:uuid,action_sha256:sha256,effect_id:uuid}) -> {authorized:bool}` faz CAS e registra effect_id; repetir o mesmo effect_id devolve a autorização anterior, outro efeito é recusado. Erros ERR_INVALID/ERR_FORBIDDEN/ERR_ACTION_CHANGED/ERR_EXPIRED/ERR_UNAVAILABLE. Expiração em 1..600000 ms; ações forge também obedecem ao TTL de preview de 300000 ms. A concessão e o efeito entram na mesma transação de ledger, sem consumir e perder autorização antes de persistir intenção. E2 testa essas portas com ação concreta e executor I/O mínimo, sem chamar workspaces/threads da mesma etapa.

ForgePreview fecha a aprovação de ações Git/PR: host é hostname da conexão autorizada, repository owner/repo, head_sha obrigatório; create_draft exige title (1..256 bytes), base_branch/head_branch (1..120), proíbe pr_number; link/comment/review/merge exigem pr_number>=1; review exige review_event; merge exige merge_method; campos de outra variante proibidos. body até 16384 bytes, vazio só em link/merge ou review=approve. source_control.preview persiste ForgePreview completo e cria PermissionRequest kind=forge por essas portas, devolvendo request_id. Para ação manual, run_id é o command_id durável e node_id é preview_id; essa convenção é namespace lógico de ação, não run fictício de provider. action_sha256 devolvido é exatamente o hash PermissionAction do R3, usado em execute/consume. required_scope=read para link, scm.merge para merge e scm.write para demais. Actor também precisa approve para conceder. Preview/hash/receipt não conferem scope. A variante forge é schema E0/serviço genérico de aprovação E2; só source-control E4 chama forge externo, mantendo independência das lanes.

## R4 — Pareamento e autenticação completos

Bootstrap local E0: host gera bearer efêmero aleatório de 32 bytes para processo Kernel em loopback, associa a principal local e lista de scopes concedidos e entrega por canal seguro de processo; só hash persiste no verificador. A credencial local expira em 900000 ms (`expires_at_ms` é incluído nos metadados entregues); autenticação no instante de expiração ou posterior retorna `ERR_EXPIRED`. Encerrar/reiniciar o host invalida todas as credenciais locais e não restaura verificadores ativos. Ambiente de teste usa store isolado; produção não aceita identidade arbitrária enviada pelo cliente. Esse mecanismo local permite testar E1/E2 sem antecipar pareamento remoto.

E3: módulo environments entrega os endpoints PocketWiki/Kernel e módulo exclusivo `internal/harness-sessions/` no repositório MiddlewareAuth. Provider adapters de E2 não editam esse módulo. API pública:

| Endpoint | Autenticação/entrada fechada | Saída | Falhas |
| --- | --- | --- | --- |
| POST /v1/harness/pairing/challenges | host/admin autenticado; `{requested_scopes:Scope[]}` | `{challenge_id:uuid,challenge_secret:string,server_fingerprint:sha256,expires_at_ms:int}` | 400 INVALID, 403 FORBIDDEN, 429 RATE_LIMIT, 503 UNAVAILABLE |
| POST /v1/harness/pairing/complete | challenge_secret autentica bootstrap; entrada de environments.pair | `{environment_id:uuid,connection_id:uuid,granted_scopes:Scope[],grant:SessionGrant}` | 400 INVALID, 403 PAIRING, 409 IDENTITY_CHANGED, 429 RATE_LIMIT, 503 UNAVAILABLE |
| POST /v1/harness/sessions/refresh | refresh_token autentica; `{session_id:uuid,refresh_token:string}` | `{grant:SessionGrant}` | 400 INVALID, 401 SESSION_EXPIRED, 403 REVOKED, 409 REFRESH_REUSED, 503 UNAVAILABLE |
| POST /v1/harness/connections/revoke | host/admin ou titular; `{connection_id:uuid}` | `{revoked:bool}` | 400 INVALID, 403 FORBIDDEN, 503 UNAVAILABLE |

Os códigos acima têm prefixo `ERR_` e usam HarnessError. São endpoints diretos, sem CommandReceipt: nunca gravar token/challenge/refresh na outbox, stream ou snapshot. TLS obrigatório fora de loopback, Content-Type JSON e Cache-Control no-store; credenciais jamais em URL. Origin web deve corresponder à allowlist configurada no host antes do bootstrap (inclui a origem do dispositivo pretendido); rejeitar Origin não permitido antes de consumir challenge. Cookie não é usado: resposta entrega bearer/refresh ao solicitante por TLS. Web guarda em sessionStorage, Mac em Keychain. Não enviar tokens de provider.

Scope é enum fechado `read,submit,approve,execute,context.read,memory.personal.read,memory.write,scm.write,scm.merge`; concessão efetiva é interseção da solicitação com a concessão explícita do host. scm.write/merge não são inferidos de read ou execute. Tokens de contexto delegados têm audience de PocketWiki/context; tokens de sessão têm audience do environment Kernel. Um token não é encaminhado a downstream como substituto de credencial própria.

Fingerprint = SHA-256 da chave pública Ed25519 estável da instância codificada em DER SubjectPublicKeyInfo. Comparação é com fingerprint mostrado no host previamente confiável, não com valor obtido somente do endpoint candidato. TLS deve ser validado normalmente. Mudar chave invalida pareamento; desafio TTL 300000 ms, 5 tentativas, consumo único. O host envia o desafio ao dispositivo por canal escolhido pelo usuário. O challenge fixa principal_id do host autenticado, environment_id e concessão; complete não aceita outro principal escolhido pelo cliente.

Contrato interno do MiddlewareAuth, sempre autenticado por credencial de serviço exclusiva com audience MiddlewareAuth/harness-sessions:

- `POST /v1/harness-sessions/issue`: entrada `{issuance_id:uuid,connection_id:uuid,principal_id:uuid,environment_id:uuid,scopes:Scope[],audience:string}`; saída SessionGrant. issuance_id idempotente; mesma tentativa retorna mesmo grant por até 300000 ms em armazenamento seguro. Sem correspondência entre identidade de serviço e audience/environment concedidos: ERR_FORBIDDEN.
- `POST /v1/harness-sessions/rotate`: `{session_id:uuid,refresh_token:string}` → SessionGrant. Rotação atômica invalida refresh anterior. Perda de resposta exige novo pareamento, sem replay de refresh consumido.
- `POST /v1/harness-sessions/introspect`: `{access_token:string,audience:string}` → `{active:bool,session_id:uuid?,principal_id:uuid?,environment_id:uuid?,scopes:Scope[],expires_at_ms:int?}`. Inativo devolve active=false/scopes=[] sem identidade. Token de audience diferente é inativo.
- `POST /v1/harness-sessions/revoke`: `{connection_id:uuid}` → `{revoked:bool}`; invalida família de sessões/refresh antes do ack, idempotente.

Os erros de R4 complementam as listas locais da RFC-0010 para os respectivos endpoints; ERR_TIMEOUT também é permitido na fronteira pública. Não aplicar recuperação por receipt aos endpoints de bootstrap.

SessionGrant é `{session_id:uuid,principal_id:uuid,access_token:string,refresh_token:string,token_type:Bearer,expires_at_ms:int,refresh_expires_at_ms:int,audience:string,scopes:Scope[]}`. Tokens opacos de 32 bytes aleatórios base64url, access TTL 900000 ms, refresh TTL absoluto 2592000000 ms. Fora do cache curto de resposta idempotente de issue, guardar hashes dos tokens. Operações internas têm deadline 5000 ms, payload máximo 16 KiB e erros ERR_INVALID/ERR_FORBIDDEN/ERR_UNAVAILABLE/ERR_TIMEOUT; rotate também ERR_SESSION_EXPIRED/ERR_REVOKED/ERR_REFRESH_REUSED.

Pairing mantém reservation de challenge + issuance_id até confirmar issue; concorrente não cria segunda conexão. Falha antes de grant mantém challenge reservado para retry pelo mesmo secret/issuance; retorno idempotente máximo 300000 ms, depois novo challenge. Nenhum retry cego em rotate. Todas as chamadas mutantes fazem introspecção sem cache positivo; indisponibilidade falha fechada 503. SSE revalida a cada 500 ms e em revogação; a chamada de introspecção de stream tem deadline 500 ms (mais restritivo que o default interno), e timeout fecha o stream. Assim, desconexão ocorre no máximo 1000 ms após revogação. Timer é injetável no teste, não sleep real.

## R5 — Histórico e dependências

RFC-0004/01 entrega em E3 `threads.history` com HistoryPage e mensagens completas, roles e source_seq. through_seq fixa boundary concluída; paginação de 100 mensagens, 4 MiB, TTL 600000 ms. Não usar snippet do recall como substituto. RFC-0011 e 0012 passam a E4, dependem explicitamente de 0004/01; MCP também depende de environments/01 para autenticação remota. RFC-0002 não implementa uma porta ThreadControl fictícia nem duplica histórico de mensagens.

MCP start exige binding_id/message_id e cria thread por threads.create antes de threads.message; send exige thread_id/binding_id/message_id/queue_revision; interrupt exige thread_id/queue_revision; read exige thread_id e through_seq (ou obtém a última boundary concluída no serviço threads na primeira página); list não aceita campos de mutação; pagina pelo snapshot de summaries de ambiente R1, retornando MCPThreadPage com snapshot_id/as_of_seq/next_cursor, sem usar seq de thread como cursor global. after_seq só filtra eventos do stream de um agregado, não pagina a lista de threads. command_id é obrigatório só em mutações. Leitura usa porta query, mutações a porta commands. O registry discrimina mcp.thread.call também pelo campo tool.

Cada lane publica contrato/handler no seu diretório. Integrador de cada etapa faz wiring mínimo de serviços, sem alterar domínio; shell final só E6. Thread creation/workspace/provider binding/contexto são integrados em E3, depois das portas E2. No checkpoint E3, providers/policy/leases já existem em E2; nova dependência providers/01 está explícita.

## R6/R7 — Evidência exigida

Diagnostics E2 usa probes do runtime e bridge/MiddlewareAuth legado já existente; não depende do módulo providers E2. Probes de módulos futuros só são registrados pelo integrador depois da entrega. Providers E2 é exercitado por driver de adapter real, sem ciclo de vida threads E3. Environments E3 prova sessão com runtime E1; sua integração com threads/UI é posterior.

E1 usa integração real de ledger/outbox com executor mínimo de I/O, sem LLM. E2–E4 usam integrações reais dos serviços já entregues. E4/E5 acrescentam testes browser/macOS de módulos /02. E6 executa pelo shell de produção toda a cadeia, incluindo MiddlewareAuth real, issuer/introspection/rotate/revoke reais e apenas provider/forge externos simulados.

A matriz de testes define introdução, interfaces exercitadas e superfícies exigidas; gate só aceita conjunto completo de pares cenário/superfície. Um teste web isolado não libera macOS. Relatório guarda SHA do MiddlewareAuth além de PocketWiki/Kernel. Iniciar E0 significa executar NH-00/NH-TEST; não significa declarar gate E0 aprovado, implementar etapas seguintes ou habilitar features em produção.
