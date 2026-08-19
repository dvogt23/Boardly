import Foundation

extension JSONDecoder {
    static let planka: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = ISO8601Formatters.fractional.date(from: string) { return date }
            if let date = ISO8601Formatters.standard.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date from '\(string)'")
        }
        return decoder
    }()
}

extension JSONEncoder {
    /// The mirror of `JSONDecoder.planka`, for data the app writes and reads back itself
    /// — the offline cache. A plain `JSONEncoder` writes dates as numeric intervals,
    /// which `.planka` then refuses to decode, so the two must be paired.
    static let planka: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601Formatters.fractional.string(from: date))
        }
        return encoder
    }()
}

/// Canonical PLANKA wire-format date formatters, shared by both the decoder
/// (above) and `CardPatch` encoding so the read and write sides never desync.
enum ISO8601Formatters {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let standard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
