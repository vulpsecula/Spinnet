import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Fixtures shared by the Settings test suites. They lived as private helpers
/// on SettingsWindowControllerTests while that one class held every Settings
/// test; the per-model suites need the same ones.
extension XCTestCase {
    var testMenuFontFamily: String {
        MenuAppearanceConfiguration.fontOptions.first {
            $0 != MenuAppearanceConfiguration.MenuFont.system.rawValue
        } ?? MenuAppearanceConfiguration.MenuFont.system.rawValue
    }

    func makeController(emptySlotCount: Int = 0) throws -> SettingsWindowController {
        let editor = try makeEditor()
        for _ in 0..<emptySlotCount {
            try editor.addEmptySlot()
        }
        let controller = SettingsWindowController(editor: editor)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    func mouseEvent(
        type: CGEventType,
        buttonNumber: Int,
        location: CGPoint
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .center
        ))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))
        return event
    }

    func makeEditor(
        capabilities: [PluginCapability] = []
    ) throws -> HostConfigurationEditor {
        let registry = PluginRegistry()
        let manifest = try PluginManifest(
            id: PluginID("com.spinnet.fixture"),
            name: "Fixture",
            version: "1.0.0",
            capabilities: capabilities,
            commands: [CommandDeclaration(
                id: CommandID("fixture.open"),
                title: "Open URL",
                hostCommand: .openURL
            ), CommandDeclaration(
                id: CommandID("fixture.transform_text"),
                title: "Transform Text",
                execution: .javascript,
                isConfigurable: false,
                script: "transform-text.js"
            )],
            preset: MenuItemPresetDeclaration(
                readiness: .readyToUse,
                isConfigurable: true,
                defaultPrimaryCommandID: CommandID("fixture.open"),
                defaultAlternateCommandIDs: [CommandID("fixture.transform_text")],
                defaultInputs: [CommandID("fixture.open"): .string("https://example.com")]
            )
        )
        try registry.register(PluginPackage(
            rootURL: URL(fileURLWithPath: "/tmp/fixture.spinnetplugin"),
            manifest: manifest
        ))
        let action = try ActionConfiguration(
            id: ActionID("open-url"),
            pluginID: manifest.id,
            command: manifest.commands[0],
            input: .string("https://example.com")
        )
        let configuration = try HostConfiguration(
            actions: [action],
            menu: MenuConfiguration(items: [
                try MenuItemConfiguration(primaryActionID: action.id)
            ])
        )
        return HostConfigurationEditor(registry: registry, configuration: configuration)
    }

    func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bounds = view.bounds
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: representation)
        return representation
    }

    func renderedAccessibilityLabels(in root: NSObject) -> Set<String> {
        var labels = Set<String>()
        var visited = Set<ObjectIdentifier>()

        func visit(_ value: Any) {
            guard let object = value as? NSObject else { return }
            let identifier = ObjectIdentifier(object)
            guard visited.insert(identifier).inserted else { return }
            let attributeValue = NSSelectorFromString("accessibilityAttributeValue:")
            let accessibilityLabel = NSSelectorFromString("accessibilityLabel")
            let accessibilityChildren = NSSelectorFromString("accessibilityChildren")
            var descriptions: [String] = object.responds(to: attributeValue)
                ? [NSAccessibility.Attribute.description, .title].compactMap { attribute in
                    object.perform(attributeValue, with: attribute)?
                        .takeUnretainedValue() as? String
                }
                : []
            if object.responds(to: accessibilityLabel),
               let label = object.perform(accessibilityLabel)?.takeUnretainedValue() as? String {
                descriptions.append(label)
            }
            var children = object.responds(to: attributeValue)
                ? object.perform(attributeValue, with: NSAccessibility.Attribute.children)?
                    .takeUnretainedValue() as? [Any]
                : nil
            if children == nil, object.responds(to: accessibilityChildren) {
                children = object.perform(accessibilityChildren)?
                    .takeUnretainedValue() as? [Any]
            }
            labels.formUnion(descriptions.filter { !$0.isEmpty })
            children?.forEach(visit)
        }

        visit(root)
        return labels
    }

    func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard let lhs = lhs.usingColorSpace(.deviceRGB),
              let rhs = rhs.usingColorSpace(.deviceRGB) else {
            return 0
        }
        return max(
            abs(lhs.redComponent - rhs.redComponent),
            abs(lhs.greenComponent - rhs.greenComponent),
            abs(lhs.blueComponent - rhs.blueComponent)
        )
    }
}
