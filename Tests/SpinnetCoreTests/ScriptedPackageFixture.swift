import Foundation
import SpinnetCore

/// A scripted Plugin package written to a temporary directory, owned by the
/// tests rather than shipped in the Host. Loader and runtime tests need a real
/// package on disk — a real manifest file and real script files — so they build
/// one here instead of reading a copy that also has to be kept in the app.
enum ScriptedPackageFixture {
    static let pluginID = PluginID("com.spinnet.fixture")

    static let transformTextCommandID = CommandID("fixture.transform_text")
    static let transformDataCommandID = CommandID("fixture.transform_data")

    /// Declares every Host Command variant plus the two JavaScript Commands, so
    /// a single package covers the declarative path, the scripted path, and the
    /// Capability boundary between them.
    private static let manifest = """
    {
      "protocol_version": "1.0",
      "id": "com.spinnet.fixture",
      "name": "Spinnet Fixture Plugin",
      "version": "1.0.0",
      "capabilities": ["read_selected_text", "write_clipboard"],
      "preset": {
        "readiness": "ready_to_use",
        "is_configurable": true,
        "default_primary_command_id": "fixture.open_url",
        "default_alternate_command_ids": ["fixture.transform_text"],
        "default_inputs": {
          "fixture.open_url": "https://github.com/vulpsecula/Spinnet"
        }
      },
      "commands": [
        {"id": "fixture.open_url", "title": "Open URL", "execution": "host", "is_configurable": true, "host_command": "url.open"},
        {"id": "fixture.open_application", "title": "Open Application", "execution": "host", "is_configurable": true, "host_command": "application.open"},
        {"id": "fixture.open_file", "title": "Open File", "execution": "host", "is_configurable": true, "host_command": "file.open"},
        {"id": "fixture.open_folder", "title": "Open Folder", "execution": "host", "is_configurable": true, "host_command": "folder.open"},
        {"id": "fixture.invoke_keyboard_shortcut", "title": "Run Keyboard Shortcut", "execution": "host", "is_configurable": true, "host_command": "keyboard_shortcut.invoke"},
        {"id": "fixture.invoke_service", "title": "Run macOS Service", "execution": "host", "is_configurable": true, "host_command": "service.invoke"},
        {"id": "fixture.invoke_shortcut", "title": "Run Shortcut", "execution": "host", "is_configurable": true, "host_command": "shortcut.invoke"},
        {"id": "fixture.copy_text", "title": "Copy Text", "execution": "host", "is_configurable": true, "host_command": "clipboard.copy"},
        {"id": "fixture.present_feedback", "title": "Present Feedback", "execution": "host", "is_configurable": true, "host_command": "feedback.present"},
        {"id": "fixture.transform_text", "title": "Transform Text", "execution": "javascript", "is_configurable": false, "script": "transform-text.js"},
        {"id": "fixture.transform_data", "title": "Transform Structured Data", "execution": "javascript", "is_configurable": true, "script": "structured-data.js"}
      ]
    }
    """

    /// Reads the selection through a Host Service and writes the result back to
    /// the clipboard, so revoking either Capability changes the outcome.
    private static let transformText = """
    (() => {
      const selectedText = String(requestHostService("read_selected_text"));
      const output = selectedText
        .trim()
        .split(/\\s+/)
        .map((word, index) => index % 2 === 0 ? word.toUpperCase() : word.toLowerCase())
        .join("-");
      requestHostService("write_clipboard", output);
      let checksum = 2166136261;
      for (let index = 0; index < output.length; index += 1) {
        checksum = Math.imul(checksum ^ output.charCodeAt(index), 16777619) >>> 0;
      }
      return { checksum: String(checksum), output_bytes: output.length };
    })()
    """

    /// Pure transform over its input, with no Host Service use, so scripted
    /// execution can be measured without the Capability boundary in the way.
    private static let structuredData = """
    (() => {
      const document = typeof input === "string" ? JSON.parse(input) : input;
      const enabled = document.items
        .filter((item) => item.enabled)
        .sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0)
        .map((item) => `${item.id}:${item.name}`);
      const output = JSON.stringify(enabled);
      let checksum = 2166136261;
      for (let index = 0; index < output.length; index += 1) {
        checksum = Math.imul(checksum ^ output.charCodeAt(index), 16777619) >>> 0;
      }
      return { checksum: String(checksum), output_bytes: output.length };
    })()
    """

    static func write() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetScriptedFixture-\(UUID().uuidString).spinnetplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manifest.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try transformText.write(to: root.appendingPathComponent("transform-text.js"), atomically: true, encoding: .utf8)
        try structuredData.write(to: root.appendingPathComponent("structured-data.js"), atomically: true, encoding: .utf8)
        return root
    }

    static func load() throws -> PluginPackage {
        try PluginManifestLoader.load(packageAt: write())
    }
}
