const labels = { accepted: 'Aceito', pending: 'Pendente', succeeded: 'Concluído', failed: 'Falhou', uncertain: 'Resultado incerto' };

export function receiptPresentation(receipt) {
  if (!Object.hasOwn(labels, receipt.state)) throw new TypeError('Estado de receipt inválido');
  return { commandId: receipt.command_id, label: labels[receipt.state], completed: receipt.state === 'succeeded' };
}
