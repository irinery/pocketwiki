# E0 — handoff autorizado e responsabilidade dos chats

Esta decisão substitui condições anteriores conflitantes nos envios, plano e aceites das issues #21, #22 e #38. Ela autoriza continuar implementação sobre commits imutáveis já entregues; não aprova o gate E0.

## Dependência sem ciclo

NH-00 entrega base contratual → NH-TEST implementa/executa rig → revisão integrada GATE-E0 → E1.

NH-TEST não depende de gate E0 aprovado, issue #21 fechada ou SHA mesclado em main. Esses requisitos ficam removidos como pré-condições de desenvolvimento. O PR documental #45 aberto também não bloqueia o trabalho empilhado. Integração em main e fechamento das issues são atos posteriores, distintos do handoff. A base não deve ser descrita como mesclada quando não está.

Handoff autorizado nesta coordenação:

- PocketWiki NH-00: `5d516e59c6fcdf41a551f8725d1ca19d770d41c1`.
- PocketKernel: `03f8f30eb781b4d16a9dca76f7548f9781bbef02`.
- MiddlewareAuth: `04f44f62126c785f7b28718d2eff837c28cb65df`.
- NH-TEST existente antes desta correção: `61451cc888639164aa0000a1615e994c20e233dc`, descendente confirmado da base NH-00.

Não recriar/rebasear NH-TEST só para trocar sua base por main. Preservar commits e os arquivos não rastreados preexistentes. Um estado antigo blocked de chat não torna a pré-condição revogada obrigatória novamente.

## Posse e retomada

Chat `01a19566-e3bc-79e1-b478-712a57013287` (Implementar NH-00 no PocketWiki): possui apenas a worktree pocketwiki-nh00 e pocketkernel-nh00. Seu trabalho de continuidade é registrar o handoff e revisar o cumprimento dos AC-01…AC-08 da própria lane, concluindo a entrega NH-00 com as evidências existentes. Não implementar NH-TEST, não editar pocketwiki-nhtest nem assumir sua branch ao receber “continue”. Não esperar testes ou alterações do outro chat para declarar o handoff autorizado. Defeito novo de contrato deve ser entregue em commit separado e reportado como patch explícito; nunca mover a base consumida silenciosamente.

Chat `01a19567-1ac9-76a3-ad88-f2829caec846` (Implementar NH-TEST #22): único escritor de pocketwiki-nhtest, branch codex/nh-e0-nhtest, Tests/NewHarnessE2E e scripts do rig. Continuar da worktree existente incluindo o commit desta decisão. Não esperar merge, fechamento de issue ou gate E0 aprovado. Concluir o fluxo de teste e a rastreabilidade dos relatórios; não reimplementar NH-00.

Commits por entregas importantes em cada lane. Não usar amend/rebase/reset no trabalho da outra lane. Artefatos devem identificar o SHA efetivamente testado; os relatórios antigos de 4e60dc4 não são automaticamente evidência do HEAD 61451cc ou de mudanças seguintes.

## MacOS: dependência de ambiente, não de outra lane

Este host foi verificado com CommandLineTools, sem Xcode.app. Isso bloqueia executar XCTest aqui, mas não bloqueia implementar/revisar o host macOS, seu launcher, projeto e configuração de CI. NH-TEST deve preparar execução reproduzível em host com Xcode (CI macOS ou host disponível), fixando os três SHAs e dependências. Se o host requer provisionamento externo, registrar comando/entrada e dependência exata; continuar as tarefas independentes. Não repetir consultas a #21/main esperando uma mudança irrelevante.

Nenhum skip ou exit 2 pode virar aprovação. Gate E0 só passa com CONTRACT-00/service, LEGACY-00/web e LEGACY-00/macos reais, mesma base e hashes exigidos e agregador aprovado. E1 continua dependendo desse gate. Ausência de Xcode deixa somente a execução macOS/gate pendente; não desfaz o handoff NH-00→NH-TEST.
