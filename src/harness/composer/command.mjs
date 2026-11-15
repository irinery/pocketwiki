import { validateOperationInput } from '../contracts/validate.mjs';
import { ComposerContextService } from './retention.mjs';
import { canonicalJSON, digest, fail, isPlainObject, ownerKey, UUID, validateAuth } from './service.mjs';

// Idempotent domain handler called only after Kernel has accepted the command.
// Kernel remains the authority for aggregate revision, receipt and outbox.
export class ComposerCommandService extends ComposerContextService {
  async executeCommand(auth, command) {
    validateAuth(auth);
    const operations = {
      'composer.stage': () => this.stage(auth, command.input),
      'composer.draft.save': () => this.saveDraft(auth, command.input.draft),
      'composer.prepare': () => this.prepare(auth, command.input),
      'composer.pin': () => this.pin(auth, command.input)
    };
    if (!isPlainObject(command) || Object.keys(command).length !== 6 || Object.keys(command).some((key) => !['protocol_major', 'command_id', 'environment_id', 'expected_revision', 'operation', 'input'].includes(key)) || command.protocol_major !== 1 || !UUID.test(command.command_id ?? '') || !UUID.test(command.environment_id ?? '') || !Number.isSafeInteger(command.expected_revision) || command.expected_revision < 0 || !Object.hasOwn(operations, command.operation) || !validateOperationInput(command.operation, command.input).valid) fail('ERR_INVALID', 'Comando inválido.');
    if (command.environment_id !== auth.environment_id) fail('ERR_FORBIDDEN', 'Environment divergente.');
    const owner = ownerKey(auth);
    const commandHash = digest(Buffer.from(canonicalJSON({ owner, command }), 'utf8'));
    const existing = this.state.commands.find((record) => record.command_id === command.command_id);
    if (existing) {
      if (existing.owner !== owner) fail('ERR_FORBIDDEN', 'Comando pertence a outra identidade.');
      if (existing.hash !== commandHash) fail('ERR_CONFLICT', 'command_id reutilizado com payload diferente.');
      return { result: structuredClone(existing.result), duplicate: true };
    }
    this.deferPersist = true;
    try {
      const result = await operations[command.operation]();
      this.state.commands.push({ command_id: command.command_id, owner, hash: commandHash, result: structuredClone(result) });
      this.deferPersist = false;
      this._persist();
      return { result, duplicate: false };
    } catch (error) {
      this.deferPersist = false;
      this.state = structuredClone(this.confirmedState);
      throw error;
    }
  }
}
