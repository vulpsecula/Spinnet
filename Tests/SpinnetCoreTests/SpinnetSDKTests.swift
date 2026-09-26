import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// The `spinnet` object the helper injects into every script (W9 #56): one
/// namespace per area, each wrapper a camelCase name for exactly one Host
/// Service, and `PluginAPI/spinnet.d.ts` describing the same object.
final class SpinnetSDKTests: XCTestCase {
    /// Services the SDK leaves unwrapped because a ticket under the plugin
    /// architecture map, #47, removes them before Level 1 is published. A
    /// script can still reach them through `requestHostService`. The list may
    /// only shrink: when a ticket removes its service, its line stops
    /// compiling; when a ticket keeps a service under a new shape, delete
    /// its line here and wrap it in the SDK instead.
    private static let unwrapped: [PluginHostService: String] = [
        .presentResults: "W15 #62 moves Translator onto Plugin Views",
        .smartJump: "W14 #61 moves Smart Jump's recognition into its Plugin",
        .invokeExternalApp: "W8 #55 replaces it with a Reviewed App Interface and Deep Link Templates"
    ]

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private var helper: PluginTestHelper!

    override func setUpWithError() throws {
        helper = try PluginTestHelper(environment: PluginRuntimeEnvironment(
            apiLevel: 1, hostVersion: "9.8.7", preferredLanguage: "zh-Hans-CN"
        ))
    }

    override func tearDown() {
        helper?.shutdown()
        helper = nil
    }

    // MARK: - Wrappers

    /// Calling every wrapper with a distinct probe shows which service each
    /// one requests: exactly one, with the argument as its input, unchanged.
    func testEachWrapperRequestsExactlyOneHostServiceWithItsArgumentAsTheInput() throws {
        let wrappers = try wrappedServices()

        XCTAssertEqual(wrappers["selection.readText"], .readSelectedText)
        XCTAssertEqual(wrappers["selection.replace"], .insertText)
        XCTAssertEqual(wrappers["clipboard.read"], .readCurrentClipboard)
        XCTAssertEqual(wrappers["clipboard.write"], .writeClipboard)
        XCTAssertEqual(wrappers["clipboard.history"], .readClipboardHistory)
        XCTAssertEqual(wrappers["clipboard.historyContent"], .readClipboardHistoryContent)
        XCTAssertEqual(wrappers["clipboard.showHistory"], .presentClipboardHistory)
        XCTAssertEqual(wrappers["window.read"], .readFocusedWindow)
        XCTAssertEqual(wrappers["window.setFrame"], .setFocusedWindowFrame)
        XCTAssertEqual(wrappers["window.toggleFullScreen"], .toggleFocusedWindowFullScreen)
        XCTAssertEqual(wrappers["window.restore"], .restoreFocusedWindowFrame)
        XCTAssertEqual(wrappers["open.url"], .openURL)
        XCTAssertEqual(wrappers["open.path"], .openLocalPath)
        XCTAssertEqual(wrappers["http.request"], .httpsRequest)
        XCTAssertEqual(wrappers["text.detectLanguage"], .detectLanguage)
        XCTAssertEqual(wrappers["screen.capture"], .captureScreen)
    }

