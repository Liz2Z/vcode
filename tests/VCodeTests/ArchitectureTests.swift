import Foundation
import XCTest

final class ArchitectureTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/VCode")
    }

    func testDomainHasNoPlatformOrInfrastructureDependencies() throws {
        let forbidden = try NSRegularExpression(pattern: #"\b(?:AppKit|NSView|NSTextView|FileManager|Process|GitCLI|SourceFileStore|LanguageServerConnection)\b"#)
        let files = try sourceFiles(containing: "/Domain/")
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(forbidden.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), file.path)
        }
    }

    func testApplicationCoordinatesWithoutOwningViewsOrProcessIO() throws {
        let forbidden = try NSRegularExpression(pattern: #"\b(?:AppKit|NSView|NSTextView|Process|Pipe|FileHandle|FileManager)\b"#)
        for file in try sourceFiles(containing: "/Application/") where file.path.contains("/Contexts/") {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(forbidden.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), file.path)
        }
    }

    func testInfrastructureDoesNotDependOnPresentation() throws {
        let forbidden = try NSRegularExpression(pattern: #"\b(?:AppKit|WorkspaceController|WorkspaceView|EditorView|CodePane|FileTree|InspectionPresenter)\b"#)
        for file in try sourceFiles(containing: "/Infrastructure/") {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(forbidden.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), file.path)
        }
    }

    func testGitAndFileBrowsingStayIndependentOfEachOtherAndReadingUI() throws {
        let rules: [(String, String)] = [
            ("/Contexts/Git/", #"\b(?:WorkspaceState|WorkspaceReader|FileBrowser|SourceFileStore|SourceContent|FileSnapshot|CodePane|FileTree|ReadingError|FileAccessError)\b"#),
            ("/Contexts/FileBrowsing/", #"\b(?:GitService|GitRepository|GitCLI|GitStatus|GitChange|GitDestination|WorkspaceReader|FileSnapshot|CodePane|EditorView)\b"#),
            ("/Contexts/Workspace/Application/", #"\b(?:GitCLI|SourceFileStore)\b"#),
            ("/Presentation/", #"\b(?:GitCLI|SourceFileStore)\b"#)
        ]
        for (component, pattern) in rules {
            let forbidden = try NSRegularExpression(pattern: pattern)
            let files = try sourceFiles(containing: component)
            XCTAssertFalse(files.isEmpty, component)
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                XCTAssertNil(forbidden.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), file.path)
            }
        }
    }

    private func sourceFiles(containing component: String) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.path.contains(component) }
    }
}
