import { spawn } from 'node:child_process';

// Verifica no mesmo tick que cria o processo, inclusive após awaits não canceláveis.
export function spawnBeforeDeadline(signal, executable, args, options, spawnImpl = spawn) {
  signal.throwIfAborted();
  return spawnImpl(executable, args, options);
}
