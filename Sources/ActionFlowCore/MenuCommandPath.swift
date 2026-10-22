import Foundation

/// An exact menu bar path such as ["File", "New"]. Titles are preserved
/// byte-for-byte: no trimming, case folding, or fuzzy matching. Parsing is
/// pure data validation and never queries an application or its menus.
public struct MenuCommandPath: Equatable, Sendable {
    public static let minimumSegments = 2
    public static let maximumSegments = 8
    public static let maximumTitleUTF8Bytes = 256
    public static let maximumPathUTF8Bytes = 2_048
    public static let maximumJSONBytes = 4_096

    public let segments: [String]

    public init(segments: [String]) throws {
        for segment in segments { try Self.validateTitle(segment) }
        guard (Self.minimumSegments...Self.maximumSegments).contains(segments.count) else {
            throw MenuCommandPathError.segmentCount
        }
        guard segments.reduce(0) { $0 + $1.utf8.count } <= Self.maximumPathUTF8Bytes else {
            throw MenuCommandPathError.pathTooLong
        }
        self.segments = segments
    }

    /// Parses the `text` payload of a menu command action. The payload must be
    /// a JSON array of exact title strings, for example ["File", "New"].
    public init(parsing jsonText: String) throws {
        guard jsonText.utf8.count <= Self.maximumJSONBytes else { throw MenuCommandPathError.jsonTooLarge }
        guard let data = jsonText.data(using: .utf8) else { throw MenuCommandPathError.invalidJSON }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw MenuCommandPathError.invalidJSON }
        guard let array = object as? [Any] else { throw MenuCommandPathError.notJSONArray }
        var segments: [String] = []
        for element in array {
            // NSNumber-bridged strings and non-string members are both rejected.
            guard let title = element as? String, !(element is NSNumber) else {
                throw MenuCommandPathError.notJSONArray
            }
            segments.append(title)
        }
        try self.init(segments: segments)
    }

    static func validateTitle(_ title: String) throws {
        guard !title.isEmpty else { throw MenuCommandPathError.emptyTitle }
        guard !title.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw MenuCommandPathError.whitespaceOnlyTitle
        }
        guard !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MenuCommandPathError.controlCharacters
        }
        guard title.utf8.count <= maximumTitleUTF8Bytes else { throw MenuCommandPathError.titleTooLong }
    }

    /// Canonical re-encoding: one JSON array of the exact validated titles.
    public var canonicalJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: segments),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

/// Fixed, redacted messages. Menu titles and JSON payloads never appear in errors.
public enum MenuCommandPathError: Error, Equatable, Sendable {
    case invalidJSON
    case notJSONArray
    case segmentCount
    case emptyTitle
    case whitespaceOnlyTitle
    case controlCharacters
    case titleTooLong
    case pathTooLong
    case jsonTooLarge

    public var message: String {
        switch self {
        case .invalidJSON: return "Menu path must be valid JSON."
        case .notJSONArray: return "Menu path must be a JSON array of exact menu titles."
        case .segmentCount: return "A menu path needs between 2 and 8 titles."
        case .emptyTitle: return "Menu titles cannot be empty."
        case .whitespaceOnlyTitle: return "Menu titles cannot be only whitespace."
        case .controlCharacters: return "Menu titles cannot contain control characters."
        case .titleTooLong: return "A menu title cannot exceed 256 UTF-8 bytes."
        case .pathTooLong: return "A menu path cannot exceed 2048 UTF-8 bytes in total."
        case .jsonTooLarge: return "Menu path JSON cannot exceed 4096 bytes."
        }
    }
}
