import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const docsDir = resolve(root, 'docs/rfcs/new-harness');
const manifest = JSON.parse(await readFile(resolve(docsDir, 'manifest.json'), 'utf8'));

const classes = {
  'runtime.dispatch': 'mutation', 'runtime.receipt': 'read', 'runtime.events': 'read',
  'providers.select': 'mutation', 'providers.catalog': 'read',
  'threads.message': 'mutation', 'threads.create': 'mutation', 'threads.list': 'read', 'threads.history': 'read',
  'composer.prepare': 'mutation', 'composer.stage': 'local', 'composer.draft.save': 'local', 'composer.resolve': 'local', 'composer.pin': 'local',
  'permissions.respond': 'mutation', 'permissions.pending': 'read', 'permissions.mode': 'mutation',
  'workspaces.prepare': 'mutation', 'workspaces.release': 'mutation', 'workspaces.settings': 'read', 'workspaces.register_project': 'mutation',
  'checkpoints.restore': 'mutation', 'checkpoints.capture': 'mutation', 'checkpoints.preview': 'read', 'checkpoints.diff': 'read',
  'terminal.open': 'mutation', 'terminal.input': 'mutation', 'terminal.resize': 'mutation', 'terminal.close': 'mutation', 'terminal.read': 'read',
  'environments.pair': 'bootstrap', 'environments.challenge': 'bootstrap', 'environments.revoke': 'bootstrap', 'environments.refresh': 'bootstrap',
  'mcp.thread.call': 'mutation',
  'handoffs.prepare': 'mutation', 'handoffs.export': 'read', 'handoffs.import': 'mutation',
  'memory.recall_scoped': 'read', 'memory.capture_scoped': 'mutation', 'memory.note.get': 'read', 'memory.note.put': 'mutation', 'memory.map_legacy': 'read',
  'source_control.preview': 'mutation', 'source_control.execute': 'mutation', 'source_control.links': 'read',
  'navigation.update': 'mutation', 'navigation.list': 'read',
  'diagnostics.snapshot': 'read', 'diagnostics.export': 'read'
};

const operations = [];
for (const feature of manifest.features) {
  const markdown = await readFile(resolve(docsDir, feature.path), 'utf8');
  const phaseOne = markdown.split('## 3.2')[0];
  const blocks = phaseOne.matchAll(/```yaml\s*\ninterface:\n(.*?)\n```/gs);
  for (const [, block] of blocks) {
    const name = block.match(/^  nome: "([a-z][a-z0-9_.]+)"$/m)?.[1];
    if (!name) continue;
    const interfaceId = block.match(/^  id: ([^\n]+)$/m)?.[1]?.trim();
    const operationClass = classes[name];
    if (!operationClass) throw new Error(`No class registered for ${name}`);
    const inputText = block.split(/^  entrada:\n/m)[1]?.split(/^  saída:/m)[0] ?? '';
    const inputFields = [...inputText.matchAll(/^    - campo: ([^\n]+)\n      tipo: ([^\n]+)(.*?)(?=\n    - campo: |(?![\s\S]))/gms)].map((match) => ({
      name: match[1].trim().replaceAll('`', '').replaceAll('"', ''),
      type: match[2].trim().replaceAll('"', ''),
      required: /^      obrigatório: true$/m.test(match[3])
    }));
    operations.push({
      name,
      interface_id: interfaceId,
      module: feature.module,
      rfc: feature.rfc,
      owner: feature.owner,
      class: operationClass,
      input_schema: `operationInput_${name.replaceAll('.', '_').replaceAll('-', '_')}`,
      input_fields: inputFields,
      contract_status: name === 'runtime.dispatch' ? 'blocked' : 'closed',
      implemented: false,
      test_slot: `NH00-OP-${name.replaceAll('.', '-').replaceAll('_', '-').toUpperCase()}`
    });
  }
}

const expectedNames = Object.keys(classes).sort();
const actualNames = operations.map(({ name }) => name).sort();
if (JSON.stringify(expectedNames) !== JSON.stringify(actualNames)) {
  throw new Error(`Operation/class registry mismatch. Missing: ${expectedNames.filter((name) => !actualNames.includes(name)).join(', ')}; extra: ${actualNames.filter((name) => !expectedNames.includes(name)).join(', ')}`);
}

const registry = {
  protocol: 'harness.v1',
  documentary_source_sha: '5311a8aae2876c572f25b79540f38ee0acac7121',
  operations
};
await writeFile(resolve(root, 'src/harness/contracts/operation-registry.json'), `${JSON.stringify(registry, null, 2)}\n`);
const swiftEntries = operations.map((operation) => {
  const fields = Object.fromEntries(operation.input_fields.map(({ name, type }) => [name, type]));
  const required = operation.input_fields.filter(({ required }) => required).map(({ name }) => name);
  const fieldsLiteral = `[${Object.entries(fields).map(([key, type]) => `${JSON.stringify(key)}: ${JSON.stringify(type)}`).join(', ')}]`;
  const requiredLiteral = `[${required.map((name) => JSON.stringify(name)).join(', ')}]`;
  return `        ${JSON.stringify(operation.name)}: Entry(module: ${JSON.stringify(operation.module)}, owner: ${JSON.stringify(operation.owner)}, operationClass: ${JSON.stringify(operation.class)}, contractStatus: ${JSON.stringify(operation.contract_status)}, implemented: false, inputFields: ${fieldsLiteral}, requiredFields: Set(${requiredLiteral})),`;
});
const swiftSource = `import Foundation\n\nenum HarnessOperationRegistry {\n    struct Entry {\n        let module: String\n        let owner: String\n        let operationClass: String\n        let contractStatus: String\n        let implemented: Bool\n        let inputFields: [String: String]\n        let requiredFields: Set<String>\n    }\n\n    static let entries: [String: Entry] = [\n${swiftEntries.join('\n')}\n    ]\n}\n`;
await writeFile(resolve(root, 'Sources/PocketWikiMac/Models/Harness/HarnessOperationRegistry.swift'), swiftSource);
console.log(`generated ${operations.length} operation slots across ${manifest.features.length} modules`);
