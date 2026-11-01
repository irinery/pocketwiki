# New Harness — evolução da aba IA

Draft 0.1.0 · 2026-11-01 · [Milestone New Harness.](https://github.com/irinery/pocketwiki/milestone/1)

Proposta de transformar a aba IA em superfície de agentes e conhecimento: runtime durável no PocketKernel, memória/evidência no PocketWiki e autenticação no MiddlewareAuth. A referência é o [t3code na revisão 5732bbee](https://github.com/pingdotgg/t3code/tree/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc), sem incorporar seu código neste pacote.

O recorte reúne 15 itens aproveitáveis, cada um em uma RFC inteira e uma issue própria. São 30 fases de contrato, com 120 cenários obrigatórios, além dos cenários E2E cumulativos. `Estado de evolução: Draft` é maturidade; `Status: COMPLETO` é completude da especificação proposta conforme a regra. Nenhum dos dois significa implementação ou aprovação. O pacote atual é documentação, não mudança de comportamento do produto.

## Como ler e executar

1. [Arquitetura e implementação](arquitetura-e-implementacao.md): estado atual, domínio de cada serviço, wire, APIs, migração, rollout e licenças.
2. [Plano de worktrees GPT-6-Luna](plano-worktrees.md): etapas E0–E6, dependências, posse de arquivos, subdivisões e prompt de delegação.
3. [Revisão e testes E2E determinísticos](testes-e2e.md): rig real, fixtures de fronteira, cenários, relatórios e condições dos gates.
4. [Regra de serialização fornecida](regra-serializacao-rfc.md): referência de formato usada em todas as RFCs. O pedido explícito desta sessão autorizou gerar os drafts; não houve nova confirmação intermediária.
5. [Manifesto](manifest.json): mapa verificável de IDs, dependências e etapas.

## RFCs

| RFC | Item | Autoridade do domínio | Fases 01 / 02 |
| --- | --- | --- | --- |
| [RFC-0002](0002-runtime-duravel.md) | Runtime durável, comandos e eventos | PocketKernel | E1 / E1 |
| [RFC-0003](0003-providers-capabilities.md) | Adapters, capabilities, modelos e contas | PocketKernel + MiddlewareAuth | E2 / E4 |
| [RFC-0004](0004-threads-runs-fila.md) | Threads, runs, streaming e fila de mensagens | PocketKernel | E3 / E5 |
| [RFC-0005](0005-composer-contexto.md) | Composer com contexto, anexos e citações | PocketWiki | E2 / E4 |
| [RFC-0006](0006-permissoes-aprovacoes.md) | Política, aprovações e perguntas estruturadas | PocketKernel | E2 / E4 |
| [RFC-0007](0007-projetos-worktrees.md) | Projetos, worktrees e configuração por ambiente | PocketKernel | E2 / E4 |
| [RFC-0008](0008-diff-checkpoint-rollback.md) | Diffs, checkpoints e restauração coordenada | PocketKernel | E3 / E5 |
| [RFC-0009](0009-terminal-tasks.md) | Terminal do ambiente e tasks acompanháveis | PocketKernel | E3 / E5 |
| [RFC-0010](0010-ambientes-remotos.md) | Ambientes remotos, pareamento e reconexão | PocketWiki + PocketKernel + MiddlewareAuth | E3 / E5 |
| [RFC-0011](0011-mcp-agentes-externos.md) | MCP de orquestração e agentes externos | PocketKernel | E3 / E5 |
| [RFC-0012](0012-fork-handoff-portavel.md) | Forks e handoff portável entre providers | PocketKernel | E3 / E5 |
| [RFC-0013](0013-memoria-evidencias.md) | Memória por escopo, proveniência e evidência da wiki | PocketWiki | E2 / E4 |
| [RFC-0014](0014-git-pr-review.md) | Git, pull requests, revisão e settlement | PocketKernel | E4 / E5 |
| [RFC-0015](0015-navegacao-inbox.md) | Navegação por threads, inbox e notificações | PocketKernel + PocketWiki | E4 / E5 |
| [RFC-0016](0016-diagnostico-compatibilidade.md) | Diagnóstico, compatibilidade e distribuição rastreável | PocketWiki + PocketKernel | E2 / E4 |

A RFC-0001 permanece no diretório pai e continua sendo a base de interoperabilidade. Cada RFC nova contém cabeçalho, visão geral, mapa de fases, testes/interface/dados/regras/dependências/entrega por fase, falhas transversais e decisões, nessa ordem. As interfaces complementares também são declaradas em blocos próprios. O gerador de contratos deve produzir `docs/technical-contract/new-harness/<module>/01_*.md` e `02_*.md` a partir de uma RFC completa, após revisão do draft.

## Inventário: observado, existente e adaptação

| Item observado no t3code | Situação no PocketWiki | Proposta específica |
| --- | --- | --- |
| Log de eventos, receipts/outbox e recuperação | cliente tem POST de resposta final e cancelamento local | 0002, execução durável sem duplicar efeitos incertos |
| Adapters, capabilities e várias contas | catálogo MiddlewareAuth e bridge de inferência já existem | 0003, bindings por run e agent Codex opcional, sem prometer todos os providers |
| Queue/steer, atividade e planos | sessão textual, bloqueio durante espera | 0004, timeline e fila persistida, sem inventar suporte nativo |
| Anexos, referências, quotes e drafts | contexto da wiki e picker de arquivos | 0005, manifesto verificável e documento como conteúdo não confiável |
| Modos de permissão e perguntas | governança do Kernel, sem protocolo de aprovação na UI | 0006, autorização por ação; default supervised é decisão nossa |
| Projetos, worktrees e overrides | root da wiki e preferências locais | 0007, lease de execução e precedência de configuração explícita |
| Diff por turno/branch e checkpoints | não há restore coordenado de agente nesta UI | 0008, ref privada + journal, com preflight de provider/lease |
| Terminal e task no host de execução | não há terminal integrado na IA | 0009, PTY/task e cursor, sem executar no dispositivo remoto cliente |
| Ambiente remoto, pairing e reconnect | endpoint remoto e contrato de integração parcial | 0010, conexão direta autenticada sem construir relay cloud |
| Controle de threads por MCP externo | MCP Evidence somente para conteúdo | 0011, servidor de controle separado com scopes/receipts |
| Fork e provider handoff | JSON portável restaura texto entre modelos | 0012, linhagem, budget e proveniência, sem copiar estado privado |
| Continuidade de contexto + inspiração ai-memory | memória local legível já implementada | 0013, evolução própria por escopo e evidência; não é recurso atribuído ao t3code como store ai-memory |
| Git/PR/review e settlement | sem ciclo de revisão na aba IA | 0014, primeiro forge GitHub com preview/head pinado |
| Sidebar/inbox/estado/notificações | menu de sessões sem inbox operacional | 0015, navegação persistente e transições acionáveis |
| Diagnóstico, versão e separação de processos | supervisores e hashes já existem | 0016, correlação e compatibilidade por capacidade |

Fontes específicas com links imutáveis ficam em cada RFC. O [README do t3code](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/README.md) descreve abertura a forks e limita contribuições grandes ao upstream. A [licença MIT](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/LICENSE) exige preservar avisos quando houver cópia substancial.

## Recorte e divergências conscientes

O recorte é a aba IA e seus serviços, não paridade integral com todo o produto t3code. Apps móveis nativos, relay T3 Connect, guest links públicos, captura de tela/snap-shot, voz, browser profiles, analytics cloud e todos os forges/providers ficam fora deste milestone. APIs futuras não são presumidas disponíveis no helper hoje empacotado.

Há divergência entre documentos do upstream sobre o algoritmo de handoff: a página de usuário descreve seleção de mensagens inteiras; a interna descreve resumo textual. A RFC-0012 documenta essa diferença e escolhe seleção determinística própria. Defaults numéricos, política supervised e escopos são decisões propostas do PocketWiki, não comportamento atribuído ao upstream.

A memória atual tem [documentação própria](../../ai-memory-model-agnostic.md) e inspiração [ai-memory](https://github.com/akitaonrails/ai-memory). Esta evolução mantém o formato próprio; não passa a consumir o servidor/MCP externo nem pressupõe compatibilidade com o estado atual daquele projeto.

## Evolução dos drafts

Depois da revisão, incorporar decisões no mesmo arquivo, subir versão para 0.2.0 e gerar contratos por fase. Antes de Accepted, não tratar o wire como compatibilidade pública estável. E0 congela a versão revisada para as lanes; qualquer mudança posterior precisa de schema/fixture e revisão de gate. Não fechar feature issue sem as duas fases e o gate correspondente.

O [índice de issues](issues.md) mantém os links separados de RFCs, habilitadores e gates. Os gates têm revisão e E2E sobre a união das worktrees, não só sobre cada PR isolado.
