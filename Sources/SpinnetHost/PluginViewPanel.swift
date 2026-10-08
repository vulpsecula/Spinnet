import AppKit
import SpinnetCore
import SwiftUI

/// What the panel asks of its SwiftUI content: to leave the window's size
/// alone, and to run under the transparent title bar.
private protocol HostingSizing {
    func stopSizingWindow()
}

extension NSHostingController: HostingSizing {
    func stopSizingWindow() {
        // No size constraints of the hosting view's own: with any, AppKit
        // pins the window to the content and fights a size the user chose.
        // The content reports its size (`PluginPanelFill`) and
        // `PluginPanelLayout` decides.
        sizingOptions = []
        // The view draws its own header, so the content runs under the
        // transparent title bar instead of leaving an empty band above it.
        if #available(macOS 13.3, *) { safeAreaRegions = [] }
    }
}

/// Whether the panel's content fills the panel (a user-sized panel) or sets
/// its size (a panel following its content), and how it reports that size.
final class PluginPanelFill: ObservableObject {
    @Published var fillsPanel = false
    /// The content's own size, reported while it does not fill the panel.
    var onContentSize: ((NSSize) -> Void)?
    /// The smallest height the content can be drawn in without losing what
    /// lies outside its scrolling region (#80).
    var onMinimumHeight: ((CGFloat) -> Void)?
}

/// The smallest height a page can be drawn in: everything outside its
/// scrolling region, and the least of that region.
struct PluginPanelMinimumHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PluginPanelFillsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the content is in a panel the user sized: it fills the
    /// panel and its scrolling region takes the height left.
    var pluginPanelFills: Bool {
        get { self[PluginPanelFillsKey.self] }
        set { self[PluginPanelFillsKey.self] = newValue }
    }
}

/// The root of a panel's SwiftUI content, telling it whether it fills.
private struct PluginPanelRoot<Content: View>: View {
    @ObservedObject var fill: PluginPanelFill
    let content: Content

