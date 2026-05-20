import AppKit
import SwiftUI

struct BrandLogoView: View {
    var size: CGFloat = 82

    var body: some View {
        Group {
            if let image = Self.logoImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .accessibilityLabel("PocketWiki")
            } else {
                Text("PW")
                    .font(.system(size: size * 0.24, weight: .heavy, design: .serif))
                    .foregroundStyle(PocketWikiTheme.accent)
                    .frame(width: size, height: size)
            }
        }
        .shadow(color: PocketWikiTheme.accent.opacity(0.18), radius: 14, x: 0, y: 6)
    }

    private static var logoImage: NSImage? {
        guard let url = Bundle.module.url(forResource: "pocketwiki-logo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(PocketWikiTheme.accent)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(PocketWikiTheme.text)
                Spacer(minLength: 8)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(PocketWikiTheme.muted)
                        .lineLimit(1)
                }
            }

            content
        }
        .padding(14)
        .pocketWikiCard()
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(PocketWikiTheme.accent)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .foregroundStyle(PocketWikiTheme.accent)
                    .lineLimit(1)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(PocketWikiTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(PocketWikiTheme.bg2.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(PocketWikiTheme.border, lineWidth: 1)
        }
    }
}

struct PageListButton: View {
    let page: WikiPage
    let meta: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .foregroundStyle(PocketWikiTheme.text)
                        .lineLimit(1)
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(PocketWikiTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if page.kind == .excalidraw { return "scribble.variable" }
        if !page.missingLinks.isEmpty { return "exclamationmark.triangle" }
        if page.healthClass == .good { return "checkmark.circle" }
        return "doc.text"
    }

    private var iconColor: Color {
        if !page.missingLinks.isEmpty { return PocketWikiTheme.bad }
        if page.healthClass == .good { return PocketWikiTheme.good }
        return PocketWikiTheme.dim
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(PocketWikiTheme.accent)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(PocketWikiTheme.text)
            Text(message)
                .foregroundStyle(PocketWikiTheme.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
