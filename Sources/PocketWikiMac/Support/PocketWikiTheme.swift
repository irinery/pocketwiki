import SwiftUI

enum PocketWikiTheme {
    static let bg = Color(hex: 0x080A0D)
    static let bg2 = Color(hex: 0x0F1319)
    static let bg3 = Color(hex: 0x151B24)
    static let bg4 = Color(hex: 0x1D2633)
    static let panel = Color(hex: 0x10151D)
    static let panel2 = Color(hex: 0x131A24)
    static let border = Color(hex: 0x253040)
    static let border2 = Color(hex: 0x334256)
    static let text = Color(hex: 0xE7EDF5)
    static let dim = Color(hex: 0x93A1B5)
    static let muted = Color(hex: 0x5F6D7F)
    static let accent = Color(hex: 0xE0A942)
    static let accent2 = Color(hex: 0x72D6FF)
    static let good = Color(hex: 0x7BD88F)
    static let warn = Color(hex: 0xF0C36A)
    static let bad = Color(hex: 0xFF8080)
    static let purple = Color(hex: 0xC49BFF)

    static var appBackground: some ShapeStyle {
        LinearGradient(
            colors: [Color(hex: 0x1F2B3D).opacity(0.72), bg, Color(hex: 0x06070A)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var heroBackground: some ShapeStyle {
        LinearGradient(
            colors: [panel2.opacity(0.96), panel.opacity(0.92), bg2.opacity(0.94)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var primaryButtonBackground: some ShapeStyle {
        LinearGradient(
            colors: [accent.opacity(0.28), accent2.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct PocketWikiCardBackground: ViewModifier {
    var isHero = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHero ? AnyShapeStyle(PocketWikiTheme.heroBackground) : AnyShapeStyle(PocketWikiTheme.panel.opacity(0.9)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(PocketWikiTheme.border, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
            }
    }
}

extension View {
    func pocketWikiCard(hero: Bool = false) -> some View {
        modifier(PocketWikiCardBackground(isHero: hero))
    }
}
