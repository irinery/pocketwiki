# Acompanhamento da integração E0

Atualização registrada em 14/11/2026 para complementar o histórico documental 0.2.0. O [PR documental #45](https://github.com/irinery/pocketwiki/pull/45) permanece em draft; esta página não altera as RFCs, a matriz ou os critérios de gate.

NH-00 e NH-TEST foram integrados nas branches de integração E0. O [PR #46](https://github.com/irinery/pocketwiki/pull/46) registrou a entrega do rig e uma execução agregada anterior com os três pares; essa evidência não aprova automaticamente os commits posteriores.

Após essa execução foram integradas correções: [#48](https://github.com/irinery/pocketwiki/pull/48) para o asset Markdown no início web, [#49](https://github.com/irinery/pocketwiki/pull/49) para vincular o bootstrap à sessão do host, [#50](https://github.com/irinery/pocketwiki/pull/50) para vincular o gate ao build e impor deadlines e [#51](https://github.com/irinery/pocketwiki/pull/51) para exigir listagem de processos antes do rig e ampliar a regressão Linux. O Kernel compatível com #49 foi fixado em `ece7ed7439d552315a87b99ef94bd9fb85786cab`.

A validação técnica de E0 passou no SHA integrado [`56c982e9f4e98750791df6e1ea17ab60830fc2c1`](https://github.com/irinery/pocketwiki/commit/56c982e9f4e98750791df6e1ea17ab60830fc2c1): o [run E0 43604501035](https://github.com/irinery/pocketwiki/actions/runs/43604501035) terminou com sucesso, com os três pares exigidos no `gate.json`, JUnit sem skips e regressão Linux verde. O [run de release 43604504073](https://github.com/irinery/pocketwiki/actions/runs/43604504073) também terminou com sucesso no mesmo SHA. O [run anterior 43601232330](https://github.com/irinery/pocketwiki/actions/runs/43601232330) se refere ao SHA `17b3e7cfd865fb3b9699889ef48a62304b000bed` e não substitui a evidência do SHA integrado.

A **decisão formal do gate E0 continua pendente** na [issue #38](https://github.com/irinery/pocketwiki/issues/38). E1 continua condicionado à aprovação de E0 conforme o plano.

Os textos de revisão e liberação inicial de E0 neste diretório preservam o estado e a decisão da época. Para execução e fechamento, prevalecem a evidência do SHA integrado e a decisão registrada no gate.
