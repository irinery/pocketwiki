import AppKit
import MarkdownUI
import SwiftUI

struct LocalAIChatPanel: View {
    @Bindable var chat: LocalAIChatSession
    let connectionLabel: String
    let contextScope: LocalAIContextScope
    let canSend: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let onReset: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(PocketWikiTheme.border)
                .frame(height: 1)

            messageList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            composer
        }
        .pocketWikiCard()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Label("Conversa", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(PocketWikiTheme.text)

            Spacer()

            Text(connectionLabel)
                .font(.caption.monospaced())
                .foregroundStyle(PocketWikiTheme.muted)
                .lineLimit(1)

            Button(action: onReset) {
                Label("Reset", systemImage: "arrow.counterclockwise.circle")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .controlSize(.small)
            .help("Resetar a conversa e voltar para contexto Auto com temperatura baixa")

            Button(action: onClear) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .controlSize(.small)
            .disabled(chat.messages.isEmpty && !chat.isStreaming)
            .help("Limpar historico")
        }
        .padding(16)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        LocalAIEmptyConversationView()
                    } else {
                        ForEach(chat.messages) { message in
                            LocalAIMessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: chat.messagesRevision) { _, _ in
                guard let last = chat.messages.last else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = chat.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(PocketWikiTheme.bad)
                    .lineLimit(3)
            }

            HStack(alignment: .bottom, spacing: 10) {
                promptEditor

                if chat.isStreaming {
                    Button(action: onCancel) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .help("Cancelar")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .tint(PocketWikiTheme.accent)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Enviar")
                }
            }

            HStack {
                Label(contextScope.title, systemImage: contextScope.systemImage)
                if let context = chat.lastContext, context.mode == .wiki {
                    Text("· \(context.includedPaths.count) fonte(s)")
                }
                Spacer()
                Text("Enter envia · Shift+Enter quebra linha")
            }
            .font(.caption)
            .foregroundStyle(PocketWikiTheme.muted)
        }
        .padding(16)
        .background(PocketWikiTheme.panel.opacity(0.98))
    }

    private var promptEditor: some View {
        ZStack(alignment: .topLeading) {
            LocalAIPromptTextView(text: $chat.prompt, onSubmit: onSend)
                .frame(minHeight: 76, maxHeight: 112)
                .background(PocketWikiTheme.bg.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(PocketWikiTheme.border, lineWidth: 1)
                }

            if chat.prompt.isEmpty {
                Text("Pergunte algo sobre a wiki...")
                    .font(.body)
                    .foregroundStyle(PocketWikiTheme.muted)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 17)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct LocalAIPromptTextView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = PromptNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = NSColor(PocketWikiTheme.text)
        textView.insertionPointColor = NSColor(PocketWikiTheme.text)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 9, height: 9)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PromptNSTextView else { return }
        textView.onSubmit = onSubmit
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }

    final class PromptNSTextView: NSTextView {
        var onSubmit: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn, !event.modifierFlags.contains(.shift) {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }
    }
}

private struct LocalAIEmptyConversationView: View {
    var body: some View {
        Text("Conecte o LM Studio e faca uma pergunta. O contexto sera adaptado ao tipo de pedido.")
            .font(.caption.monospaced())
            .foregroundStyle(PocketWikiTheme.muted)
            .lineSpacing(4)
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .background(PocketWikiTheme.bg2.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(PocketWikiTheme.border, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LocalAIMessageBubble: View {
    let message: LocalAIChatMessage

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 72) }

            VStack(alignment: .leading, spacing: 9) {
                header

                if !message.reasoning.isEmpty {
                    reasoning
                }

                if isUser || message.isStreaming {
                    Text(message.content.isEmpty ? "..." : message.content)
                        .foregroundStyle(PocketWikiTheme.text)
                        .textSelection(.enabled)
                } else {
                    Markdown(message.content.isEmpty ? "..." : message.content)
                        .markdownTheme(.pocketWiki)
                        .textSelection(.enabled)
                }

                if let usage = message.usageSummary, !message.isStreaming {
                    Text(usage)
                        .font(.caption2.monospaced())
                        .foregroundStyle(PocketWikiTheme.muted)
                }
            }
            .padding(13)
            .frame(maxWidth: 780, alignment: .leading)
            .background(
                isUser ? PocketWikiTheme.bg3.opacity(0.9) : PocketWikiTheme.bg2.opacity(0.92),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isUser ? PocketWikiTheme.accent2.opacity(0.38) : PocketWikiTheme.accent.opacity(0.25), lineWidth: 1)
            }

            if !isUser { Spacer(minLength: 72) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isUser ? "person.crop.circle" : "sparkles")
                .foregroundStyle(isUser ? PocketWikiTheme.accent2 : PocketWikiTheme.accent)
            Text(isUser ? "Voce" : "IA")
                .font(.caption.bold())
                .foregroundStyle(PocketWikiTheme.dim)
            if let model = message.modelID, !isUser {
                Text(model)
                    .font(.caption2.monospaced())
                    .foregroundStyle(PocketWikiTheme.muted)
                    .lineLimit(1)
            }
            if message.isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var reasoning: some View {
        DisclosureGroup(message.isStreaming ? "Pensando" : "Raciocinio do modelo") {
            Text(message.reasoning)
                .font(.caption.monospaced())
                .foregroundStyle(PocketWikiTheme.dim)
                .textSelection(.enabled)
                .padding(.top, 6)
        }
        .tint(PocketWikiTheme.accent2)
        .font(.caption)
    }
}
