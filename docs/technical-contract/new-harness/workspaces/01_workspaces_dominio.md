# RFC-0007/01 — Contrato de domínio de workspaces E2

Base: PocketWiki `d98f09bc4ae667c96c093c9f0b09134326ebb435`, PocketKernel `582e216c13feb7485fa9620d9543b272ec3794b5`, MiddlewareAuth `04f44f62126c785f7b28718d2eff837c28cb65df`. A [RFC-0007](../../../rfcs/new-harness/0007-projetos-worktrees.md) e [R1–R7](../../../rfcs/new-harness/contratos-integracao-v0.2.md) são normativos. Este documento não declara implementação ou gate concluído.

PocketKernel é autoridade do registro, configuração e leases. Cada mutação requer identidade e scope autenticados, CAS, receipt e idempotência de R1; cada leitura aplica policy. Nenhum ID, hash, diretório ou resultado de comando confere autorização. Estado visual deriva exclusivamente de projeção persistida e eventos, não da resposta do comando. R2/R3/R5 mantêm suas dependências de contexto, aprovação e lifecycle; R4 exige autenticação real apropriada à superfície; R6/R7 exigem evidência integrada e SHAs dos três repositórios.

| Operação | Input fechado | Resultado |
| --- | --- | --- |
| `workspaces.register_project` | `root_relative`, `title` | `project` |
| `workspaces.prepare` | `mode`, `thread_id`, `settings_revision`, `project_id?`, `base_sha?`, `branch?` | `workspace_id`, `relative_location`, `lease_id`, `effective_settings` |
| `workspaces.release` | `lease_id`, `remove` | `state: idle\|retained\|removed` |
| `workspaces.settings` | `project_id?`, `patch`, `reset` | `effective` |

`prepare` exige project para project/worktree e o proíbe em scratch; worktree exige SHA de 40 hex resolvido no servidor e branch `codex/` válida, até 120 bytes. Lease exclusivo cobre roots ancestrais e descendentes; até 32 workspaces ativos por environment. `release` só remove workspace próprio, idle, pertencente ao harness e limpo. Settings usa precedência builtin < environment < project, revisão explícita e limite 16 KiB, sem credenciais. Scratch pertence a uma thread e não oferece Git. Não executar hooks ou setup implícito, nem copiar `.env`.

A leitura paginada de `FeatureSnapshot` fixa `snapshot_id`, `revision` e `as_of_seq`; cursor opaco vincula principal e environment, expira em 600000 ms e não ultrapassa 512 bytes. Ordenação é por coleção e ID, no máximo 100 entidades somadas e 4 MiB por página. Cliente monta todas as páginas antes de trocar estado e aplica eventos posteriores à boundary exatamente uma vez. Entidade acima de 4 MiB é rejeitada na escrita.

Erros fechados da fase: `ERR_INVALID`, `ERR_FORBIDDEN`, `ERR_TIMEOUT`, `ERR_UNAVAILABLE`, `ERR_INCOMPATIBLE`, `ERR_WORKSPACE_BUSY`, `ERR_GIT`, `ERR_SETTINGS_STALE`. Consultar receipt em resultado ambíguo; nunca repetir efeito cegamente. A RFC especifica os tipos completos e limites adicionais.

## Situação de implementação e handoff

O componente Git isolado desta lane não é um serviço: exige intention durável e lease antes da chamada e não oferece policy, ledger, CAS, store, recovery ou projeção. Não ligar a helper a transporte público até implementar essas portas e os quatro comandos acima. A base E1 não expõe API genérica de transação de domínio no store runtime; o integrador precisa desenhar adapter transacional real, sem acessar estado privado por atalhos. Testes locais da helper não comprovam 01-01–01-05 por interfaces reais, nem o gate E2.
