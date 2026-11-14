import SwiftUI

struct RuntimePanel: View {
    @ObservedObject var session: RuntimeUISession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(session.available ? "Runtime conectado" : "Execução durável indisponível").font(.headline)
                Spacer()
                Button("Reconectar") { Task { await session.reconnect() } }
            }
            if let error = session.error { Text(error).accessibilityIdentifier("runtime-status-detail") }
            else if session.available { Text("Revisão \(session.revision) · evento \(session.lastSeq)") }
            TextField("Novo comando", text: $session.draft)
                .accessibilityLabel("Texto do comando durável")
                .disabled(!session.available || session.pending != nil)
            Button("Enviar comando") { Task { await session.submit() } }
                .disabled(!session.available || session.pending != nil || session.draft.isEmpty)
                .accessibilityIdentifier("runtime-submit")
            if session.pending != nil {
                Button("Consultar comando pendente") { Task { await session.resolvePending() } }
                Button("Repetir comando pendente") { Task { await session.retryPending() } }
            }
            List(session.receipts) { receipt in
                HStack { Text(receipt.label); Spacer(); Text(receipt.id).font(.caption.monospaced()) }
                    .accessibilityIdentifier("runtime-receipt-\(receipt.id)")
            }.accessibilityLabel("Recibos do runtime")
        }.padding().task { await session.open() }.accessibilityIdentifier("runtime-panel")
    }
}
