# NH-TEST — pin ativo e bases históricas

## Pin ativo para E0

- PocketKernel: `ece7ed7439d552315a87b99ef94bd9fb85786cab` (merge da PR #14).

O runner e os hosts leem a primeira ocorrência de `PocketKernel` neste arquivo; o workflow E0 também fixa e verifica esse mesmo SHA. O pin ativo de MiddlewareAuth continua sendo o registrado abaixo.

## Bases imutáveis registradas antes da implementação

- PocketWiki: `5d516e59c6fcdf41a551f8725d1ca19d770d41c1` (`codex/nh-e0-nh00`, NH-00 aprovada; base exata do novo worktree).
- PocketKernel: `03f8f30eb781b4d16a9dca76f7548f9781bbef02` (`codex/nh00-locks`, checkout/worktree separada; NH-TEST não altera esse histórico).
- MiddlewareAuth: `04f44f62126c785f7b28718d2eff837c28cb65df` (`main`, checkout separado; não alterar arquivos locais preexistentes).
- Contratos documentais: PocketWiki `5311a8aae2876c572f25b79540f38ee0acac7121`; ancestral integrado `7703ac708120d93f54c7d29c5ad34dde9591a1bf`. PR documental #45 ainda não integrado.

Worktree nova PocketWiki: branch `codex/nh-e0-nh-test`, criada de `5d516e59c6fcdf41a551f8725d1ca19d770d41c1`. Registro gravado como primeiro commit, antes dos arquivos de implementação.

## Liberação de continuidade

O handoff acima está autorizado em [e0-handoff.md](e0-handoff.md). A branch atual é `codex/nh-e0-nhtest` (renomeada após a criação); o SHA-base é preservado. Merge em main, fechamento de #21 e aprovação de E0 não são pré-condições desta lane.

## Atualização posterior: integração AC-05

Os SHAs acima registram a base histórica de NH-TEST e não são alterados por esta atualização. A integração posterior parte de PocketWiki `22f966eccaa7cf2fffecd26570b319d26f0a969f` e usa PocketKernel `ece7ed7439d552315a87b99ef94bd9fb85786cab` (merge da PR #14); o workflow E0 fixa esse SHA e verifica o checkout. MiddlewareAuth permanece em `04f44f62126c785f7b28718d2eff837c28cb65df`.

O cliente AC-05 e esse Kernel precisam ser consumidos juntos: o verifier pertence à conexão UDS persistente, e o Kernel recusa credenciais desse owner após observar seu fechamento. Kernel antigo não oferece essa garantia; clientes que encerram a conexão depois do 204 invalidam a própria sessão. Um embed precisa usar `BootstrapServer`; a compatibilidade e o wiring de produção/E1 ainda não foram demonstrados por este pin. As evidências históricas E0 anteriores continuam vinculadas aos respectivos SHAs e precisam ser executadas novamente para este par; esta atualização não declara o gate aprovado.
