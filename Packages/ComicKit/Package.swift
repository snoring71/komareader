// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComicKit",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "ComicCore", targets: ["ComicCore"]),
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // System libarchive (ZIP, RAR4/5, 7z, TAR) with vendored public headers.
        .target(
            name: "CArchive",
            linkerSettings: [.linkedLibrary("archive")]
        ),
        // Models, open data format (JSON records), merge rules, natural sort.
        .target(name: "ComicCore"),
        // One BookSource API over archives, PDFs and image folders, plus ImageIO decoding.
        .target(name: "ArchiveKit", dependencies: ["CArchive", "ComicCore"]),
        // iCloud folder scanning, download/evict, local GRDB index, cover generation.
        .target(
            name: "LibraryKit",
            dependencies: ["ComicCore", "ArchiveKit", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "ComicCoreTests", dependencies: ["ComicCore"]),
        .testTarget(
            name: "ArchiveKitTests",
            dependencies: ["ArchiveKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "LibraryKitTests", dependencies: ["LibraryKit"]),
    ],
    swiftLanguageModes: [.v5]
)
