import Foundation
import CryptoKit
import ImageIO

/// Bounded, versioned, content-addressed image bytes; filenames and local URLs never sync.
public struct CalendarIconAsset: Codable, Equatable, Sendable {
    public static let maxBytes = 256 * 1024
    public static let currentSchemaVersion = 1

    public enum Format: String, Codable, Sendable {
        case png
        case jpeg
    }

    public let format: Format
    public let bytes: Data

    public var schemaVersion: Int { Self.currentSchemaVersion }

    public var contentHash: String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case contentHash
        case format
        case bytes
    }

    public init(format: Format, bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= Self.maxBytes else {
            throw CalendarValidationError.invalidIconAsset
        }
        let isPNG = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let isJPEG = bytes.starts(with: [0xFF, 0xD8, 0xFF])
        guard (format == .png && isPNG) || (format == .jpeg && isJPEG),
              Self.isDecodableImage(bytes) else {
            throw CalendarValidationError.invalidIconAsset
        }
        self.format = format
        self.bytes = bytes
    }

    private static func isDecodableImage(_ bytes: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0,
              width <= 2_048,
              height <= 2_048,
              width * height <= 4_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            return false
        }
        return true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(Format.self, forKey: .format)
        let bytes = try container.decode(Data.self, forKey: .bytes)
        try self.init(format: format, bytes: bytes)

        if let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion),
           schemaVersion != Self.currentSchemaVersion {
            throw CalendarValidationError.invalidIconAsset
        }
        if let encodedHash = try container.decodeIfPresent(String.self, forKey: .contentHash),
           encodedHash != contentHash {
            throw CalendarValidationError.invalidIconAsset
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(format, forKey: .format)
        try container.encode(bytes, forKey: .bytes)
    }

    /// Stable merge/sync tie-breaker containing no local path or filename.
    public var deterministicKey: String {
        format.rawValue + ":" + bytes.base64EncodedString()
    }
}
