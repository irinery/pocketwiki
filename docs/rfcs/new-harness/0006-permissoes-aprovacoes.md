# RFC — Política, aprovações e perguntas estruturadas

**Projeto:** PocketWiki / New Harness. (RFC-0006)
**Data:** 2026-11-01
**Issue:** [#27](https://github.com/irinery/pocketwiki/issues/27)
**Estado de evolução:** Draft
**Versão da RFC:** 0.2.0
**Status:** COMPLETO
**Fases:** 2 arquivos a gerar
**Gerado por:** Codex, sessão New Harness

> COMPLETO significa especificação do draft preenchida; não significa aprovação, implementação ou estabilidade pública. Todos os endpoints harness.v1, módulos e limites abaixo são propostas. O endpoint atual POST /v1/kernel permanece compatível. Primitivos deste cabeçalho: uuid = UUID RFC 4122 canônico minúsculo; sha1 = 40 hex; sha256 = 64 hex; int = inteiro JSON seguro 0..9007199254740991 salvo exit_code, que aceita -255..255; string = UTF-8; `?` = opcional/ausente, nunca null implícito; array[T] = lista homogênea; enum[...] = lista fechada. Timestamps são int em ms UTC. Campos desconhecidos de comando são rejeitados; campos opcionais novos em resposta exigem minor negociado. Tipos são repetidos por fase. Regras de transporte, paginação, sessão e canonicalização são normativas em contratos-integracao-v0.2.md, que integra o cabeçalho desta RFC.

> Tipo transversal `HarnessError = {code:string (enum da interface), message:string (0..1024 bytes redigidos), correlation_id:uuid, retryable:bool}`. Em wire, bool = boolean JSON. Identidade e scopes são obtidos do transporte autenticado, nunca de um campo user_id escolhido pelo cliente.

## 1. Visão Geral

### 1.1 Problema
O contrato atual governa respostas, mas a UI não tem protocolo de aprovação de ferramentas nem distinção entre autorização de sessão e autorização de cada operação.

### 1.2 Solução
Aplicar política server-side com solicitações vinculadas a run, ação, principal e validade.

O recorte desta RFC é: Modos supervised, edits e full quando suportados; default proposto supervised; aprovação de comando/edição, recusa com motivo e perguntas com opções; revogação imediata.

### 1.3 Fora de escopo
Replicar auto-review proprietário de provider; autorização implícita por estar na tailnet; reutilizar aprovação em outra conta ou outro run.

**Origem e adaptação:** comportamento observado nos documentos abaixo da revisão `5732bbee397f0a2b0e61d0c2e432f01dca6df3dc`. A implementação proposta é própria e mantém domínio em PocketKernel. Limites e políticas deste draft pertencem ao PocketWiki e não são transcrição dos defaults do t3code.

- [docs/user/permission-modes.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/user/permission-modes.md)
- [docs/orchestration-v2/provider-capability-system.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/orchestration-v2/provider-capability-system.md)
- [docs/internals/environment-auth.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/internals/environment-auth.md)

## 2. Mapa de Fases

| Fase | Arquivo | Nome do componente | Depende de | Paralelizável com |
| --- | --- | --- | --- | --- |
| 01 | 01_permissions_dominio.md | Contrato e serviço de domínio | RFC-0002/01/02 | lanes backend da mesma etapa do plano, sem dependência entre elas |
| 02 | 02_permissions_cliente.md | Transporte/projeção e superfície cliente | 01 | lanes cliente da mesma etapa do plano, com diretórios exclusivos |

Arquivos de contrato serão gerados em `docs/technical-contract/new-harness/permissions/`; este draft entrega uma RFC inteira, não contratos parciais. A agenda global e os gates estão em `plano-worktrees.md`; cada fase só começa após dependências integradas no SHA base.

### Convenções globais
- PocketKernel é autoridade deste domínio; PocketWiki não lê store privado de integração externa.
- Auth por principal/environment + scope a cada ação. IDs de request e hashes não são credenciais.
- Erro de domínio serializa como `HarnessError {code:string, message:string, correlation_id:uuid, retryable:bool}`; message máximo 1024 bytes e redigida, code limitado à lista da fase.
- APIs propostas ficam sob `/v1/harness` no Kernel e `/api/harness` na fachada PocketWiki; o identificador canônico abaixo é a operação de domínio. E0 materializa o mapa da arquitetura e contratos-integracao-v0.2.md, sem decisões implícitas.
- Limites bytes são bytes UTF-8; limites em caracteres são Unicode scalars. Strings gerais 4096 bytes e arrays gerais 100 itens, salvo regra específica.

### Definition of Done global
- [ ] todos os cenários numerados das fases 01 e 02 executados através de interfaces reais
- [ ] JS e Swift aceitam/rejeitam o mesmo corpus de contratos
- [ ] revisão humana/técnica e E2E cumulativo no SHA integrado da etapa
- [ ] sem regressão em memória/sessões v1, wiki, MCP Evidence e modo externo
- [ ] nenhum secret em fixtures, logs, UI ou export

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
    tipo: "string?"
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

## 3.2 — Fase 02: Projeção e interface cliente

### O que é
Superfície web e macOS do domínio, consumindo o contrato confirmado sem executar efeitos diretamente na view. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Mostrar resultado, origem e estado de sincronização; manter seleção/draft e solicitar ações explícitas pela fachada.
- Expor navegação por teclado, foco e estados acessíveis em web 390/900/1440px e janela macOS compacta/regular.

**Fora do escopo deste componente:**
- Replicar auto-review proprietário de provider; autorização implícita por estar na tailnet; reutilizar aprovação em outra conta ou outro run.
- Executar subprocessos, ler filesystem local como substituto do servidor, acessar credencial de provider ou alterar regra de negócio.

**Dependências repetidas:** RFC-0006/01 + NH-00 + NH-TEST.

**Posse de arquivos:** `src/harness-ui/permissions/`, `Sources/PocketWikiMac/Views/Harness/Permissions/`, `Tests/HarnessUI/permissions/`.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 02-01 [caminho feliz]
dado: pergunta com opções e texto livre
quando: responder
então: resposta visível no nó correto sem virar consentimento de execução

TESTE 02-02 [falha]
dado: modo não suportado
quando: iniciar run
então: modo efetivo supervised explicitado antes do envio

TESTE 02-03 [edge case]
dado: pendência expira enquanto aberta
quando: confirmar
então: expired mostrado e controles não permitem aprovação tardia

TESTE 02-04 [segurança]
dado: comando com sequências ANSI/HTML
quando: abrir aprovação
então: conteúdo inerte; hash corresponde aos bytes canônicos do servidor

```

### Contratos de interface

```yaml
interface:
  id: IF-0006-02-1
  tipo: function
  nome: "permissions.view.reduce"
  entrada:
    - campo: previous
      tipo: "ViewState"
      obrigatório: true
      validação: "estado inicial ou revision válida"
    - campo: snapshot
      tipo: "FeatureSnapshot"
      obrigatório: true
      validação: "projeção persistida paginada; mesmo snapshot_id/environment/thread; nunca resposta de comando"
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

```yaml
tipo: FeatureSnapshot
campos:
  - nome: snapshot_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: as_of_seq
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: next_cursor
    tipo: "string?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: requests
    tipo: "array[PermissionRequest]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: ViewState
campos:
  - nome: environment_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: thread_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: status
    tipo: "enum[loading,ready,stale,error]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: draft
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: data
    tipo: "FeatureSnapshot?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: error
    tipo: "HarnessError?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
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

No cliente: renderizar 100 itens por página; draft 32768 bytes; erro 1024 bytes; request HTTP 30000 ms; 0 retries cegos de mutação e 0 fallback para outra identidade. Deadlines específicos da fase 01 prevalecem. Timeout visual não cancela trabalho servidor por inferência.

**Como realizar:**

1. Consumir somente a fachada congelada permissions.respond; renderizar os campos da fase 01 em módulo independente, sem reabrir backend.
2. Implementar estado loading/ready/stale/error e draft por thread/environment. Acionar request por callback tipado; efeitos e autorização pertencem ao servidor.
3. Adicionar IDs de acessibilidade estáveis e cenário browser/macOS que abra o módulo através do slot de teste de E0. A ligação nos arquivos compartilhados é exclusiva do gate E6.

### Dependências desta fase

```yaml
- id: DEP-0006-02-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0006-02-2
  tipo: componente_interno
  nome: "RFC-0006 fase 01"
  versão: "0.2.0"
  papel: "serviço e projeção tipados"
  fallback: "cache de leitura stale e ação desabilitada"
  obrigatória: true
- id: DEP-0006-02-3
  tipo: biblioteca
  nome: "SwiftUI + módulos ES nativos"
  versão: "Swift 6 / package-lock.json do PocketWiki"
  papel: "renderização e transporte por fachada"
  fallback: "não substituir por framework novo nesta lane"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface permissions.view.reduce exercitáveis sem integração com shell compartilhado
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

Evolução após revisão: atualizar este mesmo documento para 0.3.0 com changelog de decisão, gerar os 2 contratos na ordem do mapa, implementar lanes do plano e só então propor estado Accepted. Mudança incompatível de wire exige protocol major novo; status COMPLETO não permite pular gate.
