# RFCs da Pocket Stack

Este diretório contém propostas de interoperabilidade e evolução dos produtos Pocket. Uma RFC em `draft` pode orientar protótipos, mas não deve ser tratada como compatibilidade pública estável.

| RFC | Título | Estado |
| --- | --- | --- |
| [RFC-0001](0001-pocket-interop-contract.md) | Pocket Interop Contract | Draft |
| [RFC-0002 a RFC-0016](new-harness/README.md) | New Harness — evolução da aba IA, 15 RFCs e plano GPT-6-Luna | Draft 0.1.0 |

Os artefatos normativos da RFC-0001 ficam em:

- [`schemas/pocket-app-manifest.v1.schema.json`](schemas/pocket-app-manifest.v1.schema.json): manifesto de pacote ou integração;
- [`schemas/pocket-app-instance.v1.schema.json`](schemas/pocket-app-instance.v1.schema.json): descritor dinâmico de uma instância externa;
- [`schemas/pocket-event.v1.schema.json`](schemas/pocket-event.v1.schema.json): evento operacional redigido;
- [`examples/`](examples): exemplos iniciais para PocketKernel, MiddlewareAuth, PocketTrace, PocketCli, instância externa e falha de add-on.

Validação local:

```sh
./script/validate_pocket_interop_contract.sh
```
