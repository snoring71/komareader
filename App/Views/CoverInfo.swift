import LibraryKit
import SwiftUI

/// What the library shows on top of each cover when Cover Info is on (issue #41): one name
/// line, plus any of pages, size, format and location. Set once near the root from the
/// settings, like `CoverStyle`.
struct CoverInfo: Equatable {
    var isOn = false
    var name: CoverInfoName = .title
    var pages = true
    var size = true
    var format = true
    var location = false

    /// True when the name comes from inside the files, so it has to be read from them.
    var needsFileMetadata: Bool {
        isOn && name.needsFileMetadata
    }
}

enum CoverInfoName: String, CaseIterable, Identifiable {
    case none, fileName, title, author, publisher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .fileName: return "File Name"
        case .title: return "Title"
        case .author: return "Author"
        case .publisher: return "Publisher"
        }
    }

    var needsFileMetadata: Bool {
        switch self {
        case .title, .author, .publisher: return true
        case .none, .fileName: return false
        }
    }

    /// The line to show for a book. Nil for `.none`; a dash when the file does not say.
    func text(for book: Book) -> String? {
        switch self {
        case .none: return nil
        case .fileName: return (book.relativePath as NSString).lastPathComponent
        case .title: return book.metadataTitle ?? book.title
        case .author: return book.author ?? "–"
        case .publisher: return book.publisher ?? "–"
        }
    }
}

extension EnvironmentValues {
    @Entry var coverInfo = CoverInfo()
}

extension SettingsKeys {
    static let coverInfo = "library.coverInfo"
    static let coverInfoName = "library.coverInfo.name"
    static let coverInfoPages = "library.coverInfo.pages"
    static let coverInfoSize = "library.coverInfo.size"
    static let coverInfoFormat = "library.coverInfo.format"
    static let coverInfoLocation = "library.coverInfo.location"
}

/// The Cover Info settings, as stored, for the views that change them.
struct CoverInfoSettings: DynamicProperty {
    @AppStorage(SettingsKeys.coverInfo) var isOn = false
    @AppStorage(SettingsKeys.coverInfoName) var name: CoverInfoName = .title
    @AppStorage(SettingsKeys.coverInfoPages) var pages = true
    @AppStorage(SettingsKeys.coverInfoSize) var size = true
    @AppStorage(SettingsKeys.coverInfoFormat) var format = true
    @AppStorage(SettingsKeys.coverInfoLocation) var location = false

    var value: CoverInfo {
        CoverInfo(isOn: isOn, name: name, pages: pages, size: size, format: format, location: location)
    }
}

/// The choice of fields, shared by the toolbar's Cover Info menu and Settings.
struct CoverInfoFieldControls: View {
    var settings = CoverInfoSettings()

    var body: some View {
        Picker("Name", selection: settings.$name) {
            ForEach(CoverInfoName.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Pages", isOn: settings.$pages)
        Toggle("File Size", isOn: settings.$size)
        Toggle("Format", isOn: settings.$format)
        Toggle("Location", isOn: settings.$location)
    }
}

/// The info drawn over the bottom of a cover: dark and see-through, so white text reads on
/// light and dark covers alike.
struct CoverInfoOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverInfo) private var info
    @Environment(\.coverStyle) private var style
    let book: Book
    let status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = info.name.text(for: book) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
            }
            let details = detailParts
            if !details.isEmpty || book.favorite || book.bookmarked {
                HStack(spacing: 3) {
                    if book.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                    if book.bookmarked { Image(systemName: "bookmark.fill").foregroundStyle(.orange) }
                    Text(details.joined(separator: " · "))
                }
                .font(.caption2)
                .imageScale(.small)
                .lineLimit(1)
            }
            if info.location {
                Text(book.folder.isEmpty ? model.libraryName : book.folder)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .opacity(0.85)
            }
            if book.status == .reading, let fraction = book.progressFraction {
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.3))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.tint).frame(width: geo.size.width * fraction)
                        }
                }
                .frame(height: 3)
                .padding(.top, 2)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.62))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: style.cornerRadius, bottomTrailingRadius: style.cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var detailParts: [String] {
        var parts: [String] = []
        if let status { parts.append(status) }
        if info.pages, let pages = book.pageCount { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        if info.size, let size = book.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if info.format { parts.append(book.format.displayName) }
        return parts
    }
}
