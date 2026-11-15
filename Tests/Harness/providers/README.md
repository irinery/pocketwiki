# Providers: verificação local de projeção

Os testes abaixo exercitam somente a projeção isolada, não os cenários 01-NN completos e não liberam o gate E2.

```sh
node --test Tests/Harness/providers/projection.test.mjs
swiftc -parse-as-library \
  Sources/PocketWikiMac/Models/Harness/HarnessV1.swift \
  Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift \
  Sources/PocketWikiMac/Services/Harness/Providers/ProviderProjection.swift \
  Tests/Harness/providers/ProviderProjectionRunner.swift \
  -o /tmp/pocketwiki-providers-projection-test
/tmp/pocketwiki-providers-projection-test src/harness/contracts/harness-v1.schema.json Tests/Harness/providers/corpus.json
```

O integrador deve obter payload_ref na rota autenticada antes de fornecê-lo ao projetor, e conectar snapshot/stream de environment ao ledger compartilhado. As implementações não conectam UI nem shell. Ainda faltam ampliar o corpus de paridade JS/Swift e executar 01-05 com processos reais, store e eventos do runtime integrado.

O host responsável pela sessão deve chamar `setScope` com principal e geração de autorização em cada ativação ou alteração real; use `null` no JS ou `nil` no Swift ao desativar. O retorno é um **ticket local de autoridade**, não a geração do Kernel. Antes de iniciar qualquer fetch de snapshot, stream ou `payload_ref`, chame `beginRefresh` com esse ticket. O retorno é o **ticket do ciclo**: capture-o antes de cada `await` e passe esse mesmo ticket às operações da projeção ao receber as respostas. Um novo `beginRefresh` invalida os tickets de ciclos anteriores, inclusive quando revisão e sequência são iguais; uma nova ativação invalida também a autoridade anterior.

No JS, `readState`, `begin`, `append`, `buffer` e `apply` recebem o ticket do ciclo. Durante um refresh da mesma autoridade, o estado confirmado permanece visível até a última página válida e é substituído de uma vez, inclusive por um snapshot vazio. A mudança de autorização limpa esse estado imediatamente. No Swift, `ProviderProjection` roda no `MainActor`: `appendPage`, `bufferEvent` e `finish` recebem o ticket do ciclo, e `isCurrent` permite verificar o ticket depois de um `await` antes de aplicar sincronamente uma `View` na UI. O dono da UI deve substituir o estado completo apenas após `finish` e descartar `View`s copiadas em mudanças de autorização.

O checkout ainda não tem consumidor de produção dessa projeção nem um sinal confiável de mudança dos grants de conta do Kernel. `LocalCredentialHost` trata o ciclo do bearer, mas isso não comprova uma mudança de grant de provider. Logo, os tickets protegem a projeção somente quando o futuro dono da sessão os gira na ordem acima; não implementam autenticação, invalidação proativa do cache nem integração real com a autoridade de grants. Confira os limites e o contrato de integração em [HANDOFF.md](../../../src/harness/providers/HANDOFF.md).

O coordenador candidato stream-first também tem verificações locais:

```sh
node --test Tests/Harness/providers/stream-first.test.mjs Tests/HarnessUI/runtime/sse.test.mjs
swiftc -parse-as-library \
  Sources/PocketWikiMac/Models/Harness/HarnessV1.swift \
  Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift \
  Sources/PocketWikiMac/Services/Harness/Providers/ProviderProjection.swift \
  Sources/PocketWikiMac/Services/Harness/Providers/ProviderStreamFirst.swift \
  Tests/Harness/providers/ProviderStreamFirstRunner.swift \
  -o /tmp/pocketwiki-provider-stream-first-test
/tmp/pocketwiki-provider-stream-first-test src/harness/contracts/harness-v1.schema.json
```

O teste JS inclui HTTP loopback com servidor fixture; o Swift usa portas de teste.
Nenhum deles prova registro do watcher no Kernel real nem uma fonte de mudança
de grant de conta. Consulte o [handoff](../../../src/harness/providers/HANDOFF.md)
antes de ligar qualquer consumidor.
