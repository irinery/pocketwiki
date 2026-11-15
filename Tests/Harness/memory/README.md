# RFC-0013 fase 01 — validação da lane

Estado: implementação em andamento; os testes atuais ainda não são evidência do gate E2.

Execute `node --test Tests/Harness/memory/service.test.mjs` na raiz da worktree. Os testes criam diretórios temporários isolados, usam `MemoryHarnessService` e `PocketMemoryStore` reais e os removem ao final. Não imprimem conteúdo das memórias; a saída contém nomes dos testes e diagnóstico de falhas. A suíte exercita cenários 01-01 a 01-05 e regressões de cursor e mapping; não cobre ainda autorização pelo host, atomicidade entre processos ou conformidade integral do snapshot. Registre SHA da worktree e os SHAs fixos de Kernel e MiddlewareAuth separadamente no relatório do integrador, sem incluir tokens ou paths pessoais.

O host de integração deve autenticar a identidade e scopes via credencial e registro ACL E0/E1, validar vínculo ao environment/projeto/thread antes de qualquer leitura e fornecer principal e grants verificados à facade. Nenhum campo de identidade ou scope escolhido no payload pode servir como autorização. Mutações precisam passar pelo ledger/CAS/receipt do runtime; leituras de snapshot e stream devem compartilhar boundary e retenção, aplicando R1. Esta facade provisória ainda aceita um objeto `auth` confiável diretamente e não conecta essas portas: não expô-la a clientes ou registrar handlers até integração e validação completas.

A validação Swift e o wiring final continuam pendentes. Não alterar o runner global nesta lane.
