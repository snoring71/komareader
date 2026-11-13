import ComicCore
import Foundation
import Observation
import SwiftUI
import UIKit

typealias ReaderOptions = BookRecord.ReaderOptions

/// The reader settings every book starts with (Settings › Book Defaults). A book keeps its
/// own value for anything changed while reading it; the rest follow these.
/// Stored on this device only.
@MainActor
@Observable
final class ReaderDefaults {
    var direction: ReaderOptions.Direction { didSet { save() } }
    var portraitLayout: ReaderOptions.PageLayout { didSet { save() } }
    var landscapeLayout: ReaderOptions.PageLayout { didSet { save() } }
    var fit: ReaderOptions.Fit { didSet { save() } }
    var background: ReaderOptions.Background { didSet { save() } }
    var bindingShadow: Double { didSet { save() } }
    var splitDoublePages: Bool { didSet { save() } }

    private static let key = "readerDefaults"

    private struct Stored: Codable {
        var direction: ReaderOptions.Direction
        var portraitLayout: ReaderOptions.PageLayout
        var landscapeLayout: ReaderOptions.PageLayout
        var fit: ReaderOptions.Fit
        var background: ReaderOptions.Background
        var bindingShadow: Double
        var splitDoublePages: Bool
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            direction = stored.direction
            portraitLayout = stored.portraitLayout
            landscapeLayout = stored.landscapeLayout
            fit = stored.fit
            background = stored.background
            bindingShadow = stored.bindingShadow
            splitDoublePages = stored.splitDoublePages
            return
        }
        // Start from what the reader last used before defaults existed (version 0.1 kept one
        // layout and one fit for all books).
        direction = .leftToRight
        switch defaults.string(forKey: "readerLayout") {
        case "Single Page": portraitLayout = .single; landscapeLayout = .single
        case "Two Pages": portraitLayout = .double; landscapeLayout = .double
        default: portraitLayout = .single; landscapeLayout = .double
        }
        switch defaults.string(forKey: "readerFit") {
        case "Fit Width": fit = .width
        case "Fit Height": fit = .height
        default: fit = .screen
        }
        background = .black
        bindingShadow = 0
        splitDoublePages = false
    }

    private func save() {
        let stored = Stored(direction: direction, portraitLayout: portraitLayout, landscapeLayout: landscapeLayout,
                            fit: fit, background: background, bindingShadow: bindingShadow, splitDoublePages: splitDoublePages)
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Makes a book's current settings (its own and the defaults it follows) the defaults.
    /// Crop is left out: margins belong to one book.
    func adopt(_ options: ReaderOptions) {
        if let value = options.direction { direction = value }
        if let value = options.portraitLayout { portraitLayout = value }
        if let value = options.landscapeLayout { landscapeLayout = value }
        if let value = options.fit { fit = value }
        if let value = options.background { background = value }
        if let value = options.bindingShadow { bindingShadow = value }
        if let value = options.splitDoublePages { splitDoublePages = value }
    }
}

// MARK: - Names and colours

extension ReaderOptions.Direction {
    var title: String { self == .rightToLeft ? "Right to Left (Manga)" : "Left to Right" }
    var systemImage: String { self == .rightToLeft ? "arrow.left" : "arrow.right" }
}

extension ReaderOptions.PageLayout {
    var title: String { self == .single ? "Single Page" : "Two Pages" }
    var systemImage: String { self == .single ? "rectangle.portrait" : "book.pages" }
}

extension ReaderOptions.Fit {
    var title: String {
        switch self {
        case .screen: return "Fit Screen"
        case .width: return "Fit Width"
        case .height: return "Fit Height"
        }
    }

    var systemImage: String {
        switch self {
        case .screen: return "arrow.up.left.and.arrow.down.right"
        case .width: return "arrow.left.and.right"
        case .height: return "arrow.up.and.down"
        }
    }
}

extension ReaderOptions.Background {
    /// The choices offered in menus; `custom` stands for whichever colour was picked.
    enum Choice: String, CaseIterable, Identifiable {
        case black, gray, white, dynamic, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .black: return "Black"
            case .gray: return "Gray"
            case .white: return "White"
            case .dynamic: return "Match Page"
            case .custom: return "Custom Color"
            }
        }
    }

    var choice: Choice {
        switch self {
        case .black: return .black
        case .gray: return .gray
        case .white: return .white
        case .dynamic: return .dynamic
        case .custom: return .custom
        }
    }

    /// The fixed colour, or nil for `dynamic` (which depends on the page).
    var uiColor: UIColor? {
        rgb.map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
    }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        self = .fromRGB(red: r, green: g, blue: b)
    }
}

/// The binding shadow strengths offered in menus.
enum BindingShadowStrength: Double, CaseIterable, Identifiable {
    case off = 0, light = 0.35, medium = 0.6, strong = 0.9
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }

    /// The listed strength nearest to `value`.
    static func nearest(_ value: Double) -> BindingShadowStrength {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .off
    }
}

extension UIColor {
    /// Whether text and spinners on this colour should be dark.
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else {
            var white: CGFloat = 0
            getWhite(&white, alpha: &a)
            return white > 0.6
        }
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
    }
}
