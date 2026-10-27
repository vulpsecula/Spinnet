import Foundation

/// Clipboard and selected-text input parsing, bounded history reads and native effects after authorization.
public struct HostClipboardServices {
    private let selectedTextProvider: (_ allowingCopyFallback: Bool) throws -> String
    private let clipboardWriter: (String) throws -> Void
    private let currentClipboardProvider: () throws -> ClipboardContent?
    private let clipboardHistoryProvider: ([String], Int) throws -> ClipboardHistorySnapshot
    private let clipboardHistoryContentProvider: (UUID, [String], Int, Int) throws -> ClipboardHistoryContentChunk
    private let clipboardHistoryPresenter: (PluginPackage, ActionConfiguration) -> Void

    public init(selectedTextProvider: @escaping (_ allowingCopyFallback: Bool) throws -> String = { _ in throw PluginHostServiceError.unavailable("Selected text") },
                clipboardWriter: @escaping (String) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Clipboard writing") },
                currentClipboardProvider: @escaping () throws -> ClipboardContent? = { nil },
                clipboardHistoryProvider: @escaping ([String], Int) throws -> ClipboardHistorySnapshot = { _, _ in throw PluginHostServiceError.unavailable("Clipboard History") },
                clipboardHistoryContentProvider: @escaping (UUID, [String], Int, Int) throws -> ClipboardHistoryContentChunk = { _, _, _, _ in throw PluginHostServiceError.unavailable("Clipboard History content") },
                clipboardHistoryPresenter: @escaping (PluginPackage, ActionConfiguration) -> Void = { _, _ in }) {
        self.selectedTextProvider = selectedTextProvider
        self.clipboardWriter = clipboardWriter
        self.currentClipboardProvider = currentClipboardProvider
        self.clipboardHistoryProvider = clipboardHistoryProvider
        self.clipboardHistoryContentProvider = clipboardHistoryContentProvider
        self.clipboardHistoryPresenter = clipboardHistoryPresenter
    }

    func execute(_ request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration, allowsCopyFallback: Bool) throws -> JSONValue {
        switch request.service {
        case .readClipboardHistoryContent:
            guard case .object(let fields) = request.input, fields.count == 3,
                  case .string(let id) = fields["entry_id"], let entryID = UUID(uuidString: id),
                  case .number(let offset) = fields["offset"], offset.isFinite, offset >= 0, offset <= Double(Int.max / 2), offset.rounded() == offset,
                  case .number(let length) = fields["length"], length >= 1,
                  length <= Double(ClipboardHistoryBudgets.maximumContentChunkBytes),
                  length.rounded() == length else {
                throw PluginHostServiceError.invalidInput("Expected entry_id, nonnegative integer offset, and length 1…196608")
            }
            let chunk = try readHistory {
                try clipboardHistoryContentProvider(entryID, package.manifest.scope(for: .readClipboardHistory)?.dataTypes ?? [], Int(offset), Int(length))
            }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(chunk))
        case .readCurrentClipboard:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("read_current_clipboard expects null")
            }
            guard let content = try currentClipboardProvider(),
                  package.manifest.scope(for: .readCurrentClipboard)?.dataTypes.contains(content.type.rawValue) == true else { return .null }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(content))
        case .presentClipboardHistory:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("present_clipboard_history expects null")
            }
            // The Host Surface: the granted Capability decides, not where the
            // Plugin came from.
            clipboardHistoryPresenter(package, action)
            // The Plugin learns nothing from presenting; the user reads the window.
            return .null
        case .readClipboardHistory:
            var offset = 0
            if case .object(let fields) = request.input, fields.count == 1,
               case .number(let value) = fields["offset"], value >= 0, value <= Double(Int.max / 2), value.rounded() == value {
                offset = Int(value)
            } else if request.input != .null {
                throw PluginHostServiceError.invalidInput("Expected null or a nonnegative integer offset")
            }
            let snapshot = try readHistory {
                try clipboardHistoryProvider(package.manifest.scope(for: .readClipboardHistory)?.dataTypes ?? [], offset)
            }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot))
        case .readSelectedText:
            let bestEffort: Bool
            switch request.input {
            case .null: bestEffort = false
            case .object(["best_effort": .bool(true)]): bestEffort = true
            default:
                throw PluginHostServiceError.invalidInput("read_selected_text expects null or {\"best_effort\": true}")
            }
            do {
                return .string(try selectedTextProvider(allowsCopyFallback))
            } catch {
                // A failed Host Service ends the Plugin's Action, so a Plugin
                // with its own fallback asks for null instead. Refusals were
                // checked above and are never softened this way.
                guard bestEffort else { throw error }
                if case PluginHostServiceError.systemPermissionDenied = error { throw error }
                return .null
            }
        case .writeClipboard:
            guard case .string(let text) = request.input else {
                throw PluginHostServiceError.invalidInput(
                    "write_clipboard expects a text string"
                )
            }
            try clipboardWriter(text)
            return .null
        default: throw PluginHostServiceError.unavailable("This Host Service is not in the HostClipboardServices module")
        }
    }
    /// Filesystem errors can contain the private archive or payload URL.
    private func readHistory<T>(_ read: () throws -> T) throws -> T {
        do { return try read() }
        catch let error as PluginHostServiceError { throw error }
        catch { throw PluginHostServiceError.failed("Clipboard History could not be read") }
    }
}
