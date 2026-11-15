# Proposta em revisão: isolamento do store do Kernel

Status: proposta. Não instala serviços, altera contas, muda permissões nem habilita a migração. O `Open` atual recusa upgrades antigos enquanto a contenção da migração não estiver comprovada.

## Problema

O driver SQLite abre banco, WAL e SHM por caminho. Uma verificação anterior por pathname não fixa as aberturas posteriores se outro processo com a mesma autoridade puder substituir componentes. A VFS pública do driver fixado é somente leitura e a prova em Darwin não abriu um banco com WAL ativo. A alternativa por cópia e troca de ponteiro segue desabilitada; o GC experimental foi removido.

## Opção proposta: serviço de dados com identidade dedicada

Provisionar explicitamente um serviço de dados permanente sob uma identidade de sistema dedicada. Somente o serviço e administradores confiáveis teriam escrita no diretório do banco, seus ancestrais controláveis e os arquivos SQLite/WAL/SHM. O aplicativo desktop chamaria o serviço por IPC autenticado, com identidade e grants explícitos, sem fornecer um pathname arbitrário. As regras devem impedir aliases/hardlinks externos e descritores graváveis herdados por subprocessos não confiáveis.

O serviço possuiria o runtime SQLite e a migração; providers externos rodariam em outro contexto sem acesso de escrita ao store. A instalação e a propriedade dos caminhos seriam provisionadas e verificadas no macOS e Linux. Nenhuma mudança de permissões é feita automaticamente nesta proposta.

## Limites e decisões necessárias

- A hipótese de segurança é que nenhum código não confiável execute com a identidade dedicada ou permissões equivalentes. `0700` sob a mesma conta desktop não estabelece essa hipótese.
- Isolar apenas o migrador ou o destino não protege uma origem e WAL em diretório ainda gravável por outro processo. Importação de legado precisa de procedimento confiável separado que exclua escritores e descritores graváveis, preserve a origem e comprove integridade. Se essa exclusão não puder ser provada, recusar a importação.
- Contas, instalação, credenciais IPC, manutenção, atualizações, desinstalação e backup exigem projeto e revisão específicos por plataforma. A proposta não presume privilégios disponíveis nem transfere propriedade de arquivos existentes.
- O modelo altera a implantação e a fronteira de confiança, mas não pode reduzir os requisitos de autorização, ledger, recovery ou proteção do legado. Nenhuma capability é liberada somente pela existência do serviço.
- A alternativa é uma VFS gravável que ancore todas as operações de SQLite, WAL/SHM, locks e fsync a descritores em Darwin e Linux, com auditoria e testes próprios. Ainda não existe implementação comprovada neste projeto.

## Critérios de aceite

Com ambiente provisionado para teste: verificar dono/permissões e ancestrais; negar abertura fora do namespace e acesso direto do usuário desktop; provar autorização IPC e revogação; testar WAL vivo, interrupções e reabertura; comparar contagens/hashes e manter backup privado; testar concorrência/locks e recuperação; demonstrar que o processo de provider não escreve no banco; preservar o store legado quando a importação falhar. Resultados com mudanças de privilégio exigem ambiente de teste explícito; nenhuma remediação de arquivos do usuário é implícita.

O modelo precisa de decisão do produto e de implementação/testes reais antes de alterar o contrato vigente ou habilitar a migração.
