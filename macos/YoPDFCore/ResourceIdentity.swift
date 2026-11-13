import Foundation

/// Stable, strongly-typed identifier for an underlying opened or linked resource
/// (PDF file, Markdown paper note, etc.).
public struct ResourceID: Hashable, Equatable, Sendable, Codable, Identifiable, CustomStringConvertible, RawRepresentable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
