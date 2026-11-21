import SwiftUI
import UIKit

/// The app's black-and-white look (#55). The accent color (`AccentColor` in the asset catalog)
/// is black in light mode and white in dark mode, so anything drawn on an accent fill needs
/// the opposite color, `Color.onAccent`, to stay readable in both.
extension Color {
    /// White in light mode, black in dark mode: text and symbols on an accent (primary) fill.
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })

    /// The Read tab's fill: black in light mode; in dark mode a dark grey that stands out from
    /// the black background without the glare of a white tab (#73).
    static let readTabFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)
            : .black
    })

    /// The Read tab's checkmark: white in light mode; in dark mode a lighter grey, not full
    /// white, so it reads clearly without drawing the eye (#73).
    static let readTabCheck = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0xA8 / 255, alpha: 1) : .white
    })
}

/// A switch in black and white instead of green: on is a solid primary track with an inverted
/// knob on the right, off is the usual grey track with a white knob on the left. Set once at
/// the app root, so every `Toggle` uses it.
struct MonoToggleStyle: ToggleStyle {
    private static let size = CGSize(width: 51, height: 31)
    private static let inset: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        MonoToggle(configuration: configuration)
    }

    private struct MonoToggle: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack {
                configuration.label
                Spacer(minLength: 12)
                track
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: flip)
            .opacity(isEnabled ? 1 : 0.5)
            .sensoryFeedback(.selection, trigger: configuration.isOn)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "1" : "0")
            .accessibilityAction(.default, flip)
        }

        private var track: some View {
            let size = MonoToggleStyle.size
            let knob = size.height - MonoToggleStyle.inset * 2
            let on = configuration.isOn
            return Capsule()
                .fill(on ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color(uiColor: .systemFill)))
                .frame(width: size.width, height: size.height)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(on ? Color.onAccent : Color.white)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .frame(width: knob, height: knob)
                        .padding(MonoToggleStyle.inset)
                }
                .animation(.spring(duration: 0.25, bounce: 0.15), value: on)
        }

        private func flip() {
            guard isEnabled else { return }
            configuration.isOn.toggle()
        }
    }
}

/// A thin bar showing how far through a book the reader is: the primary color at full
/// strength on a faded track of the same color.
struct MonoProgressBar: View {
    let fraction: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.2))
                Capsule().fill(Color.primary)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}
