import ComicCore
import LibraryKit
import SwiftUI

/// Settings › File Names (#77): the patterns used to read series, number, author, year and
/// publisher from file names, which can be switched off or reordered, next to a sample of real
/// file names and what is read from each.
struct FileNamesView: View {
    @Environment(AppModel.self) private var model
    @State private var rules = FileNameRules.standard
    @State private var samples: [Book] = []

    var body: some View {
        List {
            Section {
                ForEach($rules.rules) { $rule in
                    Toggle(isOn: $rule.isOn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.kind.title)
                            Text(rule.kind.example)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("filename-rule-\(rule.kind.rawValue)")
                }
                .onMove { from, to in rules.rules.move(fromOffsets: from, toOffset: to) }
            } header: {
                Text("Patterns")
            } footer: {
                Text("Patterns higher in the list are tried first. Drag to reorder. What a file name says is used only where the book's ComicInfo.xml says nothing and you have not edited it.")
            }

            Section {
                Button("Restore Standard Patterns") { rules = .standard }
                    .tint(.primary)
                    .disabled(rules == .standard)
            }

            Section {
                ForEach(samples) { book in
                    let read = FileNameReader.read(book.title, folder: book.folder, rules: rules)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.relativePath)
                            .font(.subheadline)
                            .lineLimit(2)
                            .truncationMode(.head)
                        Text(Self.summary(read))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("From Your Library")
            } footer: {
                Text("A sample of your file names and what is read from each with the patterns above.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("File Names")
        .onAppear {
            rules = model.fileNameRules
            samples = Self.sample(model.books)
        }
        .onChange(of: rules) { _, new in model.fileNameRules = new }
    }

    /// "Series: ARIA · Number: 7 · Author: 天野こずえ".
    static func summary(_ info: BookData) -> String {
        var parts: [String] = []
        if let series = info.series { parts.append("Series: \(series)") }
        if let number = info.number { parts.append("Number: \(number)") }
        if let count = info.count { parts.append("Of: \(count)") }
        if let writers = info.writers, !writers.isEmpty { parts.append("Author: \(writers.joined(separator: ", "))") }
        if let year = info.year { parts.append("Year: \(year)") }
        if let publisher = info.publisher { parts.append("Publisher: \(publisher)") }
        return parts.joined(separator: " · ")
    }

    /// About 30 books spread through the library by path, so different folders show.
    static func sample(_ books: [Book]) -> [Book] {
        let present = books.filter { !$0.isMissing }
        guard present.count > 30 else { return present }
        let step = Double(present.count) / 30
        return (0..<30).map { present[Int(Double($0) * step)] }
    }
}
