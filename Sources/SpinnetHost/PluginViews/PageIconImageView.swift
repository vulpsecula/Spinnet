import AppKit
import SpinnetCore

/// A View Page's display-only icon, shared by Collection cells and icon components.
final class PageIconImageView: NSImageView {
    private struct Request: Equatable {
        let bundleIdentifier: String
        let pixelSide: Int
    }

    private static let appIcons = CurrentAppIcons(capacity: 256)
    private var request: Request?
    private var appImage: NSImage?

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyDown
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ source: PluginPageIconSource?, side: CGFloat, tint: NSColor,
              symbolConfiguration: NSImage.SymbolConfiguration) {
        let symbol: String?
        let next: Request?
        switch source {
        case .app(let bundleIdentifier, let fallback):
            symbol = fallback
            next = Request(bundleIdentifier: bundleIdentifier, pixelSide: max(1, min(256, Int((side * 2).rounded(.up)))))
        case .symbol(let name):
            symbol = name
            next = nil
        case nil:
            symbol = nil
            next = nil
        }
        if request != next {
            request = next
            appImage = nil
            if let next {
                let cached = Self.appIcons.icon(forBundleIdentifier: next.bundleIdentifier, pixelSide: next.pixelSide) { [weak self] loaded in
                    guard let self, self.request == next else { return }
                    self.appImage = loaded
                    self.image = loaded
                    self.contentTintColor = nil
                }
                if let cached { appImage = cached }
            }
        }
        self.symbolConfiguration = symbolConfiguration
        contentTintColor = appImage == nil ? tint : nil
        image = appImage ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }
}
