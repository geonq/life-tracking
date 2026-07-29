import Foundation

/// Bounded self-contained image bytes; filenames and local URLs never sync.
public struct CalendarIconAsset: Codable, Equatable, Sendable {
    public static let maxBytes = 256 * 1024

    public enum Format: String, Codable, Sendable {
        case png
        case jpeg
    }

    public let format: Format
    public let bytes: Data

    private enum CodingKeys: String, CodingKey {
        case format
        case bytes
    }

    public init(format: Format, bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= Self.maxBytes else {
            throw CalendarValidationError.invalidIconAsset
        }
        let isPNG = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let isJPEG = bytes.starts(with: [0xFF, 0xD8, 0xFF])
        guard (format == .png && isPNG) || (format == .jpeg && isJPEG) else {
            throw CalendarValidationError.invalidIconAsset
        }
        self.format = format
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(Format.self, forKey: .format)
        let bytes = try container.decode(Data.self, forKey: .bytes)
        try self.init(format: format, bytes: bytes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(bytes, forKey: .bytes)
    }

    /// Stable merge/sync tie-breaker containing no local path or filename.
    public var deterministicKey: String {
        format.rawValue + ":" + bytes.base64EncodedString()
    }
}
