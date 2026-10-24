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
        XCTAssertTrue(window.acceptsMouseMovedEvents, "The real window must deliver pointer motion, not only explicit test events")
    }

    func testCommandHoverOnlyUnderlinesConfirmedTargetsAndReleaseClearsIt() throws {
        // Also cover delivery slower than the former 130 ms sleep. Wait for the
        // actual probe, rather than assuming how quickly CI services its queue.
        for deliveryDelay in [0.0, 0.2] {
            let (pane, window) = fixture()
            defer { pane.text.cancelInspection(); window.close() }
            let firstProbe = expectation(description: "First definition probe, delay \(deliveryDelay)")
            let secondProbe = expectation(description: "Second definition probe, delay \(deliveryDelay)")
            var answers: [(Bool) -> Void] = []
            pane.text.onDefinitionProbe = { _, answer in
                DispatchQueue.main.asyncAfter(deadline: .now() + deliveryDelay) {
                    answers.append(answer)
                    if answers.count == 1 { firstProbe.fulfill() }
                    else if answers.count == 2 { secondProbe.fulfill() }
                    else { XCTFail("Unexpected additional definition probe") }
                }
            }
            _ = try move(pane, word: "first", command: true)
            wait(for: [firstProbe], timeout: 5)
            XCTAssertEqual(answers.count, 1)
            let firstAnswer = try XCTUnwrap(answers.first, "First definition probe did not arrive")
            XCTAssertNil(pane.text.underlinedIdentifier)
            firstAnswer(false)
            XCTAssertNil(pane.text.underlinedIdentifier)
            let second = try move(pane, word: "second", command: true)
            wait(for: [secondProbe], timeout: 5)
            XCTAssertEqual(answers.count, 2)
            let secondAnswer = try XCTUnwrap(answers.dropFirst().first, "Second definition probe did not arrive")
            secondAnswer(true)
            XCTAssertEqual(pane.text.underlinedIdentifier, second)
            XCTAssertNotNil(pane.text.layoutManager?.temporaryAttribute(.underlineStyle, atCharacterIndex: second.location, effectiveRange: nil))
            let release = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
            pane.text.flagsChanged(with: release)
            XCTAssertNil(pane.text.underlinedIdentifier)
            XCTAssertNil(pane.text.layoutManager?.temporaryAttribute(.underlineStyle, atCharacterIndex: second.location, effectiveRange: nil))
        }
    }

    func testOldCommandProbeCannotUnderlineAFormerTarget() throws {
        let (pane, window) = fixture()
        defer { pane.text.cancelInspection(); window.close() }
        let firstProbe = expectation(description: "First pending definition probe")
        let secondProbe = expectation(description: "Second pending definition probe")
        var answers: [(Bool) -> Void] = []
        pane.text.onDefinitionProbe = { _, answer in
            answers.append(answer)
            if answers.count == 1 { firstProbe.fulfill() }
            else if answers.count == 2 { secondProbe.fulfill() }
            else { XCTFail("Unexpected additional definition probe") }
        }
        _ = try move(pane, word: "first", command: true)
        wait(for: [firstProbe], timeout: 5)
        let firstAnswer = try XCTUnwrap(answers.first, "First definition probe did not arrive")
        let second = try move(pane, word: "second", command: true)
        wait(for: [secondProbe], timeout: 5)
        let secondAnswer = try XCTUnwrap(answers.dropFirst().first, "Second definition probe did not arrive")
        firstAnswer(true)
        XCTAssertNil(pane.text.underlinedIdentifier)
        secondAnswer(true)
        XCTAssertEqual(pane.text.underlinedIdentifier, second)
        pane.text.resetSymbolFeedback()
        secondAnswer(true)
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
        XCTAssertEqual(answers.count, 2)
        let firstAnswer = try XCTUnwrap(answers.first)
        let secondAnswer = try XCTUnwrap(answers.dropFirst().first)
        firstAnswer([second])
        XCTAssertTrue(pane.text.occurrenceRanges.isEmpty)
        secondAnswer([firstUse, first, first, NSRange(location: NSNotFound, length: 2)])
        XCTAssertEqual(pane.text.occurrenceRanges, [first, firstUse])
        pane.text.clearInspectionFeedback()
        XCTAssertEqual(pane.text.occurrenceRanges, [first, firstUse])
        XCTAssertEqual((pane.text.layoutManager as? CodeLayoutManager)?.symbolRanges, [first, firstUse])
        pane.show(lines: [CodeLine(number: 1, text: "const changed = 1;", kind: .unchanged)], path: "new.ts", title: "", detail: "")
        secondAnswer([first])
        XCTAssertTrue(pane.text.occurrenceRanges.isEmpty)
        pane.text.highlightSymbol(at: nil)
        XCTAssertTrue(pane.text.occurrenceRanges.isEmpty)
    }
}
