import ImageIO
import XCTest
import SpinnetCore
@testable import SpinnetHost

/// The native capture adapter runs `/usr/sbin/screencapture` with fixed
/// arguments and then copies and saves as the request says. A
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
        var jpegs: [(URL, URL)] = []
        var analysed: [URL] = []
        /// What Automatic finds in the capture.
        var suggested: ScreenCaptureFormat = .png
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
            suggestedFormat: { url in
                recorder.analysed.append(url)
                return recorder.suggested
            },
            writeJPEG: { source, destination in
                recorder.jpegs.append((source, destination))
                try Data("jpeg".utf8).write(to: destination)
            },
            temporaryDirectory: temporary,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            dispatch: { $0() },
            report: { recorder.reports.append($0) }
        )
    }

    private func request(_ source: ScreenCaptureSource = .area, copy: Bool = true, saveTo folder: URL? = nil,
                         format: ScreenshotSettings.FileFormat = .png) -> ScreenCaptureRequest {
        ScreenCaptureRequest(source: source, copyToClipboard: copy, saveFolder: folder, saveFormat: format)
    }

    /// The tool always writes a lossless PNG; the saved file's format is
    /// decided afterwards.
    func testEachSourceRunsScreencaptureWithFixedArguments() throws {
        let output = URL(fileURLWithPath: "/tmp/out.png")
        XCTAssertEqual(NativeScreenCapturer.arguments(for: .area, output: output), ["-i", "-t", "png", "/tmp/out.png"])
        XCTAssertEqual(NativeScreenCapturer.arguments(for: .window, output: output), ["-i", "-W", "-t", "png", "/tmp/out.png"])
        XCTAssertEqual(NativeScreenCapturer.arguments(for: .fullScreen, output: output), ["-m", "-t", "png", "/tmp/out.png"])
        XCTAssertEqual(NativeScreenCapturer.executableURL.path, "/usr/sbin/screencapture")
    }

    func testCopyOnlyCapturesToATemporaryFileCopiesItAndRemovesIt() throws {
        let recorder = Recorder()
        let temporary = try folder()
        try makeCapturer(recorder, temporary: temporary).begin(request(format: .jpeg))

        XCTAssertEqual(recorder.runs.count, 1)
        XCTAssertEqual(recorder.runs[0].0, NativeScreenCapturer.executableURL)
        let output = try XCTUnwrap(recorder.runs[0].1.last)
        XCTAssertEqual(URL(fileURLWithPath: output).deletingLastPathComponent().standardizedFileURL, temporary.standardizedFileURL)
        XCTAssertEqual(recorder.copied.map(\.path), [output], "the clipboard gets the lossless capture")
        XCTAssertEqual(recorder.jpegs.count, 0)
        XCTAssertEqual(recorder.analysed, [], "nothing is saved, so there is no format to choose")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output), "the temporary capture is removed")
        XCTAssertEqual(recorder.reports, [])
    }

    func testSavingAsPNGKeepsTheCaptureAsANamedFileWithoutTouchingTheClipboard() throws {
        let recorder = Recorder()
        let destination = try folder()
        let temporary = try folder()
        try makeCapturer(recorder, temporary: temporary).begin(request(.fullScreen, copy: false, saveTo: destination))

        let saved = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertEqual(saved, ["Screenshot \(localTime).png"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(saved[0])), Data("image".utf8))
        XCTAssertEqual(recorder.copied, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), [], "the temporary capture is removed")
    }

    func testSavingAsJPEGReencodesTheCapture() throws {
        let recorder = Recorder()
        let destination = try folder()
        try makeCapturer(recorder, temporary: try folder()).begin(request(copy: false, saveTo: destination, format: .jpeg))

        XCTAssertEqual(recorder.jpegs.count, 1)
        XCTAssertEqual(recorder.jpegs[0].0.path, recorder.runs[0].1.last)
        XCTAssertEqual(recorder.jpegs[0].1.pathExtension, "jpg")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).map { ($0 as NSString).pathExtension }, ["jpg"])
        XCTAssertEqual(recorder.analysed, [])
    }

    func testAutomaticSavesInTheFormatTheContentSuggests() throws {
        for (suggested, expected) in [(ScreenCaptureFormat.jpg, "jpg"), (.png, "png")] {
            let recorder = Recorder()
            recorder.suggested = suggested
            let destination = try folder()
            try makeCapturer(recorder, temporary: try folder()).begin(request(saveTo: destination, format: .automatic))

            XCTAssertEqual(recorder.analysed.map(\.path), [try XCTUnwrap(recorder.runs[0].1.last)])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).map { ($0 as NSString).pathExtension },
                           [expected])
            XCTAssertEqual(recorder.jpegs.count, suggested == .jpg ? 1 : 0)
            XCTAssertEqual(recorder.copied.count, 1)
        }
    }

    func testCopyAndSaveKeepsEveryCaptureAndCopiesIt() throws {
        let recorder = Recorder()
        let destination = try folder()
        let capturer = makeCapturer(recorder, temporary: try folder())
        try capturer.begin(request(.window, saveTo: destination))
        try capturer.begin(request(.window, saveTo: destination))

        let saved = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        XCTAssertEqual(saved, ["Screenshot \(localTime) (2).png", "Screenshot \(localTime).png"],
                       "a second capture in the same second does not overwrite the first")
        XCTAssertEqual(recorder.copied.count, 2)
    }

    /// The real ImageIO adapters: a gradient PNG is analysed as a photo-like
    /// image and re-encoded as a readable JPEG.
    func testTheImageIOAdaptersReadAndReencodeARealCapture() throws {
        let directory = try folder()
        let png = directory.appendingPathComponent("capture.png")
        let width = 320, height = 200
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(x * 255 / (width - 1))
                pixels[offset + 1] = UInt8(y * 255 / (height - 1))
                pixels[offset + 2] = 90
            }
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        XCTAssertEqual(NativeScreenCapturer.suggestedFormat(ofImageAt: png), .jpg)
        let jpeg = directory.appendingPathComponent("capture.jpg")
        try NativeScreenCapturer.writeJPEG(from: png, to: jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, width)
    }

    /// The fixed clock, formatted in this Mac's time zone as saved names are.
    private var localTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Esc ends interactive capture without writing anything. That is the
    /// user changing their mind, so nothing is copied, saved, or reported.
    func testACancelledCaptureIsQuiet() throws {
        let recorder = Recorder()
        recorder.writesOutput = false
        let destination = try folder()
        try makeCapturer(recorder, temporary: try folder())
            .begin(request(saveTo: destination))

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
        try capturer.begin(request())
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
        let request = request()
        try capturer.begin(request)
        XCTAssertThrowsError(try capturer.begin(request)) { error in
            guard case .unavailable = error as? PluginHostServiceError else { return XCTFail("\(error)") }
        }
        pending.removeFirst()()
        XCTAssertNoThrow(try capturer.begin(request))
    }
}
