import Foundation

/// Focused-window grammar and effects, supplied by native or recorded adapters.
public struct HostWindowServices {
    private let focusedWindowProvider: () throws -> FocusedWindow
    private let focusedWindowFrameSetter: (WindowRect) throws -> Void
    private let focusedWindowFullScreenToggler: () throws -> Void
    private let focusedWindowFrameRestorer: () throws -> Void

    public init(focusedWindowProvider: @escaping () throws -> FocusedWindow = { throw PluginHostServiceError.unavailable("Focused window") },
                focusedWindowFrameSetter: @escaping (WindowRect) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Focused window") },
                focusedWindowFullScreenToggler: @escaping () throws -> Void = { throw PluginHostServiceError.unavailable("Focused window") },
                focusedWindowFrameRestorer: @escaping () throws -> Void = { throw PluginHostServiceError.unavailable("Focused window") }) {
        self.focusedWindowProvider = focusedWindowProvider
        self.focusedWindowFrameSetter = focusedWindowFrameSetter
        self.focusedWindowFullScreenToggler = focusedWindowFullScreenToggler
        self.focusedWindowFrameRestorer = focusedWindowFrameRestorer
    }

    func execute(_ request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        switch request.service {
        case .readFocusedWindow:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("read_focused_window expects null")
            }
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(focusedWindowProvider()))
        case .setFocusedWindowFrame:
            guard let frame = WindowRect(json: request.input) else {
                throw PluginHostServiceError.invalidInput(
                    "set_focused_window_frame expects x, y, width, and height, with a positive size"
                )
            }
            try focusedWindowFrameSetter(frame)
            return .null
        case .toggleFocusedWindowFullScreen:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("toggle_focused_window_full_screen expects null")
            }
            try focusedWindowFullScreenToggler()
            return .null
        case .restoreFocusedWindowFrame:
            guard request.input == .null else {
                throw PluginHostServiceError.invalidInput("restore_focused_window_frame expects null")
            }
            try focusedWindowFrameRestorer()
            return .null
        default: throw PluginHostServiceError.unavailable("This Host Service is not in the HostWindowServices module")
        }
    }
}
