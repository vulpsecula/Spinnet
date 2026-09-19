import SpinnetCore
import XCTest
@testable import SpinnetHost

/// The result popup's state: the original text or what the user typed, and
/// each section filling in on the main thread as its answer arrives. A newer
/// submission replaces an older one, whose late answers are dropped.
final class ResultsPopupModelTests: XCTestCase {
    private func session(original: String?, answer: @escaping (String) -> String) throws -> ResultsPresentationSession {
        var fields: [String: JSONValue] = [
            "title": .string("Translate"),
            "sections": .array(["One", "Two"].map { title in
                .object(["title": .string(title),
                         "request": .object(["method": .string("POST"), "url": .string("https://api.example.com/\(title)"),
                                             "json_body": .object(["q": .string("{{text}}")])]),
                         "result_pointer": .string("/text")])
            })
        ]
        if let original { fields["original"] = .string(original) } else { fields["input"] = .object([:]) }
        return ResultsPresentationSession(presentation: try ResultsPresentation(serviceInput: .object(fields))) { request in
            guard case .object(let members) = request, case .string(let body)? = members["body"],
                  case .object(let sent) = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)),
                  case .string(let text)? = sent["q"] else { throw PluginHostServiceError.failed("bad request") }
            let reply = try JSONEncoder().encode(JSONValue.object(["text": .string(answer(text))]))
            return .object(["status": .number(200), "headers": .object([:]), "body": .string(String(decoding: reply, as: UTF8.self))])
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testAPopupWithTheOriginalResolvesAtOnce() throws {
        let model = ResultsPopupModel(session: try session(original: "Hello") { "\($0)!" }, copy: { _ in })
        XCTAssertEqual(model.shownText, "Hello")
        XCTAssertFalse(model.asksForText)
        model.start()
        XCTAssertEqual(model.states, [.pending, .pending])
        waitUntil { model.states == [.succeeded("Hello!"), .succeeded("Hello!")] }
    }

    func testAPopupThatAsksForTextWaitsForASubmission() throws {
        let model = ResultsPopupModel(session: try session(original: nil) { $0.uppercased() }, copy: { _ in })
        XCTAssertTrue(model.asksForText)
        model.start()
        XCTAssertNil(model.states, "Nothing is sent before the user submits")
        model.input = "   "
        model.submit()
        XCTAssertNil(model.states, "Blank input is not sent")
        model.input = "hi there"
        model.submit()
        waitUntil { model.states == [.succeeded("HI THERE"), .succeeded("HI THERE")] }
        XCTAssertEqual(model.shownText, "hi there")
    }

    func testANewerSubmissionDropsTheLateAnswersOfAnOlderOne() throws {
        let release = DispatchSemaphore(value: 0)
        let model = ResultsPopupModel(session: try session(original: nil) { text in
            if text == "old" { release.wait() }
            return text
        }, copy: { _ in })
        model.input = "old"
        model.submit()
        model.input = "new"
        model.submit()
        waitUntil { model.states == [.succeeded("new"), .succeeded("new")] }
        release.signal()
        release.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(model.states, [.succeeded("new"), .succeeded("new")])
    }

    func testOnlyAResultCanBeCopied() throws {
        var copied: [String] = []
        let model = ResultsPopupModel(session: try session(original: "Hello") { $0 }, copy: { copied.append($0) })
        model.copy(section: 0)
        XCTAssertEqual(copied, [], "Nothing to copy yet")
        model.start()
        waitUntil { model.states?.first == .succeeded("Hello") }
        model.copy(section: 0)
        XCTAssertEqual(copied, ["Hello"])
    }
}
