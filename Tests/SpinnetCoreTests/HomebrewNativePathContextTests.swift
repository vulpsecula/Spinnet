import XCTest
import SpinnetCore

final class HomebrewNativePathContextTests: XCTestCase {
    func testActualFixedConfigurationReadDoesNotRequireACurrentCaskSourceOrInstaller() throws {
        let context = try HomebrewNativePathContext.read(name: "spinnet-owned-missing-configuration-fixture", executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(context.home.path, NSHomeDirectory())
        XCTAssertEqual(context.prefix.path, "/opt/homebrew")
        XCTAssertEqual(context.appDirectory.path, "/Applications")
    }
}
