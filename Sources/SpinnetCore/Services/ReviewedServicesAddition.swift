import Foundation

public enum ReviewedServicesAddition {
    public enum Presentation: String { case surface, menu }
    public static let id = "tools.showServices"
    public static let members: [PluginInterfaceMember] = [.hostCommand(id), .standardAction(id), .request(id)]
    public static func validate(_ input: JSONValue) throws {
        guard case .object(let fields) = input, fields["tool"] == .string("homebrew"), Set(fields.keys).isSubset(of: ["tool", "presentation"]),
              fields["presentation"] == nil || fields["presentation"] == .string("menu") || fields["presentation"] == .string("surface") else {
            throw PluginHostServiceError.invalidInput("tools.showServices requires tool: homebrew and optional presentation: surface or menu")
        }
    }
    public static func presentation(_ input: JSONValue) throws -> Presentation {
        try validate(input)
        return input.value(atPointer: "/presentation") == .string("menu") ? .menu : .surface
    }
    public static func authorize(in scope: PluginCapabilityScope?) throws {
        guard let tool = scope?.reviewedTools.first(where: { $0.tool == "homebrew" }), tool.operations.contains("services"), tool.kinds.contains("formula") else {
            throw PluginHostServiceError.capabilityScopeDenied(.readReviewedTools)
        }
    }
}
