import XCTest
@testable import SpinnetHost

final class LinkOpenerTests: XCTestCase {
    private let link = URL(string: "https://example.com/page")!
    private let safari = URL(fileURLWithPath: "/Applications/Safari.app")
    private let firefox = URL(fileURLWithPath: "/Applications/Firefox.app")
    private let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")

    func testALinkOpensInTheBrowserInFront() {
        let recorder = Recorder(front: firefox, browsers: [safari, firefox])
        XCTAssertTrue(recorder.opener.open(link))
        XCTAssertEqual(recorder.openedWith, [link: firefox])
        XCTAssertEqual(recorder.openedByDefault, [])
    }

    func testALinkOpensInTheDefaultBrowserWhenTheAppInFrontIsNotABrowser() {
        let recorder = Recorder(front: notes, browsers: [safari, firefox])
        XCTAssertTrue(recorder.opener.open(link))
        XCTAssertEqual(recorder.openedWith, [:])
        XCTAssertEqual(recorder.openedByDefault, [link])
    }

    func testALinkOpensInTheDefaultBrowserWhenNoAppIsInFront() {
        let recorder = Recorder(front: nil, browsers: [safari])
        XCTAssertTrue(recorder.opener.open(link))
        XCTAssertEqual(recorder.openedByDefault, [link])
    }

    func testTheBrowserInFrontIsMatchedByItsStandardizedPath() {
        let recorder = Recorder(front: URL(fileURLWithPath: "/Applications/./Firefox.app/"), browsers: [firefox])
        XCTAssertTrue(recorder.opener.open(link))
        XCTAssertEqual(recorder.openedWith.values.map(\.path), [firefox.path])
    }

    func testALinkFallsBackToTheDefaultBrowserWhenTheBrowserInFrontRefusesIt() {
        let recorder = Recorder(front: firefox, browsers: [firefox])
        recorder.browserInFrontFails = true
        XCTAssertTrue(recorder.opener.open(link))
        XCTAssertEqual(recorder.openedByDefault, [link])
    }

    func testTheDefaultBrowsersAnswerIsReturned() {
        let recorder = Recorder(front: nil, browsers: [])
        recorder.defaultSucceeds = false
        XCTAssertFalse(recorder.opener.open(link))
    }
}

private final class Recorder {
    var openedWith: [URL: URL] = [:]
    var openedByDefault: [URL] = []
    var browserInFrontFails = false
    var defaultSucceeds = true
    let front: URL?
    let browsers: [URL]

    init(front: URL?, browsers: [URL]) {
        self.front = front
        self.browsers = browsers
    }

    var opener: LinkOpener {
        LinkOpener(environment: .init(
            appInFront: { [front] in front },
            browsers: { [browsers] _ in browsers },
            openWith: { [self] link, app, failed in
                openedWith[link] = app
                if browserInFrontFails { failed() }
            },
            openByDefault: { [self] link in
                openedByDefault.append(link)
                return defaultSucceeds
            }))
    }
}
