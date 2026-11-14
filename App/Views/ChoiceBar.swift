import SwiftUI

/// A row of choices, one selected, like a segmented control. Used instead of a segmented
/// `Picker`, which on iPad in popovers and sheets often ignored taps (the control lit up but
/// the selection did not move until tapped again).
///
/// The highlight slides to the tapped choice at once; the new value is handed on once the
/// slide is over, so whatever the change sets off (the reader redrawing its pages, say) does
/// not stutter the animation.
struct ChoiceBar<Value: Hashable>: View {
    let choices: [(Value, String)]
    @Binding var selection: Value
    /// The choice just tapped, shown until it has been handed on.
    @State private var pending: Value?
    @State private var commit: Task<Void, Never>?

    private static var slide: Animation { .spring(duration: 0.28, bounce: 0.12) }
    private static var height: CGFloat { 34 }

    init(_ choices: [(Value, String)], selection: Binding<Value>) {
        self.choices = choices
        _selection = selection
    }

    private var shown: Value { pending ?? selection }
    private var shownIndex: Int { choices.firstIndex { $0.0 == shown } ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices.indices, id: \.self) { index in
                let selected = index == shownIndex
                Button {
                    choose(choices[index].0)
                } label: {
                    Text(choices[index].1)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // One highlight that slides between equal-width slots, under the labels.
        .background(alignment: .leading) {
            GeometryReader { geo in
                let width = geo.size.width / CGFloat(max(choices.count, 1))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width, height: geo.size.height)
                    .offset(x: width * CGFloat(shownIndex))
            }
        }
        .padding(3)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        .animation(Self.slide, value: shownIndex)
        .onDisappear { commitNow() }
    }

    private func choose(_ value: Value) {
        guard value != shown else { return }
        pending = value
        commit?.cancel()
        commit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            if Task.isCancelled { return }
            commitNow()
        }
    }

    private func commitNow() {
        guard let value = pending else { return }
        commit?.cancel()
        commit = nil
        if selection != value { selection = value }
        pending = nil
    }
}
