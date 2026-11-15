# Proposta em revisão: ingestão explícita de objeto no composer

Status: proposta, sem alterar o contrato vigente. A leitura por root continua indisponível até que contenção e unicidade sejam comprovadas. Esta proposta não aprova SERVICE-0005 nem o gate E2.

## Problema

Uma árvore live concedida por root pode conter hardlinks para objetos também nomeados fora da concessão. Se um nome for removido entre `open` e `fstat`, uma contagem posterior de links não comprova que o objeto estava restrito ao root na abertura. `openat2` resolve contenção do caminho, mas não prova ausência de aliases; a garantia de `O_UNIQUE` para todos os filesystems relevantes não foi comprovada. O fallback de leitura está fechado.

## Contrato proposto

Adicionar uma segunda origem: `object grant` explícito, conferido por um host confiável ao principal, environment e thread. A autoridade é o objeto ou os bytes efetivamente concedidos, não o nome em um root. O host pode receber um descritor por herança ou IPC autenticado, ou bytes enviados explicitamente; número de descritor, ID ou hash recebidos no JSON não concedem acesso.

O serviço valida o grant e seus limites, lê o objeto uma vez e persiste os bytes no staging privado. O hash cobre exatamente essa cópia. Preview, quote, prepare, pin e resolve usam a cópia imutável e verificam identidade e autorização; atualizar conteúdo exige nova ingestão. A interface deve mostrar o conteúdo capturado antes de sua aceitação quando a autorização depender de aprovação de bytes específicos.

A origem atual por root permanece distinta. Para fontes live, mantém-se a rejeição de alteração entre preview e prepare. Para objetos importados, o conteúdo é congelado na ingestão: uma alteração posterior da origem não altera a cópia. O novo tipo precisa de schema, capability negociada, testes JS/Swift e revisão do contrato antes de ser habilitado.

## Limites

- Um descritor estável sobrevive a rename, mas não impede escrita concorrente no mesmo inode. A cópia e o hash representam os bytes capturados; não provam snapshot coerente do arquivo de origem.
- Um seletor que retorna URL ou pathname, por si só, não demonstra concessão atômica do objeto. O broker e a semântica do grant precisam ser definidos e testados.
- Isto não satisfaz automaticamente a exigência atual de leitura live por root, bloqueio de hardlinks externos ou detecção de mudança da fonte live. O gate permanece fechado até essa exigência ser atendida ou o contrato ser alterado explicitamente.
- Uma alternativa de snapshot exige namespace comprovadamente imutável, controle de mounts e tratamento de hardlinks já existentes; no macOS pode exigir broker/entitlements específicos. Não é fallback transparente para um aplicativo comum.

## Verificação proposta

Exercitar com processos e stores reais: grant válido/negado por principal e thread; limite de bytes; staging e hash; preview; citações UTF-8; CAS/receipt; restart; pin/unpin; resolução autenticada; referências forjadas; conteúdo tratado como `untrusted_content`; mutação concorrente da fonte sem modificar os bytes já persistidos. Testar a origem live separadamente conforme o contrato aplicável. Nenhuma fixture deve criar autorização implícita.

Fontes técnicas: [NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel), [XDG FileChooser](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.FileChooser.html), [openat2 Linux](https://kernel.googlesource.com/pub/scm/docs/man-pages/man-pages/+/master/man/man2/openat2.2), [snapshots APFS](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/fs_snapshot_create.2).
