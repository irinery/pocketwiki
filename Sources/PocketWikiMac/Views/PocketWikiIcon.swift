import SwiftUI

struct PocketWikiIcon: View {
    let kind: PocketWikiIconKind
    var size: CGFloat = 18

    var body: some View {
        PocketWikiIconShape(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PocketWikiIconShape: Shape {
    let kind: PocketWikiIconKind

    func path(in rect: CGRect) -> Path {
        var path = Path()

        switch kind {
        case .dashboard:
            path.move(to: CGPoint(x: 3, y: 3))
            path.addLine(to: CGPoint(x: 3, y: 21))
            path.addLine(to: CGPoint(x: 21, y: 21))
            path.addRoundedRect(in: CGRect(x: 7, y: 12, width: 3, height: 5), cornerSize: CGSize(width: 1, height: 1))
            path.addRoundedRect(in: CGRect(x: 12, y: 8, width: 3, height: 9), cornerSize: CGSize(width: 1, height: 1))
            path.addRoundedRect(in: CGRect(x: 17, y: 5, width: 3, height: 12), cornerSize: CGSize(width: 1, height: 1))

        case .ai:
            path.move(to: CGPoint(x: 9.5, y: 2))
            path.addCurve(to: CGPoint(x: 6, y: 5.7), control1: CGPoint(x: 7.5, y: 2), control2: CGPoint(x: 6, y: 3.5))
            path.addCurve(to: CGPoint(x: 4, y: 13), control1: CGPoint(x: 3.8, y: 7), control2: CGPoint(x: 3, y: 10.2))
            path.addCurve(to: CGPoint(x: 8, y: 19), control1: CGPoint(x: 1.8, y: 16.2), control2: CGPoint(x: 4.3, y: 19))
            path.addLine(to: CGPoint(x: 9.5, y: 19))
            path.addLine(to: CGPoint(x: 9.5, y: 2))
            path.move(to: CGPoint(x: 14.5, y: 2))
            path.addCurve(to: CGPoint(x: 18, y: 5.7), control1: CGPoint(x: 16.5, y: 2), control2: CGPoint(x: 18, y: 3.5))
            path.addCurve(to: CGPoint(x: 20, y: 13), control1: CGPoint(x: 20.2, y: 7), control2: CGPoint(x: 21, y: 10.2))
            path.addCurve(to: CGPoint(x: 16, y: 19), control1: CGPoint(x: 22.2, y: 16.2), control2: CGPoint(x: 19.7, y: 19))
            path.addLine(to: CGPoint(x: 14.5, y: 19))
            path.addLine(to: CGPoint(x: 14.5, y: 2))
            for y in [7.0, 12.0, 17.0] {
                path.move(to: CGPoint(x: 9.5, y: y))
                path.addLine(to: CGPoint(x: y == 12 ? 7 : 8, y: y))
                path.move(to: CGPoint(x: 14.5, y: y))
                path.addLine(to: CGPoint(x: y == 12 ? 17 : 16, y: y))
            }

        case .reader:
            path.move(to: CGPoint(x: 4, y: 19.5))
            path.addCurve(to: CGPoint(x: 6.5, y: 17), control1: CGPoint(x: 4, y: 18.1), control2: CGPoint(x: 5.1, y: 17))
            path.addLine(to: CGPoint(x: 20, y: 17))
            path.move(to: CGPoint(x: 4, y: 4.5))
            path.addCurve(to: CGPoint(x: 6.5, y: 2), control1: CGPoint(x: 4, y: 3.1), control2: CGPoint(x: 5.1, y: 2))
            path.addLine(to: CGPoint(x: 20, y: 2))
            path.addLine(to: CGPoint(x: 20, y: 22))
            path.addLine(to: CGPoint(x: 6.5, y: 22))
            path.addCurve(to: CGPoint(x: 4, y: 19.5), control1: CGPoint(x: 5.1, y: 22), control2: CGPoint(x: 4, y: 20.9))
            path.addLine(to: CGPoint(x: 4, y: 4.5))

        case .draw:
            path.move(to: CGPoint(x: 12, y: 20))
            path.addLine(to: CGPoint(x: 21, y: 20))
            path.move(to: CGPoint(x: 16.5, y: 3.5))
            path.addCurve(to: CGPoint(x: 19.5, y: 6.5), control1: CGPoint(x: 17.4, y: 2.6), control2: CGPoint(x: 20.4, y: 5.6))
            path.addLine(to: CGPoint(x: 7, y: 19))
            path.addLine(to: CGPoint(x: 3, y: 20))
            path.addLine(to: CGPoint(x: 4, y: 16))
            path.addLine(to: CGPoint(x: 16.5, y: 3.5))
            path.move(to: CGPoint(x: 15, y: 5))
            path.addLine(to: CGPoint(x: 18, y: 8))

        case .map:
            path.addEllipse(in: CGRect(x: 3, y: 3, width: 6, height: 6))
            path.addEllipse(in: CGRect(x: 15, y: 4, width: 6, height: 6))
            path.addEllipse(in: CGRect(x: 9, y: 15, width: 6, height: 6))
            path.move(to: CGPoint(x: 8.6, y: 7.1))
            path.addLine(to: CGPoint(x: 15.4, y: 7.9))
            path.move(to: CGPoint(x: 16.4, y: 9.5))
            path.addLine(to: CGPoint(x: 13.4, y: 15.3))
            path.move(to: CGPoint(x: 10.2, y: 15.8))
            path.addLine(to: CGPoint(x: 7.8, y: 8.8))

        case .health:
            path.move(to: CGPoint(x: 22, y: 12))
            path.addLine(to: CGPoint(x: 18, y: 12))
            path.addLine(to: CGPoint(x: 15, y: 20))
            path.addLine(to: CGPoint(x: 9, y: 4))
            path.addLine(to: CGPoint(x: 6, y: 12))
            path.addLine(to: CGPoint(x: 2, y: 12))

        case .timeline:
            path.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            path.move(to: CGPoint(x: 12, y: 7))
            path.addLine(to: CGPoint(x: 12, y: 12))
            path.addLine(to: CGPoint(x: 15, y: 14))

        case .server:
            path.addRoundedRect(in: CGRect(x: 3, y: 4, width: 18, height: 8), cornerSize: CGSize(width: 2, height: 2))
            path.addRoundedRect(in: CGRect(x: 3, y: 12, width: 18, height: 8), cornerSize: CGSize(width: 2, height: 2))
            path.addEllipse(in: CGRect(x: 6.6, y: 7.6, width: 0.8, height: 0.8))
            path.addEllipse(in: CGRect(x: 6.6, y: 15.6, width: 0.8, height: 0.8))
        }

        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 24, y: rect.height / 24)
        return path.applying(transform)
    }
}
