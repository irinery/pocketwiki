# Decisão: falhas HTTP de `providers.select`

Status: decisão de contrato registrada para `providers.select`; a proposta
anterior de receipt `failed` foi rejeitada. Esta decisão não habilita endpoint,
`Ready`, migração, UI nem gate. Ela não muda o tratamento de falhas de outros
comandos, inclusive seus receipts `failed` e resultados tipados.

A RFC 0003/01 conserva `ERR_PROVIDER_UNAVAILABLE` no HTTP 503,
`ERR_CATALOG_STALE` no HTTP 409 e `ERR_UNSUPPORTED` no HTTP 422. O corpo é o
próprio `HarnessError` fechado, não um `CommandReceipt`, `Result` nem objeto
`{error: ...}`. Para esses três códigos, o status correspondente é fixo; cada status pode
ser usado por outros erros de fronteira. Por exemplo, 409
`ERR_CONFLICT` continua sendo conflito de hash ou CAS, e erro genérico de
transporte/store não vira diagnóstico tipado por comparação de texto. O schema
`providersSelectHTTPDomainError` limita os três códigos, não valida status HTTP;
o par status/código deve ser verificado no transporte. As demais falhas de
autorização, entrada e transporte seguem a arquitetura/R1.

## Tentativa, retry e concorrência

Esses três erros descrevem a tentativa que respondeu. Uma tentativa que falha
antes do commit não cria receipt, `result_ref`, resultado terminal `failed`,
reserva durável de erro ou evento de falha; não registra binding/capabilities
novos nem muda a seleção confirmada. Não se garante que a mesma falha ou
`correlation_id` será repetida. Só um commit de sucesso vincula duravelmente
`command_id` ao hash canônico e ao receipt. Uma falha anterior não fixa o hash
para o servidor; cliente não deve trocar silenciosamente o payload sob o mesmo
ID. Repetir o mesmo ID **e mesmo envelope canônico** pode consultar/handshakar o
adapter novamente e, se a causa for resolvida e o CAS continuar válido, aceitar
uma seleção. Idempotência aqui é do commit de sucesso, não garantia de I/O único.

Após autorização e validação, consultar o índice do command antes de CAS e de
qualquer adapter: sucesso já aceito com mesmo ID/hash e proveniência válida
retorna seu receipt com 200/`duplicate=true`, mesmo se a revisão atual mudou;
ID aceito com hash diferente dá 409 `ERR_CONFLICT`. Mesmo ID/hash concorrente
pode preparar mais de uma vez, mas só um sucesso é confirmado. Não converter um
sucesso já confirmado em erro de domínio por um diagnóstico posterior.

Ao finalizar a preparação, inclusive diante de diagnóstico de domínio, voltar
a verificar auth/scope, principal/environment, grant e epoch da conta e peer;
negação prevalece sobre diagnóstico sensível. Sob a autoridade e serialização do
writer, resolver primeiro receipt/hash já confirmado e sua origem; para comando
ainda não aceito, verificar o CAS novamente antes de confirmar sucesso ou
retornar o diagnóstico da tentativa. CAS alterado retorna 409 `ERR_CONFLICT`,
sem aceitar o diagnóstico preparado sob revisão antiga. Se essa revalidação não
puder ser feita por falha do store ou da autoridade, negar com erro de fronteira
aplicável; não afirmar um diagnóstico de domínio sem validação atual. Se uma outra tentativa
com mesmo ID/hash confirmar **depois** dessa verificação, ela pode coexistir com
uma resposta de erro já emitida: o erro não prova ausência global de receipt.
O cliente preserva a última seleção confirmada e consulta/reconcilia o mesmo ID
antes de apresentar uma nova intenção. Uma resposta perdida, timeout, 404,
revogação ou retenção desconhecida não prova que não houve commit.

Depois de um erro reconhecido, retry do mesmo comando mantém ID/hash. Uma nova
intenção explícita, inclusive novo `catalog_revision` após refresh, usa novo ID.
`retryable` orienta a ação do usuário, não promete disponibilidade nem autoriza
repetir automaticamente efeitos externos. Quando já há receipt de sucesso,
replay e leitura exigem autorização e proveniência atuais; revoke/regrant não
revive epoch anterior. A falha de transporte ou de publicação após possível
commit mantém o resultado incerto: reconciliar receipt pelo mesmo ID, sem
inventar falha de domínio, e nunca emitir segunda resposta após bytes parciais.

## Revisão, seq e efeitos

No ledger candidato inspecionado, a transação de sucesso faz CAS em
`ledger_environment.revision`, avança a revisão em 1 e incrementa `seq` pelo
número de changes; o writer de `providers.select` grava binding e capabilities
como dois eventos. Erro da própria tentativa antes do commit não faz esse
commit nem avança revision/seq **por ele**. Isso não fixa os valores globais:
outra transação concorrente pode avançá-los. A preparação pode ter confirmado
`TrackCatalogTx` antes de falhar, atualizando digest e revisão **de catálogo**
independentes; não prometer rollback desse tracking nem invariância de todos os
dados. A implementação precisa provar atomicidade/rollback do writer e não
inferir ausência de efeitos externos por timeout.

Preparação limita-se a catálogo/handshake: não envia prompt, não cria execução
ou outro efeito externo irreversível. Se algum adapter futuro tiver efeito desse
tipo, precisa de protocolo durável de intenção e reconciliação antes de usar
esta regra. Locks de auth/peer/SQLite não ficam retidos durante rede, mas o
writer e a publicação revalidam a autoridade. Falhas e receipts que exponham
informação de conta são publicados somente sob autorização atual até Write e
Flush limitados; bytes já aceitos podem chegar após revoke. Um proxy que apenas
recebe receipt interno e libera as guardas antes do HTTP Flush não cumpre isso.

## Verificação exigida antes de habilitar

- Testar os três pares status/código e `HarnessError` fechado, limites UTF-8,
  UUID, `retryable`, redaction e rejeição de corpos mistos; nenhum altera os
  códigos, schemas ou estados de comandos de outras operações. JS e Swift
  validam o mesmo corpus; testes HTTP conferem status, pois schema de JSON não
  conhece status. Sucesso segue receipt 202/200 e GET tipado próprio.
- Em storage e processos reais, provar falha sem receipt/binding/evento próprio,
  retry mesmo ID/hash com novo I/O e eventual sucesso, payload mudado com ID
  aceito em 409, replay de sucesso antes de adapter/CAS, CAS após preparação,
  concorrência sucesso/falha e duas falhas, e os efeitos independentes de
  tracking de catálogo. Checar revision/seq próprias e concorrentes sem supor
  que permanecem globalmente imóveis.
- Testar erro de rede/cancelamento distinto do diagnóstico tipado; perda de
  resposta antes e depois do commit, 404 inconclusivo, retry mesmo ID, falha de
  commit e restart; sem alegar exactly-once de handshake. Não executar prompt
  na preparação nem afirmar rollback de I/O já iniciado.
- Testar scope/peer/conta e revoke/regrant em preflight, preparação, commit e
  publicação, proveniência íntegra e leituras alheias negadas; race de Flush,
  expiração e erro parcial, sem reaproveitar bytes nem dar segunda resposta.
  Cliente associa respostas à tentativa e epoch locais: erro antigo não apaga
  seleção nova nem autoridade reativada, inclusive quando revision é igual.
- Validar schemas, adaptadores, migração/retenção de comandos aceitos, serviço e
  isolamento reais no SHA integrado. Esta decisão não substitui essas entregas
  nem comprova SERVICE-0003.
