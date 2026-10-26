import XCTest
@testable import VCode

final class LanguageServiceTests: XCTestCase {
    func testDocumentHighlightsIncludeDefinitionAndUsesWithoutOtherScopes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-symbol-highlights-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("main.ts")
        let source = "export interface Payload { value: string; }\nconst first: Payload = { value: 'hello' };\nfunction local() { interface Payload { other: number; }; const item: Payload = { other: 1 }; }\nexport type Result = Payload;\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        try "{\"compilerOptions\":{\"strict\":true},\"include\":[\"*.ts\"]}".write(to: folder.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let resourcePath = ProcessInfo.processInfo.environment["VCODE_LSP_RESOURCES"]
        let service = LanguageService(resources: resourcePath.map { URL(fileURLWithPath: $0) })
        defer { service.stop() }
        service.open(url: file, text: source, root: folder)
        let finished = expectation(description: "Semantic highlights in the current document")
        service.inspect(url: file, line: 0, character: 19, kind: .documentHighlight) { result in
            guard case .success(.highlights(let highlights)) = result else { XCTFail("Expected semantic document highlights: \(result)"); finished.fulfill(); return }
            XCTAssertEqual(Set(highlights.map(\.startLine)), Set([0, 1, 3]))
            XCTAssertTrue(highlights.allSatisfy { $0.endCharacter - $0.startCharacter == 7 })
            finished.fulfill()
        }
        wait(for: [finished], timeout: 25)
    }
    func testTypeReferencesExcludeDeclarationAndUnrelatedSameNamedTypes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-type-references-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("model.ts")
        let usage = folder.appendingPathComponent("usage.ts")
        let source = "export interface Payload { value: string; }\nexport interface NeverUsed { unused: true; }\n"
        try source.write(to: model, atomically: true, encoding: .utf8)
        let usageSource = "import type { Payload } from './model';\nexport function read(value: Payload): Payload { return value; }\n"
        try usageSource.write(to: usage, atomically: true, encoding: .utf8)
        try "interface Payload { different: number; }\nconst unrelated: Payload = { different: 1 };\nexport {};\n".write(to: folder.appendingPathComponent("unrelated.ts"), atomically: true, encoding: .utf8)
        try "{\"compilerOptions\":{\"strict\":true},\"include\":[\"*.ts\"]}".write(to: folder.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let resourcePath = ProcessInfo.processInfo.environment["VCODE_LSP_RESOURCES"]
        let service = LanguageService(resources: resourcePath.map { URL(fileURLWithPath: $0) })
        defer { service.stop() }
        service.open(url: model, text: source, root: folder)
        let references = expectation(description: "Real semantic type references")
        service.inspect(url: model, line: 0, character: 19, kind: .references) { result in
            switch result {
            case .success(.locations(let locations)):
                XCTAssertGreaterThanOrEqual(locations.count, 2)
                XCTAssertTrue(locations.allSatisfy { $0.url == usage }, "\(locations)")
            case .failure(let error): XCTFail(error.localizedDescription)
            default: XCTFail("Expected references")
            }
            references.fulfill()
        }
        wait(for: [references], timeout: 25)
        let empty = expectation(description: "Unused type has zero usages")
        service.inspect(url: model, line: 1, character: 19, kind: .references) { result in
            guard case .success(.locations(let locations)) = result else { XCTFail("Expected empty references"); empty.fulfill(); return }
            XCTAssertTrue(locations.isEmpty)
            empty.fulfill()
        }
        wait(for: [empty], timeout: 25)
        service.open(url: usage, text: usageSource, root: folder)
        let imported = expectation(description: "Imported type references exclude the original declaration too")
        let column = (usageSource.components(separatedBy: "\n")[1] as NSString).range(of: "Payload").location + 2
        service.inspect(url: usage, line: 1, character: column, kind: .references) { result in
            guard case .success(.locations(let locations)) = result else { XCTFail("Expected imported type references: \(result)"); imported.fulfill(); return }
            XCTAssertEqual(locations.count, 3)
            XCTAssertTrue(locations.allSatisfy { $0.url == usage }, "The original declaration must not be counted when querying from an imported alias: \(locations)")
            imported.fulfill()
        }
        wait(for: [imported], timeout: 25)
    }

    func testRealNestedMemberAndConsecutiveTypeDefinitionJumps() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-nested-lsp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "{\"compilerOptions\":{\"strict\":true},\"include\":[\"*.ts\"]}".write(to: folder.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let model = folder.appendingPathComponent("model.ts")
        let main = folder.appendingPathComponent("main.ts")
        let declarations = """
        export interface Payload { value: string; }
        export interface Response { payload: Payload; }
        export interface Service { send(): Response; }
        export interface Client { service: Service; }
        export declare const client: Client;
        """
        let consumer = "import { client } from './model';\nconst response = client.service.send();\n"
        try declarations.write(to: model, atomically: true, encoding: .utf8)
        try consumer.write(to: main, atomically: true, encoding: .utf8)
        let resourcePath = ProcessInfo.processInfo.environment["VCODE_LSP_RESOURCES"]
        let service = LanguageService(resources: resourcePath.map { URL(fileURLWithPath: $0) })
        defer { service.stop() }
        func jump(source: String, url: URL, needle: String) throws -> CodeLocation {
            let range = (source as NSString).range(of: needle)
            XCTAssertNotEqual(range.location, NSNotFound)
            let prefix = (source as NSString).substring(to: range.location + 1).components(separatedBy: "\n")
            let finished = expectation(description: "Definition of " + needle)
            var locations: [CodeLocation] = []
            service.inspect(url: url, line: prefix.count - 1, character: (prefix.last! as NSString).length, kind: .definition) { result in
                switch result {
                case .success(.locations(let found)): locations = found
                case .failure(let error): XCTFail(error.localizedDescription)
                default: XCTFail("Expected definition locations")
                }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 25)
            return try XCTUnwrap(locations.first)
        }
        service.open(url: main, text: consumer, root: folder)
        let member = try jump(source: consumer, url: main, needle: "service.send")
        XCTAssertEqual(member.url, model)
        XCTAssertEqual(member.line, 3)
        let method = try jump(source: consumer, url: main, needle: "send()")
        XCTAssertEqual(method.line, 2)
        service.open(url: method.url, text: declarations, root: folder)
        let response = try jump(source: declarations, url: model, needle: "Response;")
        XCTAssertEqual(response.line, 1)
        let payload = try jump(source: declarations, url: model, needle: "Payload;")
        XCTAssertEqual(payload.line, 0)
    }

    func testNativeStandardLibraryHoverAndDefinitionWithoutNode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-native-libs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("main.ts")
        let source = "export const result = [1, 2].map(value => value.toFixed(2));\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let resources = ProcessInfo.processInfo.environment["VCODE_LSP_RESOURCES"].map { URL(fileURLWithPath: $0) }
        let service = LanguageService(resources: resources)
        defer { service.stop() }
        service.open(url: file, text: source, root: folder)
        let hover = expectation(description: "Standard Array.map returns string[]")
        service.inspect(url: file, line: 0, character: 15, kind: .hover) { result in
            guard case .success(.hover(let text)) = result else { XCTFail("Expected library-backed type: \(result)"); hover.fulfill(); return }
            XCTAssertTrue(text.contains("string[]"), text)
            hover.fulfill()
        }
        wait(for: [hover], timeout: 25)
        let definition = expectation(description: "Array.map resolves into bundled standard declarations")
        service.inspect(url: file, line: 0, character: 29, kind: .definition) { result in
            guard case .success(.locations(let locations)) = result else { XCTFail("Expected native standard-library definition: \(result)"); definition.fulfill(); return }
            XCTAssertTrue(locations.contains { $0.url.lastPathComponent == "lib.es5.d.ts" }, "\(locations)")
            definition.fulfill()
        }
        wait(for: [definition], timeout: 25)
    }

