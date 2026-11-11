import ComicCore
import UIKit

/// A generated sample library used for UI tests and screenshots (launch with `-demo`).
/// Add `-demoCount 10000` for that many extra small books, to test the grid at scale.
enum DemoLibrary {
    static let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DemoData", isDirectory: true)

    static func make(extraBooks: Int = 0) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DemoLibrary", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: dataRoot)
        let series: [(String, Int, UIColor)] = [
            ("Starfall", 4, .systemIndigo), ("Harbor Lights", 3, .systemTeal),
            ("Night Market", 3, .systemOrange), ("Paper Moon", 2, .systemPink),
        ]
        for (name, volumes, color) in series {
            for volume in 1...volumes {
                let folder = root.appendingPathComponent(name).appendingPathComponent("\(name) \(volume)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for page in 1...8 {
                    let wide = page == 6
                    let image = render(title: page == 1 ? "\(name)\nVol. \(volume)" : "\(page)", color: color, wide: wide, cover: page == 1)
                    try? image.jpegData(compressionQuality: 0.8)?.write(to: folder.appendingPathComponent(String(format: "%03d.jpg", page)))
                }
            }
        }
        makeMany(extraBooks, in: root.appendingPathComponent("More", isDirectory: true))
        seedOtherDevices(folderName: root.lastPathComponent)
        return root
    }

    /// Small two-page books, ten to a series, written from a few pre-rendered pages.
    private static func makeMany(_ count: Int, in folder: URL) {
        guard count > 0 else { return }
        let colors: [UIColor] = [.systemRed, .systemGreen, .systemBlue, .systemPurple, .systemBrown, .systemMint]
        let pages = colors.map { color in
            (render(title: "Demo", color: color, wide: false, cover: true).jpegData(compressionQuality: 0.6) ?? Data(),
             render(title: "2", color: color, wide: false, cover: false).jpegData(compressionQuality: 0.6) ?? Data())
        }
        for index in 0..<count {
            let series = index / 10 + 1
            let book = folder.appendingPathComponent("Series \(series)").appendingPathComponent("Series \(series) \(index % 10 + 1)")
            try? FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
            let (cover, page) = pages[series % pages.count]
            try? cover.write(to: book.appendingPathComponent("001.jpg"))
            try? page.write(to: book.appendingPathComponent("002.jpg"))
        }
    }

    /// Positions from "other devices" for Harbor Lights 1: the iPhone opened it last at page 3,
    /// but the Mac had read on to page 6, so the reader offers to jump there.
    private static func seedOtherDevices(folderName: String) {
        guard let store = try? RecordStore.open(dataRoot: dataRoot, folderName: folderName) else { return }
        let path = "Harbor Lights/Harbor Lights 1"
        var record = BookRecord(bookId: StableID.book(path: path), file: .init(path: path, size: nil, modified: nil))
        record.progress["mac-demo"] = .init(page: 5, pageCount: 8, finished: false, updatedAt: Date().addingTimeInterval(-86_400))
        record.progress["iphone-demo"] = .init(page: 2, pageCount: 8, finished: false, updatedAt: Date().addingTimeInterval(-3_600))
        try? store.write(record)
    }

    private static func render(title: String, color: UIColor, wide: Bool, cover: Bool) -> UIImage {
        let size = CGSize(width: wide ? 1600 : 800, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            (cover ? color : UIColor(white: 0.97, alpha: 1)).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if !cover {
                // Simple panel grid.
                color.withAlphaComponent(0.25).setFill()
                let inset: CGFloat = 40, gap: CGFloat = 24
                let w = (size.width - inset * 2 - gap) / 2, h = (size.height - inset * 2 - gap * 2) / 3
                for row in 0..<3 {
                    for col in 0..<2 where !(row == 1 && col == 1) {
                        let rect = CGRect(x: inset + CGFloat(col) * (w + gap), y: inset + CGFloat(row) * (h + gap),
                                          width: row == 1 ? w * 2 + gap : w, height: h)
                        UIBezierPath(roundedRect: rect, cornerRadius: 12).fill()
                    }
                }
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: cover ? 110 : 160, weight: .heavy),
                .foregroundColor: cover ? UIColor.white : color,
                .paragraphStyle: style,
            ]
            let text = NSAttributedString(string: title, attributes: attributes)
            let bounds = text.boundingRect(with: size, options: [.usesLineFragmentOrigin], context: nil)
            text.draw(in: CGRect(x: 0, y: (size.height - bounds.height) / 2, width: size.width, height: bounds.height))
        }
    }
}
