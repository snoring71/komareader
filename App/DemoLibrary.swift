import UIKit

/// A generated sample library used for UI tests and screenshots (launch with `-demo`).
enum DemoLibrary {
    static func make() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DemoLibrary", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
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
        return root
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
