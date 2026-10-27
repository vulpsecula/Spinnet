import Foundation

/// Screen-capture requests keep configured-folder checks and user preferences together.
public struct HostScreenCaptureServices {
    private let screenCapturer: (ScreenCaptureRequest) throws -> Void
    private let preferredScreenCapturer: (ScreenCaptureSource) throws -> Void

    public init(screenCapturer: @escaping (ScreenCaptureRequest) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Screen capture") },
                preferredScreenCapturer: @escaping (ScreenCaptureSource) throws -> Void = { _ in throw PluginHostServiceError.unavailable("Screen capture") }) {
        self.screenCapturer = screenCapturer
        self.preferredScreenCapturer = preferredScreenCapturer
    }

    func execute(_ request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        switch request.service {
        case .captureScreen where request.operation != nil && request.input.isSourceAlone:
            // The Plugin names only what to capture; the user's screenshot
            // preferences say whether to copy or save (decision N9), and the
            // Plugin learns neither.
            guard case .object(let fields) = request.input, case .string(let raw)? = fields["source"],
                  let source = ScreenCaptureSource(rawValue: raw) else {
                throw PluginHostServiceError.invalidInput("screen.capture expects source: area, fullscreen or window")
            }
            try preferredScreenCapturer(source)
            return .null
        case .captureScreen:
            // The folder comes from the Action the user configured, never from
            // the Plugin alone: the request may only name that folder.
            let registered = package.manifest.commands.first { $0.id == action.commandID }
            let capture = try ScreenCaptureRequest(
                serviceInput: request.input,
                configuredFolders: registered?.configuredFolders(in: action.input) ?? []
            )
            // Starting the capture is the Action. The user finishes or cancels
            // it on screen after the Action has returned, which is why the
            // Plugin receives nothing back.
            try screenCapturer(capture)
            return .null
        default: throw PluginHostServiceError.unavailable("This Host Service is not in the HostScreenCaptureServices module")
        }
    }

}

private extension JSONValue {
    /// An object with `source` as its only member.
    var isSourceAlone: Bool {
        guard case .object(let fields) = self else { return false }
        return fields.count == 1 && fields["source"] != nil
    }
}
