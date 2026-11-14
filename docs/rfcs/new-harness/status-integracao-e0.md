# Acompanhamento da integração E0

Atualização registrada em 14/11/2026 para complementar o histórico documental 0.2.0. O [PR documental #45](https://github.com/irinery/pocketwiki/pull/45) permanece em draft; esta página não altera as RFCs, a matriz ou os critérios de gate.

NH-00 e NH-TEST foram integrados nas branches de integração E0. O [PR #46](https://github.com/irinery/pocketwiki/pull/46) registrou a entrega do rig e uma execução agregada anterior com os três pares; essa evidência não aprova automaticamente os commits posteriores.

Após essa execução foram integradas correções: [#48](https://github.com/irinery/pocketwiki/pull/48) para o asset Markdown no início web, [#49](https://github.com/irinery/pocketwiki/pull/49) para vincular o bootstrap à sessão do host [#50](https://github.com/irinery/pocketwiki/pull/50) para vincular o gate ao build e impor deadlines e [#51](https://github.com/irinery/pocketwiki/pull/51) para exigir listagem de processos antes do rig e ampliar a regressão Linux. O Kernel compatível com #49 foi fixado em `ece7ed7439d552315a87b99ef94bd9fb85786cab`.

O gate E0 **continua pendente**: estão em acompanhamento o [run E0 43604501035](https://github.com/irinery/pocketwiki/actions/runs/43604501035) e o [run de release 43604504073](https://github.com/irinery/pocketwiki/actions/runs/43604504073) para o SHA integrado `56c982e9f4e98750791df6e1ea17ab60830fc2c1`, seguidos da revisão e decisão na [issue #38](https://github.com/irinery/pocketwiki/issues/38). O run 43601232330 se refere ao SHA anterior `17b3e7c`. Não inferir aprovação para esse SHA a partir de runs anteriores. E1 continua condicionado à aprovação de E0 conforme o plano.

Os textos de revisão e liberação inicial de E0 neste diretório preservam o estado e a decisão da época. Para execução e fechamento, prevalecem a evidência do SHA integrado e a decisão registrada no gate.
