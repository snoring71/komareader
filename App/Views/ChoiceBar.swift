import SwiftUI

/// A row of choices, one selected, like a segmented control. Used instead of a segmented
/// `Picker`, which on iPad in popovers and sheets often ignored taps (the control lit up but
/// the selection did not move until tapped again).
struct ChoiceBar<Value: Hashable>: View {
    let choices: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var highlight

    init(_ choices: [(Value, String)], selection: Binding<Value>) {
        self.choices = choices
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices.indices, id: \.self) { index in
                let value = choices[index].0
                let selected = value == selection
                Button {
                    guard !selected else { return }
                    selection = value
                } label: {
                    Text(choices[index].1)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .padding(.horizontal, 6)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color(uiColor: .systemBackground))
                                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selected", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        .animation(.snappy(duration: 0.2), value: selection)
    }
}
