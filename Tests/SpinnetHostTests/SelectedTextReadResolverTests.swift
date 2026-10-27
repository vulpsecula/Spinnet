import XCTest
import SpinnetCore
@testable import SpinnetHost

final class SelectedTextReadResolverTests: XCTestCase {
    func testUnavailableCopyAfterEmptyAccessibilityDoesNotClaimThereIsNoSelection() {
        XCTAssertThrowsError(try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: true,
            accessibilityRead: { "" },
            clipboardCopyFallback: { .unavailable }
        )) { error in
            XCTAssertEqual(error as? PluginHostServiceError,
                           .unavailable("Selected text could not be read"))
        }
    }

    func testCompletedCopyWithoutSelectionAfterEmptyAccessibilityReturnsEmptyText() throws {
        XCTAssertEqual(try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: true,
            accessibilityRead: { "" },
            clipboardCopyFallback: { .noSelection }
        ), "")
    }

    func testBestEffortServiceCanDistinguishUnavailableCopyFromNoSelection() throws {
        let command = CommandDeclaration(id: CommandID("selection.read"), title: "Read Selection",
                                         execution: .javascript, script: "selection.js")
        let clipboardScope = PluginCapabilityScope(capability: .readCurrentClipboard,
                                                   commandIDs: [command.id], dataTypes: ["text"])
        let manifest = try PluginManifest(id: PluginID("example.selection-reader"), name: "Reader", version: "1",
                                         capabilities: [.readSelectedText, .readCurrentClipboard],
                                         capabilityScopes: [clipboardScope], commands: [command])
        let package = PluginPackage(rootURL: URL(fileURLWithPath: "/tmp/selection-reader"), manifest: manifest)
        let action = try ActionConfiguration(id: ActionID("selection.read"), pluginID: manifest.id,
                                             command: command, input: .null)
        let grants = PluginCapabilityGrantStore()
        for capability in manifest.capabilities {
            grants.setDecision(.granted, for: manifest.id, pluginVersion: manifest.version,
                               capability: capability, scope: manifest.scope(for: capability))
        }
        var copyResult = SelectedTextCopyResult.unavailable
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants, systemPermissionCheck: { _ in true },
            clipboard: .init(selectedTextProvider: { allowsCopy in
                XCTAssertTrue(allowsCopy)
                return try SelectedTextReadResolver.readSelectedText(
                    allowClipboardCopyFallback: allowsCopy,
                    accessibilityRead: { "" }, clipboardCopyFallback: { copyResult })
            }))
        let request = PluginRuntimeHostServiceRequest(invocationID: "selection-test", actionID: action.id,
                                                     service: .readSelectedText,
                                                     input: .object(["best_effort": .bool(true)]))
        XCTAssertEqual(try broker.execute(request: request, for: package, action: action), .null)
        copyResult = .noSelection
        XCTAssertEqual(try broker.execute(request: request, for: package, action: action), .string(""))
        copyResult = .selected("Selected message")
        XCTAssertEqual(try broker.execute(request: request, for: package, action: action), .string("Selected message"))
    }

    func testCompletedCopyProbeWithoutSelectionReturnsEmptyTextForSmartJump() throws {
        let expectedError = NSError(domain: "AX", code: 1)
        var copyProbeCount = 0

        let text = try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: true,
            accessibilityRead: { throw expectedError },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .noSelection
            }
        )

        XCTAssertEqual(text, "")
        XCTAssertEqual(copyProbeCount, 1)
    }

    func testUnavailableCopyProbePreservesTheAccessibilityError() {
        let expectedError = NSError(domain: "AX", code: 2)
        var copyProbeCount = 0

        XCTAssertThrowsError(try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: true,
            accessibilityRead: { throw expectedError },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .unavailable
            }
        )) { error in
            XCTAssertEqual(error as NSError, expectedError)
        }
        XCTAssertEqual(copyProbeCount, 1)
    }

    func testAccessibilitySuccessDoesNotRunCopyProbe() throws {
        var copyProbeCount = 0

        let text = try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: true,
            accessibilityRead: { "selected text" },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .noSelection
            }
        )

        XCTAssertEqual(text, "selected text")
        XCTAssertEqual(copyProbeCount, 0)
    }

    func testEmptyAccessibilityResultFallsBackToSimulatedCopyWhenAuthorized() throws {
        var copyProbeCount = 0

        let text = try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: true,
            accessibilityRead: { "" },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .selected("Codex Terminal selection")
            }
        )

        XCTAssertEqual(text, "Codex Terminal selection")
        XCTAssertEqual(copyProbeCount, 1)
    }

    func testEmptyAccessibilityResultDoesNotCopyWithoutClipboardAuthorization() throws {
        var copyProbeCount = 0

        let text = try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: false,
            accessibilityRead: { "" },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .selected("Codex Terminal selection")
            }
        )

        XCTAssertEqual(text, "")
        XCTAssertEqual(copyProbeCount, 0)
    }

    func testDisabledCopyFallbackPreservesTheAccessibilityError() {
        let expectedError = NSError(domain: "AX", code: 3)
        var copyProbeCount = 0

        XCTAssertThrowsError(try SelectedTextReadResolver.readSelectedText(
            allowClipboardCopyFallback: false,
            accessibilityRead: { throw expectedError },
            clipboardCopyFallback: {
                copyProbeCount += 1
                return .noSelection
            }
        )) { error in
            XCTAssertEqual(error as NSError, expectedError)
        }
        XCTAssertEqual(copyProbeCount, 0)
    }
}
