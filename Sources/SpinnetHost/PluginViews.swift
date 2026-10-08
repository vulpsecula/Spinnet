import AppKit
import Combine
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
    /// Tells the user of a failure that comes after the view has closed.
    let report: (String) -> Void
    /// The App insertion would go to now, which the views of Plugins
    /// declaring `host_operations` show; nil where no Host tracks it.
    var insertionTargets: InsertionTargetTracker? = nil
    /// Loads the pictures of pages' `image` components (#81); without one
    /// every picture shows as unavailable.
    var images: PluginPageImageProvider? = nil
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
    /// A pinned view stays open when it loses focus and when an action or
    /// operation with `closes_view` succeeds.
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
    /// A Requested Host Operation the view committed has run for a while.
    @Published private(set) var isPerformingOperation = false

    private let environment: PluginViewEnvironment
    private var toastCount = 0
    private(set) var view: JSONValue
    private var targetChanges: AnyCancellable?

    init(session: PluginViewSession, presentation: PluginViewPresentation, description: PluginViewDescription,
         environment: PluginViewEnvironment) {
        self.session = session
        self.description = description
        self.environment = environment
        view = presentation.view
        update(presentation, description: description, newView: true, answersTyping: false, presentedAnew: true)
        if session.showsInsertionTargets {
            targetChanges = environment.insertionTargets?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    // MARK: - Insertion target

    /// Whether this view's insertions follow `host_operations`: the Host
    /// names the App on each insert action and, when the view asks, in a
    /// target line, and inserts only into the App it named.
    var showsInsertionTargets: Bool { session.showsInsertionTargets && environment.insertionTargets != nil }

    /// The App the Host names as where text goes now, or nil for none.
    var insertionTargetName: String? { environment.insertionTargets?.current?.name }

    /// The target line the Host draws when the view asks for it.
    var insertionTargetLine: String? {
        guard showsInsertionTargets, description.showsInsertionTarget else { return nil }
        return insertionTargetName.map { "Inserts into \($0)" } ?? Self.noInsertionTarget
    }

    /// The label an insert action carries beside its title.
    func insertionTargetLabel(of action: PluginViewAction) -> String? {
        guard showsInsertionTargets, case .standard(.insertText, _) = action.kind else { return nil }
        return insertionTargetName.map { "into \($0)" } ?? Self.noInsertionTarget
    }

    static let noInsertionTarget = "No App to insert into"

    /// What the user could see as where text would go when making a gesture:
    /// the App the view names, if it names one.
    private func shownInsertionTarget(namedByTheView names: Bool) -> InsertionTargetCapture {
        guard showsInsertionTargets, names, let targets = environment.insertionTargets else { return .notShown }
        return targets.capture()
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
        isPerformingOperation = presentation.isPerformingOperation
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
        session.send(.submitted(values: .object(values)),
                     insertionTarget: shownInsertionTarget(namedByTheView: description.showsInsertionTarget))
    }

    // MARK: - Actions

    func choose(_ action: PluginViewAction) {
        hostError = nil
        switch action.kind {
        case .event(let id):
            session.send(.actionChosen(id),
                         insertionTarget: shownInsertionTarget(namedByTheView: description.showsInsertionTarget))
        case .standard(let standard, let closesView):
            perform(standard, closingView: closesView)
        }
    }

    /// Opens a link from Detail text, under the `open_url` rules.
    func open(_ url: URL) {
        hostError = nil
        perform(.openURL(url.absoluteString), closingView: false)
    }

    /// Performs a standard action and closes the view if asked once it has
    /// succeeded, unless the user pinned it. Inserted text is typed only after the Host brings its App
    /// forward, which takes the keyboard from this view, so a view that
    /// closes on inserting closes as soon as the insert is under way, and
    /// a later failure is shown in the view if it is still open, or else as
    /// the Host's message.
    private func perform(_ standard: PluginViewStandardAction, closingView: Bool) {
        let finishedAtOnce = FinishedAtOnce()
        // An insert action names its App itself, so pressing it is a
        // gesture made with that App shown.
        var target = PluginViewInsertionTarget.origin(origin)
        if showsInsertionTargets, case .insertText = standard {
            target = .shown(shownInsertionTarget(namedByTheView: true))
        }
        do {
            try environment.hostActions.perform(standard, for: session.action, insertingInto: target) { [weak self] error in
                guard !finishedAtOnce.returned else {
                    self?.finishedLater(error)
                    return
                }
                finishedAtOnce.outcome = .some(error)
            }
        } catch {
            hostError = environment.hostActions.failure(error, for: session.action)
            return
        }
        finishedAtOnce.returned = true
        if case .some(let error?) = finishedAtOnce.outcome {
            hostError = environment.hostActions.failure(error, for: session.action)
            return
        }
        if closingView, !isPinned { session.close() }
    }

    private func finishedLater(_ error: PluginHostServiceError?) {
        guard let error else { return }
        let failure = environment.hostActions.failure(error, for: session.action)
        if session.isEnded {
            environment.report("\(pluginName) — \(session.action.title): \(failure.message)")
        } else {
            hostError = failure
        }
    }

    private final class FinishedAtOnce {
        var returned = false
        var outcome: PluginHostServiceError??
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

    /// The control a swap button after `control` exchanges its value with,
    /// or nil when there is no button there.
    func swapTarget(of control: PluginViewSettingControl) -> PluginViewSettingControl? {
        guard let key = control.swapWith else { return nil }
        return description.settings.first { $0.key == key }
    }

    /// Stores the two settings exchanged, then tells the Plugin of the swap.
    func swapSettings(_ control: PluginViewSettingControl) {
        guard let other = swapTarget(of: control) else { return }
        hostError = nil
        do {
            let event = try environment.hostActions.swapSettings(control.key, other.key, pluginID: session.pluginID)
            objectWillChange.send()
            session.send(event)
        } catch {
            hostError = environment.hostActions.failure(error, for: session.action)
        }
    }

    static func swapLabel(_ control: PluginViewSettingControl, with other: PluginViewSettingControl) -> String {
        "Swap \(control.title) and \(other.title)"
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
        for control in description.settings {
            labels.append(control.title)
            if let other = swapTarget(of: control) { labels.append(Self.swapLabel(control, with: other)) }
        }
        if let form = description.form {
            labels += form.fields.map(\.title) + (form.submitsOnReturn ? [] : [form.submitTitle])
        }
        for (index, section) in (description.detail?.sections ?? []).enumerated() {
            labels.append(Self.label(of: section, at: index))
            if content(of: section).copyableText != nil { labels.append(Self.copyLabel(of: section, at: index)) }
        }
        if let line = insertionTargetLine { labels.append(line) }
        labels += description.actions.map(actionLabel)
        if isBusy { labels.append(Self.busyLabel) }
        if isPerformingOperation { labels.append(Self.operationBusyLabel) }
        if let error { labels.append(error.message) }
        if let route = repairRoute { labels.append(route.title) }
        if let toast { labels.append(toast) }
        return labels
    }

    static let closeLabel = "Close the view"
    static let busyLabel = "Working"
    static let operationBusyLabel = "Performing the request"

    /// What VoiceOver reads for an action: its title, and for an insert
    /// action the App it inserts into.
    func actionLabel(_ action: PluginViewAction) -> String {
        insertionTargetLabel(of: action).map { "\(action.title), \($0)" } ?? action.title
    }

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
    /// The page's declaration that the user may resize the window (#80);
    /// nil, as for every Level 1 view, keeps the Host's default layout.
    var resizing: PluginPageResizing? { get set }
    /// Whether the window floats above other Apps' windows. Only a pinned
    /// view does: macOS's window-capture highlight tints only normal-level
    /// windows, and an unpinned view closes once another App takes focus.
    var floats: Bool { get set }
    /// Where the window is and whether the user chose its size.
    var geometry: PluginPanelGeometry { get }
    /// The user moved or resized the window, or a screen change moved it.
    var onGeometryChange: ((PluginPanelGeometry) -> Void)? { get set }
    /// Shows the window near the pointer, or where `pinned` puts it, in
    /// front and taking keyboard focus, without activating Spinnet.
    func show(near pointer: NSPoint, restoring pinned: PluginPanelGeometry?)
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
        /// The Level 1 view shown, or nil while a page is.
        let model: PluginViewModel?
        /// The page shown (Candidate Contract `collections`), or nil.
        let page: PluginPageModel?
        let window: PluginViewWindow
        var presentationCount: Int
        var viewRevision: Int
        /// Keep the window floating while the view is pinned, and the pin
        /// memory up to date.
        var pinWatch: [AnyCancellable]

        var session: PluginViewSession? { model?.session ?? page?.session }
        var isPinned: Bool { model?.isPinned ?? page?.isPinned ?? false }
    }

    private let environment: PluginViewEnvironment
    private let makeWindow: (PluginViewModel) -> PluginViewWindow
    private let makePageWindow: (PluginPageModel) -> PluginViewWindow
    private let pointer: () -> NSPoint
    private let frontmostApplication: () -> PluginViewOrigin?
    private let report: (String) -> Void
    private let pins: PluginViewPins
    private var entries: [PluginID: Entry] = [:]

    /// `report` tells the user why a view closed when the Plugin broke the
    /// interface.
    init(environment: PluginViewEnvironment, makeWindow: @escaping (PluginViewModel) -> PluginViewWindow,
         makePageWindow: @escaping (PluginPageModel) -> PluginViewWindow = { PluginViewPanelWindow(pageModel: $0) },
         pins: PluginViewPins = PluginViewPins(defaults: nil),
         pointer: @escaping () -> NSPoint, frontmostApplication: @escaping () -> PluginViewOrigin?,
         report: @escaping (String) -> Void) {
        self.environment = environment
        self.makeWindow = makeWindow
        self.makePageWindow = makePageWindow
        self.pointer = pointer
        self.frontmostApplication = frontmostApplication
        self.report = report
        self.pins = pins
        environment.sections.onChange = { [weak self] session, id in
            guard let entry = self?.entries[session.pluginID], entry.session === session else { return }
            entry.model?.sectionChanged(id)
        }
        environment.images?.onChange = { [weak self] pluginID in
            self?.entries[pluginID]?.page?.imagesChanged()
        }
    }

    func model(for pluginID: PluginID) -> PluginViewModel? { entries[pluginID]?.model }

    /// The page shown for the Plugin, under Candidate Contract `collections`.
    func pageModel(for pluginID: PluginID) -> PluginPageModel? { entries[pluginID]?.page }

    func present(_ presentation: PluginViewPresentation, of session: PluginViewSession) {
        if let page = presentation.page { return present(page, presentation, of: session) }
        // A page gave way to a Level 1 view: the page's window goes, and the
        // view gets a window of its own, keeping the pin and, pinned, its
        // place.
        var replaced: (isPinned: Bool, geometry: PluginPanelGeometry)?
        if let entry = entries[session.pluginID], entry.session === session, entry.page != nil {
            replaced = (entry.isPinned, entry.window.geometry)
            closeWindow(of: session)
            environment.images?.imagesPresented([], in: session)
        }
        let description: PluginViewDescription
        do {
            description = try PluginViewDescription(parsing: presentation.view,
                                                    settingsFields: environment.settingsFields(session.pluginID),
                                                    permits: session.permits)
        } catch {
            // The sessions read every view before it gets here, so this is
            // a Host fault; the view cannot be drawn either way.
            report("\(environment.pluginName(session.pluginID)) — \(session.action.title): \(error)")
            DispatchQueue.main.async { [weak session] in session?.close() }
            return
        }
        let fetched = description.detail?.sections.filter(\.isHostFetched) ?? []
        if var entry = entries[session.pluginID], let model = entry.model, model.session === session {
            let presentedAnew = session.presentationCount != entry.presentationCount
            let newView = session.viewRevision != entry.viewRevision
            model.update(presentation, description: description, newView: newView,
                         answersTyping: session.answeredEvent?.coalesces ?? false, presentedAnew: presentedAnew)
            entry.window.title = description.title
            if presentedAnew {
                model.origin = frontmostApplication()
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
        let opening = opening(session.pluginID, replacing: replaced)
        model.isPinned = opening.isPinned
        let window = makeWindow(model)
        window.onResignKey = { [weak model] in
            guard let model, !model.isPinned else { return }
            model.close()
        }
        window.onUserClose = { [weak model] in model?.close() }
        let pinWatch = watchPin(model.$isPinned, of: window, for: session.pluginID) { [weak model] in
            model?.isPinned ?? false
        }
        entries[session.pluginID] = Entry(model: model, page: nil, window: window,
                                          presentationCount: session.presentationCount, viewRevision: session.viewRevision,
                                          pinWatch: pinWatch)
        environment.sections.sectionsPresented(fetched, in: session)
        show(window, for: session.pluginID, opening)
    }

    /// Shows a page, or updates the page shown in place.
    private func present(_ page: PluginPage, _ presentation: PluginViewPresentation, of session: PluginViewSession) {
        var replaced: (isPinned: Bool, geometry: PluginPanelGeometry)?
        if var entry = entries[session.pluginID], entry.session === session {
            if let model = entry.page {
                let presentedAnew = session.presentationCount != entry.presentationCount
                let newView = session.viewRevision != entry.viewRevision
                model.update(presentation, page: page, newView: newView, presentedAnew: presentedAnew)
                if newView { environment.images?.imagesPresented(page.imageRequests, in: session) }
                entry.window.title = page.title
                entry.window.resizing = page.resizing
                if presentedAnew { entry.window.focus() }
                entry.presentationCount = session.presentationCount
                entry.viewRevision = session.viewRevision
                entries[session.pluginID] = entry
                return
            }
            // A Level 1 view gave way to a page.
            replaced = (entry.isPinned, entry.window.geometry)
            closeWindow(of: session)
        }
        let model = PluginPageModel(session: session, presentation: presentation, page: page, environment: environment)
        let opening = opening(session.pluginID, replacing: replaced)
        model.isPinned = opening.isPinned
        let window = makePageWindow(model)
        window.title = page.title
        window.resizing = page.resizing
        window.onResignKey = { [weak model] in
            guard let model, !model.isPinned else { return }
            model.close()
        }
        window.onUserClose = { [weak model] in model?.close() }
        let pinWatch = watchPin(model.$isPinned, of: window, for: session.pluginID) { [weak model] in
            model?.isPinned ?? false
        }
        entries[session.pluginID] = Entry(model: nil, page: model, window: window,
                                          presentationCount: session.presentationCount, viewRevision: session.viewRevision,
                                          pinWatch: pinWatch)
        environment.images?.imagesPresented(page.imageRequests, in: session)
        show(window, for: session.pluginID, opening)
    }

    /// How a new window opens (ADR 0016): with the pin, and the place, of
    /// the window it replaces in the same session; otherwise with the
    /// Plugin's remembered Pin, where the pinned panel last was, or, not
    /// pinned, beside the pointer.
    private func opening(_ pluginID: PluginID, replacing replaced: (isPinned: Bool, geometry: PluginPanelGeometry)?)
        -> (isPinned: Bool, restoring: PluginPanelGeometry?) {
        if let replaced { return (replaced.isPinned, replaced.isPinned ? replaced.geometry : nil) }
        let isPinned = pins.isPinned(pluginID)
        return (isPinned, isPinned ? pins.geometry(for: pluginID) : nil)
    }

    private func show(_ window: PluginViewWindow, for pluginID: PluginID,
                      _ opening: (isPinned: Bool, restoring: PluginPanelGeometry?)) {
        window.show(near: pointer(), restoring: opening.restoring)
        if opening.isPinned { pins.remember(window.geometry, for: pluginID) }
    }

    /// Floats the window while pinned, and remembers the Pin when the user
    /// changes it and the pinned window's geometry as it changes.
    private func watchPin(_ pin: Published<Bool>.Publisher, of window: PluginViewWindow, for pluginID: PluginID,
                          isPinned: @escaping () -> Bool) -> [AnyCancellable] {
        let pins = pins
        window.onGeometryChange = { geometry in
            if isPinned() { pins.remember(geometry, for: pluginID) }
        }
        return [
            pin.sink { [weak window] in window?.floats = $0 },
            pin.dropFirst().removeDuplicates().sink { [weak window] pinned in
                pins.setPinned(pinned, for: pluginID)
                if pinned, let window { pins.remember(window.geometry, for: pluginID) }
            }
        ]
    }

    /// Removes the window shown for `session` without ending it.
    private func closeWindow(of session: PluginViewSession) {
        guard let entry = entries.removeValue(forKey: session.pluginID) else { return }
        entry.window.onResignKey = nil
        entry.window.onUserClose = nil
        entry.window.onGeometryChange = nil
        entry.window.close()
    }

    /// The user called the Plugin again while its view is open: the window
    /// comes to the front where it is and takes the keyboard, keeping its
    /// pin and what the user is doing in it.
    func bringForward(_ session: PluginViewSession) {
        guard let entry = entries[session.pluginID], entry.session === session else { return }
        entry.window.focus()
    }

    func isPinned(_ session: PluginViewSession) -> Bool {
        guard let entry = entries[session.pluginID], entry.session === session else { return false }
        return entry.isPinned
    }

    func showToast(_ toast: String, in session: PluginViewSession) {
        guard let entry = entries[session.pluginID], entry.session === session else { return }
        entry.model?.showToast(toast)
        entry.page?.showToast(toast)
    }

    func close(_ session: PluginViewSession, because reason: PluginViewSessionEnd) {
        guard let entry = entries[session.pluginID], entry.session === session else { return }
        entries.removeValue(forKey: session.pluginID)
        entry.window.onResignKey = nil
        entry.window.onUserClose = nil
        entry.window.onGeometryChange = nil
        entry.window.close()
        environment.sections.sessionEnded(session)
        environment.images?.sessionEnded(session)
        if case .failed(let failure) = reason {
            let title = entry.model?.title ?? entry.page?.title ?? session.action.title
            report("\(environment.pluginName(session.pluginID)) — \(title) closed: \(failure.message)")
        }
    }
}
