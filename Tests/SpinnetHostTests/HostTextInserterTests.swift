import XCTest
@testable import SpinnetCore
@testable import SpinnetHost

/// The Host's text insertion (#69, P3): the target App is brought to the
/// front, Spinnet gives up the keyboard, and the text is typed as Unicode
/// keyboard events posted to that App, never through the clipboard. A fake
/// desktop records what would be activated and posted, so no real App is
/// touched.
final class HostTextInserterTests: XCTestCase {
    private var desktop: FakeDesktop!
    private var inserter: HostTextInserter!

    override func setUp() {
        desktop = FakeDesktop()
        inserter = HostTextInserter(environment: desktop.environment)
    }

    private func insert(_ text: String, into target: HostTextInserter.Target) -> PluginHostServiceError?? {
        var outcome: PluginHostServiceError??
        inserter.insert(text, into: target) { outcome = .some($0) }
        return outcome
    }

    // MARK: - Keystrokes

    func testTextIsTypedInChunksOfWholeCharacters() throws {
        let family = "👨‍👩‍👧‍👦"
        let flag = "🏴󠁧󠁢󠁳󠁣󠁴󠁿"
        let text = "abcdefghijklmnopqrs" + family + "é" + flag + "中文"
        let strokes = try HostTextInserter.keystrokes(for: text)
        XCTAssertEqual(strokes.map(\.text).joined(), text, "Nothing is lost or reordered")
        for stroke in strokes {
            guard case .text(let chunk) = stroke else { return XCTFail("\(stroke)") }
            XCTAssertLessThanOrEqual(chunk.utf16.count, HostTextInserter.maximumUnitsPerEvent)
        }
        let chunks = strokes.map(\.text)
        XCTAssertTrue(chunks.contains { $0.contains(family) }, "A ZWJ sequence is never split across events")
        XCTAssertTrue(chunks.contains { $0.contains(flag) }, "A tag sequence is never split across events")
        XCTAssertEqual(chunks.first, "abcdefghijklmnopqrs", "The family would not fit after the letters")
    }

    func testACharacterLongerThanOneEventIsSplitBetweenScalarsNeverInsideASurrogatePair() throws {
        let long = "e" + String(repeating: "\u{301}", count: 30) + "😀"
        XCTAssertEqual(long.count, 2)
        let strokes = try HostTextInserter.keystrokes(for: long)
        XCTAssertEqual(strokes.map(\.text).joined(), long)
        XCTAssertGreaterThan(strokes.count, 1)
        for stroke in strokes {
            let units = Array(stroke.text.utf16)
            XCTAssertLessThanOrEqual(units.count, HostTextInserter.maximumUnitsPerEvent)
            XCTAssertFalse(UTF16.isTrailSurrogate(units[0]), "No event starts with half a pair")
            XCTAssertFalse(UTF16.isLeadSurrogate(units[units.count - 1]), "No event ends with half a pair")
        }
    }

    func testLineBreaksAndTabsAreTypedAsTheirKeys() throws {
        XCTAssertEqual(try HostTextInserter.keystrokes(for: "a\nb\r\nc\rd\te"),
                       [.text("a"), .lineBreak, .text("b"), .lineBreak, .text("c"), .lineBreak, .text("d"), .tab,
                        .text("e")])
    }

    func testOtherControlCharactersAreRefusedRatherThanTyped() {
        for text in ["a\u{8}", "\u{1B}", "x\u{7F}", "\u{0}"] {
            XCTAssertThrowsError(try HostTextInserter.keystrokes(for: text), text.debugDescription) { error in
                guard case .invalidInput = error as? PluginHostServiceError else { return XCTFail("\(error)") }
            }
        }
    }

    // MARK: - Delivery

    func testAViewInsertBringsItsOriginForwardThenTypesIntoIt() {
        desktop.frontmost = 7
        desktop.pollsUntilFrontmost = 3

        XCTAssertEqual(insert("hi😀", into: .application(42)), .some(nil))
        XCTAssertEqual(desktop.activated, [42])
        XCTAssertEqual(desktop.posted.map(\.pid), [42])
        XCTAssertEqual(desktop.posted.map(\.stroke), [.text("hi😀")])
        XCTAssertGreaterThanOrEqual(desktop.clock, 0.05, "It waits a moment once the App is in front")
        XCTAssertLessThan(desktop.clock, 1)
    }

    func testTheScriptPathTypesIntoTheAppInFront() {
        desktop.frontmost = 99
        XCTAssertEqual(insert("x", into: .frontmost), .some(nil))
        XCTAssertEqual(desktop.activated, [99], "Even the App in front is activated, so a Plugin View gives up the keyboard")
        XCTAssertEqual(desktop.posted.map(\.pid), [99])
    }

    func testWithoutAccessibilityNothingHappens() {
        desktop.trusted = false
        XCTAssertEqual(insert("x", into: .application(42)), .some(.systemPermissionDenied(.accessibility)))
        XCTAssertEqual(desktop.activated, [])
        XCTAssertEqual(desktop.posted.count, 0)
    }

    func testRefusalsBeforeActivation() {
        desktop.frontmost = nil
        XCTAssertEqual(insert("x", into: .frontmost), .some(.unavailable("No App is in front to insert into")))

        desktop.frontmost = desktop.ownProcess
        XCTAssertEqual(insert("x", into: .frontmost), .some(.unavailable("Spinnet does not insert text into itself")))
        XCTAssertEqual(insert("x", into: .application(desktop.ownProcess)),
                       .some(.unavailable("Spinnet does not insert text into itself")))

        desktop.running = []
        XCTAssertEqual(insert("x", into: .application(42)), .some(.unavailable("The App to insert into is no longer open")))

        XCTAssertEqual(insert("a\u{8}", into: .application(42))??.actionFailureCategory, .hostServiceFailed)
        XCTAssertEqual(desktop.activated, [])
        XCTAssertEqual(desktop.posted.count, 0)
    }

