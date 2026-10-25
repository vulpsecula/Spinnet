import Foundation

/// Stable repository paths for source-based tests and their checked-in data.
/// Keep this anchor in Tests/Support so a test file can move independently.
public enum TestRepository {
    public static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    public static let tests = root.appendingPathComponent("Tests", isDirectory: true)
}
