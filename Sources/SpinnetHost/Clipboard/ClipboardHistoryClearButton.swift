import SwiftUI

/// The same destructive confirmation is used in History and Host Settings.
struct ClipboardHistoryClearButton: View {
    let action: () -> Void
    @State private var confirmClear = false

    var body: some View {
        Button(localized("Clear History…")) { confirmClear = true }
            .alert(localized("Delete all retained clipboard entries?"), isPresented: $confirmClear) {
                Button(localized("Clear History"), role: .destructive, action: action)
                Button(localized("Cancel"), role: .cancel) {}
            } message: {
                Text(localized("This cannot be undone. Collection and Plugin grants do not change."))
            }
    }
}
