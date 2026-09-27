import AppKit
import SpinnetCore

/// What the Host's Plugin View renderer needs from the rest of the Host.
struct PluginViewEnvironment {
    /// Standard actions and setting controls, performed without a View Event.
    let hostActions: PluginViewHostActions
    /// What each Host-Fetched Section shows.
    let sections: HostFetchedSectionProvider
    /// The Plugin's declared `settings_fields`, which setting controls name.
    let settingsFields: (PluginID) -> [CommandConfigurationField]
    let pluginName: (PluginID) -> String
    /// Takes the user where a refusal is repaired.
    let repair: (PluginViewRepairRoute, PluginID) -> Void
    /// The user's own copy of what a section shows, as ⌘C would copy it.
    let copy: (String) -> Void
    /// Runs an operation after a delay, such as hiding a toast.
    let schedule: (TimeInterval, @escaping () -> Void) -> Void
}

/// What a Detail section shows.
enum PluginViewSectionContent: Equatable {
    /// The section's own text, in the Markdown subset.
    case markdown([PluginViewMarkdown.Block])
    /// A Host-Fetched Section, as its provider says.
    case fetched(HostFetchedSectionState)

    /// What the section's Copy button copies, if it shows any text.
    var copyableText: String? {
        switch self {
        case .markdown(let blocks): return PluginViewMarkdown.plainText(of: blocks)
        case .fetched(.text(let text)), .fetched(.delivered(let text)): return text
        case .fetched: return nil
        }
    }
}

/// One drawn Plugin View: the description it shows, the values the user has
/// entered, its pin, busy state, error and toast. It turns the user's input
/// into View Events for its session, or into standard actions and setting
/// changes the Host performs itself.
final class PluginViewModel: ObservableObject {
    let session: PluginViewSession
    @Published private(set) var description: PluginViewDescription
    /// Each form field's value, keyed by field.
    @Published private(set) var values: [String: JSONValue] = [:]
    /// A pinned view stays open when it loses focus.
    @Published var isPinned = false
    @Published private(set) var isBusy = false
    /// The last event's failure, from the session.
    @Published private(set) var eventError: ActionFailure?
    /// The failure of something the Host did in the view itself.
    @Published private(set) var hostError: ActionFailure?
    @Published private(set) var toast: String?
    /// Changes whenever a Host-Fetched Section has something new to show.
    @Published private(set) var sectionRevision = 0
    /// The App that was in front when an Action last presented the view.
    var origin: PluginViewOrigin?

    private let environment: PluginViewEnvironment
    private var toastCount = 0
    private(set) var view: JSONValue

    init(session: PluginViewSession, presentation: PluginViewPresentation, description: PluginViewDescription,
         environment: PluginViewEnvironment) {
        self.session = session
        self.description = description
        self.environment = environment
        view = presentation.view
        update(presentation, description: description, newView: true, answersTyping: false, presentedAnew: true)
    }

    var title: String { description.title }
    var pluginName: String { environment.pluginName(session.pluginID) }

    /// The error shown inline: the Host's own, or else the last event's.
    var error: ActionFailure? { hostError ?? eventError }
    var repairRoute: PluginViewRepairRoute? { error.flatMap(PluginViewRepairRoute.init) }

    /// Shows what the session presents. `newView` says the script answered
    /// with a view, rather than only the busy state or error changing, and
    /// `answersTyping` that the view answers a field change.
    ///
    /// A field keeps what the user entered while the answer to their own
    /// typing arrives, so a slow answer never undoes a keystroke. Any other
    /// new view sets each field to the value it describes, which is how a
    /// Plugin clears or fills a field; a field the view did not have before
    /// always starts from its described value.
    func update(_ presentation: PluginViewPresentation, description: PluginViewDescription, newView: Bool,
                answersTyping: Bool, presentedAnew: Bool) {
        view = presentation.view
        self.description = description
        isBusy = presentation.isBusy
        eventError = presentation.error
        if presentedAnew { hostError = nil }
        guard newView else { return }
        var updated: [String: JSONValue] = [:]
        for field in description.form?.fields ?? [] {
            if answersTyping, let typed = values[field.key], typed.hasSameKind(as: field.value) {
                updated[field.key] = typed
            } else {
                updated[field.key] = field.value
            }
        }
        values = updated
    }

    // MARK: - Form

    func edit(_ key: String, to value: JSONValue) {
        guard values[key] != nil, values[key] != value else { return }
        values[key] = value
        hostError = nil
        session.send(.fieldChanged(field: key, values: .object(values)))
    }

    func text(of key: String) -> String {
        if case .string(let text)? = values[key] { return text }
        return ""
    }

