import registry from './contracts/operation-registry.json' with { type: 'json' };
import manifest from '../../docs/rfcs/new-harness/manifest.json' with { type: 'json' };

export const operationRegistry = Object.freeze(registry.operations);
export const registeredModules = Object.freeze(manifest.features.map(({ module }) => module));

export function listCapabilities({ enabledModules = registeredModules } = {}) {
  const enabled = new Set(enabledModules);
  return operationRegistry
    .filter((operation) => operation.implemented && enabled.has(operation.module))
    .map(({ name, module, class: operationClass }) => ({ name, module, class: operationClass }));
}

export function findOperation(name) {
  return operationRegistry.find((operation) => operation.name === name);
}

export function requireOperation(name, expectedClass) {
  const operation = findOperation(name);
  if (!operation) throw Object.assign(new Error('Operation is not in the v1 registry'), { code: 'ERR_INVALID' });
  if (operation.class !== expectedClass) throw Object.assign(new Error('Operation class does not match this route'), { code: 'ERR_INVALID' });
  if (!operation.implemented) throw Object.assign(new Error('Operation is not implemented'), { code: 'ERR_UNSUPPORTED' });
  return operation;
}
