# RFC-0016/01 — handoff parcial

Base PocketWiki `d98f09bc4ae667c96c093c9f0b09134326ebb435`; PocketKernel `582e216c13feb7485fa9620d9543b272ec3794b5`; MiddlewareAuth `04f44f62126c785f7b28718d2eff837c28cb65df` (não modificado). Esta lane não libera E2 nem declara integração de autenticação ou ledger.

`DiagnosticsService.snapshot` exige portas injetadas de autorização, probe e persistência; sem elas retorna `ERR_UNAVAILABLE`. A autorização deve validar principal, environment, run e scope usando identidade de transporte, antes de qualquer leitura. O probe deve usar runtime e supervisor existentes, sem controle de processo, e devolver somente saúde autorizada. O repositório de relatórios deve persistir e isolar por principal/environment/run; a facade não fornece store substituto. `export` exige uma porta de comando real que verifique autorização, preview atual, CAS e receipt e grave o arquivo; não implementa nenhuma dessas garantias. Não conecte portas que não as cumpram.

O contrato congelado `DiagnosticReport` não possui logs. A facade descarta logs e indica `truncated=true` quando solicitados; não satisfaz o caso completo 01-03. O preview é JSON UTF-8 exato de `previewBytes`; o SHA-256 só aprova esses mesmos bytes. `component_id` e `code` são allowlists locais provisórias para impedir vazamento; fontes adicionais exigem revisão da lista. O schema gerado permite `run_id: null`, mas o cabeçalho normativo da RFC especifica opcionais ausentes, nunca null; este módulo segue o cabeçalho.

Pendente: adapter sobre store existente no Kernel, projeção persistida com página/boundary/eventos e TTL (01-05), integração real com auth e receipt/ledger, probe real do bridge/MiddlewareAuth e transporte novo/legado, export para arquivo via porta de efeito, versão/capabilities e testes nas superfícies reais. Testes isolados aqui cobrem somente comportamentos locais com fronteiras injetadas, não os cenários completos 01-01 a 01-05 nem gate SERVICE-0016. O integrador deve validar versão e bytes de preview em todos os clientes e reconciliar o contrato de logs antes de habilitar o recurso.

Teste local: `node --test Tests/Harness/diagnostics/service.test.mjs`.
