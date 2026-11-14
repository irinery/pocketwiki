import { receiptPresentation } from './presentation.mjs';

// Mounted by a host slot. The host supplies an authenticated RuntimeClient.
export function mountRuntimePanel(root, client) {
  const status = document.createElement('p'); status.setAttribute('role', 'status');
  const form = document.createElement('form');
  const input = document.createElement('textarea'); input.setAttribute('aria-label', 'Texto do comando durável');
  const submit = document.createElement('button'); submit.textContent = 'Enviar comando';
  const receipts = document.createElement('ul'); receipts.setAttribute('aria-label', 'Recibos do runtime');
  form.append(input, submit); root.replaceChildren(status, form, receipts);
  function render(state) {
    status.textContent = state.error === 'LEGACY_SERVER' ? 'Execução durável indisponível. O chat legado continua disponível.' : state.error ? state.error : state.available ? `Revisão ${state.revision} · evento ${state.lastSeq}` : 'Conectando';
    submit.disabled = !state.available;
    receipts.replaceChildren(...state.receipts.map(receipt => {
      const { commandId, label, completed } = receiptPresentation(receipt);
      const item = document.createElement('li'); item.textContent = `${commandId}: ${label}`; item.dataset.completed = String(completed); return item;
    }));
  }
  client.onChange = render; render(client.state);
  form.addEventListener('submit', async event => {
    event.preventDefault(); submit.disabled = true;
    try { await client.submit(input.value); input.value = ''; }
    catch (error) { status.textContent = 'Não foi possível enviar o comando.'; }
    finally { submit.disabled = !client.state.available; }
  });
  return { open: () => client.open(), reconnect: () => client.reconnect() };
}
