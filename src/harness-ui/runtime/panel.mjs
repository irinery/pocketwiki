import { receiptPresentation } from './presentation.mjs';

// Mounted by a host slot. The host supplies an authenticated RuntimeClient.
export function mountRuntimePanel(root, client) {
  const status = document.createElement('p'); status.setAttribute('role', 'status');
  const form = document.createElement('form');
  const input = document.createElement('textarea'); input.setAttribute('aria-label', 'Texto do comando durável');
  const submit = document.createElement('button'); submit.textContent = 'Enviar comando';
  const resolve = document.createElement('button'); resolve.type = 'button'; resolve.textContent = 'Consultar comando pendente';
  const receipts = document.createElement('ul'); receipts.setAttribute('aria-label', 'Recibos do runtime');
  form.append(input, submit); root.replaceChildren(status, form, resolve, receipts);
  function render(state) {
    status.textContent = state.error === 'LEGACY_SERVER' ? 'Execução durável indisponível. O chat legado continua disponível.' : state.error ? state.error : state.available ? `Revisão ${state.revision} · evento ${state.lastSeq}` : 'Conectando';
    submit.disabled = !state.available || !!state.pendingCommandId;
    resolve.hidden = !state.pendingCommandId;
    input.disabled = !!state.pendingCommandId;
    receipts.replaceChildren(...state.receipts.map(receipt => {
      const { commandId, label, completed } = receiptPresentation(receipt);
      const item = document.createElement('li'); item.textContent = `${commandId}: ${label}`; item.dataset.completed = String(completed); return item;
    }));
  }
  client.onChange = render; render(client.state);
  resolve.addEventListener('click', async () => {
    try { await client.resolvePending(); }
    catch { status.textContent = 'Não foi possível consultar o comando pendente.'; }
  });
  form.addEventListener('submit', async event => {
    event.preventDefault(); submit.disabled = true;
    const submitted = input.value;
    try { await client.submit(submitted); if (input.value === submitted) input.value = ''; }
    catch (error) { status.textContent = 'Não foi possível enviar o comando.'; }
    finally { submit.disabled = !client.state.available || !!client.state.pendingCommandId; }
  });
  return { open: () => client.open(), reconnect: () => client.reconnect() };
}