    /// A wrapper called without an argument sends `null`, as
    /// `requestHostService(name)` does, and it returns the service's answer.
    func testAWrapperWithoutAnArgumentSendsNullAndReturnsTheAnswer() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text"], script: """
            [spinnet.selection.readText(), spinnet.selection.readText({ best_effort: true })]
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .answer { input in input == .null ? .string("hello") : .null }
        ]))

        XCTAssertEqual(try run.result.get(), .array([.string("hello"), .null]))
        XCTAssertEqual(run.inputs(to: .readSelectedText), [.null, .object(["best_effort": .bool(true)])])
    }

    /// A service failure reaches the Host the same way whether the script
    /// used the wrapper or the raw call.
    func testAWrapperFailsTheSameWayAsTheRawCall() throws {
        let failure = RecordedHostServices([.readSelectedText: .failure(.unavailable("No readable selection"))])
        let wrapped = try writePlugin(capabilities: ["read_selected_text"], script: "spinnet.selection.readText()")
        let raw = try writePlugin(capabilities: ["read_selected_text"], script: "requestHostService(\"read_selected_text\")")

        let wrappedError = try XCTUnwrap(failureOf(helper.run(PluginTestInvocation("example.run"), of: wrapped,
                                                             answering: failure)))
        let rawError = try XCTUnwrap(failureOf(helper.run(PluginTestInvocation("example.run"), of: raw,
                                                         answering: failure)))

        XCTAssertEqual(wrappedError.failureCategory, .hostServiceFailed)
        XCTAssertEqual(wrappedError, rawError)
    }

    /// A refused Capability ends the whole invocation: catching the error
    /// does not let the script carry on to another protected operation.
    func testARefusalThroughAWrapperFailsTheWholeInvocation() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text"], script: """
            (() => {
              try { spinnet.clipboard.write("copied"); } catch (error) {}
              spinnet.selection.readText();
              return "carried on";
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .writeClipboard: .value(.null),
            .readSelectedText: .value(.string("hello"))
        ]))

        XCTAssertEqual(failureOf(run)?.failureCategory, .capabilityDenied)
        XCTAssertEqual(run.requests.map(\.service), [.writeClipboard])
    }

    /// `requestHostService` stays as the raw call beside the SDK.
    func testTheRawCallRemains() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text"], script: """
            typeof requestHostService === "function" ? requestHostService("read_selected_text") : "missing"
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .value(.string("hello"))
        ]))

        XCTAssertEqual(try run.result.get(), .string("hello"))
    }

    /// The areas later tickets fill are there already, empty, so a script
    /// can test for a feature without guarding the area itself.
    func testTheAreasLaterTicketsFillArePresentAndEmpty() throws {
        let plugin = try writePlugin(capabilities: [], script: """
            ["apps", "storage", "ui"].map((area) => [typeof spinnet[area], Object.keys(spinnet[area]).length])
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices())

        XCTAssertEqual(try run.result.get(), .array(Array(repeating: .array([.string("object"), .number(0)]), count: 3)))
    }

    /// A script cannot swap a wrapper for something else, whether by accident
    /// or to confuse a later script in the same context.
    func testTheSDKCannotBeChangedByTheScript() throws {
        let plugin = try writePlugin(capabilities: [], script: """
            (() => {
              "use strict";
              try { spinnet.clipboard.write = () => "replaced"; return "changed"; } catch (error) { return "frozen"; }
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices())

        XCTAssertEqual(try run.result.get(), .string("frozen"))
    }

    // MARK: - Environment

    /// The Host tells the script which Plugin API Level it supports, its own
    /// version, the user's preferred language, and the invocation's IDs.
    func testTheEnvironmentReportsTheHostAndTheInvocation() throws {
        let plugin = try writePlugin(capabilities: [], script: "spinnet.environment")

        let run = helper.run(PluginTestInvocation("example.run", actionID: "action-7"), of: plugin,
                             answering: RecordedHostServices())

        guard case .object(var environment) = try run.result.get() else {
            return XCTFail("spinnet.environment is not an object")
        }
        // The Host makes a fresh invocation ID for every run.
        guard case .string(let invocationID)? = environment.removeValue(forKey: "invocationID") else {
            return XCTFail("spinnet.environment has no invocationID")
        }
        XCTAssertFalse(invocationID.isEmpty)
        XCTAssertEqual(environment, [
            "apiLevel": .number(1),
            "hostVersion": .string("9.8.7"),
            "preferredLanguage": .string("zh-Hans-CN"),
            "pluginID": .string("com.example.sdk"),
            "commandID": .string("example.run"),
            "actionID": .string("action-7")
        ])
    }

    /// The Host builds the environment from what it is: the highest Plugin
    /// API Level it supports, its bundle's version, and the first of the
    /// user's preferred languages.
    func testTheHostsEnvironmentComesFromItsBundleAndTheUsersLanguages() throws {
        let bundle = try XCTUnwrap(Bundle(url: try writeBundle(version: "2.3.4")))

        let environment = PluginRuntimeEnvironment.current(bundle: bundle, preferredLanguages: ["de-CH", "en-US"])

        XCTAssertEqual(environment, PluginRuntimeEnvironment(
            apiLevel: PluginAPILevel.highestSupported, hostVersion: "2.3.4", preferredLanguage: "de-CH"
        ))
    }

    // MARK: - Coverage

    /// The SDK wraps every Host Service the Host registers, except those
    /// being removed, and wraps nothing else.
    func testTheSDKCoversEveryHostServiceTheHostRegisters() throws {
        let wrapped = Set(try wrappedServices().values)
        let expected = Set(PluginHostService.allCases).subtracting(Self.unwrapped.keys)

        for service in expected.subtracting(wrapped).sorted(by: { $0.rawValue < $1.rawValue }) {
            XCTFail("The SDK does not wrap \(service.rawValue). Add a camelCase wrapper for it to the area it "
                + "belongs to in PluginAPI/spinnet.js, and declare it with `@service \(service.rawValue)` in "
                + "PluginAPI/spinnet.d.ts.")
        }
        for service in wrapped.intersection(Self.unwrapped.keys) {
            XCTFail("\(service.rawValue) is wrapped but listed as unwrapped; delete it from `unwrapped`.")
        }
    }

    /// `spinnet.d.ts` declares the same wrappers as the SDK, each tagged with
    /// the service it requests, and names every service the Host registers.
    func testTheTypesDescribeTheSameWrappersAndEveryHostService() throws {
        let types = try String(contentsOf: Self.repository.appendingPathComponent("PluginAPI/spinnet.d.ts"),
                               encoding: .utf8)
        let declared = try DeclaredSDK(types)
        let wrappers = try wrappedServices()

        XCTAssertEqual(declared.wrappers, wrappers.mapValues(\.rawValue),
                       "Every wrapper in spinnet.js needs a method in spinnet.d.ts tagged `@service <name>`")
        XCTAssertEqual(declared.areas, try sdkAreas())
        XCTAssertEqual(declared.serviceNames, Set(PluginHostService.allCases.map(\.rawValue)),
                       "HostServiceName in spinnet.d.ts lists every Host Service the Host registers")
    }

    // MARK: - Support

    /// Every wrapper, keyed `area.name`, and the one service it requested.
    private func wrappedServices() throws -> [String: PluginHostService] {
        let plugin = try writePlugin(capabilities: [], script: """
            (() => {
              const called = [];
              for (const area of Object.keys(spinnet)) {
                if (area === "environment") continue;
                for (const name of Object.keys(spinnet[area])) {
                  spinnet[area][name]({ probe: area + "." + name });
                  called.push(area + "." + name);
                }
              }
              return called;
            })()
            """)
        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: AnswerEveryService())
        guard case .array(let called) = try run.result.get() else {
            XCTFail("The probe returned no list of wrappers")
            return [:]
        }
        XCTAssertEqual(run.requests.count, called.count, "Each wrapper makes exactly one request")

        var services: [String: PluginHostService] = [:]
        for request in run.requests {
            guard case .object(let input) = request.input, input.count == 1,
                  case .string(let wrapper) = input["probe"] else {
                XCTFail("\(request.service.rawValue) received \(request.input), not the wrapper's argument")
                continue
            }
            XCTAssertNil(services[wrapper], "\(wrapper) made more than one request")
            services[wrapper] = request.service
        }
        return services
    }

    private func sdkAreas() throws -> Set<String> {
        let plugin = try writePlugin(capabilities: [], script: "Object.keys(spinnet)")
        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices())
        guard case .array(let areas) = try run.result.get() else { return [] }
        return Set(areas.compactMap { if case .string(let area) = $0 { return area } else { return nil } })
    }

    private func failureOf(_ run: PluginTestRun) -> PluginRuntimeError? {
        guard case .failure(let error) = run.result else { return nil }
        return error as? PluginRuntimeError
    }

    /// A one-Command package in a temporary directory, removed after the test.
    private func writePlugin(capabilities: [String], script: String) throws -> PluginUnderTest {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetSDK-\(UUID().uuidString).spinnetplugin", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        try """
        {
          "protocol_version": "1.0", "id": "com.example.sdk", "name": "SDK Example", "version": "1.0.0",
          "capabilities": [\(list)],
          "commands": [
            {"id": "example.run", "title": "Run", "execution": "javascript", "is_configurable": false, "script": "run.js"}
          ]
        }
        """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try script.write(to: root.appendingPathComponent("run.js"), atomically: true, encoding: .utf8)
        return try PluginUnderTest(packageAt: root)
    }

    /// A bundle whose Info.plist carries little more than a version,
    /// standing in for the app bundle.
    private func writeBundle(version: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetSDKHost-\(UUID().uuidString).app", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.host", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return root
    }
}

/// Answers every request with `null` without looking at grants, so the
/// probe can reach every service whatever its Capability.
private struct AnswerEveryService: PluginHostServiceBroker {
    func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        .null
    }
}

/// What `spinnet.d.ts` declares, read line by line: the areas of the
/// `Spinnet` interface, each area interface's methods tagged `@service`, and
/// the names in `HostServiceName`.
private struct DeclaredSDK {
    /// `area.method` to the service its `@service` tag names.
    var wrappers: [String: String] = [:]
    var areas: Set<String> = []
    var serviceNames: Set<String> = []

    init(_ source: String) throws {
        var areaOfInterface: [String: String] = [:]
        var methods: [(interface: String, method: String, service: String)] = []
        var interface: String?
        var pendingService: String?
        var readingServiceNames = false

        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("export type HostServiceName") { readingServiceNames = true }
            if readingServiceNames {
                serviceNames.formUnion(Self.captures(#"^\s*\| "([a-z_]+)""#, in: line))
                // The last member ends the union; comments may hold semicolons.
                if !Self.captures(#"^\s*\| "[a-z_]+"(;)"#, in: line).isEmpty { readingServiceNames = false }
                continue
            }
            if let name = Self.captures(#"^export interface (\w+)"#, in: line).first {
                interface = name
                continue
            }
            if line.hasPrefix("}") {
                interface = nil
                continue
            }
            guard let current = interface else { continue }
            if current == "Spinnet",
               let property = Self.captures(#"^\s+readonly (\w+): (\w+);"#, in: line, groups: 2) {
                areas.insert(property[0])
                areaOfInterface[property[1]] = property[0]
            }
            if let service = Self.captures(#"@service ([a-z_]+)"#, in: line).first {
                pendingService = service
            }
            if let service = pendingService, let method = Self.captures(#"^\s+(\w+)\("#, in: line).first {
                methods.append((current, method, service))
                pendingService = nil
            }
        }
        for method in methods {
            guard let area = areaOfInterface[method.interface] else {
                throw DeclarationError("\(method.interface).\(method.method) belongs to no area of Spinnet")
            }
            wrappers["\(area).\(method.method)"] = method.service
        }
    }

    private static func captures(_ pattern: String, in line: String) -> [String] {
        captures(pattern, in: line, groups: 1).map { $0 } ?? []
    }

    private static func captures(_ pattern: String, in line: String, groups: Int) -> [String]? {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range) else { return nil }
        return (1...groups).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
    }

    struct DeclarationError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
