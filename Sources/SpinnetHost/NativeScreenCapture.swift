import AppKit
import ImageIO
import SpinnetCore

/// Runs native screen captures for the `capture_screen` Host Service.
///
/// The capture itself is macOS's own `/usr/sbin/screencapture`, started with
/// a fixed argument list built from a validated `ScreenCaptureRequest`: no
/// shell, and nothing a Plugin wrote reaches the command line. The tool
/// supplies the interactive area and window selection, including Esc to
/// cancel, which is why it is preferred here over ScreenCaptureKit, which
/// would need a Host-drawn selection overlay to do the same.
///
/// The tool always writes a lossless PNG. The clipboard gets that PNG; a saved
/// file is that PNG, or a JPEG encoded from it, as the request's format says.
///
/// Interactive capture takes as long as the user does, far longer than a
/// scripted Action's deadline, so `begin` returns once the capture has started
/// and the post-capture operations run when the tool exits. A capture the user
/// cancels writes no file, and is dropped quietly.
final class NativeScreenCapturer {
    static let executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

    /// Runs the capture tool to completion with the given arguments.
    typealias Runner = (_ executable: URL, _ arguments: [String]) throws -> Void

    private let runner: Runner
    private let copyImage: (URL) throws -> Void
    private let suggestedFormat: (URL) -> ScreenCaptureFormat
    private let writeJPEG: (_ source: URL, _ destination: URL) throws -> Void
    private let temporaryDirectory: URL
    private let now: () -> Date
    private let dispatch: (@escaping () -> Void) -> Void
    private let report: (String) -> Void
    private let lock = NSLock()
    private var inProgress = false

    init(
        runner: @escaping Runner = NativeScreenCapturer.runProcess,
        copyImage: @escaping (URL) throws -> Void = NativeScreenCapturer.copyImageToPasteboard,
        suggestedFormat: @escaping (URL) -> ScreenCaptureFormat = NativeScreenCapturer.suggestedFormat(ofImageAt:),
        writeJPEG: @escaping (URL, URL) throws -> Void = NativeScreenCapturer.writeJPEG(from:to:),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        now: @escaping () -> Date = Date.init,
        dispatch: @escaping (@escaping () -> Void) -> Void = {
            DispatchQueue.global(qos: .userInitiated).async(execute: $0)
        },
        report: @escaping (String) -> Void = { _ in }
    ) {
        self.runner = runner
        self.copyImage = copyImage
        self.suggestedFormat = suggestedFormat
        self.writeJPEG = writeJPEG
        self.temporaryDirectory = temporaryDirectory
        self.now = now
        self.dispatch = dispatch
        self.report = report
    }

    /// The tool's arguments for a source: `-i` for an interactive area,
    /// `-i -W` to start in window selection, `-m` for the main display, then
    /// a lossless PNG and the output file.
    static func arguments(for source: ScreenCaptureSource, output: URL) -> [String] {
        let selection: [String]
        switch source {
        case .area: selection = ["-i"]
        case .window: selection = ["-i", "-W"]
        case .fullScreen: selection = ["-m"]
        }
        return selection + ["-t", "png", output.path]
    }

    /// Starts a capture and returns. Only one capture runs at a time, since a
    /// second interactive selection cannot share the screen with the first.
    func begin(_ request: ScreenCaptureRequest) throws {
        try lock.withLock {
            guard !inProgress else {
                throw PluginHostServiceError.unavailable("A screenshot is already in progress")
            }
            inProgress = true
        }
        dispatch { [self] in
            defer { lock.withLock { inProgress = false } }
            do {
                try capture(request)
            } catch {
                report("Screenshot failed: \(error.localizedDescription)")
            }
        }
    }

    private func capture(_ request: ScreenCaptureRequest) throws {
        let capture = temporaryDirectory.appendingPathComponent("Spinnet Screenshot \(UUID().uuidString).png")
        try runner(Self.executableURL, Self.arguments(for: request.source, output: capture))
        // Esc, or a click away from any window, ends the tool without a file.
        guard FileManager.default.fileExists(atPath: capture.path) else { return }
        defer { try? FileManager.default.removeItem(at: capture) }
        if let folder = request.saveFolder {
            let format: ScreenCaptureFormat
            switch request.saveFormat {
            case .automatic: format = suggestedFormat(capture)
            case .png: format = .png
            case .jpeg: format = .jpg
            }
            let destination = savedFileURL(in: folder, format: format)
            if format == .jpg {
                try writeJPEG(capture, destination)
            } else {
                try FileManager.default.copyItem(at: capture, to: destination)
            }
        }
        if request.copyToClipboard {
            try copyImage(capture)
        }
    }

    /// `Screenshot 2026-09-19 at 10.11.12.png`, as macOS names its own, with a
    /// counter when a capture in the same second already took the name.
    private func savedFileURL(in folder: URL, format: ScreenCaptureFormat) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screenshot \(formatter.string(from: now()))"
        var candidate = folder.appendingPathComponent("\(base).\(format.rawValue)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(counter)).\(format.rawValue)")
            counter += 1
        }
        return candidate
    }

    /// Automatic format for a capture file. The image is read at most 2048
    /// pixels on its long side, sampling pixels rather than blending them, so
    /// a large Retina capture stays small in memory and keeps its edges.
    static func suggestedFormat(ofImageAt url: URL) -> ScreenCaptureFormat {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return .png }
        let scale = min(1, 2048 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? ScreenshotContent.suggestedFormat(rgba: pixels, width: width, height: height) : .png
    }

    /// Encodes a capture as a JPEG at a quality where photographs show no
    /// visible loss.
    static func writeJPEG(from source: URL, to destination: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw PluginHostServiceError.failed("The capture could not be saved as JPEG")
        }
        CGImageDestinationAddImageFromSource(output, input, 0, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw PluginHostServiceError.failed("The capture could not be saved as JPEG")
        }
    }

    static func runProcess(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }

    static func copyImageToPasteboard(_ url: URL) throws {
        let copy = {
            guard let image = NSImage(contentsOf: url) else {
                throw PluginHostServiceError.failed("The capture could not be read")
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.writeObjects([image]) else {
                throw PluginHostServiceError.failed("Clipboard could not be updated")
            }
        }
        if Thread.isMainThread { try copy() } else { try DispatchQueue.main.sync(execute: copy) }
    }
}
