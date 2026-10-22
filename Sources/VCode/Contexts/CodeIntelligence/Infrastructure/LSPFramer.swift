import Foundation

struct LSPFramer {
    private var buffer = Data()
    init() {}

    mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []
        while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let pieces = line.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2, pieces[0].lowercased() == "content-length" else { return nil }
                return Int(pieces[1].trimmingCharacters(in: .whitespaces))
            }.first
            guard let length, length >= 0, length < 32 * 1024 * 1024 else {
                throw LanguageServiceError.connection("The language service sent an invalid message.")
            }
            let bodyStart = end.upperBound
            guard buffer.count - bodyStart >= length else { break }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
            guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw LanguageServiceError.connection("The language service sent an invalid response.")
            }
            messages.append(message)
            buffer.removeSubrange(0..<(bodyStart + length))
        }
        return messages
    }

    static func encode(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        var result = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        result.append(body)
        return result
    }
}
