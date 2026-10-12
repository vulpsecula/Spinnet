import Foundation
import Security
import ServiceManagement
import Darwin

/// Separate audited native namespaces; no Plugin entry point or raw audit-token
/// claim. Listeners set exact same-team designated requirements before resume.
@objc public protocol HomebrewNativeInspectionHostProtocol {
    func reserve(_ draft: Data, reply: @escaping (Data, String) -> Void)
    func confirmInspection(_ inspectionID: String, reply: @escaping (String, String) -> Void)
    func summary(_ inspectionID: String, reply: @escaping (Data, String) -> Void)
    func status(_ inspectionID: String, reply: @escaping (Data, String) -> Void)
    func recoverStatus(_ inspectionID: String, reply: @escaping (Data, String) -> Void)
    func laneStatus(reply: @escaping (Data, String) -> Void)
    func page(_ inspectionID: String, seal: String, offset: Int, reply: @escaping (Data, String) -> Void)
    func acknowledgeReview(_ receipt: Data, reply: @escaping (String) -> Void)
    func confirmMutation(_ confirmation: Data, reply: @escaping (String, String) -> Void)
    func cancel(_ inspectionID: String, reply: @escaping () -> Void)
}
@objc public protocol HomebrewNativeInspectionClientProtocol {
    func inspect(_ request: Data, authorization: Data, reply: @escaping (Data, String) -> Void)
    func validateAdmission(_ request: Data, authorization: Data, reply: @escaping (String) -> Void)
}

public enum HomebrewNativeInspectionAuthorization {
    public static let hostService = HomebrewSystemAuthorization.service + ".inspection.host"
    public static let clientService = HomebrewSystemAuthorization.service + ".inspection.client"
    /// Status check only. This path neither registers a daemon nor opens
    /// Settings. A missing helper is explicit unavailability before inspection.
    public static func requireExistingService() throws {
        _ = try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.helperIdentifier)
        let service = SMAppService.daemon(plistName: HomebrewSystemAuthorization.helperIdentifier + ".plist")
        guard service.status == .enabled else { throw PluginHostServiceError.unavailable("Authenticated read-only inspection requires Spinnet's already enabled reviewed tool helper; no helper was registered and no mutation started") }
    }
    public static func hostConnection() throws -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: hostService, options: .privileged)
        connection.setCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.helperIdentifier))
        connection.remoteObjectInterface = NSXPCInterface(with: HomebrewNativeInspectionHostProtocol.self)
        connection.resume(); return connection
    }
    public static func clientConnection() throws -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: clientService, options: .privileged)
        connection.setCodeSigningRequirement(try HomebrewSystemAuthorization.requirement(identifier: HomebrewSystemAuthorization.helperIdentifier))
        connection.remoteObjectInterface = NSXPCInterface(with: HomebrewNativeInspectionClientProtocol.self)
        connection.resume(); return connection
    }
    /// Called only by the Host listener AFTER public audited transport signing
    /// validation, not by JSON decoding. The listener must independently verify
    /// getpwuid_r(home), discovered prefix and continuing process identity.
    private static func validatedGuest(_ connection: NSXPCConnection, identifier: String) throws -> (UInt64, String) {
        guard connection.effectiveUserIdentifier != 0, let identity = HomebrewTaskProcess.startIdentity(connection.processIdentifier) else { throw HomebrewNativeInspection.Failure.invalidPeer }
        let text = try HomebrewSystemAuthorization.requirement(identifier: identifier)
        var code: SecCode?, requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
              HomebrewTaskProcess.startIdentity(connection.processIdentifier) == identity else { throw HomebrewNativeInspection.Failure.invalidPeer }
        return (identity, text)
    }
    public static func hostPeer(_ connection: NSXPCConnection) throws -> HomebrewNativeInspection.Peer {
        let (identity, requirement) = try validatedGuest(connection, identifier: HomebrewSystemAuthorization.hostIdentifier)
        let peer = HomebrewNativeInspection.Peer(uid: connection.effectiveUserIdentifier, pid: connection.processIdentifier,
            startIdentity: identity, auditSession: connection.auditSessionIdentifier,
            designatedRequirementSHA256: HomebrewSystemAuthorization.digest(Data(requirement.utf8)))
        try peer.validate(); return peer
    }
    /// Authenticated client must be the still-live initiating Host's immediate
    /// child, in that same UID and audit session. Listener signing requirement
    /// independently permits only the exact authorization-client identifier.
    public static func isInspectionClient(_ connection: NSXPCConnection, for peer: HomebrewNativeInspection.Peer) -> Bool {
        guard (try? validatedGuest(connection, identifier: HomebrewSystemAuthorization.clientIdentifier)) != nil else { return false }
        return connection.effectiveUserIdentifier == peer.uid && connection.auditSessionIdentifier == peer.auditSession
            && HomebrewTaskProcess.startIdentity(peer.pid) == peer.startIdentity
            && HomebrewTaskProcess.startIdentity(connection.processIdentifier) != nil
            && HomebrewSystemAuthorization.processParent(connection.processIdentifier) == peer.pid
    }
    public static func validRight(_ name: String, inspection: Bool) -> Bool {
        let namespace = inspection ? HomebrewNativeInspection.inspectionRightNamespace : HomebrewNativeInspection.mutationRightNamespace
        guard name.hasPrefix(namespace + ".") else { return false }
        return String(name.dropFirst(namespace.count + 1)).range(of: "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", options: .regularExpression) != nil
    }
    /// Never called during tests or mere metadata discovery. Root receives the
    /// initial Host confirmation before configuring its request-bound right.
    public static func configureInspectionRight(for session: HomebrewNativeInspectionSession) throws {
        guard session.state == .awaitingInspectionAuthorization else { throw HomebrewNativeInspection.Failure.wrongState }
        try configure(session.inspectionRightName, inspection: true)
    }
    /// Distinct fresh right configured only AFTER complete concrete final Host
    /// confirmation. Inspection authorization can never satisfy this namespace.
    public static func configureMutationRight(for session: HomebrewNativeInspectionSession) throws {
        guard session.state == .awaitingMutationAuthorization else { throw HomebrewNativeInspection.Failure.wrongState }
        try configure(session.mutationRightName, inspection: false)
    }
    private static func configure(_ name: String, inspection: Bool) throws {
        guard getuid() == 0, validRight(name, inspection: inspection) else { throw HomebrewNativeInspection.Failure.invalidPeer }
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { throw HomebrewNativeInspection.Failure.storeUnavailable }
        defer { AuthorizationFree(reference, []) }
        let definition: [String: Any] = ["class": "user", "group": "admin", "authenticate-user": true, "shared": false, "timeout": 0, "allow-root": false]
        let prompt = inspection ? "Inspect all receipt ownership metadata without changing installed packages" : "Admit this separately confirmed concrete Homebrew mutation"
        guard AuthorizationRightSet(reference, name, definition as CFDictionary, prompt as CFString, nil, nil) == errAuthorizationSuccess else { throw HomebrewNativeInspection.Failure.storeUnavailable }
    }
    public static func removeRights(for session: HomebrewNativeInspectionSession) {
        guard getuid() == 0 else { return }
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return }
        defer { AuthorizationFree(reference, []) }
        for (name, inspection) in [(session.inspectionRightName, true), (session.mutationRightName, false)] where validRight(name, inspection: inspection) {
            _ = AuthorizationRightRemove(reference, name)
        }
    }
}
