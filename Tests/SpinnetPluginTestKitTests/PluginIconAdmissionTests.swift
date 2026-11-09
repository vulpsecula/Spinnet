import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit
import SpinnetTestSupport

/// A Plugin author's tests load the package's Plugin Icon the way the Host
/// admits it, and see the same refusal the Host gives an invalid one.
final class PluginIconAdmissionTests: XCTestCase {
    private func package(icon: String, files: [String: Data] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Iconic.spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("""
        {"protocol_version": "1.0", "engines": {"spinnet": "^1.0.0"}, "id": "com.example.iconic",
         "name": "Iconic", "version": "1.0.0", "icon": \(icon),
         "commands": [{"id": "run", "title": "Run", "execution": "javascript", "script": "run.js"}]}
        """.utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data("null".utf8).write(to: root.appendingPathComponent("run.js"))
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return root
    }

    private func assertRefused(_ url: URL, mentioning words: [String], file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertThrowsError(try PluginUnderTest(packageAt: url), file: file, line: line) { error in
            let reason = String(describing: error)
            XCTAssertTrue(reason.contains("icon"), reason, file: file, line: line)
            for word in words { XCTAssertTrue(reason.contains(word), "\(word): \(reason)", file: file, line: line) }
        }
    }

    func testThePluginIconLoadsAsTheHostAdmitsIt() throws {
        let plugin = try PluginUnderTest(packageAt: package(icon: #"{"symbol": "macwindow"}"#))
        XCTAssertEqual(plugin.manifest.icon, .symbol("macwindow"))
    }

    func testAnInvalidSymbolIsRefusedWithAReason() throws {
        let url = try package(icon: #"{"symbol": "MacWindow"}"#)
        XCTAssertThrowsError(try PluginUnderTest(packageAt: url)) { error in
            XCTAssertTrue(String(describing: error).contains("icon"), "\(error)")
        }
    }

    // MARK: Package pictures

    func testPNGAndPDFPicturesInThePackageAreAdmitted() throws {
        let png = IconPictureFixtures.bitmap(width: 64, height: 64)
        let pdf = IconPictureFixtures.pdf()
        let plugin = try PluginUnderTest(packageAt: package(
            icon: #"{"image": "icons/mark.pdf", "dark_image": "icons/mark-dark.png"}"#,
            files: ["icons/mark.pdf": pdf, "icons/mark-dark.png": png]))
        XCTAssertEqual(plugin.manifest.icon, .picture(IconPicture(path: "icons/mark.pdf", darkPath: "icons/mark-dark.png")))
        XCTAssertNoThrow(try PluginUnderTest(packageAt: package(icon: #"{"image": "Mark.PNG", "template": true}"#,
                                                                files: ["Mark.PNG": png])))
    }

    func testAMissingPictureRefusesThePackage() throws {
        assertRefused(try package(icon: #"{"image": "mark.png"}"#), mentioning: ["mark.png", "not in the package"])
        assertRefused(try package(icon: #"{"image": "mark.png", "dark_image": "dark.png"}"#,
                                  files: ["mark.png": IconPictureFixtures.bitmap(width: 8, height: 8)]),
                      mentioning: ["dark.png", "not in the package"])
        assertRefused(try package(icon: #"{"image": "mark.png"}"#, files: ["mark.png/inner.png": Data()]),
                      mentioning: ["mark.png", "not in the package"])
    }

    func testAPictureLeadingOutsideThePackageRefusesIt() throws {
        let url = try package(icon: #"{"image": "mark.png"}"#)
        let outside = url.deletingLastPathComponent().appendingPathComponent("outside.png")
        try IconPictureFixtures.bitmap(width: 8, height: 8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("mark.png"), withDestinationURL: outside)
        assertRefused(url, mentioning: ["mark.png", "outside the package"])
        assertRefused(try package(icon: #"{"image": "../outside.png"}"#), mentioning: [])
    }

    /// The file must be what its name says: a PNG or a PDF.
    func testAPictureInAnotherFormatRefusesThePackage() throws {
        let jpeg = IconPictureFixtures.bitmap(width: 8, height: 8, type: .jpeg)
        assertRefused(try package(icon: #"{"image": "mark.png"}"#, files: ["mark.png": jpeg]),
                      mentioning: ["mark.png", "PNG"])
        assertRefused(try package(icon: #"{"image": "mark.pdf"}"#,
                                  files: ["mark.pdf": IconPictureFixtures.bitmap(width: 8, height: 8)]),
                      mentioning: ["mark.pdf", "PDF"])
        assertRefused(try package(icon: #"{"image": "mark.pdf"}"#, files: ["mark.pdf": Data("not a pdf".utf8)]),
                      mentioning: ["mark.pdf", "PDF"])
        assertRefused(try package(icon: #"{"image": "mark.jpg"}"#, files: ["mark.jpg": jpeg]), mentioning: [".pdf"])
    }

    func testAnOversizedPictureRefusesThePackage() throws {
        let bytes = IconPictureBudgets.maximumPictureBytes
        assertRefused(try package(icon: #"{"image": "mark.pdf"}"#, files: ["mark.pdf": Data(count: bytes + 1)]),
                      mentioning: ["mark.pdf", "\(bytes) bytes"])
        let edge = IconPictureBudgets.maximumPNGEdge
        assertRefused(try package(icon: #"{"image": "mark.png"}"#,
                                  files: ["mark.png": IconPictureFixtures.bitmap(width: edge + 1, height: 8)]),
                      mentioning: ["mark.png", "\(edge) pixels"])
        assertRefused(try package(icon: #"{"image": "mark.png", "dark_image": "dark.png"}"#,
                                  files: ["mark.png": IconPictureFixtures.bitmap(width: 8, height: 8),
                                          "dark.png": IconPictureFixtures.bitmap(width: 8, height: edge + 1)]),
                      mentioning: ["dark.png", "\(edge) pixels"])
        XCTAssertNoThrow(try PluginUnderTest(packageAt: package(
            icon: #"{"image": "mark.png"}"#, files: ["mark.png": IconPictureFixtures.bitmap(width: edge, height: edge)])))
    }

    func testATemplatePictureWithADarkPictureRefusesThePackage() throws {
        let png = IconPictureFixtures.bitmap(width: 8, height: 8)
        assertRefused(try package(icon: #"{"image": "mark.png", "template": true, "dark_image": "dark.png"}"#,
                                  files: ["mark.png": png, "dark.png": png]),
                      mentioning: ["template", "dark_image"])
    }
}
