import SpinnetTestSupport
import Foundation
import JavaScriptCore
import SpinnetPluginAPI
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// The `spinnet` object the helper injects into every script (W9 #56): one
/// namespace per area, each wrapper a camelCase name for exactly one Host
/// Service, and `PluginAPI/sdk/spinnet.d.ts` describing the same object.
final class SpinnetSDKTests: XCTestCase {
    private static let repository = TestRepository.root

    private var helper: PluginTestHelper!

    override func setUpWithError() throws {
        helper = try PluginTestHelper(environment: PluginRuntimeEnvironment(
            hostVersion: "9.8.7", preferredLanguage: "zh-Hans-CN"
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

        XCTAssertEqual(wrappers["selection.readText"], "selection.readText")
        XCTAssertEqual(wrappers["selection.replace"], "selection.replace")
        XCTAssertEqual(wrappers["clipboard.read"], "clipboard.read")
        XCTAssertEqual(wrappers["clipboard.write"], "clipboard.write")
        XCTAssertEqual(wrappers["clipboardHistory.read"], "clipboardHistory.read")
        XCTAssertEqual(wrappers["clipboardHistory.readContent"], "clipboardHistory.readContent")
        XCTAssertEqual(wrappers["clipboardHistory.show"], "clipboardHistory.show")
        XCTAssertEqual(wrappers["window.read"], "window.read")
        XCTAssertEqual(wrappers["window.setFrame"], "window.setFrame")
        XCTAssertEqual(wrappers["window.toggleFullScreen"], "window.toggleFullScreen")
        XCTAssertEqual(wrappers["window.restore"], "window.restore")
        XCTAssertEqual(wrappers["open.url"], "open.url")
        XCTAssertEqual(wrappers["open.path"], "open.path")
        XCTAssertEqual(wrappers["http.request"], "http.request")
        XCTAssertEqual(wrappers["text.detectLanguage"], "text.detectLanguage")
        XCTAssertEqual(wrappers["screen.capture"], "screen.capture")
        XCTAssertEqual(wrappers["storage.get"], "storage.get")
        XCTAssertEqual(wrappers["storage.set"], "storage.set")
        XCTAssertEqual(wrappers["storage.remove"], "storage.remove")
        XCTAssertEqual(wrappers["storage.keys"], "storage.keys")
        XCTAssertEqual(wrappers["storage.clear"], "storage.clear")
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
        let raw = try writePlugin(capabilities: ["read_selected_text"], script: "requestHostService(\"selection.readText\")")

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

    func testOptionalCapabilityDenialCanBeCaughtBeforeAnIndependentGrantedOperation() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text", "write_clipboard"],
                                     optional: ["read_selected_text"], script: """
            (() => {
              try { spinnet.selection.readText(); }
              catch (error) {
                if (error.code !== "capability_denied") throw error;
                spinnet.clipboard.write("manual input");
                return "continued safely";
              }
              return "unexpected read";
            })()
            """)
        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .failure(.capabilityDenied(.readSelectedText)),
            .writeClipboard: .value(.null)
        ]))
        XCTAssertEqual(try run.result.get(), .string("continued safely"))
        XCTAssertEqual(run.requests.map(\.service), [.readSelectedText, .writeClipboard])
    }

    func testOptionalSystemPermissionDenialStillEndsInvocation() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text", "write_clipboard"],
                                     optional: ["read_selected_text"], script: """
            (() => {
              try { spinnet.selection.readText(); } catch (error) {}
              spinnet.clipboard.write("must not reach here");
              return "continued";
            })()
            """)
        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .failure(.systemPermissionDenied(.accessibility)),
            .writeClipboard: .value(.null)
        ]))
        XCTAssertEqual(failureOf(run)?.failureCategory, .systemPermissionDenied)
        XCTAssertEqual(run.requests.map(\.service), [.readSelectedText])
    }

    func testDeclaredRequiredDenialCannotFallThroughEvenAlongsideAnOptionalCapability() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text", "write_clipboard"],
                                     optional: ["write_clipboard"], script: """
            (() => {
              try { spinnet.selection.readText(); } catch (error) {}
              spinnet.clipboard.write("must not reach here");
              return "continued";
            })()
            """)
        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .failure(.capabilityDenied(.readSelectedText)),
            .writeClipboard: .value(.null)
        ]))
        XCTAssertEqual(failureOf(run)?.failureCategory, .capabilityDenied)
        XCTAssertEqual(run.requests.map(\.service), [.readSelectedText])
    }

    func testOptionalCapabilityOutsideCommandScopeCannotBeCaught() throws {
        let source = try writePlugin(capabilities: ["read_selected_text", "write_clipboard"],
                                     optional: ["read_selected_text"], script: """
            (() => {
              try { spinnet.selection.readText(); } catch (error) {}
              spinnet.clipboard.write("must not reach here");
              return "continued";
            })()
            """)
        let manifestURL = source.package.rootURL.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var commands = try XCTUnwrap(manifest["commands"] as? [[String: Any]])
        var second = commands[0]
        second["id"] = "example.other"
        commands.append(second)
        manifest["commands"] = commands
        manifest["capability_scopes"] = [["capability": "read_selected_text", "command_ids": ["example.other"],
            "data_types": [], "includes_existing_host_data": false, "https_hosts": [], "external_apps": []]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let plugin = try PluginUnderTest(packageAt: source.package.rootURL)
        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .value(.string("private")), .writeClipboard: .value(.null)
        ]))
        XCTAssertEqual(failureOf(run)?.failureCategory, .capabilityDenied)
        XCTAssertEqual(run.requests.map(\.service), [.readSelectedText])
    }

    func testUncaughtOptionalDenialKeepsCapabilityFailureCategory() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text"], optional: ["read_selected_text"],
                                     script: "spinnet.selection.readText()")
        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .failure(.capabilityDenied(.readSelectedText))
        ]))
        XCTAssertEqual(failureOf(run)?.failureCategory, .capabilityDenied)
    }

    /// `requestHostService` stays as the raw call beside the SDK.
    func testTheRawCallRemains() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text"], script: """
            typeof requestHostService === "function" ? requestHostService("selection.readText") : "missing"
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .value(.string("hello"))
        ]))

        XCTAssertEqual(try run.result.get(), .string("hello"))
    }

    // MARK: - View builders

    /// `spinnet.ui` holds a pure builder for every view component, standard
    /// action and answer, and nothing else.
    func testTheUIAreaHoldsABuilderForEveryComponentAndStandardAction() throws {
        let plugin = try writePlugin(capabilities: [], script: "Object.keys(spinnet.ui).sort()")

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices())

        XCTAssertEqual(try run.result.get(), .array([
            "action", "choiceField", "close", "components", "copyText", "detail", "form", "insertText", "multilineTextField",
            "openPluginSettings", "openURL", "page", "request", "section", "setting", "show", "showPage", "source", "textField", "toast", "toggleField",
            "urlField", "view"
        ].map(JSONValue.string)))
    }

    /// The builders ask the Host for nothing, and what they build is a view
    /// the Host draws, read back member for member.
    func testTheUIBuildersArePureAndBuildWhatTheHostDraws() throws {
        let plugin = try writePlugin(capabilities: [], script: """
            (() => {
              const ui = spinnet.ui;
              const view = ui.view({
                title: "Everything",
                subtitle: "Built by spinnet.ui",
                settings: [ui.setting("tone", { swapWith: "pitch" }), ui.setting("pitch")],
                form: ui.form({
                  submitTitle: "Send",
                  fields: [
                    ui.textField({ key: "a", title: "A", placeholder: "Type", value: "x", accent: "blue", status: "Open · x" }),
                    ui.multilineTextField({ key: "b", title: "B" }),
                    ui.urlField({ key: "c", title: "C" }),
                    ui.toggleField({ key: "d", title: "D", value: true }),
                    ui.choiceField({ key: "e", title: "E", choices: ["s", "l"], choiceTitles: ["Small", "Large"], value: "l" })
                  ]
                }),
                detail: ui.detail({ sections: [
                  ui.section({ id: "one", title: "One", text: "**Bold**" }),
                  ui.section({ id: "two", fetch: { any: "thing" } })
                ] }),
                actions: [
                  ui.action({ id: "go", title: "Go", shortcut: "cmd+g" }),
                  ui.copyText({ text: "copied", shortcut: "cmd+shift+c" }),
                  ui.openURL({ title: "Docs", url: "https://example.com" }),
                  ui.insertText({ text: "inserted", closesView: true }),
                  ui.openPluginSettings()
                ]
              });
              return [ui.show(view, { state: { step: 1 }, toast: "Ready" }), ui.toast("Done"), ui.close(),
                      ui.close({ toast: "Bye" }),
                      ui.form({ submitOnReturn: true, fields: [ui.multilineTextField({ key: "b", title: "B" })] })];
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices())

        XCTAssertEqual(run.requests, [], "The builders call no Host Service")
        guard case .array(let answers) = try run.result.get(), answers.count == 5 else {
            return XCTFail("The script did not answer five values")
        }
        XCTAssertTrue(try PluginViewForm(parsing: answers[4]).submitsOnReturn)
        let shown = try PluginScriptAnswer(parsing: answers[0])
        XCTAssertEqual(shown.state, .object(["step": .number(1)]))
        XCTAssertEqual(shown.toast, "Ready")
        let view = try PluginViewDescription(parsing: try XCTUnwrap(shown.view), settingsFields: [
            CommandConfigurationField(kind: .choice, title: "Tone", choices: ["plain", "warm"], key: "tone"),
            CommandConfigurationField(kind: .choice, title: "Pitch", choices: ["plain", "warm"], key: "pitch")
        ])
        XCTAssertEqual(view.title, "Everything")
        XCTAssertEqual(view.subtitle, "Built by spinnet.ui")
        XCTAssertEqual(view.settings.map(\.key), ["tone", "pitch"])
        XCTAssertEqual(view.settings.map(\.swapWith), ["pitch", nil])
        XCTAssertEqual(view.form?.submitTitle, "Send")
        XCTAssertEqual(view.form?.fields.map(\.kind), [.text, .multilineText, .url, .toggle, .choice])
        XCTAssertEqual(view.form?.values, .object(["a": .string("x"), "b": .string(""), "c": .string(""),
                                                   "d": .bool(true), "e": .string("l")]))
        XCTAssertEqual(view.form?.fields[0].placeholder, "Type")
        XCTAssertEqual(view.form?.fields.map(\.accent), [.blue, nil, nil, nil, nil])
        XCTAssertEqual(view.form?.fields.map(\.status), ["Open · x", nil, nil, nil, nil])
        XCTAssertEqual(view.form?.fields[4].choices.map(\.title), ["Small", "Large"])
        XCTAssertEqual(view.detail?.sections, [
            PluginViewSection(id: "one", title: "One", text: "**Bold**", fetch: nil),
            PluginViewSection(id: "two", title: nil, text: nil, fetch: .object(["any": .string("thing")]))
        ])
        XCTAssertEqual(view.actions, [
            PluginViewAction(title: "Go", shortcut: PluginViewShortcut(key: "g", modifiers: [.command]), kind: .event("go")),
            PluginViewAction(title: "Copy", shortcut: PluginViewShortcut(key: "c", modifiers: [.command, .shift]),
                             kind: .standard(.copyText("copied"), closesView: false)),
            PluginViewAction(title: "Docs", shortcut: nil, kind: .standard(.openURL("https://example.com"), closesView: false)),
            PluginViewAction(title: "Insert", shortcut: nil, kind: .standard(.insertText("inserted"), closesView: true)),
            PluginViewAction(title: "Plugin Settings", shortcut: nil, kind: .standard(.openPluginSettings, closesView: false))
        ])
        XCTAssertEqual(try PluginScriptAnswer(parsing: answers[1]), PluginScriptAnswer(toast: "Done"))
        XCTAssertEqual(try PluginScriptAnswer(parsing: answers[2]), PluginScriptAnswer(close: true))
        XCTAssertEqual(try PluginScriptAnswer(parsing: answers[3]), PluginScriptAnswer(close: true, toast: "Bye"))
    }

    // MARK: - Plugin Storage

    /// `spinnet.storage` over a real store: what one run keeps, the next
    /// reads, and so does a run after a relaunch, with a new helper and a new
    /// store over the same directory.
    func testStorageKeepsValuesBetweenRunsAndLaunches() throws {
        let directory = temporaryDirectory()
        let plugin = try writePlugin(capabilities: [], script: """
            (() => {
              const runs = (spinnet.storage.get("runs") ?? 0) + 1;
              spinnet.storage.set({ key: "runs", value: runs });
              spinnet.storage.set({ key: "history", value: { last: runs } });
              return [runs, spinnet.storage.keys()];
            })()
            """)
        func run(on helper: PluginTestHelper) throws -> JSONValue {
            try helper.run(PluginTestInvocation("example.run"), of: plugin,
                           answering: RecordedHostServices(storage: PluginStorage(directory: directory))).result.get()
        }

        XCTAssertEqual(try run(on: helper), .array([.number(1), .array([.string("history"), .string("runs")])]))
        XCTAssertEqual(try run(on: helper), .array([.number(2), .array([.string("history"), .string("runs")])]))
        helper.shutdown()
        helper = try PluginTestHelper()
        XCTAssertEqual(try run(on: helper), .array([.number(3), .array([.string("history"), .string("runs")])]))
    }

    func testStorageRemovesAndClears() throws {
        let plugin = try writePlugin(capabilities: [], script: """
            (() => {
              spinnet.storage.set({ key: "a", value: 1 });
              spinnet.storage.set({ key: "b", value: 2 });
              spinnet.storage.remove("a");
              const afterRemove = spinnet.storage.keys();
              spinnet.storage.clear();
              return [afterRemove, spinnet.storage.keys(), spinnet.storage.get("b")];
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin,
                             answering: RecordedHostServices(storage: PluginStorage(directory: temporaryDirectory())))

        XCTAssertEqual(try run.result.get(), .array([.array([.string("b")]), .array([]), .null]))
    }

    /// A write over a limit stores nothing and throws an error the script can
    /// catch and carry on from, unlike a refusal.
    func testAWriteOverALimitThrowsAnErrorTheScriptCanCatch() throws {
        let storage = PluginStorage(directory: temporaryDirectory())
        let plugin = try writePlugin(capabilities: [], script: """
            (() => {
              spinnet.storage.set({ key: "big", value: "kept" });
              try {
                spinnet.storage.set({ key: "big", value: "x".repeat(600 * 1024) });
                return "stored";
              } catch (error) {
                return [error instanceof Error, error.code, String(error.message).includes("512 KiB"),
                        spinnet.storage.get("big")];
              }
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin,
                             answering: RecordedHostServices(storage: storage))

        XCTAssertEqual(try run.result.get(), .array([.bool(true), .string("storage_limit_exceeded"), .bool(true),
                                                     .string("kept")]))
    }

    /// A value too large even to send to the Host is over the limit too, and
    /// fails the same catchable way rather than ending the invocation.
    func testAValueTooLargeToSendThrowsTheSameCatchableError() throws {
        let storage = PluginStorage(directory: temporaryDirectory())
        let plugin = try writePlugin(capabilities: [], script: """
            (() => {
              try {
                spinnet.storage.set({ key: "huge", value: "x".repeat(2 * 1024 * 1024) });
                return "stored";
              } catch (error) {
                return [error.code, spinnet.storage.keys()];
              }
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin,
                             answering: RecordedHostServices(storage: storage))

        XCTAssertEqual(try run.result.get(), .array([.string("storage_limit_exceeded"), .array([])]))
    }

    /// A value of the largest size travels to the Host and back in one
    /// message each way, even one the Host's JSON would otherwise double by
    /// escaping every slash.
    func testTheLargestValueGoesToTheHostAndBack() throws {
        let plugin = try writePlugin(capabilities: [], script: """
            (() => {
              const value = "/".repeat(512 * 1024 - 2);
              spinnet.storage.set({ key: "slashes", value });
              return spinnet.storage.get("slashes") === value;
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin,
                             answering: RecordedHostServices(storage: PluginStorage(directory: temporaryDirectory())))

        XCTAssertEqual(try run.result.get(), .bool(true))
    }

    /// Left uncaught, the error ends the Action as a failed Host Service.
    func testAnUncaughtLimitErrorFailsTheActionAsAHostServiceFailure() throws {
        let plugin = try writePlugin(capabilities: [], script: """
            spinnet.storage.set({ key: "big", value: "x".repeat(600 * 1024) })
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin,
                             answering: RecordedHostServices(storage: PluginStorage(directory: temporaryDirectory())))

        XCTAssertEqual(failureOf(run)?.failureCategory, .hostServiceFailed)
        XCTAssertTrue(failureOf(run).map { "\($0)".contains("512 KiB") } ?? false, "\(String(describing: failureOf(run)))")
    }

    /// Only a write over a limit may be caught: a malformed request still
    /// ends the invocation like any failed Host Service.
    func testAMalformedStorageRequestStillEndsTheInvocation() throws {
        let plugin = try writePlugin(capabilities: [], script: """
            (() => {
              try { spinnet.storage.get(""); } catch (error) {}
              return "carried on";
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin,
                             answering: RecordedHostServices(storage: PluginStorage(directory: temporaryDirectory())))

        XCTAssertEqual(failureOf(run)?.failureCategory, .hostServiceFailed)
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

    /// Host identity and language belong to the SDK environment. Invocation
    /// identity stays available through the script globals.
    func testTheEnvironmentReportsOnlyTheHostAndLanguage() throws {
        let plugin = try writePlugin(capabilities: [], script: "({environment:spinnet.environment,environmentKeys:Object.keys(spinnet.environment).sort(),pluginID,commandID,actionID,invocationID})")
        let run = helper.run(PluginTestInvocation("example.run", actionID: "action-7"), of: plugin, answering: RecordedHostServices())
        let value = try run.result.get()
        XCTAssertEqual(value.value(atPointer: "/environment"), .object(["hostVersion": .string("9.8.7"), "preferredLanguage": .string("zh-Hans-CN")]))
        XCTAssertEqual(value.value(atPointer: "/environmentKeys"), .array([.string("hostVersion"), .string("preferredLanguage")]),
                       "Undefined properties must not retain retired environment members")
        XCTAssertEqual(value.value(atPointer: "/pluginID"), .string("com.example.sdk"))
        XCTAssertEqual(value.value(atPointer: "/commandID"), .string("example.run"))
        XCTAssertEqual(value.value(atPointer: "/actionID"), .string("action-7"))
        guard case .string(let id)? = value.value(atPointer: "/invocationID") else { return XCTFail("No invocation ID") }
        XCTAssertFalse(id.isEmpty)
    }

    /// The Host uses its bundle version and the first preferred language.
    func testTheHostsEnvironmentComesFromItsBundleAndTheUsersLanguages() throws {
        let bundle = try XCTUnwrap(Bundle(url: try writeBundle(version: "2.3.4")))

        let environment = PluginRuntimeEnvironment.current(bundle: bundle, preferredLanguages: ["de-CH", "en-US"])

        XCTAssertEqual(environment, PluginRuntimeEnvironment(
            hostVersion: "2.3.4", preferredLanguage: "de-CH"
        ))
    }

    // MARK: - Coverage

    /// The runtime, types and catalogue expose the same callable operations.
    func testTheSDKCoversEveryCallableCatalogueOperation() throws {
        let wrapped = try wrappedServices()
        let expected = Set(HostServiceCatalogue.operations.filter { $0.isOffered(at: .call) }.map(\.id))
        XCTAssertEqual(Set(wrapped.keys), expected)
        XCTAssertEqual(Set(wrapped.values), expected)
    }

    func testTheTypesDescribeTheSameWrappersAndEveryCallableOperation() throws {
        let types = try String(contentsOf: Self.repository.appendingPathComponent("PluginAPI/sdk/spinnet.d.ts"), encoding: .utf8)
        let declared = try DeclaredSDK(types)
        XCTAssertEqual(declared.wrappers, try wrappedServices())
        XCTAssertEqual(declared.areas, try sdkAreas())
        XCTAssertEqual(declared.serviceNames, Set(HostServiceCatalogue.operations.filter { $0.isOffered(at: .call) }.map(\.id)))
    }

    // MARK: - Support

    /// Probe forwarding before Host validation; real-helper tests above
    /// cover execution, grants and failures. Reviewed reads get valid input.
    private func sdkProbe(_ expression: String) throws -> JSONValue {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var requests=[]; function requestHostService(id,input){requests.push({id,input});return null;} var environment={hostVersion:'1.0.0',preferredLanguage:'en'};")
        for (index, source) in [SpinnetSDK.source, SpinnetSDK.currentSource, SpinnetSDK.adaptiveSource, SpinnetSDK.autoremoveSource, SpinnetSDK.commandOutputSource].enumerated() {
            let factory = try XCTUnwrap(context.evaluateScript(source))
            let request = try XCTUnwrap(context.objectForKeyedSubscript("requestHostService"))
            let environment = try XCTUnwrap(context.objectForKeyedSubscript("environment"))
            let args: [Any]
            if index == 0 { args = [request, environment] }
            else {
                let sdk = try XCTUnwrap(context.objectForKeyedSubscript("spinnet"))
                if index == 1 { args = [request, environment, sdk] }
                else if index == 3 || index == 4 { args = [sdk, request] }
                else { args = [sdk] }
            }
            context.setObject(try XCTUnwrap(factory.call(withArguments: args)), forKeyedSubscript: "spinnet" as NSString)
            XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        }
        let result = try XCTUnwrap(context.evaluateScript("JSON.stringify(" + expression + ")")?.toString())
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        return try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))
    }

    private func wrappedServices() throws -> [String: String] {
        let value = try sdkProbe("""
            (()=>{const result={};for(const area of Object.keys(spinnet)){
              if(area==='ui'||area==='environment')continue;
              for(const name of Object.keys(spinnet[area])){
                if(typeof spinnet[area][name]!=='function')continue;
                const id=area+'.'+name;
                const input=id==='tools.read'?{tool:'homebrew',operation:'installed'}:{probe:id};
                const before=requests.length;spinnet[area][name](input);
                if(requests.length!==before+1)throw Error(id+' did not forward exactly once');
                const call=requests[before];if(JSON.stringify(call.input)!==JSON.stringify(input))throw Error(id+' changed its input');
                result[id]=call.id;
              }
            }return result;})()
            """)
        guard case .object(let values) = value else { throw DeclaredSDK.DeclarationError("No wrapper result") }
        return values.compactMapValues { if case .string(let text) = $0 { return text }; return nil }
    }

    private func sdkAreas() throws -> Set<String> {
        guard case .array(let values) = try sdkProbe("Object.keys(spinnet)") else { return [] }
        return Set(values.compactMap { if case .string(let text) = $0 { return text }; return nil })
    }

    private func failureOf(_ run: PluginTestRun) -> PluginRuntimeError? {
        guard case .failure(let error) = run.result else { return nil }
        return error as? PluginRuntimeError
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetSDKStorage-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A one-Command package in a temporary directory, removed after the test.
    private func writePlugin(capabilities: [String], optional: [String] = [], script: String) throws -> PluginUnderTest {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetSDK-\(UUID().uuidString).spinnetplugin", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        let optionalList = optional.map { "\"\($0)\"" }.joined(separator: ", ")
        try """
        {
          "protocol_version": "1.0", "engines": {"spinnet":"^1.0.0"}, "id": "com.example.sdk", "name": "SDK Example", "version": "1.0.0",
          "capabilities": [\(list)],
          "optional_capabilities": [\(optionalList)],
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

/// What `spinnet.d.ts` declares, read line by line: the areas of the
/// `Spinnet` interface, each callable namespace member, and the public `CallID` union.
private struct DeclaredSDK {
    /// `area.method` to the service its `@service` tag names.
    var wrappers: [String: String] = [:]
    var areas: Set<String> = []
    var serviceNames: Set<String> = []

    init(_ source: String) throws {
        var areaOfInterface: [String: String] = [:]
        var methods: [(interface: String, method: String, service: String)] = []
        var current: String?
        var readingCalls = false
        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("export type CallID =") { readingCalls = true; continue }
            if readingCalls {
                serviceNames.formUnion(Self.captures(#"^\s*\| "([A-Za-z.]+)""#, in: line))
                if line.hasSuffix(";") { readingCalls = false }
                continue
            }
            if let name = Self.captures(#"^export interface (\w+)"#, in: line).first { current = name; continue }
            if line.hasPrefix("}") { current = nil; continue }
            guard let interface = current else { continue }
            if interface == "Spinnet", let property = Self.captures(#"^\s+readonly (\w+): (\w+);"#, in: line, groups: 2) {
                areas.insert(property[0]); areaOfInterface[property[1]] = property[0]
            }
            if let method = Self.captures(#"^\s+readonly (\w+): .*Callable<"([A-Za-z.]+)">"#, in: line, groups: 2) {
                methods.append((interface, method[0], method[1]))
            }
        }
        for method in methods {
            guard let area = areaOfInterface[method.interface] else { throw DeclarationError("No namespace for " + method.interface) }
            wrappers[area + "." + method.method] = method.service
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
