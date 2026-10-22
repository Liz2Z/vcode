import XCTest
@testable import VCode

final class LanguageServiceLifecycleTests: XCTestCase {
    func testInspectionWaitsForInitializationAndUsesProjectMemoryLimit() throws {
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
        let options = try String(contentsOf: fixture.root.appendingPathComponent("memory-limit"), encoding: .utf8)
        XCTAssertEqual(options, "2048")
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
            let server = resources.appendingPathComponent("TypeScript/node_modules/typescript-language-server/lib/cli.mjs")
            let runtime = resources.appendingPathComponent("Runtime/node")
            try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
            let candidates = [
                ProcessInfo.processInfo.environment["VCODE_LSP_RESOURCES"].map { $0 + "/Runtime/node" } ?? "",
                URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/VCode.app/Contents/Resources/Runtime/node").path,
                "/opt/homebrew/bin/node", "/usr/local/bin/node"
            ]
            guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw XCTSkip("Node runtime is required for LSP lifecycle tests")
            }
            try FileManager.default.createSymbolicLink(atPath: runtime.path, withDestinationPath: node)
            try "export const value = 42;".write(to: file, atomically: true, encoding: .utf8)
            let script = "const mode = '\(mode)';\n" + #"""
            import fs from 'node:fs';
            const marker = 'started-once';
            const first = !fs.existsSync(marker);
            fs.writeFileSync(marker, 'yes');
            let buffer = Buffer.alloc(0);
            let opened = false;
            function send(message) {
                const body = JSON.stringify({jsonrpc: '2.0', ...message});
                process.stdout.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
            }
            function receive(message) {
                if (message.method === 'exit') process.exit(0);
                if (message.method === 'initialize') {
                    fs.writeFileSync('memory-limit', String(message.params.initializationOptions.maxTsServerMemory));
                    if (mode === 'crash') {
                        process.stderr.write('FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory\n');
                        setTimeout(() => process.exit(1), 100);
                    } else {
                        setTimeout(() => send({id: message.id, result: {capabilities: {}}}), mode === 'delayed' ? 200 : 0);
                    }
                }
                if (message.method === 'initialized' && mode === 'recover' && first) {
                    setTimeout(() => process.exit(1), 100);
                }
                if (message.method === 'textDocument/didOpen') opened = true;
                if (message.method === 'textDocument/hover') {
                    if (opened) send({id: message.id, result: {contents: 'const value: number'}});
                    else send({id: message.id, error: {message: 'Document was not opened'}});
                }
            }
            process.stdin.on('data', data => {
                buffer = Buffer.concat([buffer, data]);
                while (true) {
                    const end = buffer.indexOf('\r\n\r\n');
                    if (end < 0) break;
                    const length = Number(/Content-Length: (\d+)/i.exec(buffer.subarray(0, end).toString())[1]);
                    if (buffer.length < end + 4 + length) break;
                    const message = JSON.parse(buffer.subarray(end + 4, end + 4 + length).toString());
                    buffer = buffer.subarray(end + 4 + length);
                    receive(message);
                }
            });
            """#
            try script.write(to: server, atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
