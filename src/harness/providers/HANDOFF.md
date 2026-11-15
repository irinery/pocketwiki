# Provider projection: inactive authorization-cycle guards

The JS and Swift provider projections have no production consumer in this
checkout. The local credential issuer handles bearer lifecycle, but there is no
connected notification or authority for Kernel provider-account grant epochs.
No provider transport/listener or authenticated provider session is wired here;
this change does not claim revocation or cache invalidation in a running app.

A future trusted session owner must call `setScope` on every actual authorization
transition (including loss, expiry, disconnect and uncertain outcomes). It must
call `beginRefresh` before starting the first snapshot, stream or payload fetch,
retain that exact local refresh ticket across all awaits and pass it with each
projection operation. A new authorization activation invalidates the old
authority and refresh tickets; a new refresh invalidates older refresh tickets
while retaining the current authority ticket. This holds even when principal,
external generation, revision and sequence are identical. Do not reconstruct tickets from their contents. These local
tickets do not establish or discover a Kernel account-grant generation.

JS keeps the confirmed same-authority projection until the last replacement
page validates, then replaces it as one unit, including an empty snapshot. An
authorization transition immediately clears it. Swift's `@MainActor` projection
builds and returns a complete detached `View`; the eventual owner must retain or
replace visible state atomically, check the ticket after every await and clear
its own previously returned views on auth changes. Already delivered values and
buffered network bytes cannot be recalled. The client must also invalidate old
in-flight requests/responses, not compare only ledger revision or sequence.

No real account-grant change signal is available here. Wiring this to credential
renewal alone would not prove invalidation after account revoke/regrant; until a
trusted source and lifecycle are provided, the production integration remains
blocked and must not enable provider reads on the assumption that tickets alone
are authorization.

## Candidato stream-first

`ProviderStreamFirst` em JS usa `ProviderR1Transport` para snapshot de ambiente,
SSE e referências R1. Primeiro obtém uma página preliminar apenas para escolher
`after_seq`, abre o SSE e começa a consumir os frames antes de buscar um novo
snapshot exibível. O servidor precisa instalar o watcher antes de enviar os
headers 200; headers válidos por si só não provam que isso ocorreu. Enquanto o
snapshot é paginado, eventos e referências são cercados pelo ticket do ciclo e
limitados em quantidade e bytes. A troca só é publicada após as páginas e o
buffer conhecidos serem processados. Erro, EOF, cursor expirado ou idle timeout
invalidam a autoridade local e sinalizam estado indisponível. Um novo refresh
oculta o estado enquanto troca de watcher; ele não deixa o conteúdo antigo
visível na janela sem stream. O adapter limita headers e JSON a 30 segundos,
exige SSE/no-store e o parser limita frames e idle. O teste HTTP loopback usa um
servidor fixture, não o Kernel de produção.

A versão Swift é apenas um coordenador `@MainActor` sobre portas injetadas.
A porta de stream deve validar headers, registrar o watcher antes de retornar,
verificar ID SSE e impor deadline/idle e cancelamento; as portas de snapshot e
payload também precisam impor os limites e deadlines do transporte. O runner
Swift testa ordenação, buffer, EOF e payload atrasado com callbacks de teste,
sem provar URLSession, socket Kernel ou paridade de transporte com JS. Ambos os
coordenadores dependem de um dono que entregue mudanças reais de autorização;
eles não geram nem inferem a geração dos grants de conta. Nada aqui registra uma
rota, conecta um consumidor de produção ou comprova a invalidação do cache de
uma UI real.
