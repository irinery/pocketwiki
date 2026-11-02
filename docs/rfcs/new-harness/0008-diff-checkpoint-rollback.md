# RFC — Diffs, checkpoints e restauração coordenada

**Projeto:** PocketWiki / New Harness. (RFC-0008)
**Data:** 2026-11-01
**Issue:** [#29](https://github.com/irinery/pocketwiki/issues/29)
**Estado de evolução:** Draft
**Versão da RFC:** 0.2.0
**Status:** COMPLETO
**Fases:** 2 arquivos a gerar
**Gerado por:** Codex, sessão New Harness

> COMPLETO significa especificação do draft preenchida; não significa aprovação, implementação ou estabilidade pública. Todos os endpoints harness.v1, módulos e limites abaixo são propostas. O endpoint atual POST /v1/kernel permanece compatível. Primitivos deste cabeçalho: uuid = UUID RFC 4122 canônico minúsculo; sha1 = 40 hex; sha256 = 64 hex; int = inteiro JSON seguro 0..9007199254740991 salvo exit_code, que aceita -255..255; string = UTF-8; `?` = opcional/ausente, nunca null implícito; array[T] = lista homogênea; enum[...] = lista fechada. Timestamps são int em ms UTC. Campos desconhecidos de comando são rejeitados; campos opcionais novos em resposta exigem minor negociado. Tipos são repetidos por fase. Regras de transporte, paginação, sessão e canonicalização são normativas em contratos-integracao-v0.2.md, que integra o cabeçalho desta RFC.

> Tipo transversal `HarnessError = {code:string (enum da interface), message:string (0..1024 bytes redigidos), correlation_id:uuid, retryable:bool}`. Em wire, bool = boolean JSON. Identidade e scopes são obtidos do transporte autenticado, nunca de um campo user_id escolhido pelo cliente.

## 1. Visão Geral

### 1.1 Problema
Não há contrato de diff por turno e restaurar filesystem sem coordenar conversa deixa a IA operando sobre estado que não existe mais.

### 1.2 Solução
Salvar checkpoints em refs privadas e restaurar somente após validar snapshot, exclusividade e rollback do provider.

O recorte desta RFC é: Snapshot antes/depois de run; diff por turno versus branch; preview e confirmação de restore para worktree exclusiva; preservação de dirty/untracked autorizados.

### 1.3 Fora de escopo
Reverter efeitos externos, produção ou banco; restaurar project root compartilhado; forçar provider que não suporta rollback; remover arquivos ignorados arbitrariamente.

**Origem e adaptação:** comportamento observado nos documentos abaixo da revisão `5732bbee397f0a2b0e61d0c2e432f01dca6df3dc`. A implementação proposta é própria e mantém domínio em PocketKernel. Limites e políticas deste draft pertencem ao PocketWiki e não são transcrição dos defaults do t3code.

- [docs/internals/overview.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/internals/overview.md)
- [docs/user/composer.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/user/composer.md)
- [docs/user/source-control.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/user/source-control.md)

## 2. Mapa de Fases

| Fase | Arquivo | Nome do componente | Depende de | Paralelizável com |
| --- | --- | --- | --- | --- |
| 01 | 01_checkpoints_dominio.md | Contrato e serviço de domínio | RFC-0002/01/02, RFC-0003/01, RFC-0006/01, RFC-0007/01 | lanes backend da mesma etapa do plano, sem dependência entre elas |
| 02 | 02_checkpoints_cliente.md | Transporte/projeção e superfície cliente | 01 | lanes cliente da mesma etapa do plano, com diretórios exclusivos |

Arquivos de contrato serão gerados em `docs/technical-contract/new-harness/checkpoints/`; este draft entrega uma RFC inteira, não contratos parciais. A agenda global e os gates estão em `plano-worktrees.md`; cada fase só começa após dependências integradas no SHA base.

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
Salvar checkpoints em refs privadas e restaurar somente após validar snapshot, exclusividade e rollback do provider. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Snapshot antes/depois de run; diff por turno versus branch; preview e confirmação de restore para worktree exclusiva; preservação de dirty/untracked autorizados.
- Persistir revisão/receipt e expor resultado tipado com erros observáveis.

**Fora do escopo deste componente:**
- Reverter efeitos externos, produção ou banco; restaurar project root compartilhado; forçar provider que não suporta rollback; remover arquivos ignorados arbitrariamente.
- Editar views existentes, rotas globais e scripts de CI nesta lane.

**Dependências repetidas:** RFC-0002/01/02, RFC-0003/01, RFC-0006/01, RFC-0007/01.

**Posse de arquivos:** PocketWiki: `src/harness/checkpoints/`, `Sources/PocketWikiMac/Services/Harness/Checkpoints/`, `Tests/Harness/checkpoints/`. PocketKernel (outro repo): novo módulo lógico `harness/checkpoints` e seus testes; adapter para store existente, sem substituir serviços privados de outro domínio.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 01-01 [caminho feliz]
dado: worktree exclusiva e provider capaz
quando: pré-visualizar e restaurar checkpoint
então: arquivos e cursor correspondem ao checkpoint e journal concluído

TESTE 01-02 [falha]
dado: provider rejeita rollback
quando: confirmar restore
então: ERR_UNSUPPORTED; hash de todos os arquivos permanece igual

TESTE 01-03 [edge case]
dado: edição humana entre preview e confirmação
quando: confirmar restore
então: ERR_CONTEXT_STALE; edição preservada

TESTE 01-04 [segurança]
dado: path malicioso ou outro thread usa subdiretório
quando: restaurar
então: ERR_FORBIDDEN/ERR_WORKSPACE_BUSY e nenhum arquivo alterado

TESTE 01-05 [integração]
dado: projeção válida com mais entidades que page_size e cache cliente apagado
quando: ler ao menos 2 páginas do mesmo snapshot enquanto ocorre mutação concorrente
então: snapshot consistente na boundary e evento posterior aplicado 1 vez, sem duplicação

```

### Contratos de interface

```yaml
interface:
  id: IF-0008-01-1
  tipo: function
  nome: "checkpoints.restore"
  entrada:
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread autorizada"
    - campo: checkpoint_id
      tipo: "uuid"
      obrigatório: true
      validação: "checkpoint do mesmo workspace"
    - campo: preview_sha256
      tipo: "sha256"
      obrigatório: true
      validação: "hash do plano de restore"
    - campo: workspace_revision
      tipo: "int"
      obrigatório: true
      validação: ">= 1; deve coincidir"
    - campo: approval_id
      tipo: "uuid"
      obrigatório: true
      validação: "aprovação específica válida"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: restore_id
          tipo: "uuid"
        - campo: status
          tipo: "enum[restored,recovery_required]"
        - campo: workspace_revision
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
        - code: ERR_UNSUPPORTED
          quando: "provider não suporta rollback"
          ação: "422; abortar antes do FS"
        - code: ERR_CONTEXT_STALE
          quando: "workspace mudou"
          ação: "409; exigir preview novo"
        - code: ERR_WORKSPACE_BUSY
          quando: "lease compartilhado/overlap"
          ação: "409; não restaurar"
        - code: ERR_RECOVERY_REQUIRED
          quando: "restore interrompido após mudança parcial"
          ação: "409; bloquear novos runs"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

**Interface complementar: checkpoints.capture**

```yaml
interface:
  id: IF-0008-01-2
  tipo: function
  nome: "checkpoints.capture"
  entrada:
    - campo: run_id
      tipo: "uuid"
      obrigatório: true
      validação: "run autorizado"
    - campo: boundary
      tipo: "enum[before,after]"
      obrigatório: true
      validação: "lista fechada"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: checkpoint
          tipo: "Checkpoint"
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
        - code: ERR_UNSUPPORTED
          quando: "provider não suporta rollback"
          ação: "422; abortar antes do FS"
        - code: ERR_CONTEXT_STALE
          quando: "workspace mudou"
          ação: "409; exigir preview novo"
        - code: ERR_WORKSPACE_BUSY
          quando: "lease compartilhado/overlap"
          ação: "409; não restaurar"
        - code: ERR_RECOVERY_REQUIRED
          quando: "restore interrompido após mudança parcial"
          ação: "409; bloquear novos runs"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: checkpoints.preview**

```yaml
interface:
  id: IF-0008-01-3
  tipo: function
  nome: "checkpoints.preview"
  entrada:
    - campo: checkpoint_id
      tipo: "uuid"
      obrigatório: true
      validação: "mesmo workspace autorizado"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: checkpoint_id
          tipo: "uuid"
        - campo: preview_sha256
          tipo: "sha256"
        - campo: files
          tipo: "array[FileDelta]"
        - campo: workspace_revision
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
        - code: ERR_UNSUPPORTED
          quando: "provider não suporta rollback"
          ação: "422; abortar antes do FS"
        - code: ERR_CONTEXT_STALE
          quando: "workspace mudou"
          ação: "409; exigir preview novo"
        - code: ERR_WORKSPACE_BUSY
          quando: "lease compartilhado/overlap"
          ação: "409; não restaurar"
        - code: ERR_RECOVERY_REQUIRED
          quando: "restore interrompido após mudança parcial"
          ação: "409; bloquear novos runs"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: checkpoints.diff**

```yaml
interface:
  id: IF-0008-01-4
  tipo: function
  nome: "checkpoints.diff"
  entrada:
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread legível"
    - campo: scope
      tipo: "enum[turn,branch]"
      obrigatório: true
      validação: "lista fechada"
    - campo: run_id
      tipo: "uuid?"
      obrigatório: false
      validação: "obrigatório em turn"
    - campo: base_sha
      tipo: "sha1?"
      obrigatório: false
      validação: "obrigatório em branch"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: files
          tipo: "array[FileDelta]"
        - campo: patch
          tipo: "string"
        - campo: truncated
          tipo: "bool"
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
        - code: ERR_UNSUPPORTED
          quando: "provider não suporta rollback"
          ação: "422; abortar antes do FS"
        - code: ERR_CONTEXT_STALE
          quando: "workspace mudou"
          ação: "409; exigir preview novo"
        - code: ERR_WORKSPACE_BUSY
          quando: "lease compartilhado/overlap"
          ação: "409; não restaurar"
        - code: ERR_RECOVERY_REQUIRED
          quando: "restore interrompido após mudança parcial"
          ação: "409; bloquear novos runs"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: Checkpoint
campos:
  - nome: checkpoint_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: run_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: workspace_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: git_ref
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: conversation_cursor
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: files
    tipo: "array[FileDelta]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: FileDelta
campos:
  - nome: relative_path
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: status
    tipo: "enum[added,modified,deleted,binary]"
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
  - nome: checkpoints
    tipo: "array[Checkpoint]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

### Regras de comportamento

1. Usar refs/pocketwiki/checkpoints/<uuid>; não criar commits na branch do usuário. Git object de checkpoint captura somente paths autorizados e não ignorados.
2. Preflight exige capability rollback, callback vivo, lease exclusivo incluindo diretórios sobrepostos, aprovação e workspace sem mudanças após preview.
3. Escrever journal restore-prepared e snapshot de segurança; rollback do provider precede alteração de arquivos. Se provider recusa, nenhum arquivo muda.
4. Falha após rollback do provider retém journal e workspace bloqueado recovery_required; reconciliar explicitamente, sem declarar restauração atômica entre Git e provider.
5. Diff de turno separa edição do agente de arquivos trazidos por pull/merge/rebase; branch diff mostra comparação completa. Binário mostra metadados, não patch textual.
6. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 100 checkpoints por thread; 100 MiB por checkpoint; diff textual 2 MiB; 500 arquivos por diff; restore 30000 ms; 0 retry automático de restore; 0 arquivo ignorado incluído automaticamente.

**Como realizar:**

1. Implementar store Git de checkpoints e journal coordenador no Kernel; nenhum git reset --hard genérico na UI.
2. Separar captura de base/after de cálculo de diff para não prolongar duração do provider. Registrar commit ancestry para diferenciar merge de edição própria.
3. UI própria apresenta escopo completo, dirty files incluídos e confirmação vinculada a preview hash.

### Dependências desta fase

```yaml
- id: DEP-0008-01-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0008-01-2
  tipo: componente_interno
  nome: "RFC-0002 fases 01 e 02"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0008-01-3
  tipo: componente_interno
  nome: "RFC-0003 fase 01"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0008-01-4
  tipo: componente_interno
  nome: "RFC-0006 fase 01"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0008-01-5
  tipo: componente_interno
  nome: "RFC-0007 fase 01"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0008-01-6
  tipo: componente_interno
  nome: "PocketKernel"
  versão: "harness.v1 proposto"
  papel: "autoridade do domínio"
  fallback: "capability ausente: modo legado ou recurso indisponível; sem execução substituta"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface checkpoints.restore exercitáveis sem integração com shell compartilhado
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
- Reverter efeitos externos, produção ou banco; restaurar project root compartilhado; forçar provider que não suporta rollback; remover arquivos ignorados arbitrariamente.
- Executar subprocessos, ler filesystem local como substituto do servidor, acessar credencial de provider ou alterar regra de negócio.

**Dependências repetidas:** RFC-0008/01 + NH-00 + NH-TEST.

**Posse de arquivos:** `src/harness-ui/checkpoints/`, `Sources/PocketWikiMac/Views/Harness/Checkpoints/`, `Tests/HarnessUI/checkpoints/`.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 02-01 [caminho feliz]
dado: turno altera 1 arquivo e merge traz 2
quando: abrir diff do turno e branch
então: turno mostra 1 alteração própria; branch mostra comparação completa

TESTE 02-02 [falha]
dado: crash durante restore após rollback do provider
quando: reabrir painel
então: recovery_required visível e envio bloqueado até reconciliação

TESTE 02-03 [edge case]
dado: diff binário e arquivo com rename
quando: abrir preview
então: metadados binários e caminho antigo/novo preservados

TESTE 02-04 [segurança]
dado: patch HTML com script
quando: renderizar diff
então: texto escapado e zero execução

```

### Contratos de interface

```yaml
interface:
  id: IF-0008-02-1
  tipo: function
  nome: "checkpoints.view.reduce"
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
        - code: ERR_UNSUPPORTED
          quando: "provider não suporta rollback"
          ação: "422; abortar antes do FS"
        - code: ERR_CONTEXT_STALE
          quando: "workspace mudou"
          ação: "409; exigir preview novo"
        - code: ERR_WORKSPACE_BUSY
          quando: "lease compartilhado/overlap"
          ação: "409; não restaurar"
        - code: ERR_RECOVERY_REQUIRED
          quando: "restore interrompido após mudança parcial"
          ação: "409; bloquear novos runs"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: Checkpoint
campos:
  - nome: checkpoint_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: run_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: workspace_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: git_ref
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: conversation_cursor
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: files
    tipo: "array[FileDelta]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: FileDelta
campos:
  - nome: relative_path
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: status
    tipo: "enum[added,modified,deleted,binary]"
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
    tipo: "string"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: checkpoints
    tipo: "array[Checkpoint]"
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

1. Usar refs/pocketwiki/checkpoints/<uuid>; não criar commits na branch do usuário. Git object de checkpoint captura somente paths autorizados e não ignorados.
2. Preflight exige capability rollback, callback vivo, lease exclusivo incluindo diretórios sobrepostos, aprovação e workspace sem mudanças após preview.
3. Escrever journal restore-prepared e snapshot de segurança; rollback do provider precede alteração de arquivos. Se provider recusa, nenhum arquivo muda.
4. Falha após rollback do provider retém journal e workspace bloqueado recovery_required; reconciliar explicitamente, sem declarar restauração atômica entre Git e provider.
5. Diff de turno separa edição do agente de arquivos trazidos por pull/merge/rebase; branch diff mostra comparação completa. Binário mostra metadados, não patch textual.
6. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 100 checkpoints por thread; 100 MiB por checkpoint; diff textual 2 MiB; 500 arquivos por diff; restore 30000 ms; 0 retry automático de restore; 0 arquivo ignorado incluído automaticamente.

No cliente: renderizar 100 itens por página; draft 32768 bytes; erro 1024 bytes; request HTTP 30000 ms; 0 retries cegos de mutação e 0 fallback para outra identidade. Deadlines específicos da fase 01 prevalecem. Timeout visual não cancela trabalho servidor por inferência.

**Como realizar:**

1. Consumir somente a fachada congelada checkpoints.restore; renderizar os campos da fase 01 em módulo independente, sem reabrir backend.
2. Implementar estado loading/ready/stale/error e draft por thread/environment. Acionar request por callback tipado; efeitos e autorização pertencem ao servidor.
3. Adicionar IDs de acessibilidade estáveis e cenário browser/macOS que abra o módulo através do slot de teste de E0. A ligação nos arquivos compartilhados é exclusiva do gate E6.

### Dependências desta fase

```yaml
- id: DEP-0008-02-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0008-02-2
  tipo: componente_interno
  nome: "RFC-0008 fase 01"
  versão: "0.2.0"
  papel: "serviço e projeção tipados"
  fallback: "cache de leitura stale e ação desabilitada"
  obrigatória: true
- id: DEP-0008-02-3
  tipo: biblioteca
  nome: "SwiftUI + módulos ES nativos"
  versão: "Swift 6 / package-lock.json do PocketWiki"
  papel: "renderização e transporte por fachada"
  fallback: "não substituir por framework novo nesta lane"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface checkpoints.view.reduce exercitáveis sem integração com shell compartilhado
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
