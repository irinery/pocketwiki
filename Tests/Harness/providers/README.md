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
