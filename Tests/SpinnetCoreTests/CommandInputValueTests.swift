import SpinnetCore
import XCTest

/// How a Command input reads as its configuration field's text and how
/// edited text goes back into it.
final class CommandInputValueTests: XCTestCase {
    func testAFieldEditKeepsAnObjectInputsOtherMembers() {
        let field = CommandConfigurationField(kind: .shortcut)
        let original: JSONValue = .object(["name": .string("Build project"), "input": .string("source tree")])

        XCTAssertEqual(CommandInputValue.presentation(of: original, field: field, hostCommand: .invokeShortcut),
                       "Build project")
        XCTAssertEqual(CommandInputValue.resolve(text: "Build project", field: field, hostCommand: .invokeShortcut,
                                                 original: original), original)
        XCTAssertEqual(CommandInputValue.resolve(text: "Run project", field: field, hostCommand: .invokeShortcut,
                                                 original: original),
                       .object(["name": .string("Run project"), "input": .string("source tree")]))

        let pathInput: JSONValue = .object(["path": .string("/tmp/report.txt"), "bookmark": .string("retained")])
        XCTAssertEqual(CommandInputValue.resolve(text: "/tmp/renamed.txt", field: CommandConfigurationField(kind: .file),
                                                 hostCommand: .openFile, original: pathInput),
                       .object(["path": .string("/tmp/renamed.txt"), "bookmark": .string("retained")]))
    }

    /// Every member a Host Command reads its value from is shown by its
    /// field, written back by it, and accepted as valid input.
    func testEachHostCommandValueMemberIsReadByItsFieldAndAccepted() {
        for command in HostCommand.allCases {
            guard let field = command.configurationField else { continue }
            for key in command.valueKeys {
                let input: JSONValue = .object([key: .string("value"), "extra": .string("kept")])
                XCTAssertEqual(CommandInputValue.presentation(of: input, field: field, hostCommand: command), "value",
                               "\(command.rawValue).\(key)")
                XCTAssertEqual(CommandInputValue.resolve(text: "edited", field: field, hostCommand: command, original: input),
                               .object([key: .string("edited"), "extra": .string("kept")]), "\(command.rawValue).\(key)")
                if command != .openURL {
                    XCTAssertTrue(command.isValidInput(.object([key: .string("value")])), "\(command.rawValue).\(key)")
                }
            }
        }
        XCTAssertTrue(HostCommand.openURL.isValidInput(.object(["url": .string("https://example.com")])))
    }

    func testAToggleReadsABooleanAStringOrItsFirstToggleMember() {
        XCTAssertEqual(CommandInputValue.isOn(.bool(true)), true)
        XCTAssertEqual(CommandInputValue.isOn(.string("FALSE")), false)
        XCTAssertEqual(CommandInputValue.isOn(.object(["checked": .bool(true)])), true)
        XCTAssertNil(CommandInputValue.isOn(.object(["other": .bool(true)])))

        let toggle = CommandConfigurationField(kind: .toggle)
        let original: JSONValue = .object(["enabled": .bool(false), "label": .string("kept")])
        XCTAssertEqual(CommandInputValue.presentation(of: original, field: toggle, hostCommand: nil), "false")
        XCTAssertEqual(CommandInputValue.resolve(text: "true", field: toggle, hostCommand: nil, original: original),
                       .object(["enabled": .bool(true), "label": .string("kept")]))
        XCTAssertEqual(CommandInputValue.resolve(text: "true", field: toggle, hostCommand: nil, original: nil), .bool(true))
    }
}
