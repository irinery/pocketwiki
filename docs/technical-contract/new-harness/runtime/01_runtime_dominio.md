# RFC-0002/01 — Fronteira de transporte (parcial)

Base: PocketWiki `56c982e9f4e98750791df6e1ea17ab60830fc2c1`; fonte normativa: RFC-0002/01, `arquitetura-e-implementacao.md`, `contratos-integracao-v0.2.md` e schemas E0. O Kernel é autoridade de ledger, policy, outbox e recovery. A ponte não altera `PocketKernelClient`, rotas globais ou UI e não implementa fallback nem retry automático.

JavaScript `RuntimeTransport`: capabilities, dispatch, receipt, query, snapshot, stream HTTP bruto e payload referenciado. Valida comando E0 e igualdade dos campos repetidos antes de I/O; resposta dispatch usa `commandReceipt` E0. Snapshot valida envelope E0, boundary, limite somado de entidades por página e cursor de até 512 bytes. SSE é entregue como Response para consumidor posterior; ainda não faz parse, revalidação, referência, montagem ou projeção.

Swift `RuntimeTransport`: capabilities, dispatch, receipt, query e snapshot. Dispatch valida campos repetidos e enum, codifica UUIDs minúsculos e proíbe redirecionamento HTTP. Não há SSE Swift nem validação completa de todas as respostas/queries nesta entrega. Nenhum transporte deve ser ligado ao shell antes da integração e das verificações pendentes.

Ambiguidade resolvida pelo cabeçalho compartilhado: R1 define stream `/v1/harness/streams/thread/{id}` com envelope tipado, apesar da rota de eventos legada mencionada em RFC-0002/01. Não aceitar `{receipt,duplicate}` como resposta de dispatch: contrato E0 exige `{receipt_id,revision,state}`. Receipts confirmam intenção, não conclusão; em falha ambígua consultar receipt antes de qualquer nova tentativa.

Verificações executadas nesta entrega: testes de transporte Node com servidor HTTP real em loopback e compilação de tipos Swift. Não demonstram cenários 01-01 a 01-05, recovery, persistência, autorização efetiva, integração Kernel ou equivalência JS/Swift. A integração de fase 01 continua pendente desses cenários com serviços reais e do stream Swift; a fase 02 permanece serial e fora do escopo.
