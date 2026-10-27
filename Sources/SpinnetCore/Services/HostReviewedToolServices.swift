import Foundation

/// Concrete tool discovery and execution are supplied by the Host, not created
/// by the public request broker or by a Plugin's recorded test environment.
public protocol HostReviewedToolReading {
    func read(_ input: JSONValue, owner: PluginID, timeout: TimeInterval,
              cancellation: HostFetchedSections.Cancellation, stillAuthorized: () throws -> Void) throws -> JSONValue
    func invalidateManagementTargets(owner: PluginID)
}

public protocol HostReviewedToolTaskStopping {
    func stop(_ id: String, for owner: PluginID?) throws
}

public struct HostReviewedToolServices {
    private let reader: HostReviewedToolReading?
    private let tasks: HostReviewedToolTaskStopping?
    private let presenter: (PluginPackage, ActionConfiguration, ReviewedServicesAddition.Presentation) throws -> Void

    public init(reader: HostReviewedToolReading? = nil, tasks: HostReviewedToolTaskStopping? = nil,
                presenter: @escaping (PluginPackage, ActionConfiguration, ReviewedServicesAddition.Presentation) throws -> Void = { _, _, _ in
                    throw PluginHostServiceError.unavailable("The reviewed Services surface is unavailable")
                }) {
        self.reader = reader; self.tasks = tasks; self.presenter = presenter
    }

    func invalidateManagementTargets(owner: PluginID) { reader?.invalidateManagementTargets(owner: owner) }

    func read(_ input: JSONValue, owner: PluginID, timeout: TimeInterval,
              cancellation: HostFetchedSections.Cancellation, stillAuthorized: () throws -> Void) throws -> JSONValue {
        guard let reader else { throw PluginHostServiceError.unavailable("Reviewed tool reads") }
        return try reader.read(input, owner: owner, timeout: timeout, cancellation: cancellation, stillAuthorized: stillAuthorized)
    }

    var canStopTasks: Bool { tasks != nil }
    func stopTask(_ id: String, owner: PluginID) throws { try tasks?.stop(id, for: owner) }
    func present(_ package: PluginPackage, action: ActionConfiguration, input: JSONValue) throws {
        try presenter(package, action, ReviewedServicesAddition.presentation(input))
    }
}
