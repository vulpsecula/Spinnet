import AppKit
import SwiftUI
import SpinnetCore

struct ExternalAppConnectionSettings: View {
    @ObservedObject var model: ExternalAppConnectionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Connections").font(.headline)
            ForEach(model.rows) { row in
                ExternalAppConnectionRow(name: row.check.interface.name, status: row.status,
                    connect: { model.connect(row.id) })
            }
            Text("Connect checks the App's read-only interface. It does not start the App or perform an Action.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .onDisappear { model.close() }
    }
}

private struct ExternalAppConnectionRow: View {
    let name: String
    let status: ExternalAppConnectionStatus
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.subheadline.weight(.semibold))
                Spacer()
                if status == .busy {
                    ProgressView().controlSize(.small)
                } else if !status.isConnected {
                    Button("Connect \(name)", action: connect)
                        .disabled(status == .notInstalled || status == .capabilityDenied || status == .ownerInvalid)
                }
            }
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status == .permissionDenied {
                Button("Open Automation Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var message: LocalizedStringResource {
        switch status {
        case .ready: return "Connected"
        case .notRunning: return "Connected. Start \(name) to use its Actions."
        case .notRunningUnchecked: return "Start \(name), then connect to check Automation permission."
        case .notInstalled: return "Install \(name) to connect."
        case .permissionNeeded: return "Connect to allow Spinnet to communicate with \(name)."
        case .permissionDenied: return "Allow Spinnet to control \(name) in macOS Automation settings, then connect again."
        case .capabilityDenied: return "Grant External App access below before connecting."
        case .ownerInvalid: return "This Plugin changed or is unavailable. Close and reopen Plugin Settings."
        case .busy: return "Checking connection…"
        case .failed(let message): return "Connection check failed: \(message)"
        }
    }
}
