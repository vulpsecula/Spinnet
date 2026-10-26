import Foundation
import XCTest
import SpinnetCore

final class PluginRuntimeWireTests: XCTestCase {
    private func invocation() -> PluginRuntimeInvocation {
        PluginRuntimeInvocation(pluginID: PluginID("com.example.wire"), actionID: ActionID("action"),
            commandID: CommandID("run"), scriptPath: "run.js", scriptSource: "null", input: .null)
    }

    func testInvocationAndEnvironmentEncodeOnlyCurrentMembers() throws {
        let value = invocation()
        let data = try JSONEncoder().encode(value)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(fields["api_level"])
        XCTAssertNil(fields["candidate_contracts"])
        let environment = try XCTUnwrap(fields["environment"] as? [String: Any])
        XCTAssertEqual(Set(environment.keys), ["host_version", "preferred_language"])
        XCTAssertEqual(try JSONDecoder().decode(PluginRuntimeInvocation.self, from: data), value)
    }

    func testRetiredOrUnknownInvocationMembersAreRefusedEvenWhenNull() throws {
        let data = try JSONEncoder().encode(invocation())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("api_level", NSNull() as Any), ("api_level", 7 as Any),
                             ("candidate_contracts", NSNull() as Any), ("candidate_contracts", [] as [Any]),
                             ("unknown", NSNull() as Any)] {
            var fields = original
            fields[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(PluginRuntimeInvocation.self,
                from: JSONSerialization.data(withJSONObject: fields)), key)
        }
    }

    func testRetiredOrUnknownEnvironmentMembersAreRefusedEvenWhenNull() throws {
        let data = try JSONEncoder().encode(invocation())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["api_level", "candidate_contracts", "unknown"] {
            var fields = original
            var environment = try XCTUnwrap(fields["environment"] as? [String: Any])
            environment[key] = NSNull()
            fields["environment"] = environment
            XCTAssertThrowsError(try JSONDecoder().decode(PluginRuntimeInvocation.self,
                from: JSONSerialization.data(withJSONObject: fields)), key)
        }
    }

    func testUnbundledEnvironmentUsesTheCurrentReleaseBaseline() {
        let environment = PluginRuntimeEnvironment.current(bundle: .main, preferredLanguages: [])
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") == nil {
            XCTAssertEqual(environment.hostVersion, HostVersion.currentString)
        }
        XCTAssertEqual(environment.preferredLanguage, "en")
    }
}
