import Foundation

public enum ReviewedServicesAddition {
    public static let id = "tools.showServices"
    public static let members: [PluginInterfaceMember] = [.hostCommand(id), .standardAction(id), .request(id)]
    public static func validate(_ input: JSONValue) throws {
        guard input == .object(["tool": .string("homebrew")]) else { throw PluginHostServiceError.invalidInput("tools.showServices requires only tool: homebrew") }
    }
    public static func authorize(in scope: PluginCapabilityScope?) throws {
        guard let tool = scope?.reviewedTools.first(where: { $0.tool == "homebrew" }), tool.operations.contains("services"), tool.kinds.contains("formula") else {
            throw PluginHostServiceError.capabilityScopeDenied(.readReviewedTools)
        }
    }
}