    var body: some View {
        // One structure either way, so filling keeps the content's identity
        // and state. Not filling, it is at its own size, measured for the
        // panel to follow.
        let fills = fill.fillsPanel
        content
            .environment(\.pluginPanelFills, fills)
            .fixedSize(horizontal: !fills, vertical: !fills)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { report(proxy.size) }
                    .onChange(of: proxy.size) { report($0) }
            })
            .onPreferenceChange(PluginPanelMinimumHeightKey.self) { height in
                if height > 0 { fill.onMinimumHeight?(height) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func report(_ size: CGSize) {
        if !fill.fillsPanel { fill.onContentSize?(size) }
    }
}

/// A panel that takes typing without activating Spinnet, so the App the
/// user was in stays frontmost behind it and inserted text can go there.
private final class PluginViewNSPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The Host's window for one Plugin View: a non-activating panel near the
/// pointer that grows downwards as its content does and stays on screen.
/// Pinned, it floats. A page that declares it may be resized (#80) lets the
/// user resize the panel, pinned or not; from then on its size is the
/// user's (`PluginPanelLayout`) and its content fills it.
final class PluginViewPanelWindow: NSObject, PluginViewWindow, NSWindowDelegate {
    /// Space between the pointer and the panel's top edge.
    static let pointerGap = PluginPanelLayout.pointerGap
    /// Space kept between the panel and the screen's edges.
    static let screenMargin = PluginPanelLayout.screenMargin
    static let width: CGFloat = 440

    var onResignKey: (() -> Void)?
    var onUserClose: (() -> Void)?
    var onGeometryChange: ((PluginPanelGeometry) -> Void)?
    /// Where the screens are: AppKit's, unless a test gives its own.
    var screens: () -> [PluginPanelScreen] = PluginPanelScreen.current
    private let panel: PluginViewNSPanel
    private let hosting: NSViewController & HostingSizing
    private let fill: PluginPanelFill
    private var layout: PluginPanelLayout?
    /// True while the panel applies `layout` itself, so the moves and
    /// resizes that causes are not taken for the user's.
    private var isApplying = false
    private var isClosing = false
    private var screenWatch: NSObjectProtocol?
    /// The size the content last reported at its own size.
    private var contentSize: NSSize?
    /// The smallest height the content reported it can be drawn in.
    private var contentMinimumHeight: CGFloat = 0

    convenience init(model: PluginViewModel) {
        let fill = PluginPanelFill()
        self.init(content: NSHostingController(rootView: PluginPanelRoot(fill: fill,
                                                                         content: PluginViewContent(model: model))),
                  fill: fill, title: model.title)
    }

    /// The window of a page (Plugin API Level 2).
    convenience init(pageModel: PluginPageModel) {
        let fill = PluginPanelFill()
        self.init(content: NSHostingController(rootView: PluginPanelRoot(fill: fill,
                                                                         content: PluginPageContent(model: pageModel))),
                  fill: fill, title: pageModel.title)
    }

    private init(content hosting: NSViewController & HostingSizing, fill: PluginPanelFill, title: String) {
        panel = PluginViewNSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
                                  styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        self.hosting = hosting
        self.fill = fill
        super.init()
        hosting.stopSizingWindow()
        hosting.view.autoresizingMask = [.width, .height]
        panel.contentView = hosting.view
        panel.contentMinSize = PluginPanelLayout.minimumSize
        // The content's size reaches the panel through `PluginPanelLayout`,
        // which follows it until the size is the user's. The change is taken
        // after the layout pass that reported it.
        fill.onContentSize = { [weak self] size in
            guard size.width > 0, size.height > 0 else { return }
            self?.contentSize = size
            DispatchQueue.main.async { self?.contentSizeChanged(to: size) }
        }
        fill.onMinimumHeight = { [weak self] height in
            DispatchQueue.main.async { self?.contentMinimumHeightChanged(to: height) }
        }
        hosting.view.layoutSubtreeIfNeeded()
        if let contentSize { panel.setContentSize(contentSize) }
        // Restart opens no view: AppKit's window restoration must not bring
        // a panel back either.
        panel.isRestorable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        // Normal level until pinned (`floats`).
        panel.level = .normal
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = .singleDesktop
        // The view draws its own close and pin buttons in its header.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        self.title = title
        panel.onCancel = { [weak self] in self?.userClosed() }
        panel.delegate = self
        screenWatch = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
    }

    deinit {
        if let screenWatch { NotificationCenter.default.removeObserver(screenWatch) }
    }

    /// Pinned: floats above other Apps' windows. Pinning and unpinning
    /// leave the size alone.
    var floats: Bool {
        get { panel.isFloatingPanel }
        set {
            panel.isFloatingPanel = newValue
            panel.level = newValue ? .floating : .normal
        }
    }

    /// The page's declaration that the user may resize the panel, and how
    /// small; nil keeps the Host's default layout, so a panel the user had
    /// sized follows its content again.
    var resizing: PluginPageResizing? {
        didSet {
            guard resizing != oldValue else { return }
            if resizing != nil {
                panel.styleMask.insert(.resizable)
                minimumSizeChanged()
            } else {
                panel.contentMinSize = minimumSize
                panel.styleMask.remove(.resizable)
                if layout?.followsContent == false, let contentSize {
                    let screens = screens()
                    change(reports: true) { $0.followContent(of: contentSize, screens: screens) }
                }
            }
        }
    }

    /// The smallest size the user may give the panel: what the page
    /// declares, and never less than its content needs.
    private var minimumSize: NSSize {
        guard let resizing else { return PluginPanelLayout.minimumSize }
        return NSSize(width: max(resizing.minimumWidth, PluginPanelLayout.minimumSize.width),
                      height: max(resizing.minimumHeight, PluginPanelLayout.minimumSize.height, contentMinimumHeight))
    }

    private func contentMinimumHeightChanged(to height: CGFloat) {
        guard !isClosing, height != contentMinimumHeight else { return }
        contentMinimumHeight = height
        if resizing != nil { minimumSizeChanged() }
    }

    /// AppKit keeps live resizing above the minimum, and a size the user
    /// chose below a larger minimum grows from its top.
    private func minimumSizeChanged() {
        let minimumSize = minimumSize
        panel.contentMinSize = minimumSize
        if let layout, !layout.followsContent,
           layout.frame.width < minimumSize.width || layout.frame.height < minimumSize.height {
            let frame = layout.frame
            change(reports: true) { $0.userResized(to: frame, minimumSize: minimumSize) }
        }
    }

    var geometry: PluginPanelGeometry {
        layout?.geometry ?? PluginPanelGeometry(frame: panel.frame, isUserSized: false)
    }

    var title: String {
        get { panel.title }
        set {
            panel.title = newValue
            panel.setAccessibilityLabel(newValue)
        }
    }

    /// A remembered size comes back only for a page that may be resized;
    /// any other opens at its content's size where the pinned panel was.
    func show(near pointer: NSPoint, restoring pinned: PluginPanelGeometry? = nil) {
        hosting.view.layoutSubtreeIfNeeded()
        let restoring = resizing == nil ? pinned.map { PluginPanelGeometry(frame: $0.frame, isUserSized: false) } : pinned
        apply(PluginPanelLayout.opening(contentSize: contentSize ?? panel.frame.size, pointer: pointer, screens: screens(),
                                        restoring: restoring, minimumSize: minimumSize))
        bringForward()
    }

    func focus() {
        bringForward()
    }

    /// Key without activating: the panel is non-activating, so Spinnet does
    /// not come forward and the user's App keeps its focus state. Unpinned,
    /// the panel is at the normal level, where ordering a window of an App
    /// that is not active leaves it behind the active App's windows, so it
    /// is ordered front regardless.
    private func bringForward() {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        panel.delegate = nil
        panel.close()
    }

    private func userClosed() {
        onUserClose?()
    }

    /// Centred under the pointer, its top just below it, and always inside
    /// the screen's visible frame.
    static func topLeft(for size: NSSize, near pointer: NSPoint, within visible: NSRect) -> NSPoint {
        PluginPanelLayout.besidePointer(size: size, pointer: pointer, visible: visible)
    }

    /// Puts the panel where `layout` says, and lets the content set the size
    /// or fill the panel accordingly.
    private func apply(_ newLayout: PluginPanelLayout) {
        // A panel starts out following its content.
        let followed = layout?.followsContent ?? true
        layout = newLayout
        if followed != newLayout.followsContent {
            fill.fillsPanel = !newLayout.followsContent
        }
        guard panel.frame != newLayout.frame else { return }
        isApplying = true
        panel.setFrame(newLayout.frame, display: true)
        isApplying = false
    }

    /// Following its content, the panel keeps its top and stays on screen
    /// as the view grows; a size the user chose is left alone.
    private func contentSizeChanged(to size: NSSize) {
        guard !isClosing, !panel.inLiveResize, size.width > 0, size.height > 0 else { return }
        let screens = screens()
        change(reports: false) { $0.contentSizeChanged(to: size, screens: screens) }
    }

    private func change(reports: Bool, _ update: (inout PluginPanelLayout) -> Void) {
        guard var changed = layout else { return }
        update(&changed)
        apply(changed)
        if reports { onGeometryChange?(changed.geometry) }
    }

    private func screensChanged() {
        let screens = screens()
        change(reports: true) { $0.screensChanged(screens) }
    }

    // MARK: - NSWindowDelegate

    /// Each step of a drag stays at or above the minimum, so the panel
    /// never shrinks past it only to spring back on release. AppKit's own
    /// `contentMinSize` cannot be relied on: the SwiftUI hosting view that
    /// is the panel's content view resets it.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        liveResizeProposal(frameSize)
    }

    /// The size a drag's step to `frameSize` is given.
    func liveResizeProposal(_ frameSize: NSSize) -> NSSize {
        let minimumSize = minimumSize
        return NSSize(width: max(frameSize.width, minimumSize.width), height: max(frameSize.height, minimumSize.height))
    }

    /// The size is the user's from the moment they take an edge.
    func windowWillStartLiveResize(_ notification: Notification) {
        change(reports: false) { $0.userBeganResizing() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let frame = panel.frame, minimumSize = minimumSize
        change(reports: true) { $0.userResized(to: frame, minimumSize: minimumSize) }
    }

    /// The user may drag the view; it then grows from where they left it.
    func windowDidMove(_ notification: Notification) {
        guard !isApplying, !panel.inLiveResize else { return }
        let frame = panel.frame
        change(reports: true) { $0.moved(to: frame) }
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        userClosed()
        return false
    }

    var presentationSnapshot: (isVisible: Bool, isKey: Bool, frame: NSRect, becomesKeyOnlyIfNeeded: Bool,
                               isNonActivating: Bool) {
        (panel.isVisible, panel.isKeyWindow, panel.frame, panel.becomesKeyOnlyIfNeeded,
         panel.styleMask.contains(.nonactivatingPanel))
    }

    /// The panel's AppKit configuration, which Pin and the page's
    /// declaration change.
    var panelSnapshot: (level: NSWindow.Level, isFloating: Bool, isResizable: Bool, minimumSize: NSSize,
                        canBecomeKey: Bool, canBecomeMain: Bool, hidesOnDeactivate: Bool, isRestorable: Bool,
                        fills: Bool) {
        (panel.level, panel.isFloatingPanel, panel.styleMask.contains(.resizable), minimumSize,
         panel.canBecomeKey, panel.canBecomeMain, panel.hidesOnDeactivate, panel.isRestorable, fill.fillsPanel)
    }

    /// Resizes the panel as the user's drag of an edge does, for tests:
    /// AppKit's live resize cannot be driven without a real drag.
    func simulateUserResize(to frame: NSRect) {
        windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification))
        isApplying = true
        panel.setFrame(frame, display: true)
        isApplying = false
        windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
    }

    /// Reacts as to `didChangeScreenParametersNotification`, for tests.
    func simulateScreenChange() { screensChanged() }

    var contentView: NSView? { panel.contentView }
}
