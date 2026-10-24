import SwiftUI

/// Master artwork for The Reveal. The app, icon renderer and motion all use these paths.
/// Coordinates are normalized to a 512-point square; the opening is actual negative space.
nonisolated struct RevealShape: Shape {
    enum Part: Sendable { case coral, peach }
    let part: Part

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch part {
        case .coral:
            path.move(to: CGPoint(x: 280, y: 66))
            path.addCurve(to: CGPoint(x: 313, y: 85), control1: CGPoint(x: 300, y: 57), control2: CGPoint(x: 312, y: 65))
            path.addLine(to: CGPoint(x: 316, y: 223))
            path.addLine(to: CGPoint(x: 180, y: 181))
            path.addCurve(to: CGPoint(x: 166, y: 191), control1: CGPoint(x: 173, y: 178), control2: CGPoint(x: 166, y: 183))
            path.addLine(to: CGPoint(x: 166, y: 294))
            path.addCurve(to: CGPoint(x: 180, y: 313), control1: CGPoint(x: 166, y: 305), control2: CGPoint(x: 170, y: 309))
            path.addLine(to: CGPoint(x: 320, y: 360))
            path.addLine(to: CGPoint(x: 322, y: 422))
            path.addCurve(to: CGPoint(x: 293, y: 447), control1: CGPoint(x: 323, y: 444), control2: CGPoint(x: 313, y: 453))
            path.addLine(to: CGPoint(x: 102, y: 382))
            path.addCurve(to: CGPoint(x: 54, y: 316), control1: CGPoint(x: 71, y: 371), control2: CGPoint(x: 54, y: 350))
            path.addLine(to: CGPoint(x: 54, y: 230))
            path.addCurve(to: CGPoint(x: 110, y: 138), control1: CGPoint(x: 54, y: 185), control2: CGPoint(x: 73, y: 156))
            path.closeSubpath()
        case .peach:
            path.move(to: CGPoint(x: 316, y: 223))
            path.addLine(to: CGPoint(x: 394, y: 243))
            path.addCurve(to: CGPoint(x: 456, y: 302), control1: CGPoint(x: 431, y: 252), control2: CGPoint(x: 454, y: 269))
            path.addLine(to: CGPoint(x: 457, y: 349))
            path.addCurve(to: CGPoint(x: 408, y: 418), control1: CGPoint(x: 457, y: 382), control2: CGPoint(x: 442, y: 405))
            path.addLine(to: CGPoint(x: 353, y: 440))
            path.addCurve(to: CGPoint(x: 314, y: 444), control1: CGPoint(x: 340, y: 447), control2: CGPoint(x: 329, y: 449))
            path.addCurve(to: CGPoint(x: 322, y: 422), control1: CGPoint(x: 321, y: 443), control2: CGPoint(x: 323, y: 434))
            path.closeSubpath()
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 512, y: rect.height / 512)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct RevealSymbol: View {
    var coralProgress: Double = 1
    var peachProgress: Double = 1
    var only: RevealShape.Part? = nil
    var monochrome = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if only == nil || only == .peach {
                    RevealShape(part: .peach)
                        .fill(monochrome ? AnyShapeStyle(Color.black) : AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 1, green: 0.77, blue: 0.58), Color(red: 1, green: 0.67, blue: 0.47)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .rotationEffect(.degrees(8 * (1 - peachProgress)), anchor: .leading)
                        .offset(x: geometry.size.width * 0.16 * (1 - peachProgress))
                        .opacity(peachProgress)
                }
                if only == nil || only == .coral {
                    RevealShape(part: .coral)
                        .fill(monochrome ? AnyShapeStyle(Color.black) : AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 0.98, green: 0.47, blue: 0.38), Color(red: 0.93, green: 0.36, blue: 0.31)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .rotationEffect(.degrees(-6 * (1 - coralProgress)), anchor: .trailing)
                        .offset(x: geometry.size.width * -0.10 * (1 - coralProgress))
                        .opacity(coralProgress)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
