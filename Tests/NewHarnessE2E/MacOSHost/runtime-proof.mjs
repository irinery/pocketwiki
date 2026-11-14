export function assertRuntimeProof({ marker, nonce, summary }) {
  if (typeof nonce !== 'string' || !/^[a-f0-9]{32,128}$/.test(nonce) || marker !== nonce ||
      !summary || summary.result !== 'Passed' || !Number.isInteger(summary.passedTests) || summary.passedTests < 1 ||
      summary.failedTests !== 0 || summary.skippedTests !== 0 || summary.expectedFailures !== 0) {
    throw new Error('prova do slot runtime ausente ou XCTest incompleto');
  }
}

export function runtimeProofExitCode(status, required, verified) {
  return required && status === 0 && !verified ? 1 : status;
}
