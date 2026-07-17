# RFCs da Pocket Stack

Este diretório contém contratos propostos para interoperabilidade entre os projetos Pocket. Uma RFC em `draft` pode orientar protótipos, mas não deve ser tratada como compatibilidade pública estável.

| RFC | Título | Estado |
| --- | --- | --- |
| [RFC-0001](0001-pocket-interop-contract.md) | Pocket Interop Contract | Draft |

Os artefatos normativos da RFC-0001 ficam em:

- [`schemas/pocket-app-manifest.v1.schema.json`](schemas/pocket-app-manifest.v1.schema.json): manifesto de pacote ou integração;
- [`schemas/pocket-app-instance.v1.schema.json`](schemas/pocket-app-instance.v1.schema.json): descritor dinâmico de uma instância externa;
- [`schemas/pocket-event.v1.schema.json`](schemas/pocket-event.v1.schema.json): evento operacional redigido;
- [`examples/`](examples): exemplos iniciais para PocketKernel, MiddlewareAuth, PocketTrace, PocketCli, instância externa e falha de add-on.

Validação local:

```sh
./script/validate_pocket_interop_contract.sh
```