    func testAnAppThatDoesNotComeForwardWithinASecondGetsNoKeystrokes() {
        desktop.frontmost = 7
        desktop.comesForward = false
        XCTAssertEqual(insert("x", into: .application(42)),
                       .some(.unavailable("The App to insert into did not come to the front; nothing was inserted")))
        XCTAssertEqual(desktop.posted.count, 0)
        XCTAssertGreaterThanOrEqual(desktop.clock, 1)
        XCTAssertLessThan(desktop.clock, 1.1)
    }

    func testKeystrokesWaitUntilSpinnetNoLongerHoldsTheKeyboard() {
        desktop.frontmost = 42
        desktop.keyboardHeldPolls = 4
        XCTAssertEqual(insert("x", into: .application(42)), .some(nil))
        XCTAssertEqual(desktop.keyboardHeldWhenPosting, [false])

        desktop.keyboardHeldPolls = .max
        XCTAssertEqual(insert("x", into: .application(42)),
                       .some(.unavailable("The App to insert into did not come to the front; nothing was inserted")))
        XCTAssertEqual(desktop.posted.count, 1, "Only the first insertion typed anything")
    }

    func testAPasswordFieldGetsNoKeystrokes() {
        desktop.frontmost = 42
        desktop.secure = true
        XCTAssertEqual(insert("secret", into: .application(42)),
                       .some(.unavailable("The focused field is a password field; nothing was inserted")))
        XCTAssertEqual(desktop.posted.count, 0)
    }

    func testTypingStopsWhenTheAppLosesTheFront() {
        desktop.frontmost = 42
        desktop.loseFrontAfterPosts = 2
        let text = String(repeating: "a", count: HostTextInserter.maximumUnitsPerEvent * 5)
        XCTAssertEqual(insert(text, into: .application(42)),
                       .some(.failed("The App to insert into left the front while the text was typed; only part of it was inserted")))
        XCTAssertEqual(desktop.posted.count, 2)
    }

    func testEmptyTextTypesNothingAndActivatesNothing() {
        desktop.frontmost = 42
        XCTAssertEqual(insert("", into: .application(42)), .some(nil))
        XCTAssertEqual(desktop.activated, [])
    }

    func testTheScriptPathWaitsForTheInsertionOffTheMainThread() throws {
        let inserter = HostTextInserter(environment: .live)
        // Off the main thread the call blocks until the main thread has run
        // the insertion; here Accessibility decides the outcome either way.
        let finished = expectation(description: "inserted")
        var thrown: Error?
        DispatchQueue.global().async {
            do { try inserter.insertAndWait("", into: .frontmost) } catch { thrown = error }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        if AXIsProcessTrusted() {
            XCTAssertNil(thrown)
        } else {
            XCTAssertEqual(thrown as? PluginHostServiceError, .systemPermissionDenied(.accessibility))
        }
        XCTAssertThrowsError(try inserter.insertAndWait("x", into: .frontmost), "On the main thread it cannot wait")
    }
}

private extension HostTextInserter.Keystroke {
    var text: String {
        switch self {
        case .text(let text): return text
        case .lineBreak: return "\n"
        case .tab: return "\t"
        }
    }
}

/// What the inserter sees of the desktop, run synchronously on a fake clock.
private final class FakeDesktop {
    var trusted = true
    let ownProcess: pid_t = 1
    var running: Set<pid_t> = [7, 42, 99]
    var frontmost: pid_t?
    /// Whether an activated App comes to the front, and after how many looks.
    var comesForward = true
    var pollsUntilFrontmost = 0
    /// How many more looks find Spinnet still holding the keyboard.
    var keyboardHeldPolls = 0
    var secure = false
    var loseFrontAfterPosts = Int.max
    private(set) var clock: TimeInterval = 0
    private(set) var activated: [pid_t] = []
    private(set) var posted: [(stroke: HostTextInserter.Keystroke, pid: pid_t)] = []
    private(set) var keyboardHeldWhenPosting: [Bool] = []
    private var keyboardHeld = false
    private var pendingActivation: pid_t?
    private var pollsSinceActivation = 0

    var environment: HostTextInserter.Environment {
        HostTextInserter.Environment(
            isTrusted: { [unowned self] in trusted },
            ownProcessIdentifier: ownProcess,
            isRunning: { [unowned self] in running.contains($0) },
            frontmost: { [unowned self] in
                if let pending = pendingActivation {
                    if pollsSinceActivation >= pollsUntilFrontmost {
                        frontmost = pending
                        pendingActivation = nil
                    } else {
                        pollsSinceActivation += 1
                    }
                }
                return frontmost
            },
            activate: { [unowned self] in
                activated.append($0)
                if comesForward {
                    pendingActivation = $0
                    pollsSinceActivation = 0
                }
            },
            holdsKeyboard: { [unowned self] in
                keyboardHeld = keyboardHeldPolls > 0
                if keyboardHeldPolls != .max { keyboardHeldPolls = max(0, keyboardHeldPolls - 1) }
                return keyboardHeld
            },
            focusedFieldIsSecure: { [unowned self] _ in secure },
            post: { [unowned self] stroke, pid in
                keyboardHeldWhenPosting.append(keyboardHeld)
                posted.append((stroke, pid))
                if posted.count >= loseFrontAfterPosts { frontmost = 7 }
                return true
            },
            pause: { _ in },
            schedule: { [unowned self] delay, work in
                clock += delay
                work()
            },
            deliver: { $0() },
            now: { [unowned self] in Date(timeIntervalSinceReferenceDate: clock) }
        )
    }
}
