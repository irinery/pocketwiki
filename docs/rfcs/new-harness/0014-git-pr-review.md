# RFC — Git, pull requests, revisão e settlement

**Projeto:** PocketWiki / New Harness. (RFC-0014)
**Data:** 2026-11-01
**Issue:** [#35](https://github.com/irinery/pocketwiki/issues/35)
**Estado de evolução:** Draft
**Versão da RFC:** 0.2.0
**Status:** COMPLETO
**Fases:** 2 arquivos a gerar
**Gerado por:** Codex, sessão New Harness

> COMPLETO significa especificação do draft preenchida; não significa aprovação, implementação ou estabilidade pública. Todos os endpoints harness.v1, módulos e limites abaixo são propostas. O endpoint atual POST /v1/kernel permanece compatível. Primitivos deste cabeçalho: uuid = UUID RFC 4122 canônico minúsculo; sha1 = 40 hex; sha256 = 64 hex; int = inteiro JSON seguro 0..9007199254740991 salvo exit_code, que aceita -255..255; string = UTF-8; `?` = opcional/ausente, nunca null implícito; array[T] = lista homogênea; enum[...] = lista fechada. Timestamps são int em ms UTC. Campos desconhecidos de comando são rejeitados; campos opcionais novos em resposta exigem minor negociado. Tipos são repetidos por fase. Regras de transporte, paginação, sessão e canonicalização são normativas em contratos-integracao-v0.2.md, que integra o cabeçalho desta RFC.

> Tipo transversal `HarnessError = {code:string (enum da interface), message:string (0..1024 bytes redigidos), correlation_id:uuid, retryable:bool}`. Em wire, bool = boolean JSON. Identidade e scopes são obtidos do transporte autenticado, nunca de um campo user_id escolhido pelo cliente.

## 1. Visão Geral

### 1.1 Problema
A aba IA não relaciona run/branch com revisão externa nem diferencia término do provider, finalização de arquivos e encerramento do trabalho após revisão.

### 1.2 Solução
Vincular threads a PRs e apresentar status/checks da revisão com ações explícitas e settlement decidido no servidor.

O recorte desta RFC é: GitHub como primeiro forge; status/diff/link de PR; criar PR draft após preview e autorização; comentário/review/merge explícitos; settlement opcional quando todos PRs terminais e nenhum run/fila pendente.

### 1.3 Fora de escopo
Paridade com todos os forges, stacks ou rebase automático; publicar comentário/merge sem ação explícita; tratar check externo desconhecido como sucesso.

**Origem e adaptação:** comportamento observado nos documentos abaixo da revisão `5732bbee397f0a2b0e61d0c2e432f01dca6df3dc`. A implementação proposta é própria e mantém domínio em PocketKernel. Limites e políticas deste draft pertencem ao PocketWiki e não são transcrição dos defaults do t3code.

- [docs/user/source-control.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/user/source-control.md)
- [docs/internals/overview.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/internals/overview.md)

## 2. Mapa de Fases

| Fase | Arquivo | Nome do componente | Depende de | Paralelizável com |
| --- | --- | --- | --- | --- |
| 01 | 01_source_control_dominio.md | Contrato e serviço de domínio | RFC-0002/01/02, RFC-0004/01, RFC-0006/01, RFC-0007/01, RFC-0008/01 | lanes backend da mesma etapa do plano, sem dependência entre elas |
| 02 | 02_source_control_cliente.md | Transporte/projeção e superfície cliente | 01 | lanes cliente da mesma etapa do plano, com diretórios exclusivos |

Arquivos de contrato serão gerados em `docs/technical-contract/new-harness/source-control/`; este draft entrega uma RFC inteira, não contratos parciais. A agenda global e os gates estão em `plano-worktrees.md`; cada fase só começa após dependências integradas no SHA base.

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
Vincular threads a PRs e apresentar status/checks da revisão com ações explícitas e settlement decidido no servidor. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- GitHub como primeiro forge; status/diff/link de PR; criar PR draft após preview e autorização; comentário/review/merge explícitos; settlement opcional quando todos PRs terminais e nenhum run/fila pendente.
- Persistir revisão/receipt e expor resultado tipado com erros observáveis.

**Fora do escopo deste componente:**
- Paridade com todos os forges, stacks ou rebase automático; publicar comentário/merge sem ação explícita; tratar check externo desconhecido como sucesso.
- Editar views existentes, rotas globais e scripts de CI nesta lane.

**Dependências repetidas:** RFC-0002/01/02, RFC-0004/01, RFC-0006/01, RFC-0007/01, RFC-0008/01.

**Posse de arquivos:** PocketWiki: `src/harness/source-control/`, `Sources/PocketWikiMac/Services/Harness/SourceControl/`, `Tests/Harness/source-control/`. PocketKernel (outro repo): novo módulo lógico `harness/source-control` e seus testes; adapter para store existente, sem substituir serviços privados de outro domínio.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 01-01 [caminho feliz]
dado: PR vinculado à branch com checks aprovados
quando: preparar/autorizar create_draft ou merge em forge fixture
então: ação publicada 1 vez e evento correlacionado à revisão exata

TESTE 01-02 [falha]
dado: rede cai depois do forge aceitar ação
quando: repetir intenção
então: consulta reconcilia resultado; nenhum comentário/PR duplicado

TESTE 01-03 [edge case]
dado: push muda head entre preview e confirmação
quando: confirmar review/merge
então: ERR_HEAD_CHANGED; nenhum envio

TESTE 01-04 [segurança]
dado: URL de PR de host não concedido ou principal read-only
quando: executar ação
então: ERR_FORBIDDEN e credencial não sai para host externo

TESTE 01-05 [integração]
dado: projeção válida com mais entidades que page_size e cache cliente apagado
quando: ler ao menos 2 páginas do mesmo snapshot enquanto ocorre mutação concorrente
então: snapshot consistente na boundary e evento posterior aplicado 1 vez, sem duplicação

```

### Contratos de interface

```yaml
interface:
  id: IF-0014-01-1
  tipo: function
  nome: "source_control.preview"
  entrada:
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread autorizada"
    - campo: operation
      tipo: "enum[link,create_draft,comment,review,merge]"
      obrigatório: true
      validação: "lista fechada"
    - campo: repository
      tipo: "string"
      obrigatório: true
      validação: "owner/repo da conexão autorizada"
    - campo: pr_number
      tipo: "int?"
      obrigatório: false
      validação: ">=1; obrigatório exceto create_draft"
    - campo: head_sha
      tipo: "sha1"
      obrigatório: true
      validação: "40 hex; revisão exata"
    - campo: body
      tipo: "string"
      obrigatório: true
      validação: "0..16384 bytes; texto editável no preview"
    - campo: host
      tipo: "string"
      obrigatório: true
      validação: "campos por variante conforme R3; URL nunca fornece credencial"
    - campo: title
      tipo: "string?"
      obrigatório: false
      validação: "campos por variante conforme R3; URL nunca fornece credencial"
    - campo: base_branch
      tipo: "string?"
      obrigatório: false
      validação: "campos por variante conforme R3; URL nunca fornece credencial"
    - campo: head_branch
      tipo: "string?"
      obrigatório: false
      validação: "campos por variante conforme R3; URL nunca fornece credencial"
    - campo: review_event
      tipo: "enum[comment,approve,request_changes]?"
      obrigatório: false
      validação: "campos por variante conforme R3; URL nunca fornece credencial"
    - campo: merge_method
      tipo: "enum[merge,squash,rebase]?"
      obrigatório: false
      validação: "campos por variante conforme R3; URL nunca fornece credencial"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: preview_id
          tipo: "uuid"
        - campo: request_id
          tipo: "uuid"
        - campo: action_sha256
          tipo: "sha256"
        - campo: head_sha
          tipo: "sha1"
        - campo: required_scope
          tipo: "enum[read,scm.write,scm.merge]"
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
        - code: ERR_HEAD_CHANGED
          quando: "SHA mudou"
          ação: "409; invalidar preview"
        - code: ERR_FORGE_UNAVAILABLE
          quando: "API/rate limit indisponível"
          ação: "503/429; respeitar Retry-After"
        - code: ERR_UNCERTAIN
          quando: "resultado da publicação desconhecido"
          ação: "409; reconciliar antes de retry"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

**Interface complementar: source_control.execute**

```yaml
interface:
  id: IF-0014-01-2
  tipo: function
  nome: "source_control.execute"
  entrada:
    - campo: preview_id
      tipo: "uuid"
      obrigatório: true
      validação: "preview ainda válido"
    - campo: action_sha256
      tipo: "sha256"
      obrigatório: true
      validação: "hash exibido ao usuário"
    - campo: head_sha
      tipo: "sha1"
      obrigatório: true
      validação: "head ainda coincide"
    - campo: approval_id
      tipo: "uuid"
      obrigatório: true
      validação: "aprovação de uso único vinculada ao preview"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: action_id
          tipo: "uuid"
        - campo: state
          tipo: "enum[pending,succeeded,failed,uncertain]"
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
        - code: ERR_HEAD_CHANGED
          quando: "SHA mudou"
          ação: "409; invalidar preview"
        - code: ERR_FORGE_UNAVAILABLE
          quando: "API/rate limit indisponível"
          ação: "503/429; respeitar Retry-After"
        - code: ERR_UNCERTAIN
          quando: "resultado da publicação desconhecido"
          ação: "409; reconciliar antes de retry"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: source_control.links**

```yaml
interface:
  id: IF-0014-01-3
  tipo: function
  nome: "source_control.links"
  entrada:
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread legível"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: links
          tipo: "array[PullRequestLink]"
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
        - code: ERR_HEAD_CHANGED
          quando: "SHA mudou"
          ação: "409; invalidar preview"
        - code: ERR_FORGE_UNAVAILABLE
          quando: "API/rate limit indisponível"
          ação: "503/429; respeitar Retry-After"
        - code: ERR_UNCERTAIN
          quando: "resultado da publicação desconhecido"
          ação: "409; reconciliar antes de retry"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: PullRequestLink
campos:
  - nome: host
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: repository
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: number
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: head_sha
    tipo: "sha1"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: state
    tipo: "enum[open,closed,merged,unknown]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: checks
    tipo: "enum[pending,passed,failed,unknown]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: ForgeAction
campos:
  - nome: preview_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: operation
    tipo: "enum[link,create_draft,comment,review,merge]"
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
  - nome: action
    tipo: "ForgePreview"
    obrigatório: true
    default: "ausente"
    limite: "conforme contratos-integracao-v0.2.md"
  - nome: request_id
    tipo: "uuid"
    obrigatório: true
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
  - nome: links
    tipo: "array[PullRequestLink]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: previews
    tipo: "array[ForgeAction]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

### Regras de comportamento

1. Preview não publica. Execução usa runtime.dispatch com approval vinculado a preview_id+action hash+head_sha. Push/merge/comentário sem resultado confirmado vira uncertain e reconcilia no mesmo host/conta.
2. Credencial GitHub fica no ambiente, nunca no cliente; escopo read não autoriza comentário/merge. Host e repo devem corresponder à conexão concedida.
3. Link inclui host/repo/número; múltiplos links por thread. Head alterado invalida preview e marcas viewed desse arquivo.
4. Atualizar links abertos a cada 120000 ms com clock injetável; rate limit respeita Retry-After, não muda de conta. Desconexão mantém cache marcado stale.
5. Auto-settle default false; se habilitado exige todos links fechados/merged, sincronização atual, fila vazia e sem run/approval ativo. Atividade nova antes do commit cancela settlement por CAS.
6. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 10 links por thread; 100 arquivos por página; preview TTL 300000 ms; poll 120000 ms; forge request 15000 ms; body 16384 bytes; 0 retry cego de mutação.

**Como realizar:**

1. Introduzir interface forge e primeiro adapter GitHub no Kernel; testes substituem só transporte HTTP do forge, mantendo domínio e policy.
2. Implementar preview e confirmação separados; correlacionar link por host/repo/number e revisão de head.
3. UI própria de revisão/PR mostra diff, checks, viewed por hash e botões explícitos; registrar settlement como evento servidor.

### Dependências desta fase

```yaml
- id: DEP-0014-01-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0014-01-2
  tipo: componente_interno
  nome: "RFC-0002 fases 01 e 02"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0014-01-3
  tipo: componente_interno
  nome: "RFC-0004 fase 01"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0014-01-4
  tipo: componente_interno
  nome: "RFC-0006 fase 01"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0014-01-5
  tipo: componente_interno
  nome: "RFC-0007 fase 01"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0014-01-6
  tipo: componente_interno
  nome: "RFC-0008 fase 01"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0014-01-7
  tipo: componente_interno
  nome: "PocketKernel"
  versão: "harness.v1 proposto"
  papel: "autoridade do domínio"
  fallback: "capability ausente: modo legado ou recurso indisponível; sem execução substituta"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface source_control.preview exercitáveis sem integração com shell compartilhado
- [ ] fixtures reais sanitizadas, falhas e relatório de execução com SHA base e final
- [ ] todos os testes 01-01 a 01-05 passando
- [ ] nenhum arquivo fora da posse da lane alterado; mudanças compartilhadas entregues como instrução ao integrador

## 3.2 — Fase 02: Projeção e interface cliente

### O que é
Superfície web e macOS do domínio, consumindo o contrato confirmado sem executar efeitos diretamente na view. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Mostrar resultado, origem e estado de sincronização; manter seleção/draft e solicitar ações explícitas pela fachada.
- Expor navegação por teclado, foco e estados acessíveis em web 390/900/1440px e janela macOS compacta/regular.

**Fora do escopo deste componente:**
- Paridade com todos os forges, stacks ou rebase automático; publicar comentário/merge sem ação explícita; tratar check externo desconhecido como sucesso.
- Executar subprocessos, ler filesystem local como substituto do servidor, acessar credencial de provider ou alterar regra de negócio.

**Dependências repetidas:** RFC-0014/01 + NH-00 + NH-TEST.

**Posse de arquivos:** `src/harness-ui/source-control/`, `Sources/PocketWikiMac/Views/Harness/SourceControl/`, `Tests/HarnessUI/source-control/`.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 02-01 [caminho feliz]
dado: PR aberto com checks unknown
quando: abrir revisão
então: unknown visível sem badge de sucesso

TESTE 02-02 [falha]
dado: thread com todos PRs merged mas novo run ativo
quando: aguardar sync
então: não settle até ausência de trabalho pendente

TESTE 02-03 [edge case]
dado: rascunho de comentário e head muda
quando: reabrir arquivo
então: rascunho preservado e exige reancorar linha

TESTE 02-04 [segurança]
dado: markdown de PR com HTML/script
quando: abrir preview
então: renderização sanitizada e links externos exigem navegação normal

```

### Contratos de interface

```yaml
interface:
  id: IF-0014-02-1
  tipo: function
  nome: "source-control.view.reduce"
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
        - code: ERR_HEAD_CHANGED
          quando: "SHA mudou"
          ação: "409; invalidar preview"
        - code: ERR_FORGE_UNAVAILABLE
          quando: "API/rate limit indisponível"
          ação: "503/429; respeitar Retry-After"
        - code: ERR_UNCERTAIN
          quando: "resultado da publicação desconhecido"
          ação: "409; reconciliar antes de retry"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: PullRequestLink
campos:
  - nome: host
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: repository
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: number
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: head_sha
    tipo: "sha1"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: state
    tipo: "enum[open,closed,merged,unknown]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: checks
    tipo: "enum[pending,passed,failed,unknown]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: ForgeAction
campos:
  - nome: preview_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: operation
    tipo: "enum[link,create_draft,comment,review,merge]"
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
  - nome: action
    tipo: "ForgePreview"
    obrigatório: true
    default: "ausente"
    limite: "conforme contratos-integracao-v0.2.md"
  - nome: request_id
    tipo: "uuid"
    obrigatório: true
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
  - nome: links
    tipo: "array[PullRequestLink]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: previews
    tipo: "array[ForgeAction]"
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

1. Preview não publica. Execução usa runtime.dispatch com approval vinculado a preview_id+action hash+head_sha. Push/merge/comentário sem resultado confirmado vira uncertain e reconcilia no mesmo host/conta.
2. Credencial GitHub fica no ambiente, nunca no cliente; escopo read não autoriza comentário/merge. Host e repo devem corresponder à conexão concedida.
3. Link inclui host/repo/número; múltiplos links por thread. Head alterado invalida preview e marcas viewed desse arquivo.
4. Atualizar links abertos a cada 120000 ms com clock injetável; rate limit respeita Retry-After, não muda de conta. Desconexão mantém cache marcado stale.
5. Auto-settle default false; se habilitado exige todos links fechados/merged, sincronização atual, fila vazia e sem run/approval ativo. Atividade nova antes do commit cancela settlement por CAS.
6. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 10 links por thread; 100 arquivos por página; preview TTL 300000 ms; poll 120000 ms; forge request 15000 ms; body 16384 bytes; 0 retry cego de mutação.

No cliente: renderizar 100 itens por página; draft 32768 bytes; erro 1024 bytes; request HTTP 30000 ms; 0 retries cegos de mutação e 0 fallback para outra identidade. Deadlines específicos da fase 01 prevalecem. Timeout visual não cancela trabalho servidor por inferência.

**Como realizar:**

1. Consumir somente a fachada congelada source_control.preview; renderizar os campos da fase 01 em módulo independente, sem reabrir backend.
2. Implementar estado loading/ready/stale/error e draft por thread/environment. Acionar request por callback tipado; efeitos e autorização pertencem ao servidor.
3. Adicionar IDs de acessibilidade estáveis e cenário browser/macOS que abra o módulo através do slot de teste de E0. A ligação nos arquivos compartilhados é exclusiva do gate E6.

### Dependências desta fase

```yaml
- id: DEP-0014-02-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0014-02-2
  tipo: componente_interno
  nome: "RFC-0014 fase 01"
  versão: "0.2.0"
  papel: "serviço e projeção tipados"
  fallback: "cache de leitura stale e ação desabilitada"
  obrigatória: true
- id: DEP-0014-02-3
  tipo: biblioteca
  nome: "SwiftUI + módulos ES nativos"
  versão: "Swift 6 / package-lock.json do PocketWiki"
  papel: "renderização e transporte por fachada"
  fallback: "não substituir por framework novo nesta lane"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface source-control.view.reduce exercitáveis sem integração com shell compartilhado
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