    func testRealTypeScriptHoverDefinitionReferencesAndDocumentRefresh() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-lsp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "{\"compilerOptions\":{\"strict\":true,\"target\":\"ES2022\"},\"include\":[\"*.ts\"]}".write(to: folder.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let model = folder.appendingPathComponent("model.ts")
        let consumer = folder.appendingPathComponent("main.ts")
        let source = "import { answer } from './model';\nexport const result = answer;\n"
        try "export const answer: number = 42;\n".write(to: model, atomically: true, encoding: .utf8)
        try source.write(to: consumer, atomically: true, encoding: .utf8)

        let resourcePath = ProcessInfo.processInfo.environment["VCODE_LSP_RESOURCES"]
        let service = LanguageService(resources: resourcePath.map { URL(fileURLWithPath: $0) })
        defer { service.stop() }
        let ready = expectation(description: "TypeScript initialized")
        service.onStatus = { status in
            if status == "TypeScript · Ready" { ready.fulfill() }
            if status.contains("Failed") || status.contains("Setup") { XCTFail(status) }
        }
        service.open(url: consumer, text: source, root: folder)
        wait(for: [ready], timeout: 25)
        service.onStatus = nil

        let hover = expectation(description: "Real hover result")
        service.inspect(url: consumer, line: 1, character: 23, kind: .hover) { result in
            switch result {
            case .success(let value):
                guard case .hover(let text) = value else { XCTFail("Expected hover"); break }
                XCTAssertTrue(text.contains("number"), text)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            hover.fulfill()
        }
        wait(for: [hover], timeout: 25)

        let definition = expectation(description: "Cross-file definition")
        service.inspect(url: consumer, line: 1, character: 23, kind: .definition) { result in
            switch result {
            case .success(let value):
                guard case .locations(let locations) = value else { XCTFail("Expected locations"); break }
                XCTAssertTrue(locations.contains { $0.url.lastPathComponent == "model.ts" })
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            definition.fulfill()
        }
        wait(for: [definition], timeout: 25)

        let references = expectation(description: "Cross-file references")
        service.inspect(url: consumer, line: 1, character: 23, kind: .references) { result in
            switch result {
            case .success(let value):
                guard case .locations(let locations) = value else { XCTFail("Expected references"); break }
                XCTAssertGreaterThanOrEqual(locations.count, 2)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            references.fulfill()
        }
        wait(for: [references], timeout: 25)

        let updated = source + "export const label: string = 'updated';\n"
        service.open(url: consumer, text: updated, root: folder)
        let refreshed = expectation(description: "didChange updates the language server")
        service.inspect(url: consumer, line: 2, character: 14, kind: .hover) { result in
            switch result {
            case .success(let value):
                guard case .hover(let text) = value else { XCTFail("Expected updated hover"); break }
                XCTAssertTrue(text.contains("string"), text)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 25)
    }
}
