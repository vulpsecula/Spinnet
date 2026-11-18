import AppKit
import SpinnetCore
import SpinnetWindowing
import SwiftUI

/// About's Activation card: the Trial or Activation, and where to enter an
/// Activation Code.
struct ActivationSection: View {
    @ObservedObject var activation: ActivationModel
    let openURL: (URL) -> Bool
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(localized("Activation")).font(.headline).frame(width: 140, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(activation.statusText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(activation.statusText)
                    if case .activated(let code) = activation.state {
                        Text(localized("Serial \(code.displaySerial)"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            if activation.acceptsCode {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(localized("Activation Code"), text: $activation.codeDraft,
                              prompt: Text(verbatim: "SPN1-…"), axis: .vertical) // Not localized: the code format
                        .lineLimit(2...4)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .focused($codeFieldFocused)
                        .onSubmit { activation.activate() }
                        .accessibilityLabel(localized("Activation Code"))
                    if let error = activation.activationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button(localized("Activate")) { activation.activate() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(activation.codeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let url = activation.purchaseURL {
                            Button(localized("Buy Spinnet…")) { _ = openURL(url) }
                        }
                    }
                }
                .padding(.leading, 160)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
        .onAppear { activation.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ActivationModel.focusCodeField)) { _ in
            codeFieldFocused = true
        }
    }
}

extension ActivationModel {
    /// Asks a visible Activation card to focus its code field.
    static let focusCodeField = Notification.Name("com.vulpsecula.Spinnet.activation.focus-code") // Not localized: a notification name
}

/// The reminder an Official Build shows at launch after its Trial, at most
/// once a day. It never blocks: every choice, or closing it, dismisses it.
final class ActivationReminderWindowController: NSWindowController {
    private let activation: ActivationModel
    private let enterCode: () -> Void
    private let openURL: (URL) -> Bool

    init(activation: ActivationModel, enterCode: @escaping () -> Void,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.activation = activation
        self.enterCode = enterCode
        self.openURL = openURL
        let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Spinnet" // Not localized: the app name
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.auxiliary)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ActivationReminderView(
            purchaseURL: activation.purchaseURL,
            buy: { [weak self] url in self?.finish { _ = openURL(url) } },
            enterCode: { [weak self] in self?.finish(enterCode) },
            later: { [weak self] in self?.finish {} }
        ))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("ActivationReminderWindowController is not decoded from a nib")
    }

    /// Shows the reminder if one is due and records it.
    @discardableResult
    func presentIfDue() -> Bool {
        guard activation.isReminderDue else { return false }
        activation.recordReminderShown()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func finish(_ then: () -> Void) {
        close()
        then()
    }
}

private struct ActivationReminderView: View {
    let purchaseURL: URL?
    let buy: (URL) -> Void
    let enterCode: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized("Your Spinnet Trial has ended"))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(localized("Every feature keeps working. If Spinnet is useful to you, an Activation Code supports its development and removes this reminder."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(localized("Later"), action: later).keyboardShortcut(.cancelAction)
                Button(localized("Enter Activation Code…"), action: enterCode)
                if let purchaseURL {
                    Button(localized("Buy Spinnet…")) { buy(purchaseURL) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
