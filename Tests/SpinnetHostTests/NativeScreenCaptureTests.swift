import XCTest
import SpinnetCore
@testable import SpinnetHost

/// The native capture adapter runs `/usr/sbin/screencapture` with fixed
/// arguments and then performs the configured post-capture operations. A
/// recording runner stands in for the tool, so these tests verify the
/// requested source and operations without capturing the screen.
final class NativeScreenCaptureTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpinnetCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    private final class Recorder {
        var runs: [(URL, [String])] = []
        var copied: [URL] = []
        var reports: [String] = []
        /// Whether the fake tool writes its output, as a completed capture does.
        var writesOutput = true
    }

    private func makeCapturer(_ recorder: Recorder, temporary: URL) -> NativeScreenCapturer {
        NativeScreenCapturer(
            runner: { executable, arguments in
                recorder.runs.append((executable, arguments))
                if recorder.writesOutput, let path = arguments.last {
                    try Data("image".utf8).write(to: URL(fileURLWithPath: path))
                }
            },
            copyImage: { url in
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "copied before the file was removed")
                recorder.copied.append(url)
            },
            temporaryDirectory: temporary,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            dispatch: { $0() },
            report: { recorder.reports.append($0) }
        )
    }

    func testEachSourceRunsScreencaptureWithFixedArguments() throws {
        let output = URL(fileURLWithPath: "/tmp/out.png")
        func arguments(_ source: ScreenCaptureSource, _ format: ScreenCaptureFormat = .png) -> [String] {
            NativeScreenCapturer.arguments(
                for: ScreenCaptureRequest(source: source, format: format, copyToClipboard: true, saveFolder: nil),
                output: output)
        }
        XCTAssertEqual(arguments(.area), ["-i", "-t", "png", "/tmp/out.png"])
        XCTAssertEqual(arguments(.window), ["-i", "-W", "-t", "png", "/tmp/out.png"])
        XCTAssertEqual(arguments(.fullScreen, .jpg), ["-m", "-t", "jpg", "/tmp/out.png"])
        XCTAssertEqual(NativeScreenCapturer.executableURL.path, "/usr/sbin/screencapture")
    }

    func testCopyOnlyCapturesToATemporaryFileCopiesItAndRemovesIt() throws {
        let recorder = Recorder()
        let temporary = try folder()
        try makeCapturer(recorder, temporary: temporary)
            .begin(ScreenCaptureRequest(source: .area, format: .png, copyToClipboard: true, saveFolder: nil))

        XCTAssertEqual(recorder.runs.count, 1)
        XCTAssertEqual(recorder.runs[0].0, NativeScreenCapturer.executableURL)
        let output = try XCTUnwrap(recorder.runs[0].1.last)
        XCTAssertEqual(URL(fileURLWithPath: output).deletingLastPathComponent().standardizedFileURL, temporary.standardizedFileURL)
        XCTAssertEqual(recorder.copied.map(\.path), [output])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output), "the temporary capture is removed")
        XCTAssertEqual(recorder.reports, [])
    }

    func testSaveOnlyWritesANamedFileIntoTheFolderWithoutTouchingTheClipboard() throws {
        let recorder = Recorder()
        let destination = try folder()
        try makeCapturer(recorder, temporary: try folder())
            .begin(ScreenCaptureRequest(source: .fullScreen, format: .jpg, copyToClipboard: false, saveFolder: destination))

        let output = URL(fileURLWithPath: try XCTUnwrap(recorder.runs.first?.1.last))
        XCTAssertEqual(output.deletingLastPathComponent().standardizedFileURL, destination.standardizedFileURL)
        XCTAssertTrue(output.lastPathComponent.hasPrefix("Screenshot "), output.lastPathComponent)
        XCTAssertEqual(output.pathExtension, "jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(recorder.copied, [])
    }

    func testCopyAndSaveKeepsTheFileAndCopiesIt() throws {
        let recorder = Recorder()
        let destination = try folder()
        let capturer = makeCapturer(recorder, temporary: try folder())
        let request = ScreenCaptureRequest(source: .window, format: .png, copyToClipboard: true, saveFolder: destination)
        try capturer.begin(request)
        try capturer.begin(request)

        let outputs = recorder.runs.compactMap(\.1.last)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertNotEqual(outputs[0], outputs[1], "a second capture in the same second does not overwrite the first")
        XCTAssertTrue(outputs.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        XCTAssertEqual(recorder.copied.map(\.path), outputs)
    }

    /// Esc ends interactive capture without writing anything. That is the
    /// user changing their mind, so nothing is copied, saved, or reported.
    func testACancelledCaptureIsQuiet() throws {
        let recorder = Recorder()
        recorder.writesOutput = false
        let destination = try folder()
        try makeCapturer(recorder, temporary: try folder())
            .begin(ScreenCaptureRequest(source: .area, format: .png, copyToClipboard: true, saveFolder: destination))

        XCTAssertEqual(recorder.runs.count, 1)
        XCTAssertEqual(recorder.copied, [])
        XCTAssertEqual(recorder.reports, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testAFailedPostCaptureOperationIsReported() throws {
        let recorder = Recorder()
        let capturer = NativeScreenCapturer(
            runner: { _, arguments in try Data("image".utf8).write(to: URL(fileURLWithPath: arguments.last!)) },
            copyImage: { _ in throw PluginHostServiceError.failed("Clipboard could not be updated") },
            temporaryDirectory: try folder(), dispatch: { $0() }, report: { recorder.reports.append($0) })
        try capturer.begin(ScreenCaptureRequest(source: .area, format: .png, copyToClipboard: true, saveFolder: nil))
        XCTAssertEqual(recorder.reports.count, 1)
        XCTAssertTrue(recorder.reports[0].contains("Screenshot"), recorder.reports[0])
    }

    /// Interactive capture is user-paced, so a second request while one is on
    /// screen is refused rather than stacked behind it.
    func testASecondCaptureWhileOneIsInProgressIsRefused() throws {
        var pending: [() -> Void] = []
        let capturer = NativeScreenCapturer(
            runner: { _, _ in }, copyImage: { _ in }, temporaryDirectory: try folder(),
            dispatch: { pending.append($0) }, report: { _ in })
        let request = ScreenCaptureRequest(source: .area, format: .png, copyToClipboard: true, saveFolder: nil)
        try capturer.begin(request)
        XCTAssertThrowsError(try capturer.begin(request)) { error in
            guard case .unavailable = error as? PluginHostServiceError else { return XCTFail("\(error)") }
        }
        pending.removeFirst()()
        XCTAssertNoThrow(try capturer.begin(request))
    }
}
