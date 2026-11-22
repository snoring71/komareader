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
    var contrast: Double { didSet { save() } }
    var sharpness: Double { didSet { save() } }
    var paperGrain: Double { didSet { save() } }
    var paperTint: Double { didSet { save() } }
    var brightness: Double { didSet { save() } }
    var gamma: Double { didSet { save() } }
    var saturation: Double { didSet { save() } }
    var blackAndWhite: Bool { didSet { save() } }
    var autoFix: Bool { didSet { save() } }
    var nightMode: ReaderOptions.NightMode { didSet { save() } }
    var nightOnlyInDark: Bool { didSet { save() } }
    var descreen: Double { didSet { save() } }
    var sharperScaling: Bool { didSet { save() } }
    var keepColorPages: Bool { didSet { save() } }
    var paperStock: ReaderOptions.PaperStock { didSet { save() } }
    var autoTrim: Bool { didSet { save() } }
    var pageTurn: ReaderOptions.PageTurn { didSet { save() } }
    var pageEdges: Bool { didSet { save() } }
    var upscale: Bool { didSet { save() } }

    /// How pages are drawn for a book that sets nothing itself.
    var look: PageLook {
        get {
            var look = PageLook()
            look.contrast = contrast
            look.sharpness = sharpness
            look.paperGrain = paperGrain
            look.paperTint = paperTint
            look.brightness = brightness
            look.gamma = gamma
            look.saturation = saturation
            look.blackAndWhite = blackAndWhite
            look.autoFix = autoFix
            look.nightMode = nightMode
            look.nightOnlyInDark = nightOnlyInDark
            look.descreen = descreen
            look.sharperScaling = sharperScaling
            look.keepColorPages = keepColorPages
            look.paperStock = paperStock
            look.upscale = upscale
            return look
        }
        set { adopt(newValue.options) }
    }

    private static let key = "readerDefaults"

    /// Saved sets of image adjustments (#123), in the order they were made. On this device.
    var namedLooks: [NamedLook] = ReaderDefaults.loadLooks() {
        didSet {
            if let data = try? JSONEncoder().encode(namedLooks) { UserDefaults.standard.set(data, forKey: Self.looksKey) }
        }
    }

    private static let looksKey = "namedLooks"

    private static func loadLooks() -> [NamedLook] {
        guard let data = UserDefaults.standard.data(forKey: looksKey) else { return [] }
        return (try? JSONDecoder().decode([NamedLook].self, from: data)) ?? []
    }

    private struct Stored: Codable {
        var direction: ReaderOptions.Direction
        var portraitLayout: ReaderOptions.PageLayout
        var landscapeLayout: ReaderOptions.PageLayout
        var fit: ReaderOptions.Fit
        var background: ReaderOptions.Background
        var bindingShadow: Double
        var splitDoublePages: Bool
        // Added later: optional, so defaults saved by an older build still load.
        var contrast: Double?
        var sharpness: Double?
        var paperGrain: Double?
        var paperTint: Double?
        var brightness: Double?
        var gamma: Double?
        var saturation: Double?
        var blackAndWhite: Bool?
        var autoFix: Bool?
        var nightMode: ReaderOptions.NightMode?
        var nightOnlyInDark: Bool?
        var descreen: Double?
        var sharperScaling: Bool?
        var keepColorPages: Bool?
        var paperStock: ReaderOptions.PaperStock?
        var autoTrim: Bool?
        var pageTurn: ReaderOptions.PageTurn?
        var pageEdges: Bool?
        var upscale: Bool?
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
            contrast = stored.contrast ?? 0
            sharpness = stored.sharpness ?? 0
            paperGrain = stored.paperGrain ?? 0
            paperTint = stored.paperTint ?? 0
            brightness = stored.brightness ?? 0
            gamma = stored.gamma ?? 0
            saturation = stored.saturation ?? 0
            blackAndWhite = stored.blackAndWhite ?? false
            autoFix = stored.autoFix ?? false
            nightMode = stored.nightMode ?? .off
            nightOnlyInDark = stored.nightOnlyInDark ?? false
            descreen = stored.descreen ?? 0
            sharperScaling = stored.sharperScaling ?? false
            keepColorPages = stored.keepColorPages ?? true
            paperStock = stored.paperStock ?? .plain
            autoTrim = stored.autoTrim ?? false
            pageTurn = stored.pageTurn ?? .slide
            pageEdges = stored.pageEdges ?? false
            upscale = stored.upscale ?? false
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
        contrast = 0
        sharpness = 0
        paperGrain = 0
        paperTint = 0
        brightness = 0
        gamma = 0
        saturation = 0
        blackAndWhite = false
        autoFix = false
        nightMode = .off
        nightOnlyInDark = false
        descreen = 0
        sharperScaling = false
        keepColorPages = true
        paperStock = .plain
        autoTrim = false
        pageTurn = .slide
        pageEdges = false
        upscale = false
    }

    private func save() {
        let stored = Stored(direction: direction, portraitLayout: portraitLayout, landscapeLayout: landscapeLayout,
                            fit: fit, background: background, bindingShadow: bindingShadow, splitDoublePages: splitDoublePages,
                            contrast: contrast, sharpness: sharpness, paperGrain: paperGrain, paperTint: paperTint,
                            brightness: brightness, gamma: gamma, saturation: saturation, blackAndWhite: blackAndWhite,
                            autoFix: autoFix, nightMode: nightMode, nightOnlyInDark: nightOnlyInDark, descreen: descreen,
                            sharperScaling: sharperScaling, keepColorPages: keepColorPages, paperStock: paperStock,
                            autoTrim: autoTrim, pageTurn: pageTurn, pageEdges: pageEdges, upscale: upscale)
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
        if let value = options.contrast { contrast = value }
        if let value = options.sharpness { sharpness = value }
        if let value = options.paperGrain { paperGrain = value }
        if let value = options.paperTint { paperTint = value }
        if let value = options.brightness { brightness = value }
        if let value = options.gamma { gamma = value }
        if let value = options.saturation { saturation = value }
        if let value = options.blackAndWhite { blackAndWhite = value }
        if let value = options.autoFix { autoFix = value }
        if let value = options.nightMode { nightMode = value }
        if let value = options.nightOnlyInDark { nightOnlyInDark = value }
        if let value = options.descreen { descreen = value }
        if let value = options.sharperScaling { sharperScaling = value }
        if let value = options.keepColorPages { keepColorPages = value }
        if let value = options.paperStock { paperStock = value }
        if let value = options.autoTrim { autoTrim = value }
        if let value = options.pageTurn { pageTurn = value }
        if let value = options.pageEdges { pageEdges = value }
        if let value = options.upscale { upscale = value }
    }
}

/// A named set of image adjustments, such as "1980s tankobon" (#123).
struct NamedLook: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Every image setting, as a book would save them.
    var options: ReaderOptions

    func look(darkAppearance: Bool) -> PageLook {
        var base = PageLook()
        base.darkAppearance = darkAppearance
        return PageLook(options: options, base: base)
    }
}

// MARK: - Names and colours

extension ReaderOptions.PageTurn {
    var title: String {
        switch self {
        case .slide: return "Slide"
        case .curl: return "Curl"
        case .fade: return "Fade"
        case .instant: return "Instant"
        }
    }
}

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
