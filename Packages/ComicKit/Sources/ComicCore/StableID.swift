import CryptoKit
import Foundation

/// Ids that every device works out the same way from the same input, so two devices that see a
/// library or a book before iCloud has synced still agree on its id (see docs/SCHEMA.md, "Ids").
///
/// An id is SHA-256 of the UTF-8 text `komareader:<kind>:<name>`, with `name` in Unicode NFC,
/// cut to 16 bytes and stamped as an RFC 9562 version 8 UUID, written in upper case.
public enum StableID {
    /// Id for a new library, from the name of the folder the user picked.
    public static func library(folderName: String) -> String {
        make(kind: "library", name: folderName)
    }

    /// Id for a book seen for the first time, from its path relative to the library folder.
    public static func book(path: String) -> String {
        make(kind: "book", name: path)
    }

    static func make(kind: String, name: String) -> String {
        let text = "komareader:\(kind):\(name.precomposedStringWithCanonicalMapping)"
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 9562 variant
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }
}
