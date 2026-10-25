import SwiftUI

/// The same destructive confirmation is used in History and Host Settings.
struct ClipboardHistoryClearButton: View {
    let action: () -> Void
    @State private var confirmClear = false

    var body: some View {
        Button("Clear History…") { confirmClear = true }
            .alert("Delete all retained clipboard entries?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Collection and Plugin grants do not change.")
            }
    }
}
