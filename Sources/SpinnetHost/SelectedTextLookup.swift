import AppKit
import SpinnetCore

enum SelectedTextAXResult<Value> {
    case value(Value)
    case noValue
    case unsupported
    case failure(AXError)
}

protocol SelectedTextAXClient {
    associatedtype Element

    func systemWideElement() -> Element
    func focusedUIElement(in element: Element) -> SelectedTextAXResult<Element>
    func focusedApplication(in element: Element) -> SelectedTextAXResult<Element>
    func frontmostApplication() -> Element?
    func focusedWindow(in element: Element) -> SelectedTextAXResult<Element>
    func selectedText(in element: Element, messagingTimeout: Float?) -> SelectedTextAXResult<String>
    func children(
        of element: Element,
        limitedTo maximumCount: Int,
        messagingTimeout: Float?
    ) -> SelectedTextAXResult<[Element]>
}

private struct PendingSelectedTextElement<Element> {
    let element: Element
    let depth: Int
}

struct SelectedTextLookup {
    static let defaultMaximumDepth = 12
    static let defaultMaximumElements = 512
    static let defaultSearchDuration = Duration.milliseconds(300)

    private let maxDepth: Int
    private let maxElements: Int
    private let searchDuration: Duration

    init(
        maxDepth: Int = Self.defaultMaximumDepth,
        maxElements: Int = Self.defaultMaximumElements,
        searchDuration: Duration = Self.defaultSearchDuration
    ) {
        self.maxDepth = max(0, maxDepth)
        self.maxElements = max(1, maxElements)
        self.searchDuration = max(.zero, searchDuration)
    }

    func read<Client: SelectedTextAXClient>(using client: Client) throws -> String {
        let systemWide = client.systemWideElement()
        if let focusedElement = try valueOrNil(
            client.focusedUIElement(in: systemWide),
            failureMessage: "Focused application has no accessible text selection"
        ), let selectedText = try nonemptySelection(in: focusedElement, using: client) {
            return selectedText
        }

        let application: Client.Element?
        switch client.focusedApplication(in: systemWide) {
        case .value(let focusedApplication):
            application = focusedApplication
        case .noValue, .unsupported:
            application = client.frontmostApplication()
        case .failure(let error):
            throw PluginHostServiceError.failed(
                "Focused application could not be read (\(String(describing: error)))"
            )
        }
        guard let application else { return "" }

        if let focusedElement = try valueOrNil(
            client.focusedUIElement(in: application),
            failureMessage: "Focused application has no accessible text selection"
        ), let selectedText = try nonemptySelection(in: focusedElement, using: client) {
            return selectedText
        }

        guard let window = try valueOrNil(
            client.focusedWindow(in: application),
            failureMessage: "Focused application has no accessible window"
        ) else {
            return ""
        }
        return try searchWindow(window, using: client)
    }

    private func nonemptySelection<Client: SelectedTextAXClient>(
        in element: Client.Element,
        using client: Client
    ) throws -> String? {
        switch client.selectedText(in: element, messagingTimeout: nil) {
        case .value(let text):
            return text.isEmpty ? nil : text
        case .noValue, .unsupported:
            return nil
        case .failure(let error):
            throw PluginHostServiceError.failed(
                "Focused application has no readable text selection (\(String(describing: error)))"
            )
        }
    }

    private func valueOrNil<Value>(
        _ result: SelectedTextAXResult<Value>,
        failureMessage: String
    ) throws -> Value? {
        switch result {
        case .value(let value):
            return value
        case .noValue, .unsupported:
            return nil
        case .failure(let error):
            throw PluginHostServiceError.failed("\(failureMessage) (\(String(describing: error)))")
        }
    }

