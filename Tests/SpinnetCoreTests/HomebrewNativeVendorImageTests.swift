import XCTest
import CryptoKit
import Darwin
import SpinnetCore

final class HomebrewNativeVendorImageTests: XCTestCase {
    func testOwnedReadonlyImageCopiesFrozenProgramAndResourcesThenActuallyDetaches() throws {
        XCTAssertNotEqual(getuid(), 0, "Owned fixture validation, not Root acceptance")
        let raw = URL(fileURLWithPath: "/private/tmp/spinnet-image-fixture-" + UUID().uuidString)
        try NativeFileQuarantine.makePrivateDirectory(raw)
        let root = raw.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Vendor.app/Contents/MacOS"), withIntermediateDirectories: true)
        let program = source.appendingPathComponent("Vendor.app/Contents/MacOS/program")
        try Data("vendor executable".utf8).write(to: program); XCTAssertEqual(chmod(program.path, 0o700), 0)
        try Data("frozen resource".utf8).write(to: source.appendingPathComponent("Vendor.app/Contents/resource"))
        let image = root.appendingPathComponent("original.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-srcfolder", source.path, "-format", "UDRO", "-volname", "SpinnetOwnedOriginFixture", image.path]
        create.standardOutput = FileHandle.nullDevice; create.standardError = FileHandle.nullDevice
        try create.run(); create.waitUntilExit(); XCTAssertEqual(create.terminationStatus, 0)
        XCTAssertEqual(chmod(image.path, 0o600), 0)
        let checksum = SHA256.hash(data: try Data(contentsOf: image)).map { String(format: "%02x", $0) }.joined()
        let tree = try HomebrewNativeVendorImage.extractVerified(image, checksum: checksum, into: root.appendingPathComponent("original"), deadline: Date().addingTimeInterval(20))
        XCTAssertEqual(try String(contentsOf: tree.selectedURL.appendingPathComponent("Vendor.app/Contents/resource")), "frozen resource")
        let installed = root.appendingPathComponent("installed")
        try Data("vendor executable".utf8).write(to: installed); XCTAssertEqual(chmod(installed.path, 0o700), 0)
        let match = try HomebrewNativeVendorOrigin.compareMember(tree, member: "Vendor.app/Contents/MacOS/program", installed: installed, deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(match.executableSHA256, "57fa54816d203f24ce26ae4734a7eba5c220408c6fccbba218ab2cd957655961")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("image-work-") }, [])
    }
}
