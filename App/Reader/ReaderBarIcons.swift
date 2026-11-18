import SwiftUI

// The reader menu bar's own icons, drawn to one 24-point grid with 1.6-point lines so they
// sit together with the SF Symbols beside them. Each shows its current value where that helps.

private let line: CGFloat = 1.6

/// Reading progress: a ring that fills as the book is read, with the percentage inside.
struct ProgressRingIcon: View {
    let fraction: Double

    var body: some View {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.22), lineWidth: 2.4)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: fraction)
            Text(verbatim: "\(percent)")
                .font(.system(size: percent >= 100 ? 9 : 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: Double(percent)))
        }
        .frame(width: 30, height: 30)
    }
}

/// One page or two open pages side by side; a dashed fold when double pages are split.
struct PageLayoutIcon: View {
    let layout: ReaderOptions.PageLayout
    var split = false

    var body: some View {
        ZStack {
            switch layout {
            case .single:
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(lineWidth: line)
                    .frame(width: 13, height: 18)
                lines.frame(width: 7)
            case .double:
                HStack(spacing: 0) {
                    UnevenRoundedRectangle(topLeadingRadius: 2.5, bottomLeadingRadius: 2.5, style: .continuous)
                        .stroke(lineWidth: line)
                        .overlay { lines.frame(width: 5) }
                    UnevenRoundedRectangle(bottomTrailingRadius: 2.5, topTrailingRadius: 2.5, style: .continuous)
                        .stroke(lineWidth: line)
                        .overlay { lines.frame(width: 5) }
                }
                .frame(width: 22, height: 16)
            }
            if split {
                VStack(spacing: 1.6) {
                    ForEach(0..<6, id: \.self) { _ in Capsule().frame(width: 1.2, height: 2.2) }
                }
                .frame(height: 22)
            }
        }
        .frame(width: 24, height: 24)
    }

    /// Two faint lines of "text" on a page.
    private var lines: some View {
        VStack(spacing: 2.5) {
            Capsule().frame(height: 1.4)
            Capsule().frame(height: 1.4).padding(.trailing, 2)
        }
        .opacity(0.55)
    }
}

/// The screen's corners with what fills it: a whole page, the width, or the height.
struct FitIcon: View {
    let fit: ReaderOptions.Fit

    var body: some View {
        ZStack {
            CornerBrackets()
                .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                .frame(width: 21, height: 21)
            switch fit {
            case .screen:
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 8, height: 11)
            case .width:
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .bold))
            case .height:
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// The four corners of a frame.
struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.3
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
    }
}

/// A page with a turned corner on the side pages turn from, and an arrow the way reading goes.
struct DirectionIcon: View {
    let rightToLeft: Bool

    var body: some View {
        ZStack {
            DogEaredPage()
                .stroke(style: StrokeStyle(lineWidth: line, lineJoin: .round))
                .frame(width: 16, height: 20)
                .scaleEffect(x: rightToLeft ? -1 : 1)
            Image(systemName: rightToLeft ? "arrow.left" : "arrow.right")
                .font(.system(size: 9, weight: .heavy))
                .offset(y: 1.5)
        }
        .frame(width: 24, height: 24)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: rightToLeft)
    }
}

/// A page outline with its top right corner folded over.
struct DogEaredPage: Shape {
    func path(in rect: CGRect) -> Path {
        let fold = rect.width * 0.36
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 2))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - 2, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 2), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 2))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 2, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        // The fold.
        path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        return path
    }
}

/// A swatch of the background colour; Match Page shows a page with its colour spilling out.
struct BackgroundIcon: View {
    let background: ReaderOptions.Background

    var body: some View {
        ZStack {
            if let color = background.uiColor {
                Circle().fill(Color(uiColor: color))
            } else {
                Circle().fill(AngularGradient(colors: [.orange, .pink, .purple, .blue, .teal, .yellow, .orange], center: .center))
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.white)
                    .frame(width: 7, height: 10)
                    .shadow(color: .black.opacity(0.3), radius: 1)
            }
            Circle().stroke(Color.primary.opacity(0.85), lineWidth: line)
        }
        .frame(width: 21, height: 21)
        .frame(width: 24, height: 24)
    }
}

/// Image adjustments: a circle half light, half dark, with a sparkle of sharpness.
struct AdjustmentsIcon: View {
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: line)
            HalfDisc().fill()
                .padding(1.5)
        }
        .frame(width: 20, height: 20)
        .overlay(alignment: .topTrailing) {
            Image(systemName: "sparkle")
                .font(.system(size: 8, weight: .bold))
                .offset(x: 4, y: -4)
        }
        .frame(width: 24, height: 24)
    }
}

/// The right half of a circle.
struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        return path
    }
}