    private func searchWindow<Client: SelectedTextAXClient>(
        _ window: Client.Element,
        using client: Client
    ) throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: searchDuration)
        var pending = [PendingSelectedTextElement(element: window, depth: 0)]
        var cursor = 0
        var scheduledElements = 1
        var lastFailure: AXError?

        while cursor < pending.count,
              cursor < maxElements,
              clock.now < deadline {
            let current = pending[cursor]
            cursor += 1

            switch client.selectedText(in: current.element, messagingTimeout: 0.05) {
            case .value(let selectedText) where !selectedText.isEmpty:
                return selectedText
            case .failure(let error):
                if lastFailure == nil { lastFailure = error }
            case .value, .noValue, .unsupported:
                break
            }

            guard current.depth < maxDepth,
                  scheduledElements < maxElements,
                  clock.now < deadline else {
                continue
            }

            let remainingCapacity = maxElements - scheduledElements
            switch client.children(
                of: current.element,
                limitedTo: remainingCapacity,
                messagingTimeout: 0.05
            ) {
            case .value(let children):
                let newChildren = children.prefix(remainingCapacity)
                pending.append(contentsOf: newChildren.map {
                    PendingSelectedTextElement(element: $0, depth: current.depth + 1)
                })
                scheduledElements += newChildren.count
            case .failure(let error):
                if lastFailure == nil { lastFailure = error }
            case .noValue, .unsupported:
                continue
            }
        }

        if let lastFailure {
            throw PluginHostServiceError.failed(
                "Focused application has no readable text selection (\(String(describing: lastFailure)))"
            )
        }
        return ""
    }
}

struct AppKitSelectedTextAXClient: SelectedTextAXClient {
    func systemWideElement() -> AXUIElement {
        AXUIElementCreateSystemWide()
    }

    func focusedUIElement(in element: AXUIElement) -> SelectedTextAXResult<AXUIElement> {
        copyElement(kAXFocusedUIElementAttribute, from: element)
    }

    func focusedApplication(in element: AXUIElement) -> SelectedTextAXResult<AXUIElement> {
        copyElement(kAXFocusedApplicationAttribute, from: element)
    }

    func frontmostApplication() -> AXUIElement? {
        let application = onMain {
            NSWorkspace.shared.frontmostApplication
        }
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return AXUIElementCreateApplication(application.processIdentifier)
    }

    func focusedWindow(in element: AXUIElement) -> SelectedTextAXResult<AXUIElement> {
        copyElement(kAXFocusedWindowAttribute, from: element)
    }

    func selectedText(in element: AXUIElement, messagingTimeout: Float?) -> SelectedTextAXResult<String> {
        apply(messagingTimeout, to: element)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard status == .success else { return result(for: status) }
        guard let value, let text = value as? String else {
            return .failure(.failure)
        }
        return .value(text)
    }

    func children(
        of element: AXUIElement,
        limitedTo maximumCount: Int,
        messagingTimeout: Float?
    ) -> SelectedTextAXResult<[AXUIElement]> {
        guard maximumCount > 0 else { return .value([]) }
        apply(messagingTimeout, to: element)

        var count: CFIndex = 0
        let countStatus = AXUIElementGetAttributeValueCount(
            element,
            kAXChildrenAttribute as CFString,
            &count
        )
        guard countStatus == .success else { return result(for: countStatus) }
        guard count > 0 else { return .value([]) }

        var values: CFArray?
        let status = AXUIElementCopyAttributeValues(
            element,
            kAXChildrenAttribute as CFString,
            0,
            CFIndex(min(maximumCount, Int(count))),
            &values
        )
        guard status == .success else { return result(for: status) }
        guard let values, let children = values as? [AXUIElement] else {
            return .failure(.failure)
        }
        return .value(children)
    }

    private func copyElement(_ attribute: String, from owner: AXUIElement) -> SelectedTextAXResult<AXUIElement> {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(owner, attribute as CFString, &value)
        guard status == .success else { return result(for: status) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .failure(.failure)
        }
        return .value(value as! AXUIElement)
    }

    private func result<Value>(for status: AXError) -> SelectedTextAXResult<Value> {
        switch status {
        case .noValue:
            return .noValue
        case .attributeUnsupported:
            return .unsupported
        default:
            return .failure(status)
        }
    }

    private func apply(_ timeout: Float?, to element: AXUIElement) {
        guard let timeout else { return }
        _ = AXUIElementSetMessagingTimeout(element, timeout)
    }

    private func onMain<Value>(_ work: () -> Value) -> Value {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
