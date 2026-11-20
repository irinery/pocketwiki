# Base imutável de integração E2

A etapa E2 parte do gate E1 aprovado na issue #39 e do run integrado [43664996560](https://github.com/irinery/pocketwiki/actions/runs/43664996560). Cada lane da etapa deve partir destes três commits, independentemente de outras lanes:

- PocketWiki: `d98f09bc4ae667c96c093c9f0b09134326ebb435`
- PocketKernel: `582e216c13feb7485fa9620d9543b272ec3794b5`
- MiddlewareAuth: `04f44f62126c785f7b28718d2eff837c28cb65df`

Schema SHA-256: `3eccb578c6f738a25e7d399539af2db7b7452c2cc1a34aca274ab19c2027d3fd`; fixture SHA-256: `daecf496f1d4cbde4067c2a1e746bb235722a59e36fd125f1226afca08c70121`; matriz SHA-256: `d0a1404c0dfae0bd330a21a0e95941dc76614aa6837dda01713a9635c368c95f`. Seed `20261102`; autenticação `host_local`.

O gate E1 e sua auditoria não aprovam E2. Para liberar a próxima etapa, o gate #40 deve agregar todos os 12 pares cumulativos no SHA integrado de E2, com as novas identidades e evidências exigidas.
