import AppKit
import XCTest
@testable import VCode

final class IdentifierFeedbackTests: XCTestCase {
    private let source = "const first = 1;\nconst second = first;\n"
    private func fixture() -> (CodePane, NSWindow) {
        _ = NSApplication.shared
        let pane = CodePane()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        pane.show(lines: Diff.lines(source).enumerated().map { CodeLine(number: $0.offset + 1, text: $0.element, kind: .unchanged) }, path: "main.ts", title: "", detail: "", showsHeader: false)
        pane.layoutSubtreeIfNeeded()
        return (pane, window)
    }
    private func move(_ pane: CodePane, word: String, command: Bool) throws -> NSRange {
        let range = (source as NSString).range(of: word)
        let layout = try XCTUnwrap(pane.text.layoutManager)
        let container = try XCTUnwrap(pane.text.textContainer)
        layout.ensureLayout(for: container)
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let point = pane.text.convert(NSPoint(x: rect.midX + pane.text.textContainerOrigin.x, y: rect.midY + pane.text.textContainerOrigin.y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: command ? .command : [], timestamp: 0, windowNumber: pane.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        pane.text.mouseMoved(with: event)
        return range
    }

    func testOrdinaryHoverDoesNotApplyBackgroundOrProbeDefinitions() throws {
        let (pane, window) = fixture()
        defer { pane.text.cancelInspection(); window.close() }
        var probes = 0
        pane.text.onDefinitionProbe = { _, _ in probes += 1 }
        let range = try move(pane, word: "first", command: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.13))
        XCTAssertEqual(probes, 0)
        XCTAssertNil(pane.text.underlinedIdentifier)
        XCTAssertNil(pane.text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
    }

    func testCommandHoverOnlyUnderlinesConfirmedTargetsAndReleaseClearsIt() throws {
        let (pane, window) = fixture()
        defer { pane.text.cancelInspection(); window.close() }
        var answers: [(Bool) -> Void] = []
        pane.text.onDefinitionProbe = { _, answer in answers.append(answer) }
        _ = try move(pane, word: "first", command: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.13))
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(pane.text.underlinedIdentifier)
        answers[0](false)
        XCTAssertNil(pane.text.underlinedIdentifier)
        let second = try move(pane, word: "second", command: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.13))
        answers[1](true)
        XCTAssertEqual(pane.text.underlinedIdentifier, second)
        XCTAssertNotNil(pane.text.layoutManager?.temporaryAttribute(.underlineStyle, atCharacterIndex: second.location, effectiveRange: nil))
        let release = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        pane.text.flagsChanged(with: release)
        XCTAssertNil(pane.text.underlinedIdentifier)
        XCTAssertNil(pane.text.layoutManager?.temporaryAttribute(.underlineStyle, atCharacterIndex: second.location, effectiveRange: nil))
    }

    func testOldCommandProbeCannotUnderlineAFormerTarget() throws {
        let (pane, window) = fixture()
        defer { pane.text.cancelInspection(); window.close() }
        var answers: [(Bool) -> Void] = []
        pane.text.onDefinitionProbe = { _, answer in answers.append(answer) }
        _ = try move(pane, word: "first", command: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.13))
        let second = try move(pane, word: "second", command: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.13))
        answers[0](true)
        XCTAssertNil(pane.text.underlinedIdentifier)
        answers[1](true)
        XCTAssertEqual(pane.text.underlinedIdentifier, second)
        pane.text.resetSymbolFeedback()
        answers[1](true)
        XCTAssertNil(pane.text.underlinedIdentifier)
    }

    func testClickedOccurrencesAreIndependentOfHoverAndRejectOldResults() throws {
        let (pane, window) = fixture()
        defer { pane.text.cancelInspection(); pane.text.resetSymbolFeedback(); window.close() }
        let first = (source as NSString).range(of: "first")
        let second = (source as NSString).range(of: "second")
        let firstUse = (source as NSString).range(of: "first", options: .backwards)
        var answers: [([NSRange]) -> Void] = []
        pane.text.onSymbolClick = { _, answer in answers.append(answer) }
        pane.text.highlightSymbol(at: second.location)
        pane.text.highlightSymbol(at: first.location)
        answers[0]([second])
        XCTAssertTrue(pane.text.occurrenceRanges.isEmpty)
        answers[1]([firstUse, first, first, NSRange(location: NSNotFound, length: 2)])
        XCTAssertEqual(pane.text.occurrenceRanges, [first, firstUse])
        pane.text.clearInspectionFeedback()
        XCTAssertEqual(pane.text.occurrenceRanges, [first, firstUse])
        XCTAssertEqual((pane.text.layoutManager as? CodeLayoutManager)?.symbolRanges, [first, firstUse])
        pane.show(lines: [CodeLine(number: 1, text: "const changed = 1;", kind: .unchanged)], path: "new.ts", title: "", detail: "")
        answers[1]([first])
        XCTAssertTrue(pane.text.occurrenceRanges.isEmpty)
        pane.text.highlightSymbol(at: nil)
        XCTAssertTrue(pane.text.occurrenceRanges.isEmpty)
    }
}
