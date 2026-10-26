import XCTest
@testable import VCode

final class LanguageServiceLifecycleTests: XCTestCase {
    func testInspectionWaitsForNativeInitializationAndOpensDocument() throws {
        let fixture = try Fixture(mode: "delayed")
        defer { fixture.remove() }
        let service = LanguageService(resources: fixture.resources)
        defer { service.stop() }
        let inspected = expectation(description: "Inspection waits for initialization and didOpen")
        service.open(url: fixture.file, text: "export const value = 42;", root: fixture.root)
        service.inspect(url: fixture.file, line: 0, character: 13, kind: .hover) { result in
            self.assertHover(result, contains: "number")
            inspected.fulfill()
        }
        wait(for: [inspected], timeout: 5)
        let arguments = try String(contentsOf: fixture.root.appendingPathComponent("arguments"), encoding: .utf8)
        XCTAssertEqual(arguments, "--lsp --stdio")
        let options = try String(contentsOf: fixture.root.appendingPathComponent("options"), encoding: .utf8)
        XCTAssertEqual(options, "{}", "Do not send Node / tsserver-only settings to the native LSP")
    }

    func testInitializationCrashFailsWaitingInspectionWithMemoryReason() throws {
        let fixture = try Fixture(mode: "crash")
        defer { fixture.remove() }
        let service = LanguageService(resources: fixture.resources)
        defer { service.stop() }
        let failed = expectation(description: "Crash reports memory failure")
        let inspected = expectation(description: "Queued inspection fails without waiting for timeout")
        service.onFailure = { reason in
            XCTAssertTrue(reason.contains("out of memory"), reason)
            failed.fulfill()
        }
        service.open(url: fixture.file, text: "export const value = 42;", root: fixture.root)
        service.inspect(url: fixture.file, line: 0, character: 13, kind: .hover) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertTrue(error.localizedDescription.contains("out of memory"), error.localizedDescription)
            inspected.fulfill()
        }
        wait(for: [failed, inspected], timeout: 5)
    }

    func testInspectionRestartsFailedServerAndReopensActiveDocument() throws {
        let fixture = try Fixture(mode: "recover")
        defer { fixture.remove() }
        let service = LanguageService(resources: fixture.resources)
        defer { service.stop() }
        let stopped = expectation(description: "First server exits after initialization")
        service.onFailure = { _ in stopped.fulfill() }
        service.open(url: fixture.file, text: "export const value = 42;", root: fixture.root)
        wait(for: [stopped], timeout: 5)
        service.onFailure = { XCTFail($0) }
        let recovered = expectation(description: "Next interaction reopens document and succeeds")
        service.inspect(url: fixture.file, line: 0, character: 13, kind: .hover) { result in
            self.assertHover(result, contains: "number")
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 5)
    }

    func testStopCancelsStartupInspectionAndIgnoresLateReady() throws {
        let fixture = try Fixture(mode: "delayed")
        defer { fixture.remove() }
        let service = LanguageService(resources: fixture.resources)
        let cancelled = expectation(description: "Waiting request is cancelled once")
        let ready = expectation(description: "Stopped server must not become ready")
        ready.isInverted = true
        service.onStatus = { if $0 == "TypeScript · Ready" { ready.fulfill() } }
        service.open(url: fixture.file, text: "export const value = 42;", root: fixture.root)
        service.inspect(url: fixture.file, line: 0, character: 13, kind: .hover) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
            XCTAssertTrue(error.localizedDescription.contains("stopped"))
            cancelled.fulfill()
        }
        service.stop()
        wait(for: [cancelled, ready], timeout: 0.8)
    }

    func testMissingNativeBinaryReportsSetupInsteadOfUsingLocalNode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-native-missing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LanguageService(resources: root)
        defer { service.stop() }
        let failure = expectation(description: "Missing native binary is visible")
        service.onFailure = { reason in
            XCTAssertTrue(reason.contains("native TypeScript"), reason)
            failure.fulfill()
        }
        service.open(url: root.appendingPathComponent("main.ts"), text: "export {};", root: root)
        wait(for: [failure], timeout: 2)
    }

    private func assertHover(_ result: Result<LanguageInspection, Error>, contains expected: String) {
        switch result {
        case .success(.hover(let text)): XCTAssertTrue(text.contains(expected), text)
        case .success: XCTFail("Expected hover")
        case .failure(let error): XCTFail(error.localizedDescription)
        }
    }

    private struct Fixture {
        let root: URL
        let resources: URL
        let file: URL

        init(mode: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-lsp-lifecycle-" + UUID().uuidString)
            resources = root.appendingPathComponent("resources")
            file = root.appendingPathComponent("main.ts")
            let server = resources.appendingPathComponent("TypeScript/tsc")
            try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "export const value = 42;".write(to: file, atomically: true, encoding: .utf8)
            // The fixture emulates a stdio executable, without requiring Node.
            let script = "#!/usr/bin/python3\nmode = '\(mode)'\n" + #"""
            import json, sys, pathlib, time
            marker = pathlib.Path('started-once')
            first = not marker.exists()
            marker.write_text('yes')
            pathlib.Path('arguments').write_text(' '.join(sys.argv[1:]))
            opened = False
            def send(message):
                body = json.dumps({'jsonrpc': '2.0', **message}).encode()
                sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n' % len(body)).encode() + body)
                sys.stdout.buffer.flush()
            while True:
                headers = {}
                while True:
                    line = sys.stdin.buffer.readline()
                    if not line: sys.exit(0)
                    if line == b'\r\n': break
                    name, value = line.decode().split(':', 1)
                    headers[name.lower()] = value.strip()
                message = json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
                method = message.get('method')
                if method == 'exit': sys.exit(0)
                if method == 'initialize':
                    pathlib.Path('options').write_text(json.dumps(message['params']['initializationOptions']))
                    if mode == 'crash':
                        sys.stderr.write('fatal error: runtime: out of memory\n')
                        sys.stderr.flush()
                        time.sleep(0.1)
                        sys.exit(1)
                    if mode == 'delayed': time.sleep(0.2)
                    send({'id': message['id'], 'result': {'capabilities': {}}})
                if method == 'initialized' and mode == 'recover' and first:
                    time.sleep(0.1)
                    sys.exit(1)
                if method == 'textDocument/didOpen': opened = True
                if method == 'textDocument/hover':
                    send({'id': message['id'], 'result': {'contents': 'const value: number'}} if opened
                         else {'id': message['id'], 'error': {'message': 'Document was not opened'}})
            """#
            try script.write(to: server, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