    func submit() {
        guard description.form != nil else { return }
        hostError = nil
        session.send(.submitted(values: .object(values)))
    }

    // MARK: - Actions

    func choose(_ action: PluginViewAction) {
        hostError = nil
        switch action.kind {
        case .event(let id):
            session.send(.actionChosen(id))
        case .standard(let standard, let closesView):
            guard perform(standard), closesView else { return }
            session.close()
        }
    }

    /// Opens a link from Detail text, under the `open_url` rules.
    func open(_ url: URL) {
        hostError = nil
        perform(.openURL(url.absoluteString))
    }

    @discardableResult
    private func perform(_ standard: PluginViewStandardAction) -> Bool {
        do {
            try environment.hostActions.perform(standard, for: session.action, origin: origin)
            return true
        } catch {
            hostError = environment.hostActions.failure(error, for: session.action)
            return false
        }
    }

    func repair() {
        guard let route = repairRoute else { return }
        environment.repair(route, session.pluginID)
    }

    // MARK: - Setting controls

    func settingValue(_ control: PluginViewSettingControl) -> JSONValue {
        environment.hostActions.value(of: control, pluginID: session.pluginID)
    }

    /// Stores the setting as Plugin Settings are, then tells the Plugin.
    func changeSetting(_ control: PluginViewSettingControl, to value: JSONValue) {
        hostError = nil
        do {
            let event = try environment.hostActions.changeSetting(control.key, to: value, pluginID: session.pluginID)
            objectWillChange.send()
            session.send(event)
        } catch {
            hostError = environment.hostActions.failure(error, for: session.action)
        }
    }

    // MARK: - Detail

    func content(of section: PluginViewSection) -> PluginViewSectionContent {
        if section.isHostFetched {
            let state = environment.sections.state(ofSection: section.id, in: session)
            if case .delivered(let text) = state { return .markdown(PluginViewMarkdown.parse(text)) }
            return .fetched(state)
        }
        return .markdown(PluginViewMarkdown.parse(section.text ?? ""))
    }

    func copy(_ section: PluginViewSection) {
        guard let text = content(of: section).copyableText else { return }
        environment.copy(text)
    }

    func sectionChanged(_ id: String) {
        sectionRevision += 1
    }

    // MARK: - Toast

    func showToast(_ text: String) {
        toast = text
        toastCount += 1
        let shown = toastCount
        environment.schedule(Self.toastDuration) { [weak self] in
            guard let self, self.toastCount == shown else { return }
            self.toast = nil
        }
    }

    static let toastDuration: TimeInterval = 2

    // MARK: - Closing

    func close() { session.close() }

    // MARK: - Accessibility

    /// What VoiceOver reads for each component, in the order the view draws
    /// them. The SwiftUI view labels each component with these.
    var accessibilityLabels: [String] {
        var labels = [title, Self.pinLabel(isPinned), Self.closeLabel]
        labels += description.settings.map(\.title)
        if let form = description.form {
            labels += form.fields.map(\.title) + [form.submitTitle]
        }
        for (index, section) in (description.detail?.sections ?? []).enumerated() {
            labels.append(Self.label(of: section, at: index))
            if content(of: section).copyableText != nil { labels.append(Self.copyLabel(of: section, at: index)) }
        }
        labels += description.actions.map(\.title)
        if isBusy { labels.append(Self.busyLabel) }
        if let error { labels.append(error.message) }
        if let route = repairRoute { labels.append(route.title) }
        if let toast { labels.append(toast) }
        return labels
    }

    static let closeLabel = "Close the view"
    static let busyLabel = "Working"

    static func pinLabel(_ isPinned: Bool) -> String { isPinned ? "Unpin the view" : "Pin the view" }

    static func label(of section: PluginViewSection, at index: Int) -> String {
        section.title ?? "Details \(index + 1)"
    }

    static func copyLabel(of section: PluginViewSection, at index: Int) -> String {
        "Copy \(label(of: section, at: index))"
    }
}

private extension JSONValue {
    func hasSameKind(as other: JSONValue) -> Bool {
        switch (self, other) {
        case (.string, .string), (.bool, .bool): return true
        default: return false
        }
    }
}

/// A window that shows one Plugin View. The Host's is a panel that takes
/// keyboard focus without bringing Spinnet forward; tests use a stand-in.
protocol PluginViewWindow: AnyObject {
    /// The window stopped being the key window, as when the user clicks
    /// another App.
    var onResignKey: (() -> Void)? { get set }
    /// The user closed the window, with Escape or its close button.
    var onUserClose: (() -> Void)? { get set }
    /// The view's title, which the window carries for VoiceOver.
    var title: String { get set }
    /// Shows the window near the pointer, in front and taking keyboard
    /// focus, without activating Spinnet.
    func show(near pointer: NSPoint)
    /// Brings the window to the front and gives it keyboard focus where it
    /// is, without activating Spinnet.
    func focus()
    func close()
}

