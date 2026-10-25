import SwiftUI

struct HostBackgroundOperationsPermissionView: View {
    let status: HostBackgroundOperationsStatus
    let error: String?
    let manage: () -> Void

    private var statusLabel: LocalizedStringKey {
        switch status {
        case .notEnabled: return "Not enabled"
        case .approvalRequired: return "Approval required"
        case .enabled: return "Enabled for Spinnet"
        case .unavailable: return "macOS background activity status is unavailable"
        }
    }
    private var actionTitle: LocalizedStringKey {
        switch status {
        case .notEnabled: return "Enable for Spinnet…"
        case .approvalRequired: return "Approve Spinnet…"
        case .enabled: return "Open Login Items…"
        case .unavailable: return "Check Again"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "gearshape.2").font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text("Spinnet Background Operations").font(.headline)
                Text("Allows Spinnet to perform system changes for Tasks you confirm. macOS may also ask for administrator approval for a specific operation.")
                    .foregroundStyle(.secondary)
                Text(statusLabel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                if status == .approvalRequired {
                    Text("Allow Spinnet in macOS Login Items & Extensions, then return here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            Button(actionTitle, action: manage).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spinnet Background Operations")
    }
}
