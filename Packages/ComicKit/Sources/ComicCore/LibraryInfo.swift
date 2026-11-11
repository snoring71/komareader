import Foundation

/// `library.json`: one per library, identifies which user folder the data belongs to.
public struct LibraryInfo: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schema: Int
    public var libraryId: String
    /// Name of the library folder the user picked (e.g. "Booklover"), so other devices can
    /// match their own pick of the same folder to this data.
    public var folderName: String
    public var createdAt: Date

    public init(libraryId: String = UUID().uuidString, folderName: String, createdAt: Date = Date()) {
        self.schema = Self.currentSchema
        self.libraryId = libraryId
        self.folderName = folderName
        self.createdAt = createdAt
    }
}
