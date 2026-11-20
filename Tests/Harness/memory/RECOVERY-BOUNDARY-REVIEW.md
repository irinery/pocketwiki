# Memória: fronteira de reconciliação para revisão

Estado: análise não aprovada, sem alteração de wire, execução ou política. Complementa [RECOVERY-CONTRACT.md](RECOVERY-CONTRACT.md); não autoriza ligar a facade ao runtime nem recuperar journals existentes. Referência de trabalho: PocketWiki `b1e74146a7d1d26de8081ef362c7330b90d1c5c1` e PocketKernel `bcedfe65db29dea9e92921f8b2798c9cf8450339`.

## Interfaces e limites atuais

- `src/harness/memory/service.mjs` e `PocketMemoryHarnessService` fazem validação e chamam stores scoped; suas portas de policy/association não constituem, por si, autoridade mantida durante o commit de arquivos. A identidade recebida precisa vir de host confiável.
- `serializeWrite` em `src/memory/store.mjs` serializa acesso à raiz mediante fila local e lock SQLite; sob esse lock rejeita qualquer `.capture-intent.json`, `.note-intent.json` ou `.import-intent.json` preexistente. O lock não participa da transação do ledger do Kernel e não prova revogação entre processos. A implementação Swift também bloqueia pendências; a equivalência de detalhes de locking deve ser verificada na integração, não presumida.
- `inspectRecoveryEnvelope`/`inspectRecoveryFile` são inspeção não-wire e retornam somente estado bloqueado. Hash valida integridade de bytes, não autorização; o receipt indicado no arquivo ainda não é consultado na autoridade.
- No Kernel, `harnessassociation.Borrow` usa transação emprestada e `Policy` do host; exige que o host forneça a associação e mantenha guardas até commit. Não implementa credencial, bridge ou origem de grants. `harnessauth.WithResourceGuardsDeadline` mantém verificações das credenciais e expiração sob a guarda da Store no processo, sem estabelecer autoridade distribuída.
- `ledger.ApplyTx` usa transação do host, reautoriza antes da deduplicação e exige callback de aplicação SQL local; não incorpora o commit dos arquivos de memória. As primitivas experimentais de efeito do ledger não são integração de memória nem demonstram atomicidade com esses arquivos.

## Fronteiras que o protocolo precisa fechar

| Momento observável | Evidência necessária | Sem essa evidência |
| --- | --- | --- |
| Admissão | Identidade derivada da credencial viva, scopes de memória, grants de cada recurso e associação thread/projeto quando aplicável, na autoridade do host. Vincular operação, namespace e bytes canônicos ao comando/receipt. | IDs, `scopes` e hashes do journal não autorizam a operação. |
| Reserva durável | Estado autoritativo que relacione command ID e hash ao receipt e à intenção exata, com deduplicação e conflito para conteúdo divergente. | Não é possível decidir se um journal pertence a comando aceito, se é órfão ou se foi substituído. |
| Aplicação nos arquivos | Limites de isolamento e serialização entre processos, efeito idempotente e revalidação conforme política aprovada; definir ponto de linearização e como a guarda permanece efetiva até ele. | Um callback booleano anterior ou o lock local não prova que a autoridade continuou válida. |
| Confirmação | Transição verificável do estado durável e publicação do resultado sob a autoridade exigida, incluindo tratamento de timeout ou disconnect. | Presença ou ausência do arquivo não comprova sucesso do receipt nem entrega ao cliente. |
| Reinício/reconciliação | Consultar autoridade e comparar identidade, namespace, operação, hash e estado; comprovar que outra instância não está aplicando a mesma intenção. | Preservar pendência e falhar fechado; não interpretar o arquivo como licença para replay. |

Como o ledger e os arquivos são domínios de commit distintos, a revisão deve explicar cada intervalo entre reserva, gravações e confirmação, inclusive falha parcial e repetição. Uma transação SQLite isolada no Kernel ou na facade não torna esses commits atômicos. A estratégia concreta de sincronização, idempotência e fencing ainda precisa ser especificada e implementada; o envelope proposto sozinho não a fornece.

## Decisões necessárias antes da implementação

1. Qual autoridade e qual processo podem reconciliar, como obtêm credencial e grants, e como revogação/expiração são coordenadas com aplicação e confirmação entre processos?
2. Uma intenção aceita antes de revogação pode ser aplicada após revogação? Definir também o comportamento de expiração e perda de associação. A resposta precisa distinguir intenção não aplicada, parcialmente aplicada e já aplicada; esta análise não escolhe uma política.
3. Como relacionar o receipt e seu estado aos bytes canônicos e ao namespace sem confiar em valores fornecidos pelo arquivo? Definir comportamento para receipt ausente, hash divergente, receipt terminal e comando repetido com payload diferente.
4. Qual é o ponto de linearização para cada operação (`capture_scoped`, `note.put`, `map_legacy`, `import`), incluindo arquivos múltiplos, CAS, `accepted_keys` e resultado consultável? Definir quais estados intermediários são recuperáveis e quando o estado é incerto.
5. Como um reconciliador prova exclusividade e evita que processo antigo continue escrevendo após reinício, troca de owner ou perda da guarda? Quais limites de storage, rename e durabilidade são assumidos e comprovados nas plataformas suportadas?
6. Como journals antigos sem vínculo autoritativo serão tratados, sem inferir principal ou receipt e sem alterar originais? O comportamento atual permanece bloqueado até decisão explícita.

## Evidências mínimas para revisão posterior

Em fixtures descartáveis com Kernel/host e stores reais JS e Swift, exercitar cada fronteira com barreiras determinísticas: falha antes/depois da reserva, entre escritas de arquivos e antes/depois da confirmação; reinício e concorrência de reconciliadores; retry idêntico e divergente; receipt ausente/incompatível; journal adulterado; isolamento de principal/environment/projeto/thread e associação; revoke/regrant e expiração antes/durante/depois da aplicação; CAS concorrente; consulta de receipt e publicação após disconnect. Demonstrar efeito no máximo uma vez quando o protocolo o prometer, preservação do estado confirmado e ausência de divulgação após negação. Testes devem indicar explicitamente quais ordens são forçadas e quais dependem do sistema operacional/storage; sem prova de perda de energia ou cross-UID, não alegá-las.

A execução desses cenários depende de protocolo e autorização aprovados. Este documento não solicita SIGKILL de processo owner, remoção de dados derivados ou modificação de dados reais. `Ready`, AUTH-REAL, SERVICE-0013 e gate E2 seguem abertos.
