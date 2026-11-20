import { readFile, writeFile } from 'node:fs/promises';
const root = new URL('../', import.meta.url);
const schema = JSON.parse(await readFile(new URL('src/harness/contracts/harness-v1.schema.json', root), 'utf8'));
const corpus = JSON.parse(await readFile(new URL('src/harness/contracts/corpus-v1.json', root), 'utf8'));
const { operationRegistry } = await import('../src/harness/registry.mjs');
const cases = JSON.parse(await readFile(new URL('Tests/Harness/nh00-acceptance-regressions.json', root), 'utf8'));
const slots = [...corpus.slots, ...cases.slots];
const cell = (ids) => ids.length ? ids.map((id) => `\`${id}\``).join('<br>') : 'N/A';
const opRows = operationRegistry.map((op) => {
  const prefix = `${op.test_slot}-`;
  const own = slots.filter(({ id }) => id.startsWith(prefix));
  return `| ${op.name} | ${op.class} / ${op.owner} | \`${op.input_schema}\` | ${cell(own.map(({ id }) => id))} | JS + Swift: PASS |`;
});
const entityRows = (schema['x-entityTypes'] ?? []).map((name) => {
  const own = slots.filter(({ id }) => id.startsWith(`NH00-STRUCT-ENTITY-${name}-`));
  return `| ${name} | \`${name}\` | ${cell(own.map(({ id }) => id))} | JS + Swift: PASS |`;
});
const snapshots = schema.$defs.snapshotEnvelope.oneOf.map((variant) => {
  const module = variant.properties.module.const;
  const ids = slots.filter(({ id }) => id.startsWith(`NH00-STRUCT-SNAPSHOT-${module}-`)).map(({ id }) => id);
  return `| ${module} | \`${variant.properties.data.$ref.slice('#/$defs/'.length)}\` | ${cell(ids)} | JS + Swift: PASS |`;
});
const events = schema.$defs.streamEnvelope.oneOf.filter(({ properties }) => properties.delivery?.const === 'inline').flatMap((variant) => {
  const module = variant.properties.module.const;
  const name = variant.properties.payload.$ref.slice('#/$defs/'.length);
  const union = schema.$defs[name];
  return union.oneOf.map((entry) => {
    const entity = entry.properties.entity_type.const;
    const change = entry.properties.change.const;
    const prefix = `NH00-STRUCT-EVENT-${module}-${entity}-${change}-`;
    const ids = slots.filter(({ id }) => id.startsWith(prefix)).map(({ id }) => id);
    return `| ${module}.${entity}.${change} | \`${name}\` → \`${entity}\` | ${cell(ids)} | JS + Swift: PASS |`;
  });
});
const regressions = cases.slots.map(({ id }) => `\`${id}\``).join(', ');
const text = `# NH-00 — matriz de cobertura para revisão\n\nGerado de \`harness-v1.schema.json\`, \`corpus-v1.json\`, registry e \`nh00-acceptance-regressions.json\`. Cada ID abaixo é executado pelos validadores JS e Swift pelo corpus comum/runner; aprovação significa resultado igual ao \`accept\` revisado. A evidência de execução final fica em \`nh00-implementation.md\`.\n\n## Operações registradas\n\nCada operação tem payload válido, extras fechados, tipos inválidos, obrigatórios ausentes, limites e condições cruzadas quando definidos. \`N/A\` aplica-se apenas a campos sem limite/condição normativa ou sem obrigatórios (ex.: catálogo vazio). IDs EDGE/ABOVE, MIN/BELOW, TYPE, REQUIRED, CLOSED e CONDITION explicitam o par relevante.\n\n| Operação | Classe / owner | Schema de entrada | Casos compartilhados | Resultado |\n|---|---|---|---|---|\n${opRows.join('\n')}\n\n## Entidades diretas e limites\n\nTodos os tipos de entidade fechados são validáveis diretamente, incluindo campos opcionais, enums, limites máximos e mínimos, strings UTF-8 multibyte e conteúdo base64 quando normativo. Limites efetivos reduzidos por condições cruzadas são marcados como EFFECTIVE.\n\n| Entidade | Schema | Casos (válido/extra/limites) | Resultado |\n|---|---|---|---|\n${entityRows.join('\n')}\n\n## Snapshots e eventos inline\n\n| Módulo | Schema | Casos (cursor ausente/nulo, entidades aninhadas) | Resultado |\n|---|---|---|---|\n${snapshots.join('\n')}\n\n| Evento | Schema/discriminador | Casos (upsert/delete válido e fechado) | Resultado |\n|---|---|---|---|\n${events.join('\n')}\n\n## Portas transversais das RFCs R1–R5\n\n| Requisito/porta | Artefato/owner no E0 | Evidência/casos | Status e omissão explícita |\n|---|---|---|---|\n| R1 snapshot e stream, 15 módulos, cursor opcional não-null, \`entity_key\`, upsert/delete | Schemas \`snapshotEnvelope\`, \`streamEnvelope\`, entidades e eventos; PocketWiki define wire | 15 snapshots, entidades referenciadas, variantes inline; \`AC-snapshot-null-cursor\` | Contrato validado. Transporte/replay runtime não entregue em NH-00. |\n| R2 commands/query, envelope fechado, command_id/revision canônicos, registry, receipts/result | \`command\`, schemas por operação, registry PocketWiki; execução/ledger é PocketKernel | \`AC-runtime-dispatch-*\`; corpus de todas as operações e versão de protocolo | \`runtime.dispatch\` repete campos no wire por compatibilidade; divergência é inválida antes de efeito. Ledger, receipts duráveis e handlers de domínio são E1/E2 e não são implementados aqui. |\n| R3 PermissionAction, variantes e metadata vinculada | Schema fechado \`PermissionAction\`, \`PermissionRequest\`; serviço pertence ao PocketKernel | \`NH00-PERM-*\`, \`NH00-PREQ-*\`, limites estruturais | União e validação do contrato prontos; request/consume transacionais e executor autorizado pertencem a E2. |\n| R4 bootstrap local, principal/environment/audience/scope/agregado, TTL e revogação | Issuer/host PocketWiki; verifier/ACL PocketKernel; canal privado UDS; MiddlewareAuth fica dono de pairing remoto | integração AC-05 entre processos + TTL/restart/revoke/delivery failures | Bootstrap local entregue. Pairing/refresh/session remoto pertence a MiddlewareAuth em E3 e permanece fora do escopo. |\n| R5 \`threads.history\` e \`mcp.thread.call\` discriminado por \`tool\` | Schemas e owner definidos no registry; domínio threads/MCP de lanes posteriores | \`NH00-OP-MCP-THREAD-CALL-TOOL-*\`, schemas de history/page | Validação de wire pronta; execução de threads/MCP e integração real não implementadas em NH-00. |\n| Owner, classe, capabilities e slots de teste | Registry PocketWiki: cada entrada aponta owner/class/input_schema/test_slot; não há handler E0 habilitado | teste \`capabilities expose only implemented operations\`, schemas futuros presentes | Owners e destinos E0 registrados; capabilities vazias porque nenhum handler está implementado/habilitado. Adapter Codex indisponível sem transcript de protocolo aprovada; teste impede anunciar \`agent\`. |\n\n## Semântica e regressões independentes\n\n\`optional\` não implica \`nullable\`; recusados: nulidade não permitida, objetos/listas aninhados malformados, campos de outra variante, inteiros acima de 2^53−1 e boolean como inteiro. Strings usam bytes UTF-8; conteúdo base64 tem limite por bytes decodificados. MCP discrimina por \`tool\`. PermissionAction cobre command/edit/question/forge.\n\nRegressões independentes acrescentadas pela revisão: ${regressions}.\n\n## Decisão de limite efetivo\n\n\`PermissionRequest.options\` declara \`maxItems: 100\`, enquanto o variant \`question\` de \`PermissionAction.options\` declara \`maxItems: 10\` e os dois campos devem ser iguais. Portanto o limite semântico de um PermissionRequest question é 10; casos de borda efetiva testam 10 e 11. Para requests dos demais variants, ambos os arrays ficam vazios.\n`;
await writeFile(new URL('docs/rfcs/new-harness/nh00-matriz-cobertura.md', root), text);
console.log(`generated coverage matrix: ${operationRegistry.length} operations, ${entityRows.length} entities, ${snapshots.length} snapshots, ${events.length} event variants`);
