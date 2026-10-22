import XCTest
@testable import VCode

final class LSPFramerTests: XCTestCase {
    func testFragmentedUnicodeAndMultipleMessages() throws {
        let first = try LSPFramer.encode(["jsonrpc": "2.0", "id": 1, "result": "你好🙂"])
        let second = try LSPFramer.encode(["jsonrpc": "2.0", "id": 2, "result": ["value": "ok"]])
        var framer = LSPFramer()
        var decoded: [[String: Any]] = []
        for byte in first + second { decoded += try framer.append(Data([byte])) }
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["result"] as? String, "你好🙂")
        XCTAssertEqual(decoded[1]["id"] as? Int, 2)
    }

    func testBatchedMessagesAndExtraHeader() throws {
        let body = Data(#"{"id":3,"result":null}"#.utf8)
        var data = Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        data.append(try LSPFramer.encode(["id": 4, "result": "four"]))
        var framer = LSPFramer()
        XCTAssertEqual(try framer.append(data).count, 2)
    }

    func testInvalidAndOversizedHeaders() {
        var framer = LSPFramer()
        XCTAssertThrowsError(try framer.append(Data("Content-Length: -1\r\n\r\n".utf8)))
        var other = LSPFramer()
        XCTAssertThrowsError(try other.append(Data("Content-Length: 999999999\r\n\r\n".utf8)))
    }
}
