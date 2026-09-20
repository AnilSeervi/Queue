import SwiftUI

// Custom glyphs from the handoff (16×16 viewBox, 1.5–1.8 stroke, round caps).
// The PR glyph is the app's identity icon — kept custom (no GitHub trademarks).

/// "Pull request" glyph: two stacked circles joined by a line + arc to a third circle.
struct PRGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var p = Path()
        // Top-left circle
        p.addEllipse(in: CGRect(x: rect.minX + 2.6 * s, y: rect.minY + 2.1 * s, width: 3.8 * s, height: 3.8 * s))
        // Bottom-left circle
        p.addEllipse(in: CGRect(x: rect.minX + 2.6 * s, y: rect.minY + 10.1 * s, width: 3.8 * s, height: 3.8 * s))
        // Connecting line
        p.move(to: pt(4.5, 6.3))
        p.addLine(to: pt(4.5, 9.7))
        // Arc from top circle to bottom-right circle
        p.move(to: pt(6.8, 4))
        p.addLine(to: pt(9.4, 4))
        p.addQuadCurve(to: pt(11.4, 6), control: pt(11.4, 4))
        p.addLine(to: pt(11.4, 9.7))
        // Bottom-right circle
        p.addEllipse(in: CGRect(x: rect.minX + 9.5 * s, y: rect.minY + 10.1 * s, width: 3.8 * s, height: 3.8 * s))
        return p
    }
}

struct PRGlyph: View {
    var color: Color
    var size: CGFloat = 15
    var lineWidth: CGFloat = 1.6

    var body: some View {
        PRGlyphShape()
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// Issue icon: circle with a dot.
struct CircleDotIcon: View {
    var color: Color
    var size: CGFloat = 15

    var body: some View {
        ZStack {
            Circle().stroke(color, lineWidth: 1.5)
            Circle().fill(color).frame(width: size * 0.28, height: size * 0.28)
        }
        .frame(width: size, height: size)
    }
}

/// Pulsing 9px dot (running CI): opacity 1→0.3, 1.6s ease-in-out infinite.
struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 9
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// Snooze icon: clock with small "z" lines at top-right (tab bar snooze-all).
struct SnoozeClockIcon: View {
    var color: Color
    var size: CGFloat = 14

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "clock")
                .font(.system(size: size * 0.8, weight: .medium))
                .foregroundStyle(color)
            VStack(alignment: .trailing, spacing: 1.5) {
                Capsule().fill(color).frame(width: size * 0.28, height: 1.4)
                Capsule().fill(color).frame(width: size * 0.2, height: 1.4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: size, height: size)
    }
}
