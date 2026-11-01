# RFC — Projetos, worktrees e configuração por ambiente

**Projeto:** PocketWiki / New Harness. (RFC-0007)
**Data:** 2026-11-01
**Issue:** [#28](https://github.com/irinery/pocketwiki/issues/28)
**Estado de evolução:** Draft
**Versão da RFC:** 0.1.0
**Status:** COMPLETO
**Fases:** 2 arquivos a gerar
**Gerado por:** Codex, sessão New Harness

> COMPLETO significa especificação do draft preenchida; não significa aprovação, implementação ou estabilidade pública. Todos os endpoints harness.v1, módulos e limites abaixo são propostas. O endpoint atual POST /v1/kernel permanece compatível. Primitivos deste cabeçalho: uuid = UUID RFC 4122 canônico minúsculo; sha1 = 40 hex; sha256 = 64 hex; int = inteiro JSON seguro 0..9007199254740991 salvo exit_code, que aceita -255..255; string = UTF-8; `?` = opcional/ausente, nunca null implícito; array[T] = lista homogênea; enum[...] = lista fechada. Timestamps são int em ms UTC. Campos desconhecidos de comando são rejeitados; campos opcionais novos em resposta exigem minor negociado. Fase pode ser implementada com este cabeçalho + seu bloco: tipos são repetidos deliberadamente.

> Tipo transversal `HarnessError = {code:string (enum da interface), message:string (0..1024 bytes redigidos), correlation_id:uuid, retryable:bool}`. Em wire, bool = boolean JSON. Identidade e scopes são obtidos do transporte autenticado, nunca de um campo user_id escolhido pelo cliente.

## 1. Visão Geral

### 1.1 Problema
A wiki já tem root selecionado, porém isso não equivale a um workspace de execução isolado. A seleção global de provider também não representa overrides por projeto.

### 1.2 Solução
Registrar workspace no host de execução com branch, lease e configuração herdada explícita.

O recorte desta RFC é: Registrar repo existente, criar worktree a partir de SHA, scratch sem Git, criar/remover override, listar owner e limpar somente workspace próprio inativo.

### 1.3 Fora de escopo
Clonar/publicar todos os forges; instalar dependências automaticamente; copiar .env; compartilhar diretório mutável entre agentes sem lease.

**Origem e adaptação:** comportamento observado nos documentos abaixo da revisão `5732bbee397f0a2b0e61d0c2e432f01dca6df3dc`. A implementação proposta é própria e mantém domínio em PocketKernel. Limites e políticas deste draft pertencem ao PocketWiki e não são transcrição dos defaults do t3code.

- [docs/user/thread-sidebar.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/user/thread-sidebar.md)
- [docs/user/project-settings.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/user/project-settings.md)
- [docs/internals/overview.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/internals/overview.md)

## 2. Mapa de Fases

| Fase | Arquivo | Nome do componente | Depende de | Paralelizável com |
| --- | --- | --- | --- | --- |
| 01 | 01_workspaces_dominio.md | Contrato e serviço de domínio | RFC-0002/01/02 | lanes backend da mesma etapa do plano, sem dependência entre elas |
| 02 | 02_workspaces_cliente.md | Transporte/projeção e superfície cliente | 01 | lanes cliente da mesma etapa do plano, com diretórios exclusivos |

Arquivos de contrato serão gerados em `docs/technical-contract/new-harness/workspaces/`; este draft entrega uma RFC inteira, não contratos parciais. A agenda global e os gates estão em `plano-worktrees.md`; cada fase só começa após dependências integradas no SHA base.

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
Registrar workspace no host de execução com branch, lease e configuração herdada explícita. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Registrar repo existente, criar worktree a partir de SHA, scratch sem Git, criar/remover override, listar owner e limpar somente workspace próprio inativo.
- Persistir revisão/receipt e expor resultado tipado com erros observáveis.

**Fora do escopo deste componente:**
- Clonar/publicar todos os forges; instalar dependências automaticamente; copiar .env; compartilhar diretório mutável entre agentes sem lease.
- Editar views existentes, rotas globais e scripts de CI nesta lane.

**Dependências repetidas:** RFC-0002/01/02.

**Posse de arquivos:** PocketWiki: `src/harness/workspaces/`, `Sources/PocketWikiMac/Services/Harness/Workspaces/`, `Tests/Harness/workspaces/`. PocketKernel (outro repo): novo módulo lógico `harness/workspaces` e seus testes; adapter para store existente, sem substituir serviços privados de outro domínio.  Os paths são destinos propostos; arquivos atuais compartilhados só mudam pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 01-01 [caminho feliz]
dado: repo local e SHA válido
quando: criar 2 worktrees para 2 threads
então: diretórios/branches distintos com o mesmo SHA base

TESTE 01-02 [falha]
dado: git worktree add falha
quando: consultar inventário e repetir intenção
então: sem workspace pronto falso; reconciliação remove registro incompleto

TESTE 01-03 [edge case]
dado: root ancestral já em uso
quando: obter novo lease em subpasta
então: ERR_WORKSPACE_BUSY; zero execução concorrente

TESTE 01-04 [segurança]
dado: branch começando com opção, path traversal e repo com hook
quando: preparar workspace
então: entradas inválidas recusadas e hook não executado

```

### Contratos de interface

```yaml
interface:
  id: IF-0007-01-1
  tipo: function
  nome: "workspaces.prepare"
  entrada:
    - campo: project_id
      tipo: "uuid"
      obrigatório: true
      validação: "projeto autorizado"
    - campo: mode
      tipo: "enum[project,worktree,scratch]"
      obrigatório: true
      validação: "lista fechada"
    - campo: base_sha
      tipo: "sha1?"
      obrigatório: false
      validação: "40 hex; obrigatório em worktree"
    - campo: branch
      tipo: "string?"
      obrigatório: false
      validação: "git check-ref-format --branch; prefixo codex/"
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "titular do lease"
    - campo: settings_revision
      tipo: "int"
      obrigatório: true
      validação: ">= 0"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: workspace_id
          tipo: "uuid"
        - campo: relative_location
          tipo: "string"
        - campo: lease_id
          tipo: "uuid"
        - campo: effective_settings
          tipo: "WorkspaceSettings"
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
        - code: ERR_WORKSPACE_BUSY
          quando: "lease ativo/dirty/overlap"
          ação: "409; não remover nem conceder escrita"
        - code: ERR_GIT
          quando: "operação git falhou"
          ação: "502; reconciliar inventário"
        - code: ERR_SETTINGS_STALE
          quando: "settings_revision diverge"
          ação: "409; recarregar configuração"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

O envelope de transporte de comando é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Interface de view é local e não cria um endpoint HTTP novo.

**Interface complementar: workspaces.release**

```yaml
interface:
  id: IF-0007-01-2
  tipo: function
  nome: "workspaces.release"
  entrada:
    - campo: lease_id
      tipo: "uuid"
      obrigatório: true
      validação: "lease pertencente ao principal"
    - campo: remove
      tipo: "bool"
      obrigatório: true
      validação: "true exige idle e clean"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: state
          tipo: "enum[idle,retained,removed]"
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
        - code: ERR_WORKSPACE_BUSY
          quando: "lease ativo/dirty/overlap"
          ação: "409; não remover nem conceder escrita"
        - code: ERR_GIT
          quando: "operação git falhou"
          ação: "502; reconciliar inventário"
        - code: ERR_SETTINGS_STALE
          quando: "settings_revision diverge"
          ação: "409; recarregar configuração"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: workspaces.settings**

```yaml
interface:
  id: IF-0007-01-3
  tipo: function
  nome: "workspaces.settings"
  entrada:
    - campo: project_id
      tipo: "uuid?"
      obrigatório: false
      validação: "projeto autorizado ou defaults do environment"
    - campo: patch
      tipo: "WorkspaceSettings"
      obrigatório: true
      validação: "objeto fechado; não aceita credencial"
    - campo: reset
      tipo: "bool"
      obrigatório: true
      validação: "true remove override; patch desconsiderado"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: effective
          tipo: "WorkspaceSettings"
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
        - code: ERR_WORKSPACE_BUSY
          quando: "lease ativo/dirty/overlap"
          ação: "409; não remover nem conceder escrita"
        - code: ERR_GIT
          quando: "operação git falhou"
          ação: "502; reconciliar inventário"
        - code: ERR_SETTINGS_STALE
          quando: "settings_revision diverge"
          ação: "409; recarregar configuração"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: WorkspaceSettings
campos:
  - nome: provider_binding_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: permission_mode
    tipo: "enum[supervised,edits,full]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: base_branch
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: origin
    tipo: "enum[builtin,environment,project]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

```yaml
tipo: WorkspaceLease
campos:
  - nome: lease_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: workspace_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: state
    tipo: "enum[active,idle,retained]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: base_sha
    tipo: "sha1?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

### Regras de comportamento

1. Precedência de settings: builtin < environment < project. UI informa origem; reset remove override. Preferências visuais ficam no cliente.
2. Worktree nasce de SHA imutável, branch única codex/; lease de escrita exclusivo por root incluindo relações ancestral/descendente. Falha no git preserva inventário recuperável.
3. Scratch pertence a 1 thread e não expõe Git/checkpoints. Deletar thread retém arquivos até limpeza explícita.
4. Sem executar hooks/scripts do repo no preparo. Setup posterior é task explícita aprovada; .env e credenciais nunca são copiados.
5. Limpeza exige lease idle, worktree do harness e status Git limpo. Dirty, branch externa ou lease ativo retorna ERR_WORKSPACE_BUSY.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 32 workspaces ativos por environment; 1 lease de escrita por árvore; git timeout 30000 ms; branch 120 bytes; settings 16 KiB; 0 execução de setup implícita.

**Como realizar:**

1. Criar workspace registry/lease no Kernel; usar git via argv e diretório autorizado. Base SHA deve ser resolvido no servidor.
2. Adicionar settings por environment/projeto no mesmo domínio, usando revision e validação de tipos; não escrever UserDefaults do cliente remotamente.
3. Módulo visual próprio mostra branch, root lógico, lease e origem da preferência. Integração com seleção global da wiki somente no E6.

### Dependências desta fase

```yaml
- id: DEP-0007-01-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0007-01-2
  tipo: componente_interno
  nome: "RFC-0002 fases 01 e 02"
  versão: "0.1.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0007-01-3
  tipo: componente_interno
  nome: "PocketKernel"
  versão: "harness.v1 proposto"
  papel: "autoridade do domínio"
  fallback: "capability ausente: modo legado ou recurso indisponível; sem execução substituta"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface workspaces.prepare exercitáveis sem integração com shell compartilhado
- [ ] fixtures reais sanitizadas, falhas e relatório de execução com SHA base e final
- [ ] todos os testes 01-01 a 01-04 passando
- [ ] nenhum arquivo fora da posse da lane alterado; mudanças compartilhadas entregues como instrução ao integrador

## 3.2 — Fase 02: Projeção e interface cliente

### O que é
Superfície web e macOS do domínio, consumindo o contrato confirmado sem executar efeitos diretamente na view. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Mostrar resultado, origem e estado de sincronização; manter seleção/draft e solicitar ações explícitas pela fachada.
- Expor navegação por teclado, foco e estados acessíveis em web 390/900/1440px e janela macOS compacta/regular.

**Fora do escopo deste componente:**
- Clonar/publicar todos os forges; instalar dependências automaticamente; copiar .env; compartilhar diretório mutável entre agentes sem lease.
- Executar subprocessos, ler filesystem local como substituto do servidor, acessar credencial de provider ou alterar regra de negócio.

**Dependências repetidas:** RFC-0007/01 + NH-00 + NH-TEST.

**Posse de arquivos:** `src/harness-ui/workspaces/`, `Sources/PocketWikiMac/Views/Harness/Workspaces/`, `Tests/HarnessUI/workspaces/`.  Os paths são destinos propostos; arquivos atuais compartilhados só mudam pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 02-01 [caminho feliz]
dado: default de environment e override de projeto
quando: abrir settings e resetar
então: origem correta antes/depois, preferência visual local preservada

TESTE 02-02 [falha]
dado: workspace dirty
quando: solicitar limpeza
então: bloqueio com paths alterados e arquivos intactos

TESTE 02-03 [edge case]
dado: thread scratch
quando: abrir toolbar
então: nenhum controle Git/rollback de arquivos disponível

TESTE 02-04 [segurança]
dado: projeto removido ou de outro environment
quando: trocar seleção
então: sem fallback para filesystem local do cliente

```

### Contratos de interface

```yaml
interface:
  id: IF-0007-02-1
  tipo: function
  nome: "workspaces.view.reduce"
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
        - code: ERR_WORKSPACE_BUSY
          quando: "lease ativo/dirty/overlap"
          ação: "409; não remover nem conceder escrita"
        - code: ERR_GIT
          quando: "operação git falhou"
          ação: "502; reconciliar inventário"
        - code: ERR_SETTINGS_STALE
          quando: "settings_revision diverge"
          ação: "409; recarregar configuração"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

O envelope de transporte de comando é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Interface de view é local e não cria um endpoint HTTP novo.

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: WorkspaceSettings
campos:
  - nome: provider_binding_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: permission_mode
    tipo: "enum[supervised,edits,full]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: base_branch
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: origin
    tipo: "enum[builtin,environment,project]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

```yaml
tipo: WorkspaceLease
campos:
  - nome: lease_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: workspace_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: state
    tipo: "enum[active,idle,retained]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: base_sha
    tipo: "sha1?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

```yaml
tipo: FeatureSnapshot
campos:
  - nome: workspace_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: relative_location
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: lease_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: effective_settings
    tipo: "WorkspaceSettings"
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

1. Precedência de settings: builtin < environment < project. UI informa origem; reset remove override. Preferências visuais ficam no cliente.
2. Worktree nasce de SHA imutável, branch única codex/; lease de escrita exclusivo por root incluindo relações ancestral/descendente. Falha no git preserva inventário recuperável.
3. Scratch pertence a 1 thread e não expõe Git/checkpoints. Deletar thread retém arquivos até limpeza explícita.
4. Sem executar hooks/scripts do repo no preparo. Setup posterior é task explícita aprovada; .env e credenciais nunca são copiados.
5. Limpeza exige lease idle, worktree do harness e status Git limpo. Dirty, branch externa ou lease ativo retorna ERR_WORKSPACE_BUSY.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 32 workspaces ativos por environment; 1 lease de escrita por árvore; git timeout 30000 ms; branch 120 bytes; settings 16 KiB; 0 execução de setup implícita.

No cliente: renderizar 100 itens por página; draft 32768 bytes; erro 1024 bytes; request HTTP 30000 ms; 0 retries cegos de mutação e 0 fallback para outra identidade. Deadlines específicos da fase 01 prevalecem. Timeout visual não cancela trabalho servidor por inferência.

**Como realizar:**

1. Consumir somente a fachada congelada workspaces.prepare; renderizar os campos da fase 01 em módulo independente, sem reabrir backend.
2. Implementar estado loading/ready/stale/error e draft por thread/environment. Acionar request por callback tipado; efeitos e autorização pertencem ao servidor.
3. Adicionar IDs de acessibilidade estáveis e cenário browser/macOS que abra o módulo através do slot de teste de E0. A ligação nos arquivos compartilhados é exclusiva do gate E6.

### Dependências desta fase

```yaml
- id: DEP-0007-02-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0007-02-2
  tipo: componente_interno
  nome: "RFC-0007 fase 01"
  versão: "0.1.0"
  papel: "serviço e projeção tipados"
  fallback: "cache de leitura stale e ação desabilitada"
  obrigatória: true
- id: DEP-0007-02-3
  tipo: biblioteca
  nome: "SwiftUI + módulos ES nativos"
  versão: "Swift 6 / package-lock.json do PocketWiki"
  papel: "renderização e transporte por fachada"
  fallback: "não substituir por framework novo nesta lane"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface workspaces.view.reduce exercitáveis sem integração com shell compartilhado
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