/// The Host's Plugin View renderer, which also keeps the window rules
/// (ADR 0010): each Plugin has at most one view, presenting again replaces
/// it in place and keeps its pin, views of different Plugins coexist, an
/// unpinned view closes when it loses focus, and a view appears near the
/// pointer and takes keyboard focus without bringing Spinnet forward.
final class PluginViewWindows: PluginViewRenderer {
    private struct Entry {
        let model: PluginViewModel
        let window: PluginViewWindow
        var presentationCount: Int
        var viewRevision: Int
    }

    private let environment: PluginViewEnvironment
    private let makeWindow: (PluginViewModel) -> PluginViewWindow
    private let pointer: () -> NSPoint
    private let frontmostApplication: () -> PluginViewOrigin?
    private let report: (String) -> Void
    private var entries: [PluginID: Entry] = [:]

    /// `report` tells the user why a view closed when the Plugin broke the
    /// interface.
    init(environment: PluginViewEnvironment, makeWindow: @escaping (PluginViewModel) -> PluginViewWindow,
         pointer: @escaping () -> NSPoint, frontmostApplication: @escaping () -> PluginViewOrigin?,
         report: @escaping (String) -> Void) {
        self.environment = environment
        self.makeWindow = makeWindow
        self.pointer = pointer
        self.frontmostApplication = frontmostApplication
        self.report = report
        environment.sections.onChange = { [weak self] session, id in
            guard let entry = self?.entries[session.pluginID], entry.model.session === session else { return }
            entry.model.sectionChanged(id)
        }
    }

    func model(for pluginID: PluginID) -> PluginViewModel? { entries[pluginID]?.model }

    func present(_ presentation: PluginViewPresentation, of session: PluginViewSession) {
        let description: PluginViewDescription
        do {
            description = try PluginViewDescription(parsing: presentation.view,
                                                    settingsFields: environment.settingsFields(session.pluginID))
        } catch {
            // The sessions read every view before it gets here, so this is
            // a Host fault; the view cannot be drawn either way.
            report("\(environment.pluginName(session.pluginID)) — \(session.action.title): \(error)")
            DispatchQueue.main.async { [weak session] in session?.close() }
            return
        }
        let fetched = description.detail?.sections.filter(\.isHostFetched) ?? []
        if var entry = entries[session.pluginID], entry.model.session === session {
            let presentedAnew = session.presentationCount != entry.presentationCount
            let newView = session.viewRevision != entry.viewRevision
            entry.model.update(presentation, description: description, newView: newView,
                               answersTyping: session.answeredEvent?.coalesces ?? false, presentedAnew: presentedAnew)
            entry.window.title = description.title
            if presentedAnew {
                entry.model.origin = frontmostApplication()
                entry.window.focus()
            }
            entry.presentationCount = session.presentationCount
            entry.viewRevision = session.viewRevision
            entries[session.pluginID] = entry
            if newView { environment.sections.sectionsPresented(fetched, in: session) }
            return
        }
        let model = PluginViewModel(session: session, presentation: presentation, description: description,
                                    environment: environment)
        model.origin = frontmostApplication()
        let window = makeWindow(model)
        window.onResignKey = { [weak model] in
            guard let model, !model.isPinned else { return }
            model.close()
        }
        window.onUserClose = { [weak model] in model?.close() }
        entries[session.pluginID] = Entry(model: model, window: window, presentationCount: session.presentationCount,
                                          viewRevision: session.viewRevision)
        environment.sections.sectionsPresented(fetched, in: session)
        window.show(near: pointer())
    }

    func showToast(_ toast: String, in session: PluginViewSession) {
        guard let entry = entries[session.pluginID], entry.model.session === session else { return }
        entry.model.showToast(toast)
    }

    func close(_ session: PluginViewSession, because reason: PluginViewSessionEnd) {
        guard let entry = entries[session.pluginID], entry.model.session === session else { return }
        entries.removeValue(forKey: session.pluginID)
        entry.window.onResignKey = nil
        entry.window.onUserClose = nil
        entry.window.close()
        environment.sections.sessionEnded(session)
        if case .failed(let failure) = reason {
            report("\(environment.pluginName(session.pluginID)) — \(entry.model.title) closed: \(failure.message)")
        }
    }
}
