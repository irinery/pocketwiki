import SwiftUI

enum PocketWikiTheme {
    static let bg = Color(hex: 0x05070B)
    static let bg2 = Color(hex: 0x09111B)
    static let bg3 = Color(hex: 0x101B29)
    static let bg4 = Color(hex: 0x19283A)
    static let panel = Color(hex: 0x0B1420)
    static let panel2 = Color(hex: 0x122235)
    static let border = Color.white.opacity(0.10)
    static let border2 = Color.white.opacity(0.18)
    static let text = Color(hex: 0xF4F7FB)
    static let dim = Color(hex: 0xB6C2D1)
    static let muted = Color(hex: 0x75859A)
    static let accent = Color(hex: 0xF6C85F)
    static let accent2 = Color(hex: 0x73D1FF)
    static let good = Color(hex: 0x7CE3A1)
    static let warn = Color(hex: 0xFFD27A)
    static let bad = Color(hex: 0xFF8D91)
    static let purple = Color(hex: 0xB9A1FF)

    static let smallRadius: CGFloat = 12
    static let controlRadius: CGFloat = 15
    static let cardRadius: CGFloat = 20
    static let heroRadius: CGFloat = 26

    static var appBackground: some ShapeStyle {
        LinearGradient(
            colors: [Color(hex: 0x0B1727), bg, Color(hex: 0x071019)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var heroBackground: some ShapeStyle {
        LinearGradient(
            colors: [Color(hex: 0x18354A).opacity(0.88), panel2.opacity(0.72), Color(hex: 0x121824).opacity(0.90)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var primaryButtonBackground: some ShapeStyle {
        LinearGradient(
            colors: [accent.opacity(0.32), accent2.opacity(0.13)],
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

struct PocketWikiAmbientBackground: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(PocketWikiTheme.appBackground)

            Circle()
                .fill(PocketWikiTheme.accent2.opacity(0.16))
                .frame(width: 520, height: 520)
                .blur(radius: 130)
                .offset(x: -360, y: -310)

            Circle()
                .fill(PocketWikiTheme.accent.opacity(0.10))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: 430, y: -250)

            Circle()
                .fill(PocketWikiTheme.purple.opacity(0.09))
                .frame(width: 460, height: 460)
                .blur(radius: 150)
                .offset(x: 250, y: 390)
        }
        .ignoresSafeArea()
    }
}

struct PocketWikiCardBackground: ViewModifier {
    var isHero = false

    func body(content: Content) -> some View {
        let radius = isHero ? PocketWikiTheme.heroRadius : PocketWikiTheme.cardRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(isHero ? AnyShapeStyle(PocketWikiTheme.heroBackground) : AnyShapeStyle(PocketWikiTheme.panel.opacity(0.68)))
                }
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(isHero ? 0.24 : 0.16), Color.white.opacity(0.04), PocketWikiTheme.accent2.opacity(isHero ? 0.20 : 0.07)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(isHero ? 0.30 : 0.20), radius: isHero ? 30 : 18, x: 0, y: isHero ? 16 : 10)
            }
    }
}

struct PocketWikiGlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(tint?.opacity(0.10) ?? .clear, in: shape)
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
        }
    }
}

struct PocketWikiSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background {
                ZStack {
                    shape.fill(.thinMaterial)
                    shape.fill((tint ?? PocketWikiTheme.panel).opacity(tint == nil ? 0.58 : 0.12))
                }
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
            }
    }
}

extension View {
    func pocketWikiCard(hero: Bool = false) -> some View {
        modifier(PocketWikiCardBackground(isHero: hero))
    }

    func pocketWikiGlass(
        cornerRadius: CGFloat = PocketWikiTheme.controlRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(PocketWikiGlassModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    func pocketWikiSurface(
        cornerRadius: CGFloat = PocketWikiTheme.controlRadius,
        tint: Color? = nil
    ) -> some View {
        modifier(PocketWikiSurfaceModifier(cornerRadius: cornerRadius, tint: tint))
    }
}
