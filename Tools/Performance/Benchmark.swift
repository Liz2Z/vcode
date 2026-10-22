import AppKit
import Foundation

// Compile with the application sources except App.swift. No windows are opened.
@main
struct PerformanceBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let folder = arguments.first else {
            throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a workspace path and optional source path"])
        }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let path = arguments.count > 1 ? arguments[1] : "src/sample.ts"
        let reader = try WorkspaceReader(folder: root)
        let state = try reader.load()
        var results: [[String: Any]] = []
        func measure(_ name: String, repetitions: Int = 3, _ body: () throws -> Int) rethrows {
            var samples: [Double] = []
            var count = 0
            for _ in 0..<repetitions {
                let start = ProcessInfo.processInfo.systemUptime
                count = try autoreleasepool(invoking: body)
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            results.append(["name": name, "milliseconds": samples, "median_ms": samples.sorted()[samples.count / 2], "result_count": count])
        }
        try measure("disk_inventory") { try reader.files.list().count }
        try measure("workspace_open") { try WorkspaceReader(folder: root).load().files.count }
        try measure("workspace_refresh") { try reader.load().files.count }
        try measure("source_snapshot") { try reader.snapshot(path: path, state: state, compare: false).after.utf8.count }
        try measure("diff_snapshot") { try reader.snapshot(path: path, state: state, compare: true, comparison: .unstaged).rows.count }
        let source = try reader.snapshot(path: path, state: state, compare: false).after
        let largeSource = (0..<5000).map { "export const value\($0): string = 'TypeScript sample \($0)';" }.joined(separator: "\n")
        measure("syntax_300kb") {
            let storage = NSTextStorage(string: largeSource)
            Syntax.apply(to: storage, path: "large.ts", font: Theme.Code.font())
            return storage.length
        }
        measure("code_pane_300kb") {
            let pane = CodePane()
            let lines = Diff.lines(largeSource).enumerated().map { CodeLine(number: $0.offset + 1, text: $0.element, kind: .unchanged) }
            pane.show(lines: lines, path: "large.ts", title: "", detail: "")
            return pane.text.string.utf8.count
        }
        let report: [String: Any] = ["root": root.path, "path": path, "files": state.files.count, "changes": state.changes.count, "source_bytes": source.utf8.count, "measurements": results]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
